import SwiftUI
import MapKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import RainCore
#endif

private enum TileFetchError: Error { case notFound }

private actor TileCache {
    static let shared = TileCache()
    private let memory = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    private let session: URLSession
    init() {
        memory.totalCostLimit = 64 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 18
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024,
                                  diskPath: "ItoRainTiles")
        session = URLSession(configuration: config)
    }
    func data(for url: URL) async throws -> Data {
        let key = url.absoluteString
        if let data = memory.object(forKey: key as NSString) { return data as Data }
        if let task = inFlight[key] { return try await task.value }
        let session = self.session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 18))
            if (response as? HTTPURLResponse)?.statusCode == 404 { throw TileFetchError.notFound }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RainError.invalidResponse("地図 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard data.count < 4_000_000, CGImageSourceCreateWithData(data as CFData, nil) != nil else {
                throw RainError.invalidData("地図タイルが対応する画像形式ではありません。")
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let result = try await task.value
        memory.setObject(result as NSData, forKey: key as NSString, cost: result.count)
        return result
    }
}

// Overzoom is explicit: radar has fewer native zoom levels than a street map.
// Without cropping the correct parent tile, rain disappears or shifts at campus zoom.
private final class GovernmentTileOverlay: MKTileOverlay {
    let template: String
    let nativeMaximum: Int
    let grayscale: Bool
    let radarID: String?
    let failure: (String, String?) -> Void
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    init(template: String, nativeMaximum: Int, grayscale: Bool, radarID: String? = nil, replacesMap: Bool = true,
         failure: @escaping (String, String?) -> Void) {
        self.template = template; self.nativeMaximum = nativeMaximum
        self.grayscale = grayscale; self.radarID = radarID; self.failure = failure
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 5; maximumZ = 20
        canReplaceMapContent = radarID == nil && replacesMap
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        Task {
            var maximum = nativeMaximum
            while true {
                let address = TileAddress.parent(x: path.x, y: path.y, z: path.z, maximumNativeZoom: maximum)
                var urlString = template.replacingOccurrences(of: "{z}", with: String(address.z))
                    .replacingOccurrences(of: "{x}", with: String(address.x))
                    .replacingOccurrences(of: "{y}", with: String(address.y))
                if template.contains("{bbox}") {
                    let world = 20037508.342789244
                    let width = 2 * world / pow(2, Double(address.z))
                    let minX = -world + Double(address.x) * width
                    let maxY = world - Double(address.y) * width
                    let bbox = [minX, maxY - width, minX + width, maxY].map { String(format: "%.3f", $0) }.joined(separator: ",")
                    urlString = urlString.replacingOccurrences(of: "{bbox}", with: bbox)
                }
                guard let url = URL(string: urlString) else { result(nil, RainError.invalidData("地図タイルのURLが無効です")); return }
                do {
                    let raw = try await TileCache.shared.data(for: url)
                    result(try Self.transform(raw, address: address, grayscale: grayscale), nil)
                    return
                } catch TileFetchError.notFound where radarID == nil && address.z > 5 {
                    maximum = address.z - 1
                } catch {
                    failure("\(radarID == nil ? "背景地図" : "雨雲")タイル取得失敗: \(error.localizedDescription)", radarID)
                    result(nil, error)
                    return
                }
            }
        }
    }

    private static func transform(_ data: Data, address: TileAddress, grayscale: Bool) throws -> Data {
        if address.subdivisions == 1 && !grayscale { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RainError.invalidData("地図画像の読み込みに失敗しました") }
        if address.subdivisions > 1 {
            let side = CGFloat(address.subdivisions)
            let width = CGFloat(image.width) / side, height = CGFloat(image.height) / side
            let rect = CGRect(x: CGFloat(address.column) * width, y: CGFloat(address.row) * height, width: width, height: height)
            guard let cropped = image.cropping(to: rect) else { throw RainError.invalidData("地図画像の切り出しに失敗しました") }
            image = cropped
        }
        if grayscale {
            let filtered = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            guard let gray = imageContext.createCGImage(filtered, from: filtered.extent) else { throw RainError.invalidData("地図の白黒変換に失敗しました") }
            image = gray
        }
        guard let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RainError.invalidData("地図の描画領域を作成できません") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let rendered = context.makeImage() else { throw RainError.invalidData("地図の描画に失敗しました") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw RainError.invalidData("PNG変換の準備に失敗しました") }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw RainError.invalidData("PNG変換に失敗しました") }
        return output as Data
    }
}

