import SwiftUI
import AppKit
import Charts
import Combine
#if SWIFT_PACKAGE
import RainCore
#endif

private func rainText(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "--"
}

@MainActor
struct DashboardView: View {
    @EnvironmentObject var store: RainStore
    private let playback = Timer.publish(every: 0.85, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 330)
            Divider()
            mapPanel.frame(minWidth: 600, minHeight: 700)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.drizzle").font(.title3)
                    Text("おつかれさま").font(.system(.headline, design: .rounded)).tracking(2)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                CampusPicker().frame(width: 175)
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await store.refresh(force: true) } } label: { Label("更新", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing).help("データを更新（リクエスト間隔は30秒以上）")
                SettingsLink { Image(systemName: "gearshape") }.help("設定・データの出典")
            }
        }
        .onReceive(playback) { _ in store.advanceRadar() }
        .sheet(isPresented: $store.showStationInspector) {
            StationInspectorView().environmentObject(store)
        }
    }
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("研究室を出る前に").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Text(store.assessment.title).font(.system(size: 25, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text(store.assessment.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                if store.campus == .ito {
                VStack(alignment: .leading, spacing: 8) {
                    Text("帰る方向").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Picker("帰る方向", selection: $store.destination) {
                        Text("高田").tag(Destination.takada)
                        Text("学研都市").tag(Destination.gakken)
                        Text("前原").tag(Destination.maebaru)
                    }.pickerStyle(.segmented).labelsHidden()
                    Text("方面に応じた参考雨量計を選びます。道路経路の判定ではありません。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                } else {
                    Text(store.campus.dataNotice).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { store.watchEnabled }, set: { value in Task { await store.setWatch(value) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("雨量が落ち着いたら通知").font(.system(size: 12, weight: .medium))
                        Text(store.campus.watchDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small).disabled(!store.campus.supportsQuietWatch)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("地上の降水観測").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        Spacer()
                        Text("mm / 各観測の集計期間").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    ForEach(store.activeStations) { station in
                        StationCard(station: station, selected: store.inspectedStationID == station.id,
                                    reference: store.referenceStations.contains(station))
                    }
                }
                GaugeHistoryView()
                Text("0 mmは、その時間帯に測定可能な降水がなかったという意味です。近隣の雨量計は、研究室や自宅の雨量計ではありません。")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(2)
                if !store.visibleErrors.isEmpty {
                    DisclosureGroup("取得状況（\(store.visibleErrors.count)）") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(store.visibleErrors.keys.sorted(), id: \.self) { key in
                                Text("\(RainStore.sourceLabel(key)): \(store.visibleErrors[key] ?? "")").font(.caption2).textSelection(.enabled)
                            }
                            Button("診断情報をコピー") { store.copyDiagnostics() }.font(.caption)
                        }.padding(.top, 8)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22)
        }
    }
    private var mapPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.campus.label)
                        .font(.system(size: 11, weight: .semibold)).tracking(1)
                    Text(store.time(store.clockNow) + " / 実測データ")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.campus == .ito {
                Picker("背景地図", selection: $store.baseMapStyle) {
                    ForEach(BaseMapStyle.allCases) { style in Text(style.label).tag(style) }
                }.labelsHidden().frame(width: 120)
                }
                Button { store.resetMapToken = UUID() } label: { Image(systemName: "scope") }.help("生活圏の全体を表示")
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            ZStack(alignment: .topLeading) {
                RainMapView().id(store.campus)
                VStack(alignment: .leading, spacing: 8) {
                    if store.campus.supportsRadar {
                    HStack(spacing: 8) {
                        Circle().fill(store.isLatestRadar ? Color.primary : Color.secondary).frame(width: 6, height: 6)
                        Text(store.isLatestRadar ? "最新の降水解析" : "過去の降水解析")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.1)
                        if let date = store.selectedFrame?.date {
                            Text(RainClock.full(date)).font(.system(size: 11, design: .monospaced))
                        }
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    if !store.isLatestRadar && store.selectedFrame != nil {
                        mapNotice("過去の雨雲を表示中です。雨量計のカードは最新の観測値です。")
                    }
                    }
                    if let warning = store.radarWarning { mapNotice(warning) }
                    if let error = store.mapMessage { mapNotice(error + " 空白は画像の欠落である可能性があり、無降水とは限りません。") }
                    if store.campus.supportsRadar && !store.showRadar { mapNotice("雨雲は非表示です。背景地図だけでは降雨の有無は分かりません。") }
                }.padding(16)
            }.frame(maxHeight: .infinity)
            Divider()
            if store.campus.supportsRadar { radarControls }
            Divider()
            HStack(spacing: 12) {
                Link(store.campus.mapAttribution, destination: store.campus.mapSourceURL)
                Link("観測データの出典", destination: store.campus.sourceURL)
                if store.campus.supportsRadar {
                    Link(store.campus == .ito ? "気象庁の雨雲" : "カナダ気象庁のレーダー", destination: URL(string: store.campus == .ito ? "https://www.jma.go.jp/bosai/nowc/" : "https://weather.gc.ca/map_e.html?layers=radar")!)
                }
                Spacer()
                Text("政府地図を白黒で表示").foregroundStyle(.secondary)
            }.font(.system(size: 10)).padding(.horizontal, 16).padding(.vertical, 9)
        }
    }
    private func mapNotice(_ message: String) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 480, alignment: .leading)
    }
    private var radarControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if store.isLatestRadar { store.radarIndex = 0 }
                    store.isPlaying.toggle()
                } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 14) }
                    .disabled(store.radarFrames.count < 2 || !store.showRadar)
                    .help("過去の降水解析を再生")
                Text(store.radarFrames.first?.date.map { RainClock.time($0) } ?? "--:--")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(store.radarIndex) }, set: { store.isPlaying = false; store.radarIndex = Int($0) }),
                       in: 0...Double(max(1, store.radarFrames.count - 1)), step: 1)
                    .disabled(store.radarFrames.count < 2).help("過去の降水解析（最大90分）")
                Button("最新") { store.selectLatestRadar() }.controlSize(.small)
                    .disabled(store.radarFrames.isEmpty)
            }
            HStack(spacing: 14) {
                Toggle("雨雲", isOn: $store.showRadar).toggleStyle(.switch).controlSize(.mini)
                Text("濃さ").font(.caption).foregroundStyle(.secondary)
                Slider(value: $store.radarOpacity, in: 0.2...1).frame(width: 90)
                Spacer()
                if store.campus == .ito { RainLegend() }
                else { Text("最新のみ・雨換算（雪の区別なし）").font(.caption2); Link("レーダー凡例（mm/h）", destination: URL(string: "https://geo.weather.gc.ca/geomet?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetLegendGraphic&LAYER=RADAR_1KM_RRAI&STYLE=Radar-Rain_14colors&FORMAT=image/png")!) }
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
    }
}

