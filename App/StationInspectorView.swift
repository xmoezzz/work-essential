import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import RainCore
#endif

/// Presents source text, never executes remote HTML or JavaScript.
private struct SourceTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}

private struct OriginalResponseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct StationInspectorView: View {
    @EnvironmentObject var store: RainStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var responseIndex = 0
    @State private var showExcerpt = false
    @State private var exportDocument = OriginalResponseDocument(Data())
    @State private var exportName = "response.bin"
    @State private var exportType = UTType.data
    @State private var exporting = false
    @State private var status = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var positionNote = ""

    private var station: Station { Stations.find(store.inspectedStationID) ?? store.activeStations[0] }
    private var snapshot: SourceSnapshot? { store.snapshots[station.provider] }
    private var responses: [SourcePayload] { snapshot?.responses ?? [] }
    private var response: SourcePayload? { responses.indices.contains(responseIndex) ? responses[responseIndex] : responses.last }
    private var record: RainObservation? { store.latest(station) }
    private var rawText: String {
        if showExcerpt {
            return snapshot?.excerpt(for: station) ?? "この観測所の抜粋を取得できません。"
        }
        return response?.text ?? "文字としてデコードできません。原本ファイルは保存できます。"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("観測所の詳細").font(.title2.bold())
                    Text("座標・観測値・受信データ").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("観測所", selection: $store.inspectedStationID) {
                    ForEach(store.activeStations) { Text($0.localName).tag($0.id) }
                }.frame(width: 195)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(station.localName)  /  \(station.provider.label)").font(.headline)
                    Text(station.address).font(.caption).foregroundStyle(.secondary)
                    if let position = store.position(for: station) {
                        Text(position.coordinateText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(position.provenance.label).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("座標未確認・地図上の設備ピンは非表示").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("地図で表示") { store.focus(station); dismiss() }
                        .disabled(store.position(for: station) == nil)
                    Link("公式サイト", destination: station.sourceURL)
                }
            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if let issue = store.stationIssue(station) {
                Label(issue + "。保持している最終データと取得時刻を確認してください。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("表示内容", selection: $tab) {
                Text("観測値").tag(0)
                Text("受信データ").tag(1)
                Text("所在地・座標").tag(2)
            }.pickerStyle(.segmented)
            Group {
                switch tab {
                case 1: rawPanel
                case 2: positionPanel
                default: observationPanel
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(22)
        .frame(minWidth: 850, idealWidth: 920, maxWidth: 1200, minHeight: 760, idealHeight: 820)
        .onAppear { resetSelection() }
        .onChange(of: store.inspectedStationID) { _, _ in resetSelection() }
        .onChange(of: responses.map(\.id)) { _, _ in
            responseIndex = max(0, responses.count - 1)
            showExcerpt = false
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            switch result {
            case .success: status = "原本を保存しました。"
            case .failure(let error): status = "保存失敗: \(error.localizedDescription)"
            }
        }
    }
    private var observationPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let record {
                HStack {
                    Text("\(record.timestampKind == .pageSnapshot ? "ページ表示時刻" : "観測時刻"): \(store.time(record.timestamp))")
                    Spacer()
                    Text("取得: \(store.time(record.fetchedAt))")
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if station.provider == .wyoming {
                        metric("配信値 (mm)", record.reportedPrecipitation)
                    } else {
                        if station.provider == .waterloo { metric("15分", record.fifteenMinutes) }
                        else { metric("10分", record.tenMinutes) }
                        metric("1時間", record.oneHour)
                        if station.campus == .ito { metric("3時間", record.threeHours) }
                        metric("24時間", record.twentyFourHours)
                    }
                }
            } else {
                Text("観測データをまだ取得していません。").foregroundStyle(.secondary)
            }
            Text(station.intervalNote).font(.caption).foregroundStyle(.secondary)
            if let sourceTime = record?.sourceTimestampText {
                Text("配信元の時刻: \(sourceTime)\n\(record?.sourceTimeZoneNote ?? "")")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            let fields = snapshot?.fields(for: station) ?? []
            if !fields.isEmpty {
                HStack {
                    Text("最新受信応答のフィールド").font(.headline)
                    Spacer()
                    if let received = snapshot?.observationResponse?.receivedAt {
                        Text("受信: " + store.time(received)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 7) {
                    GridRow { Text("項目"); Text("配信元の値"); Text("採用値（mm）") }.font(.caption.bold())
                    ForEach(fields) { field in
                        GridRow {
                            Text(field.label)
                            Text(field.sourceValue).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(field.parsedValue.map { String(format: "%.1f", $0) } ?? "欠測・未採用")
                        }
                    }
                }.font(.caption)
                Text(station.provider == .jma
                    ? "JSONの配列は値と品質フラグをそのまま表示します。欠測や品質フラグ付きの値は0に変換しません。"
                    : "HTML表の文字列と解析結果を併記。タグを含む原文は「受信データ」で確認できます。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text("観測履歴（このMacで収集・過去3時間）").font(.headline)
            Table(Array(store.history(for: station.id).reversed())) {
                TableColumn("時刻") { Text(store.time($0.timestamp)) }.width(min: 115)
                TableColumn("表示値 mm") { Text(number($0.displayValue)) }
                TableColumn("集計期間") { Text($0.intervalLabel) }
                TableColumn("1時間 mm") { Text(number($0.oneHour)) }
                TableColumn("3時間 mm") { Text(number($0.threeHours)) }
                TableColumn("24時間 mm") { Text(number($0.twentyFourHours)) }
            }.frame(minHeight: 130)
            Text("履歴は解析済みの観測表です。受信原文は起動中の最新応答のみ保持します。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var rawPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !responses.isEmpty {
                Picker("応答", selection: $responseIndex) {
                    ForEach(Array(responses.enumerated()), id: \.offset) { index, payload in
                        Text(payload.requestURL.lastPathComponent.isEmpty ? station.provider.label + " HTML" : payload.requestURL.lastPathComponent).tag(index)
                    }
                }
                if let response {
                    Text(response.requestURL.absoluteString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text("HTTP \(response.statusCode)  /  \(response.body.count) bytes")
                        Spacer()
                        Text("受信: \(store.time(response.receivedAt))")
                    }.font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("HTTPヘッダー・最終URL") {
                        ScrollView {
                            Text("\(response.responseURL.absoluteString)\n" + response.headers.keys.sorted().map { "\($0): \(response.headers[$0] ?? "")" }.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }.font(.caption)
                    HStack {
                        Toggle("観測所だけ抜粋", isOn: $showExcerpt)
                            .disabled(response.id != snapshot?.observationResponse?.id)
                        Spacer()
                        Button("表示中の文字をコピー") { RainStore.copy(rawText); status = "コピーしました。" }
                        Button("全応答の原本を保存") { export(response) }
                    }.font(.caption)
                    SourceTextView(text: rawText).frame(minHeight: 180)
                    Text(showExcerpt
                         ? (station.provider == .jma ? "観測所JSONの抜粋を表示用に整形しています。原本保存は整形前の全応答です。" : (station.provider == .waterloo ? "時刻と降水行の文字を整形した抜粋です。全応答の原本は改変しません。" : "該当するHTMLの行をタグごとそのまま抜粋しています。"))
                         : "URLSessionが受信した応答本文です。HTMLを実行せず文字として表示します。保存時は受信バイト列を変更しません。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let issue = snapshot?.parseIssue { Text("解析結果: \(issue)").font(.caption).textSelection(.enabled) }
                Text("取得・解析失敗時は、観測表の最終成功データとこの応答の時刻が異なる場合があります。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("受信原文なし", systemImage: "doc.questionmark", description: Text("起動後に取得した応答がここに表示されます。保存済みの観測値から原文を再生成することはしません。"))
                Button("データを更新") { Task { await store.refresh(force: true) } }.disabled(store.isRefreshing)
            }
        }.onChange(of: responseIndex) { _, _ in showExcerpt = false }
    }
    private var positionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let position = store.position(for: station) {
                    HStack {
                        Label(position.provenance.label, systemImage: position.provenance == .officialCatalog ? "checkmark.seal" : "pencil.circle")
                        Spacer()
                        Button("座標をコピー") { RainStore.copy(position.coordinateText); status = "座標をコピーしました。" }
                        Link("外部の地図で開く", destination: position.gsiURL)
                    }
                    Text(position.coordinateText).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Text("出典: \(position.source)\n\(position.note)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Label("設備の緯度・経度は未確認", systemImage: "location.slash").font(.headline)
                    Text("住所の代表点を設備の座標として表示することはしません。公式ページの位置図を確認し、必要に応じて下で座標を入力できます。").font(.caption).foregroundStyle(.secondary)
                }
                Link("公式の所在地・位置図を確認", destination: station.sourceURL)
                if let url = station.positionMapURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        case .failure: Label("位置図を取得できません。公式サイトで確認してください。", systemImage: "exclamationmark.triangle")
                        default: ProgressView()
                        }
                    }
                    .frame(maxHeight: 230)
                    Text("出典: 福岡市防災気象情報の公開位置図").font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                Text("このMacで使う座標").font(.headline)
                HStack {
                    TextField("緯度（小数度）", text: $latitude)
                    TextField("経度（小数度）", text: $longitude)
                }
                TextField("出典・確認方法（必須）", text: $positionNote)
                Text("入力値は常に「ユーザー入力（未検証）」と表示し、公式座標と区別します。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("座標を保存") {
                        guard let lat = Double(latitude), let lon = Double(longitude),
                              store.setPosition(for: station, latitude: lat, longitude: lon, note: positionNote) else {
                            status = "選択した大学周辺の有効な座標と出典を入力してください。"
                            return
                        }
                        status = "保存しました。地図に未検証のピンを表示します。"
                    }
                    Button("入力値を削除") { store.resetPosition(for: station); resetSelection() }
                        .disabled(store.positionOverrides[station.id] == nil)
                }
            }.textFieldStyle(.roundedBorder).padding(.vertical, 4)
        }
    }
    private func resetSelection() {
        responseIndex = max(0, responses.count - 1); showExcerpt = false; status = ""
        let position = store.position(for: station)
        latitude = position.map { String(format: "%.6f", $0.point.latitude) } ?? ""
        longitude = position.map { String(format: "%.6f", $0.point.longitude) } ?? ""
        positionNote = store.positionOverrides[station.id]?.note ?? ""
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "欠測" }
    private func metric(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(number(value) + " mm").font(.system(.title3, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func export(_ response: SourcePayload) {
        exportDocument = OriginalResponseDocument(response.body)
        exportName = response.suggestedFilename
        exportType = UTType(filenameExtension: response.fileExtension) ?? .data
        exporting = true
    }
}