private final class PlaceAnnotation: MKPointAnnotation {
    let placeID: String
    let glyph: String
    init(id: String, name: String, point: GeoPoint, glyph: String) {
        placeID = id; self.glyph = glyph
        super.init()
        title = name
        subtitle = "生活地点の目安です。雨量計の設置場所ではありません。"
        coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

private final class StationAnnotation: MKPointAnnotation {
    let station: Station
    let position: StationPosition
    init(station: Station, position: StationPosition) {
        self.station = station; self.position = position
        super.init()
        title = station.localName + (position.provenance == .userEntered ? "（手動）" : "")
        coordinate = CLLocationCoordinate2D(latitude: position.point.latitude, longitude: position.point.longitude)
        subtitle = "\(position.coordinateText) / \(position.provenance.label)"
    }
}

@MainActor
struct RainMapView: NSViewRepresentable {
    @EnvironmentObject var store: RainStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.appearance = NSAppearance(named: .aqua)
        map.showsCompass = true
        map.showsScale = true
        map.showsZoomControls = true
        map.showsBuildings = false
        map.showsTraffic = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1200, maxCenterCoordinateDistance: 42000)
        map.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: store.campus.center.latitude, longitude: store.campus.center.longitude), span: MKCoordinateSpan(latitudeDelta: 0.23, longitudeDelta: 0.34)))
        context.coordinator.update(map)
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) { context.coordinator.update(map) }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let store: RainStore
        private var campusID: Campus?
        private var labels: GovernmentTileOverlay?
        private var base: GovernmentTileOverlay?
        private var radar: GovernmentTileOverlay?
        private var baseStyle: BaseMapStyle?
        private var frameID: String?
        private var resetToken: UUID?
        private var lab: GeoPoint?
        private var stationPositions: [String: StationPosition] = [:]
        private var focusToken: UUID?
        init(store: RainStore) { self.store = store }
        func update(_ map: MKMapView) {
            if baseStyle != store.baseMapStyle || campusID != store.campus {
                campusID = store.campus
                if let labels { map.removeOverlay(labels) }
                labels = nil
                if let base { map.removeOverlay(base) }
                baseStyle = store.baseMapStyle
                let style = store.baseMapStyle
                let template = store.campus.overseasBaseTemplate ?? "https://cyberjapandata.gsi.go.jp/xyz/\(style.layer)/{z}/{x}/{y}.png"
                let overlay = GovernmentTileOverlay(template: template,
                    nativeMaximum: store.campus == .ito ? style.maximumNativeZoom : (store.campus == .waterloo ? 15 : 16),
                    grayscale: store.campus != .ito || style == .grayRoads, failure: onFailure)
                base = overlay
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                if let template = store.campus.labelsTemplate {
                    let textOverlay = GovernmentTileOverlay(template: template, nativeMaximum: 16, grayscale: true,
                                                            replacesMap: false, failure: onFailure)
                    labels = textOverlay
                    map.insertOverlay(textOverlay, at: 1, level: .aboveLabels)
                }
            }
            let desiredFrame = store.campus.supportsRadar && store.showRadar ? store.selectedFrame : nil
            if desiredFrame?.id != frameID {
                if let radar { map.removeOverlay(radar) }
                radar = nil
                frameID = desiredFrame?.id
                // Clear the map warning only when the selected layer changes; a failure is not dry weather.
                DispatchQueue.main.async { [weak self] in self?.store.mapMessage = nil }
                if let frame = desiredFrame {
                    let template: String
                    if frame.elements.contains("geomet"), let date = frame.date {
                        let stamp = ISO8601DateFormatter().string(from: date)
                        template = "https://geo.weather.gc.ca/geomet?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=RADAR_1KM_RRAI&STYLES=Radar-Rain_14colors&SRS=EPSG:3857&BBOX={bbox}&WIDTH=256&HEIGHT=256&FORMAT=image/png&TRANSPARENT=TRUE&TIME=\(stamp)"
                    } else { template = frame.tileTemplate }
                    let overlay = GovernmentTileOverlay(template: template, nativeMaximum: 10, grayscale: false,
                                                        radarID: frame.id, failure: onFailure)
                    radar = overlay
                    map.addOverlay(overlay, level: .aboveLabels)
                }
            }
            if let radar, let renderer = map.renderer(for: radar) { renderer.alpha = CGFloat(store.radarOpacity) }
            if lab != store.lab || map.annotations.isEmpty {
                lab = store.lab
                map.removeAnnotations(map.annotations.compactMap { $0 as? PlaceAnnotation })
                if store.campus == .ito {
                map.addAnnotations([
                    PlaceAnnotation(id: "lab", name: store.campus.shortLabel + "・研究室", point: store.lab, glyph: "研"),
                    PlaceAnnotation(id: "takada", name: "高田", point: GeoPoint(33.5668, 130.2313), glyph: "高"),
                    PlaceAnnotation(id: "gakken", name: "九大学研都市", point: GeoPoint(33.5781, 130.2596), glyph: "学"),
                    PlaceAnnotation(id: "maebaru", name: "前原", point: GeoPoint(33.5574, 130.1990), glyph: "前")
                ])
                } else {
                    map.addAnnotation(PlaceAnnotation(id: "lab", name: store.campus.shortLabel + "・研究室", point: store.lab, glyph: "研"))
                }
            }
            let positions = Dictionary(uniqueKeysWithValues: store.activeStations.compactMap { station -> (String, StationPosition)? in
                guard let position = store.position(for: station) else { return nil }
                return (station.id, position)
            })
            if positions != stationPositions {
                stationPositions = positions
                map.removeAnnotations(map.annotations.compactMap { $0 as? StationAnnotation })
                map.addAnnotations(store.activeStations.compactMap { station in
                    positions[station.id].map { StationAnnotation(station: station, position: $0) }
                })
            }
            for pin in map.annotations.compactMap({ $0 as? StationAnnotation }) {
                let record = store.latest(pin.station)
                let rain = record?.displayValue.map { String(format: "%.1f mm", $0) + " / " + (record?.intervalLabel ?? "--") } ?? "観測値なし"
                let issue = store.stationIssue(pin.station).map { " / " + $0 } ?? ""
                if let view = map.view(for: pin) {
                    view.toolTip = "\(pin.station.localName)\n\(pin.position.coordinateText)\n\(pin.position.provenance.label)\n\(rain)\(issue)"
                }
            }
            if resetToken != store.resetMapToken {
                resetToken = store.resetMapToken
                map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: store.campus.center.latitude, longitude: store.campus.center.longitude),
                    span: MKCoordinateSpan(latitudeDelta: store.campus == .ito ? 0.080 : 0.050, longitudeDelta: store.campus == .ito ? 0.155 : 0.080)), animated: false)
            }
            if focusToken != store.focusStationToken {
                focusToken = store.focusStationToken
                if let id = store.focusStationID, let position = positions[id] {
                    map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: position.point.latitude, longitude: position.point.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.04)), animated: true)
                }
            }
        }
        private nonisolated func onFailure(_ message: String, radarID: String?) {
            Task { @MainActor [weak self] in
                guard let self, self.campusID == self.store.campus else { return }
                if let radarID, radarID != self.store.selectedFrame?.id { return }
                self.store.mapMessage = message
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? GovernmentTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = tile.radarID == nil ? 1 : CGFloat(store.radarOpacity)
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let pin = annotation as? StationAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "gauge") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: "gauge")
                view.annotation = pin
                let published = pin.position.provenance == .officialCatalog
                view.markerTintColor = published ? NSColor.labelColor : NSColor.secondaryLabelColor
                view.glyphTintColor = .white
                view.glyphImage = NSImage(systemSymbolName: published ? "drop.fill" : "questionmark", accessibilityDescription: pin.position.provenance.label)
                view.titleVisibility = .visible
                view.subtitleVisibility = .hidden
                view.displayPriority = .required
                view.canShowCallout = false
                view.toolTip = "\(pin.station.localName)\n\(pin.position.coordinateText)\n\(pin.position.provenance.label)"
                return view
            }
            guard let place = annotation as? PlaceAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "place") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: place, reuseIdentifier: "place")
            view.annotation = place
            view.glyphText = place.glyph
            view.markerTintColor = NSColor(calibratedWhite: 0.14, alpha: 1)
            view.glyphTintColor = .white
            view.titleVisibility = .visible
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            view.canShowCallout = true
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let pin = view.annotation as? StationAnnotation else { return }
            // Defer the ObservableObject mutation outside MapKit's update callback.
            DispatchQueue.main.async { [weak self, weak mapView] in
                self?.store.inspect(pin.station)
                mapView?.deselectAnnotation(pin, animated: false)
            }
        }
    }
}
