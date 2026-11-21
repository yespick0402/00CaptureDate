import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var jobs: [HistoryJob] = []
    @State private var selectedJob: String?
    @State private var rows: [HistoryItem] = []
    @State private var selectedFiles: Set<String> = []
    @State private var page = 0
    @State private var count = 0
    @State private var message = ""
    @State private var confirmClear = false
    @State private var confirmRestore = false

    private let pageSize = 200
    private var selected: HistoryJob? { jobs.first { $0.id == selectedJob } }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            titleBar
            HStack(alignment: .top, spacing: 14) {
                jobsPanel.frame(width: 280)
                Divider()
                filesPanel
            }.frame(minHeight: 360)
            Divider()
            retentionPanel
            Text("기록 삭제는 파일을 변경하지 않습니다. 삭제한 기록의 자동 복원은 불가능합니다. 0.1.0의 기존 로그는 자동 복원 대상이 아닙니다.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isRestoring { ProgressView("기록을 확인하고 파일을 안전하게 처리하고 있습니다…") }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .padding(18).frame(minWidth: 950, minHeight: 610)
        .onAppear { model.pruneHistoryIfIdle(); load() }
        .onChange(of: selectedJob) { _ in page = 0; selectedFiles.removeAll(); loadFiles() }
        .onChange(of: model.historyRevision) { _ in load() }
        .confirmationDialog("선택한 작업의 복원 가능한 파일을 모두 원래 이름으로 되돌리시겠습니까?", isPresented: $confirmRestore) {
            Button("전체 복원", role: .destructive) { restoreAll() }
            Button("취소", role: .cancel) { }
        } message: { Text("파일이 바뀌었거나 이름이 충돌하면 건너뜁니다. 사이드카도 함께 검사합니다.") }
        .confirmationDialog("모든 작업 기록을 즉시 지우시겠습니까?", isPresented: $confirmClear) {
            Button("작업 기록 영구 비우기", role: .destructive) { clearRecords() }
            Button("취소", role: .cancel) { }
        } message: { Text("사진·영상은 변경하지 않지만, 삭제한 기록으로는 복원할 수 없습니다.") }
    }

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("작업 기록 및 원본 이름 복원").font(.title2).bold()
                Text("앱 재시작 후에도 기록을 조회할 수 있습니다. 복원 전에 동일성·충돌을 검사합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("닫기") { dismiss() }.disabled(model.isRestoring)
        }
    }

    private var jobsPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("작업 목록").font(.headline)
            List(jobs, id: \.id, selection: $selectedJob) { job in
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.started.formatted(date: .numeric, time: .shortened)).fontWeight(.medium)
                    Text(job.mode).font(.caption)
                    Text("복원 가능 \(job.completedCount) · 복원 \(job.restoredCount) · 확인 필요 \(job.pendingCount)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.tag(job.id)
            }.listStyle(.sidebar)
            Text("최신 작업 100개 표시").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var filesPanel: some View {
        if let job = selected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("파일별 기록").font(.headline)
                    Spacer()
                    Text("\(count.formatted())개").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("현재 페이지 전체 선택") {
                        selectedFiles = Set(rows.filter { $0.state == "success" }.map(\.id))
                    }.disabled(model.isBusy)
                    Button("선택 해제") { selectedFiles.removeAll() }.disabled(model.isBusy)
                    Spacer()
                    Button("선택 복원") { startSelectedRestore() }
                        .disabled(model.isBusy || selectedFiles.isEmpty)
                    Button("작업 전체 복원…") { confirmRestore = true }
                        .disabled(model.isBusy || job.completedCount == 0)
                        .buttonStyle(.borderedProminent)
                }
                List(rows) { item in fileRow(item) }.listStyle(.bordered)
                pageControls
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("작업 기록을 선택하세요").font(.headline)
                Text("완료된 작업과 원본 이름 변경 내역을 확인할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileRow(_ item: HistoryItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selectedFiles.contains(item.id) }, set: { value in
                if value { selectedFiles.insert(item.id) } else { selectedFiles.remove(item.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(model.isBusy || item.state != "success")
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: item.source).lastPathComponent).font(.system(size: 12, weight: .medium))
                Text("← " + URL(fileURLWithPath: item.output).lastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if item.state != "success" {
                    Text(stateLabel(item.state) + (item.message.isEmpty ? "" : " · " + item.message))
                        .font(.system(size: 10))
                        .foregroundStyle(item.state == "restored" ? Color.green : Color.orange)
                }
            }
            .help("원래 위치: \(item.source)\n작업 이후: \(item.output)")
            Spacer(minLength: 10)
            Text(stateLabel(item.state)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button { page = max(0, page - 1); loadFiles() } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0 || model.isBusy)
            Text("\(page + 1) / \(max(1, (count + pageSize - 1) / pageSize))")
                .monospacedDigit().font(.caption)
            Button { page += 1; loadFiles() } label: { Image(systemName: "chevron.right") }
                .disabled((page + 1) * pageSize >= count || model.isBusy)
            Spacer()
        }
    }

    private var retentionPanel: some View {
        HStack(spacing: 10) {
            Text("작업 기록 자동 삭제").fontWeight(.medium)
            Picker("보존 기간", selection: Binding(get: { model.retentionDays }, set: { model.setRetentionDays($0) })) {
                ForEach(1...30, id: \.self) { day in Text("\(day)일").tag(day) }
            }.labelsHidden().frame(width: 92).disabled(model.isBusy)
            Text("작업 완료일 기준 · 앱 실행 및 실행 중 주기적으로 정리")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("작업 기록 바로 비우기…", role: .destructive) { confirmClear = true }
                .disabled(model.isBusy || jobs.isEmpty)
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "success": return "복원 가능"
        case "restored": return "복원 완료"
        case "failed": return "작업 실패"
        case "pending", "restoring", "needs_review": return "수동 확인 필요"
        default: return state
        }
    }
    private func load() {
        guard let store = model.historyStore else { message = "DB에 접근할 수 없습니다"; return }
        do {
            jobs = try store.jobs()
            if selectedJob == nil || !jobs.contains(where: { $0.id == selectedJob }) { selectedJob = jobs.first?.id }
            loadFiles()
        } catch { message = error.localizedDescription }
    }
    private func loadFiles() {
        guard let store = model.historyStore, let id = selectedJob else { rows = []; count = 0; return }
        do {
            count = try store.itemCount(jobID: id)
            rows = try store.items(jobID: id, limit: pageSize, offset: page * pageSize)
            selectedFiles.removeAll()
        } catch { message = error.localizedDescription }
    }
    private func startSelectedRestore() {
        guard !model.isBusy, let store = model.historyStore else { return }
        let ids = Array(selectedFiles)
        model.isRestoring = true
        message = "\(ids.count)개 파일 복원 검사 중…"
        Task.detached { [self] in
            var failures: [String] = []
            for id in ids {
                do { try store.restoreItem(id) }
                catch { failures.append(error.localizedDescription) }
            }
            await MainActor.run {
                model.isRestoring = false
                message = failures.isEmpty ? "선택한 파일의 복원이 완료되었습니다." : "복원되지 않은 파일 \(failures.count)개: " + failures.prefix(5).joined(separator: " / ")
                load()
            }
        }
    }
    private func restoreAll() {
        guard !model.isBusy, let store = model.historyStore, let jobID = selectedJob else { return }
        model.isRestoring = true
        message = "전체 작업의 파일 동일성을 확인하며 복원 중…"
        Task.detached { [self] in
            let failures = store.restoreAll(jobID: jobID)
            await MainActor.run {
                model.isRestoring = false
                message = failures.isEmpty ? "전체 복원 가능한 파일을 처리했습니다." : "복원 제외 \(failures.count)개: " + failures.prefix(5).joined(separator: " / ")
                load()
            }
        }
    }
    private func clearRecords() {
        guard !model.isBusy, let store = model.historyStore else { return }
        model.isRestoring = true
        Task.detached { [self] in
            var result = ""
            do { let n = try store.clearAll(); result = "작업 기록 \(n)건을 비웠습니다. 실제 미디어 파일은 변경하지 않았습니다." }
            catch { result = error.localizedDescription }
            await MainActor.run { model.isRestoring = false; message = result; selectedJob = nil; load() }
        }
    }
}
