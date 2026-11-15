import Foundation

public enum RainCondition: String, Sendable { case unavailable, rainRecorded, zeroSample, quiet }

public struct RainAssessment: Sendable {
    public let condition: RainCondition
    public let title: String
    public let detail: String
    public let symbol: String
    public var canNotify: Bool { condition == .quiet }
}

public enum RainAssessmentEngine {
    public static func evaluate(history: [RainObservation], campus: Campus,
                                destination: Destination = .takada, now: Date,
                                failedProviders: Set<Provider> = []) -> RainAssessment {
        if campus == .ito {
            return evaluate(history: history, destination: destination, now: now, failedProviders: failedProviders)
        }
        if campus == .wyoming {
            return RainAssessment(condition: .unavailable, title: "観測値を確認",
                detail: "Greenhouseの降水量を表示します。積算期間が未確認のため、止雨の判定と通知は行いません。", symbol: "info.circle")
        }
        let station = Stations.soulis
        let unique = merge([], history, now: now).filter { $0.stationID == station.id }
        guard !failedProviders.contains(.waterloo), let record = latest(station.id, in: unique),
              record.isFresh(at: now, maxAge: station.freshnessLimit), let amount = record.fifteenMinutes else {
            return RainAssessment(condition: .unavailable, title: "15分降水量を待っています",
                detail: "冬季は1時間・24時間値のみの場合があります。欠測・古い観測・取得失敗も無降水とは判定しません。", symbol: "questionmark.circle")
        }
        if amount > 0 {
            return RainAssessment(condition: .rainRecorded, title: "北キャンパスで降水を観測",
                detail: "Soulisの15分降水量が0 mmを超えています。観測所以外の天気や雨雪の別は確定できません。", symbol: "cloud.rain")
        }
        let records = Array(unique.sorted { $0.timestamp > $1.timestamp }.prefix(3))
        let quiet = records.count == 3 && records.allSatisfy { $0.fifteenMinutes == 0 } &&
            zip(records, records.dropFirst()).allSatisfy { abs($0.timestamp.timeIntervalSince($1.timestamp) - 900) <= 1 }
        return RainAssessment(condition: quiet ? .quiet : .zeroSample,
            title: quiet ? "Soulisは3回連続で0 mm" : "直近の15分値は0 mm",
            detail: quiet ? "15分降水量が3回連続で0 mmです。研究室や帰り道の無降水を保証しません。外の様子を確認してください。" : "3回連続には達していません。雨が止んだことの証明ではありません。",
            symbol: quiet ? "checkmark.circle" : "cloud")
    }

    public static func merge(_ previous: [RainObservation], _ incoming: [RainObservation], now: Date) -> [RainObservation] {
        var byID: [String: RainObservation] = [:]
        for reading in previous + incoming {
            guard now.timeIntervalSince(reading.timestamp) <= 48 * 3600,
                  reading.timestamp <= now.addingTimeInterval(60) else { continue }
            if let existing = byID[reading.id], existing.fetchedAt > reading.fetchedAt { continue }
            byID[reading.id] = reading
        }
        return byID.values.sorted { $0.timestamp < $1.timestamp }
    }
    public static func latest(_ id: String, in history: [RainObservation]) -> RainObservation? {
        history.filter { $0.stationID == id }.max { $0.timestamp < $1.timestamp }
    }
    public static func evaluate(history: [RainObservation], destination: Destination, now: Date,
                                failedProviders: Set<Provider> = []) -> RainAssessment {
        let stations = destination.referenceStations
        let latest = stations.compactMap { self.latest($0.id, in: history) }
        guard !stations.contains(where: { failedProviders.contains($0.provider) }),
              latest.count == stations.count,
              latest.allSatisfy({ $0.isFresh(at: now) && $0.tenMinutes != nil }) else {
            return RainAssessment(condition: .unavailable, title: "新しい観測値が足りません",
                detail: "参考雨量計に欠測、更新の遅れ、取得エラーがあります。雨が降っていないとは判断できません。", symbol: "questionmark.circle")
        }
        let wet = latest.filter { ($0.tenMinutes ?? 0) > 0 }
        if !wet.isEmpty {
            let names = wet.compactMap { Stations.find($0.stationID)?.name }.joined(separator: ", ")
            return RainAssessment(condition: .rainRecorded, title: "周辺で降雨を観測",
                detail: "\(names)で直近の10分間に降雨を観測しました。雨雲と研究室の外を確認してください。", symbol: "cloud.rain")
        }
        let quiet = stations.allSatisfy { station in
            let records = Array(history.filter { $0.stationID == station.id }.sorted { $0.timestamp > $1.timestamp }.prefix(3))
            guard records.count == 3, records.allSatisfy({ $0.tenMinutes == 0 }) else { return false }
            // Three distinct, adjacent 10-minute observations: repeated polling never counts.
            return zip(records, records.dropFirst()).allSatisfy {
                abs($0.timestamp.timeIntervalSince($1.timestamp) - 600) <= 1
            }
        }
        if quiet {
            return RainAssessment(condition: .quiet, title: "周辺の雨量計は連続して0 mm",
                detail: "選択した参考雨量計で10分雨量が3回連続して0 mmです。出発前に最新の雨雲を確認してください。霧雨や局地的な雨は残る場合があります。", symbol: "checkmark.circle")
        }
        return RainAssessment(condition: .zeroSample, title: "直近の観測は0 mm",
            detail: "参考雨量計は0 mmですが、3回連続には達していません。研究室で雨が止んだことを示すものではありません。", symbol: "cloud")
    }
}

public struct NotificationGate: Sendable {
    private var armed = false
    public init() {}
    public mutating func reset() { armed = false }
    public mutating func update(_ condition: RainCondition) -> Bool {
        if condition == .rainRecorded { armed = true }
        if condition == .unavailable { armed = false }
        if condition == .quiet && armed { armed = false; return true }
        return false
    }
}

public struct TileAddress: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int
    public let subdivisions: Int
    public let column: Int
    public let row: Int
    public static func parent(x: Int, y: Int, z: Int, maximumNativeZoom: Int) -> TileAddress {
        let delta = max(0, min(z - maximumNativeZoom, 20))
        let factor = 1 << delta
        return TileAddress(x: x / factor, y: y / factor, z: z - delta,
                           subdivisions: factor, column: x % factor, row: y % factor)
    }
}