@MainActor
private struct StationCard: View {
    @EnvironmentObject var store: RainStore
    let station: Station
    let selected: Bool
    let reference: Bool
    var body: some View {
        let observation = store.latest(station)
        let issue = store.stationIssue(station)
        Button { store.inspect(station) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(station.localName).font(.system(size: 13, weight: .semibold))
                            if reference { Image(systemName: "smallcircle.filled.circle").font(.system(size: 7)).help("選択した方面の参考雨量計") }
                        }
                        Text(station.provider.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(rainText(observation?.displayValue)).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(issue == nil ? Color.primary : Color.secondary)
                }
                HStack {
                    if let issue {
                        Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 9))
                    } else {
                        Text("mm / \(observation?.intervalLabel ?? "--")").font(.system(size: 10, design: .monospaced))
                    }
                    Spacer()
                    if let observation {
                        Text("\(observation.timestampKind == .pageSnapshot ? "表示" : "観測") \(store.time(observation.timestamp))")
                            .font(.system(size: 9, design: .monospaced))
                    }
                }.foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "location")
                    Text(store.position(for: station).map {
                        $0.coordinateText + ($0.provenance == .userEntered ? "（手動）" : "")
                    } ?? "設備の座標は未確認")
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.primary.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
        .help("クリックして座標と受信原文を表示")
        .contextMenu {
            Button("観測所の詳細") { store.inspect(station) }
            if let position = store.position(for: station) {
                Button("座標をコピー") { RainStore.copy(position.coordinateText) }
            }
            Link("公式サイトを開く", destination: station.sourceURL)
        }
    }
}

