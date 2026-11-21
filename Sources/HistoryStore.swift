import Foundation
import SQLite3

// Durable per-file journal. Only metadata and paths are saved; no media bytes enter the database.
struct FileIdentity: Equatable {
    let volume: String
    let inode: String
    let size: Int64
    let modification: Double

    static func capture(_ url: URL) throws -> FileIdentity {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
            throw HistoryError.unsafe("일반 파일이 아니거나 심볼릭 링크입니다: \(url.lastPathComponent)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw HistoryError.unsafe("파일 동일성 정보를 읽지 못했습니다: \(url.lastPathComponent)")
        }
        return FileIdentity(volume: volume.stringValue, inode: inode.stringValue,
                            size: size.int64Value, modification: modified.timeIntervalSince1970)
    }
    func matches(_ url: URL) -> Bool {
        guard let now = try? Self.capture(url) else { return false }
        return volume == now.volume && inode == now.inode && size == now.size
            && abs(modification - now.modification) <= 0.002
    }
}

struct HistoryJob: Identifiable {
    let id: String
    let mode: String
    let started: Date
    let finished: Date?
    let state: String
    let completedCount: Int
    let restoredCount: Int
    let pendingCount: Int
}

struct HistoryItem: Identifiable {
    let id: String
    let jobID: String
    let source: String
    let output: String
    let state: String
    let message: String
}

struct HistoryPair {
    let original: URL
    let produced: URL
    let identity: FileIdentity?
}

enum HistoryError: LocalizedError {
    case sqlite(String), unsafe(String)
    var errorDescription: String? {
        switch self {
        case .sqlite(let s): return "작업 이력 DB 오류: " + s
        case .unsafe(let s): return s
        }
    }
}

final class HistoryStore {
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    let databaseURL: URL
    private let manager = FileManager.default

