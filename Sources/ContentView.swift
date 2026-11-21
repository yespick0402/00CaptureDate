import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var editing: MediaEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            sourcePanel
            settingsPanel
            tablePanel
            footer
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 690)
        .sheet(item: $editing) { item in
            ManualDateSheet(entry: item) { value in model.applyManualDate(for: item.id, text: value) }
        }
        .alert("안내", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("확인", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("00CaptureDate").font(.system(size: 27, weight: .bold, design: .rounded))
                Text("촬영일자 기반 파일명 변경 · 원본 우선 · 대용량 안전 처리")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("사진 / RAW / 영상", systemImage: "camera.aperture")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourcePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { model.chooseRoots() } label: { Label("파일·폴더 추가", systemImage: "folder.badge.plus") }
                        .disabled(model.isBusy)
                    Button { model.scan() } label: { Label("촬영일자 분석", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.roots.isEmpty)
                    if model.isScanning {
                        Button("분석 중단") { model.stopScan() }
                    }
                    Button("목록 비우기") { model.clearAll() }
                        .disabled(model.isBusy || model.roots.isEmpty)
                    Spacer()
                    Text("입력 위치 \(model.roots.count)개")
                    Text("파일 \(model.entries.count.formatted())개")
                        .fontWeight(.semibold)
                }
                if !model.roots.isEmpty {
                    Text(model.roots.prefix(2).map(\.path).joined(separator: "   ·   ") +
                         (model.roots.count > 2 ? "   외 \(model.roots.count - 2)개" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .textSelection(.enabled)
                }
                Text("Finder에서 전체 파일을 선택할 필요가 없습니다. 폴더만 선택하면 하위 미디어 파일을 검색합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(5)
        } label: { Label("1 · 입력 파일", systemImage: "square.stack.3d.up") }
    }

    private var settingsPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("작업 방식").frame(width: 90, alignment: .leading)
                    Picker("", selection: $model.mode) {
                        ForEach(WorkMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    .disabled(model.isBusy)
                    Spacer()
                    if model.mode == .copy {
                        Toggle("원래 폴더 구조 유지", isOn: $model.preserveFolders)
                            .disabled(model.isBusy)
                    }
                }
                if model.mode == .copy {
                    HStack {
                        Text("복사 위치").frame(width: 90, alignment: .leading)
                        Button("결과 폴더 선택…") { model.chooseDestination() }.disabled(model.isBusy)
                        Text(model.destination?.path ?? "대상 폴더를 선택하세요")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack {
                    Text("파일명 양식").frame(width: 90, alignment: .leading)
                    TextField("변경할 파일명 규칙", text: $model.pattern)
                        .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                        .font(.system(.body, design: .monospaced))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("사용 가능한 토큰").font(.caption).foregroundStyle(.secondary)
                    Text("{YYYYMMDD}  {hhmmss}  {YYYY}  {MM}  {DD}  {hh}  {mm}  {ss}  {Originalname}  {filename}  {ext}  {SEQ}")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let sample = model.entries.first(where: { $0.evidence.stamp != nil }) {
                    Text("예상 결과: \(model.predictedName(for: sample))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(5)
        } label: { Label("2 · 이름변경 규칙 및 저장 방식", systemImage: "slider.horizontal.3") }
    }

    private var tablePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Text("3 · 촬영일자 분석 결과").font(.headline)
                Spacer()
                Text("원본 \(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))")
                Text("실행 가능 \(model.readyCount.formatted())").foregroundStyle(.green)
                Text("확인 필요 \(model.reviewCount.formatted())").foregroundStyle(.orange)
                Text("촬영일시 없음 \(model.noDateCount.formatted())").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("원본 파일").frame(maxWidth: .infinity, alignment: .leading)
                Text("판정 일시").frame(width: 154, alignment: .leading)
                Text("신뢰도").frame(width: 76, alignment: .leading)
                Text("촬영일시 출처").frame(width: 155, alignment: .leading)
                Text("사용 여부").frame(width: 75, alignment: .center)
                Text("수정").frame(width: 42)
            }
            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.horizontal, 11)

            List(model.visibleEntries) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).lineLimit(1)
                        Text(item.url.deletingLastPathComponent().path)
                            .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.url.path)
                    Text(item.evidence.stamp?.formatted ?? "—")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 154, alignment: .leading)
                    Text(item.evidence.confidence.rawValue)
                        .font(.caption).foregroundStyle(color(item.evidence.confidence))
                        .frame(width: 76, alignment: .leading)
                    Text(item.evidence.source)
                        .font(.caption).lineLimit(1)
                        .frame(width: 155, alignment: .leading)
                        .help(item.evidence.details)
                    Group {
                        if item.evidence.confidence == .review {
                            Toggle("", isOn: Binding(get: { item.approved }, set: { _ in model.toggleApproval(for: item.id) }))
                                .toggleStyle(.checkbox).labelsHidden().disabled(model.isBusy)
                        } else {
                            Image(systemName: item.eligible ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(item.eligible ? Color.green : Color.secondary)
                        }
                    }.frame(width: 75)
                    Button { editing = item } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("촬영일시 직접 입력 및 승인")
                        .frame(width: 42).disabled(model.isBusy)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .frame(minHeight: 190)

            HStack {
                Text("전체 \(model.entries.count.formatted())개 · 한 페이지에 400개씩 표시")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.page = max(0, model.page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page == 0)
                Text("\(model.page + 1) / \(model.pageCount)").monospacedDigit().frame(minWidth: 66)
                Button { model.page = min(model.pageCount - 1, model.page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page >= model.pageCount - 1)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.isScanning || model.isRunning {
                ProgressView(value: Double(model.isScanning ? model.scannedCount : model.processedCount),
                             total: Double(max(1, model.isScanning ? model.discoveredCount : model.plannedCount)))
            }
            HStack(spacing: 10) {
                Button { model.dryRun() } label: { Label("충돌·규칙 사전 검사", systemImage: "checkmark.shield") }
                    .disabled(model.isBusy || model.entries.isEmpty)
                Button { model.start() } label: { Label("작업 시작", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy || model.entries.isEmpty)
                if model.isRunning {
                    Button(model.paused ? "재개" : "일시정지") { model.togglePause() }
                    Button("작업 중단") { model.stopWork() }
                }
                Spacer()
                if model.latestLog != nil {
                    Button("작업 기록 보기") { model.showLogInFinder() }
                }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !model.preflightMessage.isEmpty {
                Text(model.preflightMessage).font(.caption).fontWeight(.medium)
            }
            if !model.latestErrors.isEmpty {
                DisclosureGroup("오류·중복 내역 (최근 \(min(10, model.errors.count))건)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.latestErrors.enumerated()), id: \.offset) { pair in
                                Text(pair.element).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90)
                }
            }
            Text("원본 파일 내용/EXIF은 수정하지 않습니다. '확인 필요' 파일은 체크하거나 수동 수정해야 실행 대상에 포함됩니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func color(_ value: DateConfidence) -> Color {
        switch value { case .high: return .green; case .review: return .orange; case .missing: return .secondary }
    }
}

struct ManualDateSheet: View {
    let entry: MediaEntry
    let onApply: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(entry: MediaEntry, onApply: @escaping (String) -> Bool) {
        self.entry = entry
        self.onApply = onApply
        self._value = State(initialValue: entry.evidence.stamp?.formatted ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("촬영일시 직접 지정").font(.title2).bold()
            Text(entry.url.lastPathComponent).font(.headline)
            Text("기존 판정: \(entry.evidence.source)\n\(entry.evidence.details)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("YYYY-MM-DD HH:mm:ss", text: $value).textFieldStyle(.roundedBorder)
            Text("직접 지정한 날짜는 '수동 입력'으로 기록되며, 메타데이터의 신뢰도 '높음'으로 둔갑하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("직접 지정하고 승인") { if onApply(value) { dismiss() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(CaptureStamp.parse(value) == nil)
            }
        }.padding(24).frame(width: 480)
    }
}
