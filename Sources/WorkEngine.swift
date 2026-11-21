import Foundation
import CryptoKit

// An operation plan is frozen before the first file is modified.
enum WorkMode: String, CaseIterable, Identifiable {
    case rename = "원본 이름변경"
    case copy = "새 위치에 복사"
    var id: String { rawValue }
}

struct WorkPlan {
    let entry: MediaEntry
    let output: URL
    let companions: [(from: URL, to: URL)]
}

struct PreflightResult {
    let plans: [WorkPlan]
    let issues: [String]
    let totalBytes: Int64
}

enum Planner {
    static func prepare(_ entries: [MediaEntry], pattern: String, mode: WorkMode,
                        destination: URL?, preserveFolders: Bool) -> PreflightResult {
        let fm = FileManager.default
        var plans: [WorkPlan] = []
        var issues: [String] = []
        var reserved = Set<String>()
        var bytes: Int64 = 0
        func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }

        for entry in entries {
            guard entry.eligible, let stamp = entry.evidence.stamp else { continue }
            do {
                if mode == .rename && pattern == NamePattern.defaultValue {
                    let marker = stamp.compactDate + "_" + stamp.compactTime + "_"
                    if entry.url.deletingPathExtension().lastPathComponent.hasPrefix(marker) {
                        throw PlanError.alreadyRenamed
                    }
                }
                let newName = try NamePattern.render(pattern, stamp: stamp, originalURL: entry.url, ordinal: entry.ordinal)
                let parent: URL
                switch mode {
                case .rename: parent = entry.url.deletingLastPathComponent()
                case .copy:
                    guard let d = destination else { throw PlanError.noDestination }
                    parent = preserveFolders && !entry.relativeFolder.isEmpty
                        ? d.appendingPathComponent(entry.relativeFolder, isDirectory: true) : d
                }
                let dest = parent.appendingPathComponent(newName)
                if key(dest.path) == key(entry.url.path) { throw PlanError.sameName }
                // Same-name sidecars (.xmp/.xml) must stay paired with their media.
                let newBase = dest.deletingPathExtension().path
                let companions: [(from: URL, to: URL)] = SidecarMatcher.candidates(for: entry.url).map { sidecar in
                    (from: sidecar.source, to: URL(fileURLWithPath: newBase + sidecar.suffix + "." + sidecar.ext))
                }
                let allTargets = [dest] + companions.map(\.to)
                for target in allTargets {
                    let k = key(target.path)
                    if fm.fileExists(atPath: target.path) { throw PlanError.exists(target.lastPathComponent) }
                    if reserved.contains(k) { throw PlanError.duplicate(target.lastPathComponent) }
                }
                allTargets.forEach { reserved.insert(key($0.path)) }
                plans.append(WorkPlan(entry: entry, output: dest, companions: companions))
                bytes += entry.size
            } catch {
                issues.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return PreflightResult(plans: plans, issues: issues, totalBytes: bytes)
    }

    enum PlanError: Error, LocalizedError {
        case noDestination, sameName, alreadyRenamed, exists(String), duplicate(String)
        var errorDescription: String? {
            switch self {
            case .noDestination: return "대상 폴더를 선택하지 않았습니다"
            case .sameName: return "원본과 결과 파일명이 같아 건너뜁니다"
            case .alreadyRenamed: return "기본 이름 양식이 이미 적용된 파일을 재처리하지 않습니다"
            case .exists(let s): return "대상 파일이 이미 존재합니다: \(s)"
            case .duplicate(let s): return "이번 작업 안에서 파일명이 중복됩니다: \(s)"
            }
        }
    }
}

final class WorkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var paused = false
    func stop() { lock.lock(); stopped = true; paused = false; lock.unlock() }
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func waitIfPaused() -> Bool {
        while true {
            lock.lock(); let p = paused; let s = stopped; lock.unlock()
            if s { return false }
            if !p { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}

struct RunEvent {
    let succeeded: Bool
    let source: String
    let message: String
}

final class AuditLogger {
    let url: URL
    private let handle: FileHandle
    init() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/00CaptureDate/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "run_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).jsonl"
        url = dir.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "작업 기록 파일을 만들지 못했습니다"])
        }
        handle = try FileHandle(forWritingTo: url)
    }
    func record(mode: WorkMode, source: URL, output: URL, outcome: String, message: String, sha256: String?) throws {
        let row: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "mode": mode.rawValue, "source": source.path, "output": output.path,
            "outcome": outcome, "details": message, "sha256": sha256 ?? ""
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        handle.write(data)
        handle.write(Data([0x0a]))
        handle.synchronizeFile() // durable record per file, not only at the end of a 200 GB job
    }
    func close() { try? handle.close() }
}

