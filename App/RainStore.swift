import SwiftUI
import AppKit
import Combine
import UserNotifications
#if SWIFT_PACKAGE
import RainCore
#endif

enum BaseMapStyle: String, CaseIterable, Identifiable {
    case grayRoads, blank
    var id: String { rawValue }
    var label: String { self == .grayRoads ? "道路地図（白黒）" : "白地図" }
    var layer: String { self == .grayRoads ? "pale" : "blank" }
    var maximumNativeZoom: Int { self == .grayRoads ? 18 : 14 }
}

private enum FetchOutcome: Sendable {
    case snapshot(SourceSnapshot), radar([RadarFrame]), failure(String, String)
}

@MainActor
final class RainStore: ObservableObject {
    @Published private(set) var campus: Campus
    @Published private(set) var history: [RainObservation] = []
    @Published private(set) var radarFrames: [RadarFrame] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var clockNow = Date()
    @Published private(set) var lastContact: [String: Date] = [:]
    @Published var radarIndex = 0
    @Published var isPlaying = false
    @Published var showRadar = true
    @Published var radarOpacity = 0.72
    @Published var mapMessage: String?
    @Published var resetMapToken = UUID()
    @Published var inspectedStationID = "motooka"
    @Published var showStationInspector = false
    @Published var focusStationID: String?
    @Published var focusStationToken = UUID()
    @Published private(set) var snapshots: [Provider: SourceSnapshot] = [:]
    @Published private(set) var positionOverrides: [String: StationPosition] = [:]
    @Published private(set) var watchEnabled = false
    @Published var destination: Destination {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "destination"); notificationGate.reset() }
    }
    @Published var baseMapStyle: BaseMapStyle {
        didSet { UserDefaults.standard.set(baseMapStyle.rawValue, forKey: "basemap") }
    }
    @Published var cityEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cityEnabled, forKey: "cityEnabled")
            if !cityEnabled { errors["city"] = "設定で福岡市の観測データ取得が無効になっています。" }
            notificationGate.reset()
            if cityEnabled { Task { await refresh(force: true) } }
        }
    }
    @Published private(set) var lab: GeoPoint
    private var requestGeneration = UUID()
    private var lastAttempt: [String: Date] = [:]
    private var notificationGate = NotificationGate()
    private var timer: Timer?
    private var wakeObserver: AnyCancellable?
    private let cacheURL: URL

    init() {
        let defaults = UserDefaults.standard
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("ItoRain", isDirectory: true)
        cacheURL = folder.appendingPathComponent("observations-v1.json")
        let initialCampus = Campus(rawValue: defaults.string(forKey: "campus") ?? "") ?? .ito
        campus = initialCampus
        destination = Destination(rawValue: defaults.string(forKey: "destination") ?? "") ?? .takada
        baseMapStyle = BaseMapStyle(rawValue: defaults.string(forKey: "basemap") ?? "") ?? .grayRoads
        cityEnabled = defaults.object(forKey: "cityEnabled") == nil ? true : defaults.bool(forKey: "cityEnabled")
        lab = Self.savedLab(for: initialCampus)
        inspectedStationID = initialCampus.stations[0].id
        if let data = defaults.data(forKey: "stationPositions.v1"),
           let saved = try? JSONDecoder().decode([String: StationPosition].self, from: data) {
            positionOverrides = saved.filter {
                Stations.find($0.key)?.campus.contains($0.value.point) == true && $0.value.provenance == .userEntered &&
                StationPosition.user(latitude: $0.value.point.latitude, longitude: $0.value.point.longitude, note: $0.value.note) != nil
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let data = try Data(contentsOf: cacheURL)
                history = RainAssessmentEngine.merge([], try JSONDecoder().decode([RainObservation].self, from: data), now: Date())
            }
        } catch { errors["cache"] = "保存済み履歴: \(error.localizedDescription)" }
        for provider in campus.providers { errors[provider.key] = "データの取得を待っています。" }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.clockNow = Date()
                await self.refresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(force: true) }
        }
        Task { await refresh(force: true) }
    }

    var activeStations: [Station] { campus.stations }
    var referenceStations: [Station] { campus == .ito ? destination.referenceStations : activeStations }
    var visibleErrors: [String: String] {
        let keys = Set(campus.providers.map(\.key) + ["cache", "notifications"] + (campus.supportsRadar ? ["radar"] : []))
        return errors.filter { keys.contains($0.key) }
    }
    var selectedFrame: RadarFrame? { campus.supportsRadar && radarFrames.indices.contains(radarIndex) ? radarFrames[radarIndex] : nil }
    var isLatestRadar: Bool { campus.supportsRadar && !radarFrames.isEmpty && radarIndex == radarFrames.count - 1 }
    var assessment: RainAssessment {
        var failed = Set(campus.providers.filter { errors[$0.key] != nil })
        if !cityEnabled { failed.insert(.fukuoka) }
        return RainAssessmentEngine.evaluate(history: history, campus: campus, destination: destination, now: clockNow, failedProviders: failed)
    }
    var menuTitle: String {
        let station = activeStations[0]
        guard stationIssue(station) == nil, let value = latest(station)?.displayValue else { return "\(campus.shortLabel) --" }
        return String(format: "%@ %.1f", campus.shortLabel, value)
    }
    func time(_ date: Date, short: Bool = false) -> String { RainClock.local(date, campus: campus, short: short) }
    static func savedLab(for campus: Campus) -> GeoPoint {
        let defaults = UserDefaults.standard
        let key = "lab." + campus.rawValue
        if let values = defaults.array(forKey: key) as? [Double], values.count == 2 {
            let point = GeoPoint(values[0], values[1])
            if campus.contains(point) { return point }
        }
        if campus == .ito, defaults.object(forKey: "lab緯度") != nil {
            let point = GeoPoint(defaults.double(forKey: "lab緯度"), defaults.double(forKey: "lab経度"))
            if campus.contains(point) { return point }
        }
        return campus.defaultLab
    }
    func selectCampus(_ value: Campus) {
        guard value != campus else { return }
        campus = value
        UserDefaults.standard.set(value.rawValue, forKey: "campus")
        requestGeneration = UUID()
        watchEnabled = false
        notificationGate.reset()
        isPlaying = false
        radarFrames = []
        radarIndex = 0
        lastAttempt["radar"] = nil
        errors["radar"] = nil
        lab = Self.savedLab(for: value)
        inspectedStationID = value.stations[0].id
        showStationInspector = false
        focusStationID = nil
        focusStationToken = UUID()
        mapMessage = nil
        resetMapToken = UUID()
        for provider in value.providers where snapshots[provider] == nil {
            errors[provider.key] = "データの取得を待っています。"
        }
        Task { await refresh(force: true) }
    }
    var radarWarning: String? {
        guard campus.supportsRadar else { return "この地域の雨雲レイヤーは未接続です。雨量計の観測だけを表示します。" }
        if let error = errors["radar"] { return "雨雲データ: \(error)" }
        guard let date = radarFrames.last?.date else { return "雨雲データ未取得。地図が空白でも、雨が降っていないとは限りません。" }
        let age = clockNow.timeIntervalSince(date)
        if age > 15 * 60 || age < -60 { return "雨雲データの時刻が古いか無効です。公式サイトで確認してください。" }
        return nil
    }
    func latest(_ station: Station) -> RainObservation? {
        let candidates = [RainAssessmentEngine.latest(station.id, in: history),
                          snapshots[station.provider]?.observations.filter { $0.stationID == station.id }.max { $0.timestamp < $1.timestamp }].compactMap { $0 }
        return candidates.max { $0.timestamp < $1.timestamp }
    }
    func history(for stationID: String, hours: Double = 3) -> [RainObservation] {
        history.filter { $0.stationID == stationID && $0.timestamp >= clockNow.addingTimeInterval(-hours * 3600) }
    }
    func stationIssue(_ station: Station) -> String? {
        if station.provider == .fukuoka && !cityEnabled { return "取得を停止中" }
        let key = station.provider.key
        if errors[key] != nil { return "取得エラー" }
        guard let reading = latest(station) else { return "観測値なし" }
        if !reading.isFresh(at: clockNow, maxAge: station.freshnessLimit) { return "更新が遅れています" }
        if reading.displayValue == nil { return "欠測・品質フラグあり" }
        return nil
    }
    func inspect(_ station: Station) {
        inspectedStationID = station.id
        showStationInspector = true
    }
    func position(for station: Station) -> StationPosition? {
        positionOverrides[station.id] ?? station.publishedPosition
    }
    func focus(_ station: Station) {
        guard position(for: station) != nil else { return }
        focusStationID = station.id
        focusStationToken = UUID()
    }
    @discardableResult
    func setPosition(for station: Station, latitude: Double, longitude: Double, note: String) -> Bool {
        guard station.campus.contains(GeoPoint(latitude, longitude)),
              let position = StationPosition.user(latitude: latitude, longitude: longitude, note: note) else { return false }
        positionOverrides[station.id] = position
        persistPositions()
        return true
    }
    func resetPosition(for station: Station) {
        positionOverrides.removeValue(forKey: station.id)
        persistPositions()
    }
    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positionOverrides) {
            UserDefaults.standard.set(data, forKey: "stationPositions.v1")
        }
    }
    static func sourceLabel(_ key: String) -> String {
        ["waterloo": "Waterloo大学", "wyoming": "Wyoming Mesonet", "city": "福岡市", "amedas": "アメダス", "radar": "雨雲",
         "cache": "履歴保存", "notifications": "通知"][key] ?? key
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    func selectLatestRadar() {
        isPlaying = false
        radarIndex = max(0, radarFrames.count - 1)
    }
    func advanceRadar() {
        guard campus.supportsRadar, isPlaying, radarFrames.count > 1 else { return }
        radarIndex = (radarIndex + 1) % radarFrames.count
    }
    func setLab(latitude: Double, longitude: Double) -> Bool {
        let point = GeoPoint(latitude, longitude)
        guard campus.contains(point) else { return false }
        lab = point
        UserDefaults.standard.set([latitude, longitude], forKey: "lab." + campus.rawValue)
        resetMapToken = UUID()
        return true
    }
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        let now = Date()
        clockNow = now
        func due(_ key: String, seconds: Double) -> Bool {
            guard let last = lastAttempt[key] else { return true }
            return now.timeIntervalSince(last) >= (force ? 30 : seconds)
        }
        let providers = campus.providers.filter {
            ($0 != .fukuoka || cityEnabled) && due($0.key, seconds: $0.pollInterval)
        }
        let radarDue = campus.supportsRadar && due("radar", seconds: 300)
        guard !providers.isEmpty || radarDue else { return }
        let generation = requestGeneration
        isRefreshing = true
        defer {
            isRefreshing = false
            // A campus switch during an await must not leave the new campus unloaded.
            if generation != requestGeneration { Task { await refresh(force: true) } }
        }
        for provider in providers { lastAttempt[provider.key] = now }
        if radarDue { lastAttempt["radar"] = now; mapMessage = nil }
        let client = GovernmentClient()
        let selectedCampus = campus
        await withTaskGroup(of: FetchOutcome.self) { group in
            for provider in providers { group.addTask {
                do { return .snapshot(try await client.campusSnapshot(provider)) }
                catch { return .failure(provider.key, error.localizedDescription) }
            } }
            if radarDue { group.addTask {
                do { return .radar(try await (selectedCampus == .ito ? client.radar() : client.northAmericanRadar())) }
                catch { return .failure("radar", error.localizedDescription) }
            } }
            for await outcome in group {
                guard generation == requestGeneration else { continue }
                switch outcome {
                case .snapshot(let snapshot):
                    let key = snapshot.provider.key
                    snapshots[snapshot.provider] = snapshot
                    lastContact[key] = snapshot.responses.last?.receivedAt
                    if let issue = snapshot.parseIssue { errors[key] = issue }
                    else {
                        history = RainAssessmentEngine.merge(history, snapshot.observations, now: Date())
                        let expected = activeStations.filter { $0.provider == snapshot.provider }
                        let missing = Set(expected.map(\.id)).subtracting(snapshot.observations.map(\.stationID))
                        errors[key] = missing.isEmpty ? nil : "取得できなかった観測所: \(missing.sorted().joined(separator: ", "))"
                    }
                case .radar(let frames):
                    let followsLatest = radarFrames.isEmpty || isLatestRadar
                    let oldID = selectedFrame?.id
                    radarFrames = frames
                    radarIndex = followsLatest ? max(0, frames.count - 1) : (frames.firstIndex { $0.id == oldID } ?? 0)
                    lastContact["radar"] = Date()
                    errors["radar"] = nil
                case .failure(let key, let message): errors[key] = message
                }
            }
        }
        guard generation == requestGeneration else { return }
        clockNow = Date()
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: cacheURL, options: .atomic)
            errors["cache"] = nil
        } catch { errors["cache"] = error.localizedDescription }
        if watchEnabled, notificationGate.update(assessment.condition) { await sendQuietNotification() }
    }
    func setWatch(_ enabled: Bool) async {
        notificationGate.reset()
        guard enabled, campus.supportsQuietWatch else { watchEnabled = false; return }
        let generation = requestGeneration
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard generation == requestGeneration else { return }
            watchEnabled = allowed
            if allowed {
                errors["notifications"] = nil
                _ = notificationGate.update(assessment.condition)
            } else { errors["notifications"] = "通知が無効です。システム設定の「通知」で「おつかれさま」を有効にしてください。" }
        } catch { errors["notifications"] = error.localizedDescription }
    }
    private func sendQuietNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "おつかれさま：周辺の雨量計が連続して0 mmを記録"
        content.body = "\(campus.label): \(assessment.detail)"
        content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { errors["notifications"] = error.localizedDescription }
    }
    func copyDiagnostics() {
        var text = "おつかれさま 診断情報\n時刻: \(time(clockNow))\nキャンパス: \(campus.label) / \(destination.label)\n"
        for station in activeStations {
            let value = latest(station)
            text += "\(station.localName): \(value?.displayValue.map { String($0) } ?? "欠測") mm / \(value?.intervalLabel ?? "--") / 時刻=\(value.map { time($0.timestamp) } ?? "なし") / 状態=\(stationIssue(station) ?? "なし")\n"
        }
        text += "雨雲時刻（UTC）: \(selectedFrame?.validtime ?? "なし")\n"
        for (key, value) in errors.sorted(by: { $0.key < $1.key }) { text += "\(Self.sourceLabel(key)): \(value)\n" }
        if let mapMessage { text += "地図: \(mapMessage)\n" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
