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
    // Physical directory root supplied by the user (copy), or the source's parent (rename).
    // FileOperator never creates or follows generated subfolders outside this root.
    let directoryRoot: URL
}

struct PreflightResult {
    let plans: [WorkPlan]
    let issues: [String]
    let totalBytes: Int64
}

enum Planner {
    static func desiredName(for entry: MediaEntry, pattern: String, mode: WorkMode,
                            folderLayout: FolderLayout) throws -> String {
        guard let stamp = entry.evidence.stamp else { throw PlanError.unknownDate }
        if mode == .rename && pattern == NamePattern.defaultValue {
            let marker = stamp.compactDate + "_" + stamp.compactTime + "_"
            if entry.url.deletingPathExtension().lastPathComponent.hasPrefix(marker) {
                // A file named by an earlier version may still need date-folder organization.
                if folderLayout == .captureDate { return entry.url.lastPathComponent }
                throw PlanError.alreadyRenamed
            }
        }
        return try NamePattern.render(pattern, stamp: stamp, originalURL: entry.url, ordinal: entry.ordinal)
    }

    static func prepare(_ entries: [MediaEntry], pattern: String, mode: WorkMode,
                        destination: URL?, preserveFolders: Bool,
                        folderLayout: FolderLayout = .existing,
                        folderPattern: String = FolderPattern.defaultValue) -> PreflightResult {
        let fm = FileManager.default
        var plans: [WorkPlan] = []
        var issues: [String] = []
        var reserved = Set<String>()
        var bytes: Int64 = 0
        func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }

        for entry in entries {
            guard entry.eligible, let stamp = entry.evidence.stamp else { continue }
            do {
                let newName = try desiredName(for: entry, pattern: pattern, mode: mode, folderLayout: folderLayout)
                let base: URL
                switch mode {
                case .rename:
                    // Rename + date layout moves WITHIN the original parent folder's volume.
                    // Never redirect original data to an unrelated destination.
                    base = entry.url.deletingLastPathComponent()
                case .copy:
                    guard let d = destination else { throw PlanError.noDestination }
                    base = folderLayout == .existing && preserveFolders && !entry.relativeFolder.isEmpty
                        ? d.appendingPathComponent(entry.relativeFolder, isDirectory: true) : d
                }
                let parent: URL
                if folderLayout == .captureDate {
                    let relative = try FolderPattern.render(folderPattern, stamp: stamp)
                    if mode == .rename && base.standardizedFileURL.path.hasSuffix("/" + relative) {
                        throw PlanError.alreadyOrganized
                    }
                    parent = base.appendingPathComponent(relative, isDirectory: true)
                } else {
                    parent = base
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
                plans.append(WorkPlan(entry: entry, output: dest, companions: companions,
                                      directoryRoot: mode == .rename ? entry.url.deletingLastPathComponent() : (destination ?? base)))
                bytes += entry.size
            } catch {
                issues.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return PreflightResult(plans: plans, issues: issues, totalBytes: bytes)
    }

    enum PlanError: Error, LocalizedError {
        case noDestination, sameName, alreadyRenamed, alreadyOrganized, unknownDate, exists(String), duplicate(String)
        var errorDescription: String? {
            switch self {
            case .noDestination: return "대상 폴더를 선택하지 않았습니다"
            case .sameName: return "원본과 결과 파일명이 같아 건너뜁니다"
            case .alreadyRenamed: return "기본 이름 양식이 이미 적용된 파일을 재처리하지 않습니다"
            case .alreadyOrganized: return "이미 같은 촬영일자 폴더에 있어 중복 하위 폴더를 만들지 않습니다"
            case .unknownDate: return "촬영일시가 없습니다"
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
    // Validate every generated path component before creating it. In particular, reject
    // a pre-existing symlink named '2026년' that could redirect an original move away
    // from its starting volume. Never remove a non-empty user directory on failure.
    private static func ensureSafeParent(_ plan: WorkPlan) throws {
        let fm = FileManager.default
        let root = plan.directoryRoot.standardizedFileURL
        let target = plan.output.deletingLastPathComponent().standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard target.path == root.path || target.path.hasPrefix(prefix) else {
            throw WorkError.unsafeDirectory("선택한 저장 기준 위치 밖으로 이동할 수 없습니다: \(target.path)")
        }
        // Preserve v0.2 behavior for ordinary same-folder rename/copy: no new
        // folder hierarchy is being created in that case.
        if target.path == root.path { return }
        let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else {
            throw WorkError.unsafeDirectory("저장 기준 폴더가 없거나 심볼릭 링크입니다: \(root.path)")
        }
        let relative = String(target.path.dropFirst(prefix.count))
        var current = root
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            if fm.fileExists(atPath: current.path) {
                let info = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else {
                    throw WorkError.unsafeDirectory("하위 폴더가 일반 디렉터리가 아닙니다: \(current.path)")
                }
            } else {
                // Broken symlinks may return false for fileExists. Refuse them as well.
                if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    throw WorkError.unsafeDirectory("하위 폴더에 심볼릭 링크가 있습니다: \(current.path)")
                }
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

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
        try ensureSafeParent(plan)
        switch mode {
        case .rename:
            var moved: [(from: URL, to: URL)] = []
            do {
                for pair in plan.companions + [(from: source, to: plan.output)] {
                    if fm.fileExists(atPath: pair.to.path) { throw WorkError.targetExists(pair.to.path) }
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
        case cancelled, sourceChanged, targetExists(String), hashMismatch(String), rollbackFailed(String), cleanupFailed(String), unsafeDirectory(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "사용자가 작업을 중단했습니다"
            case .sourceChanged: return "스캔 이후 원본 파일이 변경되어 안전하게 중단했습니다"
            case .targetExists(let p): return "파일 덮어쓰기 금지: \(p)"
            case .hashMismatch(let p): return "SHA-256 검증 불일치: \(p)"
            case .rollbackFailed(let p): return "이름변경 롤백 실패 · 수동 확인 필요: \(p)"
            case .cleanupFailed(let p): return "복사 실패 후 임시/결과 파일 정리 실패 · 수동 확인 필요: \(p)"
            case .unsafeDirectory(let p): return "안전하지 않은 폴더 경로: \(p)"
            }
        }
    }
}