enum FileOperator {
    static func process(plan: WorkPlan, mode: WorkMode, control: WorkControl) throws -> String? {
        guard control.waitIfPaused() else { throw WorkError.cancelled }
        let fm = FileManager.default
        let source = plan.entry.url
        guard let data = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              data.isRegularFile == true, data.isSymbolicLink != true, Int64(data.fileSize ?? -1) == plan.entry.size else {
            throw WorkError.sourceChanged
        }
        if let oldModified = plan.entry.modified, let nowModified = data.contentModificationDate,
           abs(oldModified.timeIntervalSince(nowModified)) > 0.001 { throw WorkError.sourceChanged }
        // Preflight is repeated at operation time; never intentionally overwrite.
        for target in [plan.output] + plan.companions.map(\.to) {
            if fm.fileExists(atPath: target.path) { throw WorkError.targetExists(target.path) }
        }
        switch mode {
        case .rename:
            var moved: [(from: URL, to: URL)] = []
            do {
                for pair in plan.companions + [(from: source, to: plan.output)] {
                    try fm.moveItem(at: pair.from, to: pair.to)
                    moved.append(pair)
                }
            } catch {
                // Roll back already renamed files if a later sidecar rename fails.
                var rollbackFailures: [String] = []
                for pair in moved.reversed() {
                    do { try fm.moveItem(at: pair.to, to: pair.from) }
                    catch { rollbackFailures.append(pair.to.path) }
                }
                if !rollbackFailures.isEmpty {
                    throw WorkError.rollbackFailed(rollbackFailures.joined(separator: ", "))
                }
                throw error
            }
            return nil // rename does not modify the bytes: no redundant 200 GB hashing
        case .copy:
            let pairs: [(from: URL, to: URL)] = [(from: source, to: plan.output)] + plan.companions
            var staged: [(temporary: URL, final: URL)] = []
            var committed: [URL] = []
            var mainHash: String?
            do {
                for pair in pairs {
                    if control.isStopped { throw WorkError.cancelled }
                    try fm.createDirectory(at: pair.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let temp = pair.to.deletingLastPathComponent().appendingPathComponent(".00CaptureDate-\(UUID().uuidString).partial")
                    // Reserve cleanup target before the copy, including partial-copy errors.
                    staged.append((temporary: temp, final: pair.to))
                    try fm.copyItem(at: pair.from, to: temp)
                    let sourceHash = try sha256(of: pair.from, control: control)
                    let copiedHash = try sha256(of: temp, control: control)
                    guard sourceHash == copiedHash else { throw WorkError.hashMismatch(pair.from.lastPathComponent) }
                    if pair.from == source { mainHash = sourceHash }
                }
                // Recheck source unchanged during copying / hashing.
                let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard Int64(after.fileSize ?? -1) == plan.entry.size else { throw WorkError.sourceChanged }
                if let old = plan.entry.modified, let current = after.contentModificationDate,
                   abs(old.timeIntervalSince(current)) > 0.001 { throw WorkError.sourceChanged }
                for stagedFile in staged {
                    if control.isStopped { throw WorkError.cancelled }
                    if fm.fileExists(atPath: stagedFile.final.path) { throw WorkError.targetExists(stagedFile.final.path) }
                    try fm.moveItem(at: stagedFile.temporary, to: stagedFile.final)
                    committed.append(stagedFile.final)
                }
                return mainHash
            } catch {
                // Only files created by this operation are cleaned up; never delete pre-existing paths.
                var cleanupFailures: [String] = []
                for path in committed + staged.map(\.temporary) {
                    guard fm.fileExists(atPath: path.path) else { continue }
                    do { try fm.removeItem(at: path) }
                    catch { cleanupFailures.append(path.path) }
                }
                if !cleanupFailures.isEmpty {
                    throw WorkError.cleanupFailed(cleanupFailures.joined(separator: ", "))
                }
                throw error
            }
        }
    }

    private static func sha256(of url: URL, control: WorkControl) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            if control.isStopped { throw WorkError.cancelled }
            let chunk = try h.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum WorkError: Error, LocalizedError {
        case cancelled, sourceChanged, targetExists(String), hashMismatch(String), rollbackFailed(String), cleanupFailed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "사용자가 작업을 중단했습니다"
            case .sourceChanged: return "스캔 이후 원본 파일이 변경되어 안전하게 중단했습니다"
            case .targetExists(let p): return "파일 덮어쓰기 금지: \(p)"
            case .hashMismatch(let p): return "SHA-256 검증 불일치: \(p)"
            case .rollbackFailed(let p): return "이름변경 롤백 실패 · 수동 확인 필요: \(p)"
            case .cleanupFailed(let p): return "복사 실패 후 임시/결과 파일 정리 실패 · 수동 확인 필요: \(p)"
            }
        }
    }
}