@MainActor
private struct GaugeHistoryView: View {
    @EnvironmentObject var store: RainStore
    var body: some View {
        let station = Stations.find(store.inspectedStationID) ?? store.activeStations[0]
        let window = store.latest(station)?.intervalLabel ?? "--"
        let records = store.history(for: station.id).filter { $0.intervalLabel == window }
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("\(station.localName) / 過去3時間").font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Link(destination: station.sourceURL) { Image(systemName: "arrow.up.right.square") }
            }
            if records.contains(where: { $0.displayValue != nil }) {
                Chart(records) { record in
                    if let value = record.displayValue {
                        BarMark(x: .value("表示時刻", record.timestamp), y: .value("mm / \(window)", value), width: .fixed(5))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
                .chartXScale(domain: store.clockNow.addingTimeInterval(-3 * 3600)...store.clockNow)
                .chartYScale(domain: 0...max(1, (records.compactMap(\.displayValue).max() ?? 0) * 1.15))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let date = value.as(Date.self) { Text(store.time(date, short: true)) } }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 100)
            } else {
                Text("アプリを起動している間に履歴を収集します。欠測期間を0で補うことはありません。")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 70)
            }
            Text("mm / \(window)。異なる統計期間は混ぜません。このMacで収集した履歴です。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct RainLegend: View {
    private let levels: [(String, Color)] = [
        ("<1", Color(red: 0.88, green: 0.89, blue: 0.94)),
        ("1", Color(red: 0.63, green: 0.82, blue: 1)),
        ("5", Color(red: 0.13, green: 0.55, blue: 1)),
        ("10", Color(red: 0, green: 0.25, blue: 1)),
        ("20", Color(red: 0.98, green: 0.96, blue: 0)),
        ("30", Color(red: 1, green: 0.60, blue: 0)),
        ("50", Color(red: 1, green: 0.16, blue: 0)),
        ("80+", Color(red: 0.71, green: 0, blue: 0.41))
    ]
    var body: some View {
        HStack(spacing: 3) {
            Text("mm/h").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(levels, id: \.0) { level in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(level.1).frame(width: 22, height: 5)
                    Text(level.0).font(.system(size: 8, design: .monospaced))
                }
            }
        }.help("雨雲の降水強度です。雨量計の10分間の積算雨量とは異なります。")
    }
}

@MainActor
struct MenuPanel: View {
    @EnvironmentObject var store: RainStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("おつかれさま", systemImage: store.assessment.symbol).font(.headline)
                Spacer()
                Text("mm / 各観測の集計期間").font(.caption2).foregroundStyle(.secondary)
            }
            CampusPicker()
            Text(store.assessment.title).font(.system(size: 18, weight: .semibold, design: .rounded))
            ForEach(store.referenceStations) { station in
                Button {
                    openWindow(id: "dashboard")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    store.inspect(station)
                } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(station.localName)
                        Text(store.latest(station)?.intervalLabel ?? "--").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.stationIssue(station) != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary) }
                    Text(rainText(store.latest(station)?.displayValue)).monospacedDigit()
                    Text(store.latest(station).map { store.time($0.timestamp, short: true) } ?? "--:--")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                }.buttonStyle(.plain)
            }
            Text("近隣の参考値です。出発前に雨雲と外の様子を確認してください。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: { Label("雨雲と観測地図を開く", systemImage: "map") }
                .buttonStyle(.borderedProminent).tint(.primary).frame(maxWidth: .infinity)
            HStack {
                Button("更新") { Task { await store.refresh(force: true) } }.disabled(store.isRefreshing)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                Button("終了") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
        }.padding(20).frame(width: 310)
    }
}

@MainActor
struct CampusPicker: View {
    @EnvironmentObject var store: RainStore
    var body: some View {
        Picker("キャンパス", selection: Binding(get: { store.campus }, set: { store.selectCampus($0) })) {
            ForEach(Campus.allCases) { campus in Text(campus.label).tag(campus) }
        }.labelsHidden().help("地域を切り替えると通知の待機を解除します")
    }
}
