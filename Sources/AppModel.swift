import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var entries: [MediaEntry] = []
    @Published var totalSizeBytes: Int64 = 0
    @Published var highConfidenceCount = 0
    @Published var needsReviewCount = 0
    @Published var approvedReviewCount = 0
    @Published var missingDateCount = 0
    @Published var mode: WorkMode = .rename
    @Published var destination: URL?
    @Published var preserveFolders = true
    @Published var pattern = NamePattern.defaultValue
    @Published var page = 0
    @Published var isScanning = false
    @Published var isRunning = false
    @Published var paused = false
    @Published var discoveredCount = 0
    @Published var scannedCount = 0
    @Published var plannedCount = 0
    @Published var processedCount = 0
    @Published var successCount = 0
    @Published var failedCount = 0
    @Published var latestLog: URL?
    @Published var status = "파일이나 폴더를 추가한 후 '촬영일자 분석'을 선택하세요."
    @Published var currentFile = ""
    @Published var preflightMessage = ""
    @Published var errors: [String] = []
    @Published var alertMessage: String?
    @Published var showHistory = false
    @Published var isRestoring = false
    @Published var historyRevision = 0
    @Published var retentionDays: Int = 30
    private(set) var historyStore: HistoryStore?

    init() {
        let configured = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        retentionDays = (1...30).contains(configured) ? configured : 30
        do {
            historyStore = try HistoryStore()
            _ = try historyStore?.prune(days: retentionDays)
        } catch {
            historyStore = nil
            alertMessage = "작업 이력 DB를 열지 못했습니다. 안전을 위해 작업 실행을 차단합니다: \(error.localizedDescription)"
        }
    }

    func setRetentionDays(_ days: Int) {
        guard (1...30).contains(days) else { return }
        retentionDays = days
        UserDefaults.standard.set(days, forKey: "historyRetentionDays")
        guard let store = historyStore, !isBusy else { return }
        Task.detached { [weak self] in
            do {
                _ = try store.prune(days: days)
                await MainActor.run { self?.historyRevision += 1 }
            } catch { await MainActor.run { self?.alertMessage = error.localizedDescription } }
        }
    }

    func pruneHistoryIfIdle() {
        guard !isBusy, let store = historyStore else { return }
        let days = retentionDays
        Task.detached { [weak self] in
            do {
                _ = try store.prune(days: days)
                await MainActor.run { self?.historyRevision += 1 }
            } catch { await MainActor.run { self?.alertMessage = error.localizedDescription } }
        }
    }

    private var scanTask: Task<Void, Never>?
    private var workControl: WorkControl?
    private let pageSize = 400

    var isBusy: Bool { isScanning || isRunning || isRestoring }
    var pageCount: Int { max(1, (entries.count + pageSize - 1) / pageSize) }
    var visibleEntries: [MediaEntry] { Array(entries.dropFirst(page * pageSize).prefix(pageSize)) }
    var totalSize: Int64 { totalSizeBytes }
    var readyCount: Int { highConfidenceCount + approvedReviewCount }
    var reviewCount: Int { max(0, needsReviewCount - approvedReviewCount) }
    var noDateCount: Int { missingDateCount }
    var latestErrors: [String] { Array(errors.suffix(10).reversed()) }

    func chooseRoots() {
        let panel = NSOpenPanel()
        panel.title = "사진·영상 파일 또는 폴더 추가"
        panel.message = "여러 파일이나 폴더를 선택할 수 있습니다. 실제 데이터는 이 단계에서 읽거나 복사하지 않습니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            let existing = Set(roots.map { $0.standardizedFileURL.path })
            roots += panel.urls.filter { !existing.contains($0.standardizedFileURL.path) }
            clearScan()
            status = "입력 위치 \(roots.count)개가 추가됐습니다. 촬영일자 분석을 실행하세요."
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "결과 복사 폴더 선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { destination = panel.url; preflightMessage = "" }
    }

    func clearAll() {
        if isBusy { return }
        roots = []
        clearScan()
        status = "목록을 초기화했습니다. 디스크의 원본 파일은 변경되지 않았습니다."
    }

    private func clearScan() {
        entries = []
        totalSizeBytes = 0
        highConfidenceCount = 0
        needsReviewCount = 0
        approvedReviewCount = 0
        missingDateCount = 0
        page = 0
        discoveredCount = 0
        scannedCount = 0
        processedCount = 0
        plannedCount = 0
        successCount = 0
        failedCount = 0
        currentFile = ""
        preflightMessage = ""
        errors = []
    }

    func scan() {
        guard !roots.isEmpty, !isBusy else { return }
        clearScan()
        isScanning = true
        status = "폴더를 조사하고 있습니다. 파일 내용 전체를 메모리에 적재하지 않습니다."
        let sources = roots
        let tool = Bundle.main.resourceURL!.appendingPathComponent("exiftool/exiftool")
        guard FileManager.default.fileExists(atPath: tool.path) else {
            isScanning = false
            alertMessage = "ExifTool이 앱에 포함되지 않았습니다. GitHub Actions 빌드 산출물을 사용해 주세요."
            return
        }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = MediaInventory.discover(sources, cancelled: { Task.isCancelled })
            guard !Task.isCancelled else {
                await MainActor.run { self?.isScanning = false; self?.status = "스캔이 중단됐습니다." }
                return
            }
            await MainActor.run {
                self?.discoveredCount = found.count
                self?.status = "\(found.count)개 미디어 발견 · 촬영정보를 나누어 읽는 중"
            }
            let reader = MetadataReader(toolURL: tool)
            let session = PersistentExifSession(reader: reader)
            defer { session.close() }
            for offset in stride(from: 0, to: found.count, by: 48) {
                if Task.isCancelled { break }
                let chunk = Array(found[offset..<min(offset + 48, found.count)])
                let data = session.readBatch(chunk)
                let batch = chunk.enumerated().map { i, item in
                    MediaEntry(source: item, evidence: data[item.url.path] ?? .missing, ordinal: offset + i + 1)
                }
                await MainActor.run {
                    self?.entries.append(contentsOf: batch)
                    self?.totalSizeBytes += batch.reduce(0) { $0 + $1.size }
                    self?.highConfidenceCount += batch.filter { $0.evidence.confidence == .high }.count
                    self?.needsReviewCount += batch.filter { $0.evidence.confidence == .review }.count
                    self?.missingDateCount += batch.filter { $0.evidence.stamp == nil }.count
                    self?.scannedCount += batch.count
                    self?.status = "촬영일자 분석: \(self?.scannedCount ?? 0) / \(found.count)개"
                }
            }
            await MainActor.run {
                self?.isScanning = false
                self?.status = Task.isCancelled ? "스캔 중단 · 현재 결과만 표시" : "분석 완료 · 신뢰도 '확인 필요' 항목은 승인 전 자동 처리하지 않습니다."
                self?.scanTask = nil
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        status = "스캔 중단 요청됨 · 현재 배치가 끝나면 정지합니다."
    }

    func toggleApproval(for id: UUID) {
        guard !isBusy, let i = entries.firstIndex(where: { $0.id == id }),
              entries[i].evidence.confidence == .review else { return }
        entries[i].approved.toggle()
        approvedReviewCount += entries[i].approved ? 1 : -1
        preflightMessage = ""
    }

    func applyManualDate(for id: UUID, text: String) -> Bool {
        guard !isBusy, let date = CaptureStamp.parse(text),
              let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        switch entries[i].evidence.confidence {
        case .high: highConfidenceCount -= 1
        case .review:
            needsReviewCount -= 1
            if entries[i].approved { approvedReviewCount -= 1 }
        case .missing: missingDateCount -= 1
        }
        needsReviewCount += 1
        approvedReviewCount += 1
        entries[i].evidence = CaptureEvidence(stamp: date, confidence: .review,
                                              source: "사용자 지정", details: "수동 입력한 일시 (자동 판정 아님): \(text)")
        entries[i].approved = true
        preflightMessage = ""
        return true
    }

    func predictedName(for entry: MediaEntry) -> String {
        guard let stamp = entry.evidence.stamp else { return "촬영일시 없음" }
        do { return try NamePattern.render(pattern, stamp: stamp, originalURL: entry.url, ordinal: entry.ordinal) }
        catch { return "규칙 오류: \(error.localizedDescription)" }
    }

    private func validateDestination() -> Bool {
        guard mode == .copy else { return true }
        guard let dest = destination else { alertMessage = "복사할 대상 폴더를 선택하세요."; return false }
        let p = dest.standardizedFileURL.path
        for root in roots {
            let isDir = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let r = root.standardizedFileURL.path
            if isDir && (p == r || p.hasPrefix(r + "/")) {
                alertMessage = "복사 대상 폴더는 입력 폴더의 안쪽일 수 없습니다. 무한 재스캔·중복 복사를 방지합니다."
                return false
            }
        }
        return true
    }

    func dryRun() {
        guard !isBusy, !entries.isEmpty, validateDestination() else { return }
        let result = Planner.prepare(entries, pattern: pattern, mode: mode,
                                     destination: destination, preserveFolders: preserveFolders)
        preflightMessage = "실행 가능 \(result.plans.count)개 · 중복/규칙 오류 \(result.issues.count)개 · 준비된 원본 용량 \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))"
        errors = Array(result.issues.prefix(100))
        status = "미리보기 검사 완료. 현재 디스크 상태 기준이며 실행 직전에도 다시 검사합니다."
    }

    func start() {
        guard !isBusy, !entries.isEmpty, validateDestination() else { return }
        guard let store = historyStore else {
            alertMessage = "작업 이력 DB를 사용할 수 없어 파일 변경을 시작하지 않습니다."
            return
        }
        let snapshot = entries
        let format = pattern
        let selectedMode = mode
        let folder = destination
        let preserve = preserveFolders
        let daysToKeep = retentionDays
        isRunning = true
        paused = false
        processedCount = 0
        plannedCount = 0
        successCount = 0
        failedCount = 0
        errors = []
        currentFile = ""
        let control = WorkControl()
        workControl = control
        status = "실행 전 파일명 충돌을 검사하고 있습니다."
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Planner.prepare(snapshot, pattern: format, mode: selectedMode,
                                         destination: folder, preserveFolders: preserve)
            await MainActor.run {
                self?.plannedCount = result.plans.count
                self?.preflightMessage = "처리 계획 \(result.plans.count)개 · 미처리 충돌/오류 \(result.issues.count)개"
                self?.errors = Array(result.issues.prefix(100))
                self?.failedCount = result.issues.count
            }
            guard !result.plans.isEmpty else {
                await MainActor.run { self?.isRunning = false; self?.status = "실행할 파일이 없습니다. 신뢰도와 파일명 충돌을 확인하세요." }
                return
            }
            if selectedMode == .copy, let folder = folder,
               let attrs = try? FileManager.default.attributesOfFileSystem(forPath: folder.path),
               let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
               free > 0 && result.totalBytes > free {
                await MainActor.run {
                    self?.isRunning = false
                    self?.alertMessage = "대상 볼륨의 여유 공간(\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))이 원본 합계(\(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)))보다 작습니다. 복사를 시작하지 않았습니다."
                }
                return
            }
            let audit: AuditLogger
            do { audit = try AuditLogger() }
            catch {
                await MainActor.run { self?.isRunning = false; self?.alertMessage = "작업 기록을 만들지 못해 안전하게 중단했습니다: \(error.localizedDescription)" }
                return
            }
            let jobID: String
            do { jobID = try store.beginJob(mode: selectedMode, logURL: audit.url) }
            catch {
                audit.close()
                await MainActor.run {
                    self?.isRunning = false
                    self?.alertMessage = "SQLite 작업 기록을 만들지 못해 안전하게 중단했습니다: \(error.localizedDescription)"
                }
                return
            }
            await MainActor.run { self?.latestLog = audit.url }
            for (index, plan) in result.plans.enumerated() {
                if !control.waitIfPaused() { break }
                await MainActor.run {
                    self?.currentFile = plan.entry.url.lastPathComponent
                    self?.status = "작업 \(index + 1) / \(result.plans.count): \(plan.entry.url.lastPathComponent)"
                }
                var historyItemID: String?
                var fileOperationFinished = false
                do {
                    // A journal row must reach disk before any media is moved.
                    historyItemID = try store.prepareItem(jobID: jobID, plan: plan, mode: selectedMode)
                    let hash = try FileOperator.process(plan: plan, mode: selectedMode, control: control)
                    fileOperationFinished = true
                    try store.markSuccess(historyItemID!, plan: plan)
                    do {
                        try audit.record(mode: selectedMode, source: plan.entry.url, output: plan.output,
                                         outcome: "success", message: "완료", sha256: hash)
                    } catch {
                        // SQLite is the authoritative journal; JSONL failure is nonfatal.
                        await MainActor.run { self?.errors.append("보조 JSONL 기록 오류: \(error.localizedDescription)") }
                    }
                    await MainActor.run { self?.successCount += 1 }
                } catch {
                    if let itemID = historyItemID, !fileOperationFinished {
                        do { try store.markFailure(itemID, error.localizedDescription) }
                        catch { control.stop() }
                    }
                    // If file operation succeeded but DB commit failed, stop immediately;
                    // pending row is intentionally retained for manual reconciliation.
                    if fileOperationFinished { control.stop() }
                    try? audit.record(mode: selectedMode, source: plan.entry.url, output: plan.output,
                                      outcome: "failure", message: error.localizedDescription, sha256: nil)
                    let suffix = fileOperationFinished ? " · 파일 작업 후 DB 기록 실패: 자동 복원 금지, 수동 확인 필요" : ""
                    await MainActor.run {
                        self?.failedCount += 1
                        self?.errors.append("\(plan.entry.url.lastPathComponent): \(error.localizedDescription)\(suffix)")
                    }
                }
                await MainActor.run { self?.processedCount += 1 }
            }
            audit.close()
            do { try store.finishJob(jobID, interrupted: control.isStopped) }
            catch { await MainActor.run { self?.errors.append("작업 종료 기록 실패: \(error.localizedDescription)") } }
            do { _ = try store.prune(days: daysToKeep) }
            catch { await MainActor.run { self?.errors.append("오래된 작업 기록 정리 실패: \(error.localizedDescription)") } }
            await MainActor.run {
                self?.isRunning = false
                self?.paused = false
                self?.workControl = nil
                self?.currentFile = ""
                self?.status = control.isStopped
                    ? "중단됨 · 성공 \(self?.successCount ?? 0)개 / 오류 \(self?.failedCount ?? 0)개 · 완료된 작업은 유지됩니다."
                    : "작업 종료 · 성공 \(self?.successCount ?? 0)개 / 오류·중복 \(self?.failedCount ?? 0)개"
            }
        }
    }

    func togglePause() {
        guard isRunning else { return }
        paused.toggle()
        workControl?.setPaused(paused)
        status = paused ? "일시정지 요청 · 현재 파일 처리가 끝나면 멈춥니다." : "작업 재개"
    }
    func stopWork() {
        workControl?.stop()
        status = "중단 요청 · 현재 복사/검증 파일을 안전하게 정리한 뒤 중단합니다."
    }
    func showLogInFinder() {
        guard let url = latestLog else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "보존 기간이 만료되었거나 작업 기록을 비워 해당 로그가 삭제되었습니다."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