    init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/00CaptureDate", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databaseURL = dir.appendingPathComponent("history.sqlite3")
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "DB 열기 실패"
            if let db { sqlite3_close(db) }
            db = nil
            throw HistoryError.sqlite(message)
        }
        do {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA synchronous=FULL;")
            try exec("PRAGMA foreign_keys=ON;")
            try exec("PRAGMA busy_timeout=5000;")
            try exec("""
              CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, mode TEXT NOT NULL, started REAL NOT NULL,
                finished REAL, state TEXT NOT NULL, log_path TEXT NOT NULL DEFAULT ''
              );
              CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
                original TEXT NOT NULL, produced TEXT NOT NULL, state TEXT NOT NULL,
                message TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
                finished REAL
              );
              CREATE INDEX IF NOT EXISTS items_job ON items(job_id, created);
              CREATE TABLE IF NOT EXISTS pairs (
                item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                position INTEGER NOT NULL, original TEXT NOT NULL, produced TEXT NOT NULL,
                volume TEXT, inode TEXT, size INTEGER, modification REAL,
                PRIMARY KEY(item_id, position)
              );
              """)
            // Interrupted runs never silently become successful or automatically reverted.
            try exec("UPDATE jobs SET state='interrupted', finished=COALESCE(finished,started) WHERE state='running';")
        } catch {
            if let db { sqlite3_close(db) }
            self.db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func errorMessage() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "DB 연결 해제" }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.sqlite(errorMessage()) }
    }
    private enum Value { case text(String), integer(Int64), real(Double), null }
    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HistoryError.sqlite(errorMessage())
        }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let v): result = v.withCString { sqlite3_bind_text(stmt, i, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let v): result = sqlite3_bind_int64(stmt, i, v)
            case .real(let v): result = sqlite3_bind_double(stmt, i, v)
            case .null: result = sqlite3_bind_null(stmt, i)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(stmt); throw HistoryError.sqlite(errorMessage()) }
        }
        return stmt
    }
    private func update(_ sql: String, _ values: [Value]) throws {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryError.sqlite(errorMessage()) }
    }
    private func transaction(_ operation: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do { try operation(); try exec("COMMIT;") }
        catch { try? exec("ROLLBACK;"); throw error }
    }
    private func text(_ row: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(row, index) else { return "" }
        return String(cString: ptr)
    }
    private func boolExists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    func beginJob(mode: WorkMode, logURL: URL) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString
        try update("INSERT INTO jobs(id,mode,started,state,log_path) VALUES (?,?,?,'running',?)",
                   [.text(id), .text(mode.rawValue), .real(Date().timeIntervalSince1970), .text(logURL.path)])
        return id
    }

    // This journal entry is synced BEFORE the rename/copy operation starts.
    func prepareItem(jobID: String, plan: WorkPlan, mode: WorkMode) throws -> String {
        let id = UUID().uuidString
        let all = [(from: plan.entry.url, to: plan.output)] + plan.companions
        let identities: [FileIdentity?] = try all.map { pair in
            mode == .rename ? try FileIdentity.capture(pair.from) : nil
        }
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try update("INSERT INTO items(id,job_id,original,produced,state,created) VALUES(?,?,?,?,'pending',?)",
                       [.text(id), .text(jobID), .text(plan.entry.url.path), .text(plan.output.path), .real(Date().timeIntervalSince1970)])
            for (n, pair) in all.enumerated() {
                let key = identities[n]
                try update("INSERT INTO pairs(item_id,position,original,produced,volume,inode,size,modification) VALUES(?,?,?,?,?,?,?,?)", [
                    .text(id), .integer(Int64(n)), .text(pair.from.path), .text(pair.to.path),
                    key.map { .text($0.volume) } ?? .null, key.map { .text($0.inode) } ?? .null,
                    key.map { .integer($0.size) } ?? .null, key.map { .real($0.modification) } ?? .null
                ])
            }
        }
        return id
    }

    func markSuccess(_ itemID: String, plan: WorkPlan) throws {
        let all = [(from: plan.entry.url, to: plan.output)] + plan.companions
        let outputKeys = try all.map { try FileIdentity.capture($0.to) }
        lock.lock(); defer { lock.unlock() }
        try transaction {
            for (index, identity) in outputKeys.enumerated() {
                try update("UPDATE pairs SET volume=?,inode=?,size=?,modification=? WHERE item_id=? AND position=?", [
                    .text(identity.volume), .text(identity.inode), .integer(identity.size),
                    .real(identity.modification), .text(itemID), .integer(Int64(index))
                ])
            }
            try update("UPDATE items SET state='success', message='', finished=? WHERE id=? AND state='pending'",
                       [.real(Date().timeIntervalSince1970), .text(itemID)])
        }
    }
    func markFailure(_ itemID: String, _ message: String) throws {
        lock.lock(); defer { lock.unlock() }
        try update("UPDATE items SET state='failed', message=?, finished=? WHERE id=? AND state='pending'",
                   [.text(message), .real(Date().timeIntervalSince1970), .text(itemID)])
    }
    func finishJob(_ id: String, interrupted: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try update("UPDATE jobs SET state=?, finished=? WHERE id=?",
                   [.text(interrupted ? "interrupted" : "finished"), .real(Date().timeIntervalSince1970), .text(id)])
    }
    func jobs(limit: Int = 100) throws -> [HistoryJob] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("""
            SELECT j.id,j.mode,j.started,j.finished,j.state,
              SUM(CASE WHEN i.state='success' THEN 1 ELSE 0 END),
              SUM(CASE WHEN i.state='restored' THEN 1 ELSE 0 END),
              SUM(CASE WHEN i.state IN ('pending','restoring','needs_review') THEN 1 ELSE 0 END)
            FROM jobs j LEFT JOIN items i ON i.job_id=j.id
            GROUP BY j.id ORDER BY j.started DESC LIMIT ?
            """, [.integer(Int64(max(1, limit)))])
        defer { sqlite3_finalize(stmt) }
        var result: [HistoryJob] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(HistoryJob(id: text(stmt, 0), mode: text(stmt, 1),
                                     started: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                     finished: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                                     state: text(stmt, 4), completedCount: Int(sqlite3_column_int64(stmt, 5)),
                                     restoredCount: Int(sqlite3_column_int64(stmt, 6)), pendingCount: Int(sqlite3_column_int64(stmt, 7))))
        }
        return result
    }
    func items(jobID: String, limit: Int = 200, offset: Int = 0) throws -> [HistoryItem] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("SELECT id,job_id,original,produced,state,message FROM items WHERE job_id=? ORDER BY created,id LIMIT ? OFFSET ?",
                                 [.text(jobID), .integer(Int64(limit)), .integer(Int64(offset))])
        defer { sqlite3_finalize(stmt) }
        var result: [HistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(HistoryItem(id: text(stmt, 0), jobID: text(stmt, 1), source: text(stmt, 2),
                                      output: text(stmt, 3), state: text(stmt, 4), message: text(stmt, 5)))
        }
        return result
    }
    func itemCount(jobID: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement("SELECT COUNT(*) FROM items WHERE job_id=?", [.text(jobID)])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func restorePairs(itemID: String) throws -> (mode: String, state: String, pairs: [HistoryPair]) {
        let item = try statement("""
            SELECT j.mode, i.state FROM items i JOIN jobs j ON j.id=i.job_id WHERE i.id=?
            """, [.text(itemID)])
        let found = sqlite3_step(item) == SQLITE_ROW
        let mode = found ? text(item, 0) : ""
        let state = found ? text(item, 1) : ""
        sqlite3_finalize(item)
        guard found else { throw HistoryError.unsafe("작업 기록이 존재하지 않습니다") }
        guard state == "success" else { throw HistoryError.unsafe("복원 가능 상태가 아닙니다: \(state)") }
        let stmt = try statement("SELECT original,produced,volume,inode,size,modification FROM pairs WHERE item_id=? ORDER BY position DESC", [.text(itemID)])
        defer { sqlite3_finalize(stmt) }
        var pairs: [HistoryPair] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let identity: FileIdentity? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : FileIdentity(
                volume: text(stmt, 2), inode: text(stmt, 3), size: sqlite3_column_int64(stmt, 4),
                modification: sqlite3_column_double(stmt, 5))
            pairs.append(HistoryPair(original: URL(fileURLWithPath: text(stmt, 0)),
                                     produced: URL(fileURLWithPath: text(stmt, 1)), identity: identity))
        }
        guard !pairs.isEmpty else { throw HistoryError.unsafe("파일 복원 정보가 없습니다") }
        return (mode, state, pairs)
    }

    // Rename-only reversal. Copy mode: rename the created COPY at its destination to its old basename.
    // No originals or other files are deleted, and all paired sidecars are checked first.
    func restoreItem(_ itemID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let record = try restorePairs(itemID: itemID)
        let mode = record.mode
        var moves: [(from: URL, to: URL)] = []
        for pair in record.pairs {
            guard let identity = pair.identity, identity.matches(pair.produced) else {
                throw HistoryError.unsafe("파일이 이동·수정·교체되었거나 동일성을 확인할 수 없어 복원하지 않습니다: \(pair.produced.lastPathComponent)")
            }
            let target = mode == WorkMode.copy.rawValue
                ? pair.produced.deletingLastPathComponent().appendingPathComponent(pair.original.lastPathComponent)
                : pair.original
            guard !boolExists(target) else { throw HistoryError.unsafe("원본 파일명이 이미 존재해 건너뜁니다: \(target.path)") }
            guard !moves.contains(where: { $0.to.standardizedFileURL.path == target.standardizedFileURL.path }) else {
                throw HistoryError.unsafe("복원 경로가 중복됩니다")
            }
            moves.append((from: pair.produced, to: target))
        }
        // Crash-safe state: a crash during restoration remains visible as 'restoring', not success.
        try update("UPDATE items SET state='restoring' WHERE id=? AND state='success'", [.text(itemID)])
        var completed: [(from: URL, to: URL)] = []
        do {
            for move in moves {
                // Recheck immediately before each move, in addition to full preflight.
                guard !boolExists(move.to) else { throw HistoryError.unsafe("복원 목적지에 이미 파일이 있습니다: \(move.to.path)") }
                try manager.moveItem(at: move.from, to: move.to)
                completed.append(move)
            }
            try update("UPDATE items SET state='restored', message='', finished=? WHERE id=? AND state='restoring'",
                       [.real(Date().timeIntervalSince1970), .text(itemID)])
        } catch {
            var failedRollback = false
            for move in completed.reversed() {
                do { try manager.moveItem(at: move.to, to: move.from) }
                catch { failedRollback = true }
            }
            if failedRollback {
                try? update("UPDATE items SET state='needs_review', message=? WHERE id=?",
                            [.text("복원 중 오류 및 롤백 미완료 · 실제 파일 확인 필요"), .text(itemID)])
            } else {
                try? update("UPDATE items SET state='success', message=? WHERE id=?",
                            [.text(error.localizedDescription), .text(itemID)])
            }
            throw error
        }
    }

    // Process only one item at a time. Caller can cancel between items.
    func restoreAll(jobID: String, cancelled: () -> Bool = { false }, progress: ((Int,Int) -> Void)? = nil) -> [String] {
        var failures: [String] = []
        var offset = 0
        let total = (try? itemCount(jobID: jobID)) ?? 0
        // Keyset pagination avoids changing offsets when statuses change.
        while offset < total && !cancelled() {
            let batch: [HistoryItem]
            do { batch = try items(jobID: jobID, limit: 200, offset: offset) }
            catch { failures.append(error.localizedDescription); break }
            if batch.isEmpty { break }
            for item in batch where item.state == "success" {
                if cancelled() { break }
                do { try restoreItem(item.id) }
                catch { failures.append("\(URL(fileURLWithPath: item.output).lastPathComponent): \(error.localizedDescription)") }
            }
            offset += batch.count
            progress?(offset,total)
        }
        return failures
    }

    // Expire finished/interrupted sessions by their finish time. An active session is never purged.
    // Associated JSONL logs from v0.2 runs are also removed. Legacy v0.1 logs stay untouched.
    func prune(days: Int, now: Date = Date()) throws -> Int {
        guard (1...30).contains(days) else { throw HistoryError.unsafe("보존 기간은 1~30일만 가능합니다") }
        lock.lock(); defer { lock.unlock() }
        let deadline = now.timeIntervalSince1970 - Double(days) * 86400
        let stmt = try statement("SELECT id,log_path FROM jobs WHERE state!='running' AND COALESCE(finished,started) < ?", [.real(deadline)])
        var jobs: [(String,String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW { jobs.append((text(stmt,0), text(stmt,1))) }
        sqlite3_finalize(stmt)
        try transaction {
            for job in jobs { try update("DELETE FROM jobs WHERE id=? AND state!='running'", [.text(job.0)]) }
        }
        for job in jobs { removeOwnLog(job.1) }
        return jobs.count
    }
    func clearAll() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let active = try statement("SELECT COUNT(*) FROM jobs WHERE state='running'")
        let busy = sqlite3_step(active) == SQLITE_ROW && sqlite3_column_int64(active,0) > 0
        sqlite3_finalize(active)
        if busy { throw HistoryError.unsafe("진행 중인 작업이 있어 작업기록을 비울 수 없습니다") }
        let stmt = try statement("SELECT log_path FROM jobs")
        var logs: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { logs.append(text(stmt,0)) }
        sqlite3_finalize(stmt)
        let countStmt = try statement("SELECT COUNT(*) FROM jobs")
        let count = sqlite3_step(countStmt) == SQLITE_ROW ? Int(sqlite3_column_int64(countStmt, 0)) : 0
        sqlite3_finalize(countStmt)
        try update("DELETE FROM jobs", [])
        for p in logs { removeOwnLog(p) }
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        return count
    }
    private func removeOwnLog(_ path: String) {
        guard !path.isEmpty else { return }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let expected = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/00CaptureDate/logs").standardizedFileURL
        guard file.deletingLastPathComponent().path == expected.path,
              file.lastPathComponent.hasPrefix("run_"), file.pathExtension == "jsonl" else { return }
        try? manager.removeItem(at: file)
    }
}
