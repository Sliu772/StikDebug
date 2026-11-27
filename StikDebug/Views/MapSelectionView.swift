//
//  MapSelectionView.swift
//  StikDebug
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum RouteSearchField {
    case start
    case end
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
    static let importedRouteFallbackSpeedMetersPerSecond: CLLocationSpeed = 13.4
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
}

private enum RouteLoopMode: String, CaseIterable, Identifiable {
    case off
    case circular
    case pingPong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Once"
        case .circular: return "Loop"
        case .pingPong: return "Back & forth"
        }
    }
}

/// Reverses a playback path. Each sample stores the delay from its previous
/// sample, so the delays are shifted to stay attached to the same segment.
private func reversedPlaybackSamples(_ samples: [RoutePlaybackSample]) -> [RoutePlaybackSample] {
    guard samples.count > 1 else { return samples }
    let last = samples.count - 1
    var result: [RoutePlaybackSample] = []
    for k in 0...last {
        let index = last - k
        let delay = k == 0 ? 0 : samples[index + 1].delayFromPrevious
        result.append(RoutePlaybackSample(coordinate: samples[index].coordinate, delayFromPrevious: delay))
    }
    return result
}

/// One-shot read of where the phone currently is (needs the location permission
/// the app already asks for). Returns nil when denied or if it takes too long.
@MainActor
private final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func current() async -> CLLocationCoordinate2D? {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            self.continuation = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self.finish(self.recentKnownLocation())
            }
        }
    }

    /// The last location iOS knows, if it is recent enough to trust.
    private func recentKnownLocation() -> CLLocationCoordinate2D? {
        guard let location = manager.location,
              Date().timeIntervalSince(location.timestamp) < 900 else {
            return nil
        }
        return location.coordinate
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(self.recentKnownLocation()) }
    }
}

private struct TrailPoint: Equatable {
    var latitude: Double
    var longitude: Double
    var time: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The recorded trail as a GPX file, shared through the system share sheet.
private struct GPXExport: Transferable {
    let points: [TrailPoint]

    var gpx: String {
        let formatter = ISO8601DateFormatter()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"StikDebug\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        xml += "<trk><name>StikDebug trail</name><trkseg>\n"
        for point in points {
            xml += "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
            xml += "<time>\(formatter.string(from: point.time))</time></trkpt>\n"
        }
        xml += "</trkseg></trk>\n</gpx>\n"
        return xml
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "gpx") ?? .xml) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("StikDebug-trail.gpx")
            try export.gpx.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

private struct WanderPoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct WanderZone: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var polygon: [WanderPoint]?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private enum WanderTransport: String, CaseIterable, Identifiable {
    case driving
    case moto
    case walking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .driving: return "Car"
        case .moto: return "Moto"
        case .walking: return "Walk"
        }
    }

    var mapKitType: MKDirectionsTransportType { self == .walking ? .walking : .automobile }
}

/// Travel mode plus the settings that depend on it.
private struct WanderTravel {
    let mode: WanderTransport
    let topSpeed: CLLocationSpeed // m/s, used by Moto: always rides at this speed
    let avoidHighways: Bool

    var mapKitType: MKDirectionsTransportType { mode.mapKitType }
    var stopSpacing: ClosedRange<Double> { mode == .moto ? 700...1800 : 250...700 }
    var reach: Double { mode == .moto ? 3 : 1 }
    /// Distance over which it speeds up after a stop and slows down before the next one.
    var rampDistance: Double {
        switch mode {
        case .walking: return 0
        case .moto: return 50
        case .driving: return 40
        }
    }

    func configure(_ request: MKDirections.Request) {
        request.transportType = mapKitType
        if avoidHighways && mode != .walking {
            request.highwayPreference = .avoid
            request.tollPreference = .avoid
        }
    }
}

private enum WanderZoneKind: String, CaseIterable, Identifiable {
    case circle
    case polygon

    var id: String { rawValue }
    var title: String { self == .circle ? "Circle" : "Polygon" }
}

/// The area the wander stays in: a circle, or a polygon when `polygon` has 3+ corners.
private struct WanderZoneShape {
    let center: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let polygon: [CLLocationCoordinate2D]

    init(center: CLLocationCoordinate2D, radius: CLLocationDistance) {
        self.center = center
        self.radius = radius
        self.polygon = []
    }

    init(polygon: [CLLocationCoordinate2D]) {
        let count = Double(max(polygon.count, 1))
        let latitude = polygon.map { $0.latitude }.reduce(0, +) / count
        let longitude = polygon.map { $0.longitude }.reduce(0, +) / count
        let centroid = CLLocation(latitude: latitude, longitude: longitude)
        let farthest = polygon
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centroid) }
            .max() ?? 200
        self.center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self.radius = max(farthest, 100)
        self.polygon = polygon
    }

    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else {
            return CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) <= radius
        }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let crossing = (b.longitude - a.longitude) * (point.latitude - a.latitude)
                    / (b.latitude - a.latitude) + a.longitude
                if point.longitude < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    func randomPoint() -> CLLocationCoordinate2D {
        guard polygon.count >= 3 else { return randomCoordinate(around: center, radius: radius) }
        let latitudes = polygon.map { $0.latitude }
        let longitudes = polygon.map { $0.longitude }
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return center }
        for _ in 0..<60 {
            let point = CLLocationCoordinate2D(
                latitude: Double.random(in: minLat...maxLat),
                longitude: Double.random(in: minLon...maxLon)
            )
            if contains(point) { return point }
        }
        return center
    }
}

private enum WanderZoneStore {
    static let key = "wanderZones"

    static func load() -> [WanderZone] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let zones = try? JSONDecoder().decode([WanderZone].self, from: data) else {
            return []
        }
        return zones
    }

    static func save(_ zones: [WanderZone]) {
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Applies the speed factor and, when `humanize` is on, makes the drive feel
/// less robotic: slower around corners, a slowly drifting speed (+-10%) and
/// short stops every few hundred meters (like traffic lights).
private func humanizedSamples(
    _ samples: [RoutePlaybackSample],
    speedFactor: Double,
    humanize: Bool,
    stopSpacing: ClosedRange<Double> = 250...700,
    rampDistance: Double = 40
) -> [RoutePlaybackSample] {
    guard samples.count > 1 else { return samples }
    guard humanize else {
        return samples.map {
            RoutePlaybackSample(coordinate: $0.coordinate, delayFromPrevious: $0.delayFromPrevious / speedFactor)
        }
    }

    func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    var slow = [Double](repeating: 1, count: samples.count)
    if samples.count > 2 {
        for i in 1..<(samples.count - 1) {
            let a = samples[i - 1].coordinate
            let b = samples[i].coordinate
            let c = samples[i + 1].coordinate
            guard meters(a, b) >= 1, meters(b, c) >= 1 else { continue }
            if angularDifference(bearingDegrees(from: a, to: b), bearingDegrees(from: b, to: c)) > 30 {
                for j in max(0, i - 2)...min(samples.count - 1, i + 2) {
                    slow[j] = max(slow[j], 1.6)
                }
            }
        }
    }

    // Distance along the path, and where the random stops happen. The car waits
    // at sample (index - 1) before moving to the sample at `index`.
    var cumulative = [Double](repeating: 0, count: samples.count)
    for index in 1..<samples.count {
        cumulative[index] = cumulative[index - 1] + meters(samples[index - 1].coordinate, samples[index].coordinate)
    }
    let total = cumulative[samples.count - 1]

    var stopIndices: Set<Int> = []
    var sinceStop = 0.0
    var nextStop = Double.random(in: stopSpacing)
    for index in 1..<samples.count {
        sinceStop += cumulative[index] - cumulative[index - 1]
        if sinceStop >= nextStop {
            stopIndices.insert(index)
            sinceStop = 0
            nextStop = Double.random(in: stopSpacing)
        }
    }
    let stopPositions = stopIndices.map { cumulative[$0 - 1] }.sorted()

    // Speed multiplier (0.3...1) that ramps up after a stop and down before one.
    func ramp(_ distance: Double) -> Double {
        guard rampDistance > 0 else { return 1 }
        return 0.3 + 0.7 * min(1, max(0, distance) / rampDistance)
    }

    var wobble = 1.0
    var lastStopPosition = 0.0 // the start of the leg counts as a stop
    var result: [RoutePlaybackSample] = []
    for (index, sample) in samples.enumerated() {
        wobble = min(1.1, max(0.9, wobble + Double.random(in: -0.02...0.02)))
        let here = cumulative[index]
        let nextStopPosition = stopPositions.first(where: { $0 >= here }) ?? total
        let rampFactor = min(ramp(here - lastStopPosition), ramp(nextStopPosition - here))

        var delay = sample.delayFromPrevious * slow[index] / (speedFactor * wobble * rampFactor)
        if stopIndices.contains(index) {
            delay += Double.random(in: 4...12)
            lastStopPosition = cumulative[index - 1]
        }
        result.append(RoutePlaybackSample(coordinate: sample.coordinate, delayFromPrevious: delay))
    }
    return result
}

private func offsetCoordinate(
    from origin: CLLocationCoordinate2D,
    distance: CLLocationDistance,
    bearing degrees: Double
) -> CLLocationCoordinate2D {
    let radians = degrees * Double.pi / 180
    let latitudeOffset = distance * cos(radians) / 111_320
    let longitudeScale = 111_320 * max(cos(origin.latitude * Double.pi / 180), 0.01)
    let longitudeOffset = distance * sin(radians) / longitudeScale
    return CLLocationCoordinate2D(
        latitude: origin.latitude + latitudeOffset,
        longitude: origin.longitude + longitudeOffset
    )
}

private func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * Double.pi / 180
    let lat2 = b.latitude * Double.pi / 180
    let deltaLon = (b.longitude - a.longitude) * Double.pi / 180
    let y = sin(deltaLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
    let degrees = atan2(y, x) * 180 / Double.pi
    return (degrees + 360).truncatingRemainder(dividingBy: 360)
}

private func angularDifference(_ a: Double, _ b: Double) -> Double {
    let difference = abs(a - b).truncatingRemainder(dividingBy: 360)
    return difference > 180 ? 360 - difference : difference
}

private func randomCoordinate(around center: CLLocationCoordinate2D, radius: CLLocationDistance) -> CLLocationCoordinate2D {
    let distance = radius * 0.9 * sqrt(Double.random(in: 0...1))
    let bearing = Double.random(in: 0..<(2 * Double.pi))
    let latitudeOffset = distance * cos(bearing) / 111_320
    let longitudeScale = 111_320 * max(cos(center.latitude * Double.pi / 180), 0.01)
    let longitudeOffset = distance * sin(bearing) / longitudeScale
    return CLLocationCoordinate2D(
        latitude: center.latitude + latitudeOffset,
        longitude: center.longitude + longitudeOffset
    )
}

private struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    let (data, response) = try await URLSession.shared.data(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

private func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D],
    speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let firstCoordinate = displayCoordinates.first else { return [] }

    var samples = [RoutePlaybackSample(coordinate: firstCoordinate, delayFromPrevious: 0)]

    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speedLimit = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays) ?? fallbackSpeedMetersPerSecond
        let clampedSpeed = max(speedLimit, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        let segmentTravelTime = segmentDistance / clampedSpeed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / RouteSimulationDefaults.playbackTickInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
            }
        }
    }

    return samples
}

private func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    let speedWays = (try? await fetchOpenStreetMapWays(for: displayCoordinates)) ?? []
    return buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: speedWays,
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .noCoordinates:
            return "No valid coordinates were found. Use GPX, GeoJSON, JSON, CSV, or plain text with latitude and longitude values."
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @State private var showConnectedStatus = true
    @State private var locationConnectionNotice: String?
    @State private var connectionErrorMessage: String?
    private var isDeviceConnected: Bool {
        tunnel.isConnected && !tunnel.isStarting && tunnel.lastError == nil && connectionErrorMessage == nil
    }
    @ObservedObject private var simulationSession = LocationSimulationSession.shared
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @State private var showCoordinateImporter = false
    @State private var showRouteSearch = false
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()
    @State private var routeLoopMode: RouteLoopMode = .off
    @State private var wanderMode = false
    @AppStorage("wander.radius") private var wanderRadius: Double = 500
    @AppStorage("wander.speedFactor") private var wanderSpeedFactor: Double = 1.0
    @State private var wanderGoPoints: [CLLocationCoordinate2D] = []
    @State private var wanderGoRequested: [CLLocationCoordinate2D]?
    @AppStorage("wander.transport") private var wanderTransport: WanderTransport = .driving
    @AppStorage("wander.topSpeedKmh") private var wanderTopSpeedKmh: Double = 80
    @AppStorage("wander.avoidHighways") private var wanderAvoidHighways = false
    @AppStorage("wander.parkMinutes") private var wanderParkMinutes: Double = 0
    @AppStorage("wander.zoneKind") private var wanderZoneKind: WanderZoneKind = .circle
    @State private var wanderPolygon: [CLLocationCoordinate2D] = []
    @State private var wanderActivePolygon: [CLLocationCoordinate2D] = []
    @State private var wanderParked = false
    @AppStorage("wander.humanize") private var wanderHumanize = true
    @AppStorage("wander.travelFromHere") private var wanderTravelFromHere = true
    @State private var wanderStarting = false
    @State private var wanderStatusText: String?
    @State private var routeTrail: [TrailPoint] = []
    @State private var wanderZones: [WanderZone] = WanderZoneStore.load()
    @State private var showSaveZone = false
    @State private var newZoneName = ""
    @State private var wanderResumeRequested = false
    @State private var wanderZoneCenter: CLLocationCoordinate2D?

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulationSession.isActive || simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil || simulationSession.routeCoordinates != nil
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil ||
        simulationSession.routeCoordinates != nil
    }

    private var displayedRouteCoordinate: CLLocationCoordinate2D? {
        simulationSession.routeCoordinates == nil ? routePlaybackCoordinate : simulationSession.coordinate
    }

    private var wanderCircleCenter: CLLocationCoordinate2D? {
        if wanderZoneCenter != nil {
            return wanderActivePolygon.isEmpty ? wanderZoneCenter : nil
        }
        return (wanderMode && wanderZoneKind == .circle) ? coordinate : nil
    }

    private var wanderPolygonToDraw: [CLLocationCoordinate2D] {
        if wanderZoneCenter != nil { return wanderActivePolygon }
        return (wanderMode && wanderZoneKind == .polygon) ? wanderPolygon : []
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let durationText = Self.routeDurationFormatter.string(from: routePlan.expectedTravelTime)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • ETA \(durationText)"
        }
        return distanceText
    }

    private var routeStatusText: String {
        if simulationSession.routeCoordinates != nil {
            return "Route simulation active."
        }
        if isLoadingRoute {
            return "Calculating route…"
        }
        if isPrefetchingRouteSpeeds {
            return "Prefetching road speeds…"
        }
        if routePlan != nil {
            return "Route ready."
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "Pick both route endpoints to build the drive."
        }
        return "Plan a route from the toolbar."
    }

    private var routeAttributionLink: some View {
        Link(
            "Speed limit data © OpenStreetMap contributors (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if #available(iOS 26, *) {
            searchResultsListBase
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            searchResultsListBase
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    if routeTrail.count > 1 {
                        MapPolyline(coordinates: routeTrail.suffix(5000).map { $0.coordinate })
                            .stroke(.orange.opacity(0.85), lineWidth: 3)
                    }
                    if let circleCenter = wanderCircleCenter {
                        MapCircle(center: circleCenter, radius: wanderRadius)
                            .foregroundStyle(.blue.opacity(0.12))
                            .stroke(.blue, lineWidth: 2)
                    }
                    if wanderPolygonToDraw.count >= 3 {
                        MapPolygon(coordinates: wanderPolygonToDraw)
                            .foregroundStyle(.blue.opacity(0.12))
                            .stroke(.blue, lineWidth: 2)
                    } else if wanderPolygonToDraw.count == 2 {
                        MapPolyline(coordinates: wanderPolygonToDraw)
                            .stroke(.blue, lineWidth: 2)
                    }
                    if wanderZoneCenter == nil {
                        ForEach(Array(wanderPolygonToDraw.enumerated()), id: \.offset) { item in
                            Annotation("", coordinate: item.element) {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 10, height: 10)
                            }
                        }
                    }
                    if hasRouteContext {
                        if let routePolyline {
                            MapPolyline(routePolyline)
                                .stroke(.blue.opacity(0.8), lineWidth: 5)
                        }
                        if let routeStartCoordinate {
                            Marker("Start", coordinate: routeStartCoordinate)
                                .tint(.green)
                        }
                        if let routeEndCoordinate {
                            Marker("End", coordinate: routeEndCoordinate)
                                .tint(.red)
                        }
                        if let displayedRouteCoordinate {
                            Marker("Current", coordinate: displayedRouteCoordinate)
                                .tint(.blue)
                        }
                        ForEach(Array(wanderGoPoints.enumerated()), id: \.offset) { item in
                            Marker("Go \(item.offset + 1)", coordinate: item.element)
                                .tint(.orange)
                        }
                    } else if let coordinate {
                        Marker("Pin", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let loc = proxy.convert(point, from: .local) {
                        applySelection(loc)
                    }
                }
                .mapControls {
                    MapCompass()
                }
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }

            VStack(spacing: 0) {
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if isImportingCoordinates {
                        ProgressView("Importing coordinates…")
                            .font(.footnote)
                    }

                    if hasRouteContext {
                        routeControls
                    } else {
                        pinControls
                    }
                }
                .padding(.bottom, 24)
                .padding(.horizontal, 16)
                .padding(.horizontal, 16)
            }
        }
        .safeAreaInset(edge: .top) {
            if locationConnectionNotice != nil || !isDeviceConnected || showConnectedStatus || tunnel.connectionNotice != nil {
                Group {
                    if let notice = locationConnectionNotice {
                        Label(notice, systemImage: "airplane")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        DeviceConnectionStatusView(errorMessage: connectionErrorMessage)
                    }
                }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
            }
        }
        .task(id: isDeviceConnected) {
            showConnectedStatus = true
            guard isDeviceConnected else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                showConnectedStatus = false
            } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .locationTunnelConnected).receive(on: DispatchQueue.main)) { notification in
            locationConnectionNotice = notification.object as? String
        }
        .task(id: locationConnectionNotice) {
            guard locationConnectionNotice != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            locationConnectionNotice = nil
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }

                Button {
                    showRouteSearch = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(isBusy || isRouteRunning)

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("Import Coordinates")
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("Search location...", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
                    .onSubmit {
                        applyCoordinatesFromSearchText()
                    }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Save Bookmark", isPresented: $showSaveBookmark) {
            TextField("Name", text: $newBookmarkName)
            Button("Save") { addBookmark() }
            Button("Cancel", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Enter a name for this location.")
        }
        .alert("Save Zone", isPresented: $showSaveZone) {
            TextField("Name", text: $newZoneName)
            Button("Save") { saveWanderZone() }
            Button("Cancel", role: .cancel) { newZoneName = "" }
        } message: {
            Text("Saves the pin and the radius as a wander zone.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection
            ) { startSelection, endSelection in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                refreshRoute()
            }
        }
        .fileImporter(
            isPresented: $showCoordinateImporter,
            allowedContentTypes: CoordinateImportParser.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importCoordinates(result)
        }
        .onAppear {
            loadBookmarks()
            if let routeCoordinates = simulationSession.routeCoordinates {
                coordinate = nil
                routePolyline = makeRoutePolyline(for: routeCoordinates)
                routeStartSelection = routeCoordinates.first.map {
                    RouteSearchSelection(title: "Route Start", coordinate: $0)
                }
                routeEndSelection = routeCoordinates.last.map {
                    RouteSearchSelection(title: "Route End", coordinate: $0)
                }
                if let routePolyline {
                    position = .rect(routePolyline.boundingMapRect)
                }
            } else if let activeCoordinate = simulationSession.coordinate {
                coordinate = activeCoordinate
                simulatedCoordinate = activeCoordinate
            }
        }
        .onDisappear {
            locationConnectionNotice = nil
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            routeSpeedPrefetchTask = nil
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                applySelection(item.placemark.coordinate)
            }
        }
    }

    private func applyCoordinatesFromSearchText() {
        let importedCoordinates = CoordinateImportParser.parseInline(searchText)
        guard !importedCoordinates.isEmpty else { return }

        searchText = ""
        searchCompleter.results = []
        applyImportedCoordinates(importedCoordinates, sourceName: "Imported")
    }

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "Imported" : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate)
            return
        }

        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            applySelection(firstCoordinate)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = RouteSimulationDefaults.importedRouteFallbackSpeedMetersPerSecond
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) Start", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) End", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        let requestID = UUID()
        routeRequestID = requestID
        isPrefetchingRouteSpeeds = true
        routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            let playbackSamples = await prefetchRoutePlaybackSamples(
                displayCoordinates: displayCoordinates,
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard routeRequestID == requestID else { return }
                routePlaybackSamples = playbackSamples
                isPrefetchingRouteSpeeds = false
            }
        }
    }

    private func showImportError(_ error: Error) {
        alertTitle = "Import Failed"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Stop", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("Simulate Location", action: simulate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy || isLoadingRoute)

                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isRouteRunning)
            }

            Toggle("Wander in zone", isOn: $wanderMode)
                .disabled(isRouteRunning)

            if wanderMode {
                VStack(spacing: 6) {
                    Picker("Zone", selection: $wanderZoneKind) {
                        ForEach(WanderZoneKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Mode", selection: $wanderTransport) {
                        ForEach(WanderTransport.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if wanderTransport == .moto {
                        HStack {
                            Text("Top speed")
                            Spacer()
                            Text("\(Int(wanderTopSpeedKmh)) km/h")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Slider(value: $wanderTopSpeedKmh, in: 30...120, step: 5)
                    }

                    if wanderTransport != .walking {
                        Toggle("Avoid highways & tolls", isOn: $wanderAvoidHighways)
                    }

                    if wanderZoneKind == .circle {
                        HStack {
                            Text("Zone radius")
                            Spacer()
                            Text("\(Int(wanderRadius)) m")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Slider(value: $wanderRadius, in: 200...5000, step: 100)
                    } else {
                        Text("Tap the map to add corners (\(wanderPolygon.count))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Undo") { _ = wanderPolygon.popLast() }
                                .buttonStyle(.bordered)
                                .disabled(wanderPolygon.isEmpty)
                            Button("Clear") { wanderPolygon = [] }
                                .buttonStyle(.bordered)
                                .disabled(wanderPolygon.isEmpty)
                        }
                    }

                    HStack {
                        Text("Speed")
                        Spacer()
                        Text("\(Int(wanderSpeedFactor * 100))%")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Slider(value: $wanderSpeedFactor, in: 0.5...1.5, step: 0.1)

                    Toggle("Natural pauses", isOn: $wanderHumanize)

                    Toggle("Travel from my location", isOn: $wanderTravelFromHere)

                    HStack {
                        Text("Stay at Go places")
                        Spacer()
                        Text(wanderParkMinutes == 0 ? "until I resume" : "\(Int(wanderParkMinutes)) min")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Slider(value: $wanderParkMinutes, in: 0...60, step: 5)

                    HStack(spacing: 12) {
                        Button("Save zone") {
                            newZoneName = ""
                            showSaveZone = true
                        }
                        .buttonStyle(.bordered)

                        if !wanderZones.isEmpty {
                            Menu("Saved zones") {
                                ForEach(wanderZones) { zone in
                                    Button("\(zone.name) · \(Int(zone.radius)) m") {
                                        applyWanderZone(zone)
                                    }
                                }
                                Divider()
                                Menu("Delete") {
                                    ForEach(wanderZones) { zone in
                                        Button(zone.name, role: .destructive) {
                                            deleteWanderZone(zone)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Button("Start Wander", action: startWander)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            !pairingExists || isBusy || isRouteRunning || wanderStarting ||
                            (wanderZoneKind == .polygon && wanderPolygon.count < 3)
                        )
                }
            }

            trailControls
        } else {
            Text("Tap map to drop pin")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            routeAttributionLink

            if wanderZoneCenter == nil {
                Picker("Repeat", selection: $routeLoopMode) {
                    ForEach(RouteLoopMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if wanderZoneCenter != nil {
                if let wanderStatusText {
                    Text(wanderStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !wanderGoPoints.isEmpty {
                    HStack(spacing: 12) {
                        Button(wanderGoPoints.count == 1 ? "Go here" : "Go to \(wanderGoPoints.count) places") {
                            wanderGoRequested = wanderGoPoints
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button("Clear") { wanderGoPoints = [] }
                            .buttonStyle(.bordered)
                    }
                } else if wanderParked {
                    Text("Parked. Tap the map to pick other places.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap the map to pick places to drive to")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if wanderParked {
                    Button("Resume wandering") { wanderResumeRequested = true }
                        .buttonStyle(.borderedProminent)
                }
            }

            trailControls

            HStack(spacing: 12) {
                Button("Stop", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("Play Route", action: simulateRoute)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !pairingExists ||
                        isBusy ||
                        isLoadingRoute ||
                        isPrefetchingRouteSpeeds ||
                        routePlan == nil ||
                        routePlaybackSamples.isEmpty
                    )

                Button("Reset", action: resetRouteSelection)
                    .buttonStyle(.bordered)
                    .disabled(isBusy || isRouteRunning)
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                "Could not simulate location (error \(code)). Make sure the device is connected and the DDI is mounted."
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            LocationSimulationSession.shared.clearRoute()
            startResendLoop(with: coord)
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              let routePlan,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy else {
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "Route Simulation Failed",
            errorMessage: { code in
                "Could not start route simulation (error \(code)). Make sure the device is connected and the DDI is mounted."
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(
                at: firstCoordinate,
                coordinates: routePlan.displayCoordinates
            )
            simulatedCoordinate = nil
            routePlaybackCoordinate = firstCoordinate
            startRoutePlayback(routeID: routeID)
        }
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    connectionErrorMessage = nil
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    connectionErrorMessage = "Code \(code): \(alertMessage)"
                    locationConnectionNotice = nil
                    showAlert = true
                }
            }
        }
    }

    private func clear() {
        guard pairingExists, !isBusy else { return }
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        wanderZoneCenter = nil
        wanderGoPoints = []
        wanderActivePolygon = []
        wanderGoRequested = nil
        wanderParked = false
        wanderResumeRequested = false
        LocationSimulationSession.shared.clearRoute()
        runLocationCommand(
            errorTitle: "Clear Failed",
            errorMessage: { code in "Could not clear simulated location (error \(code))." },
            operation: clear_simulated_location
        ) {
            endBackgroundTask()
            LocationSimulationSession.shared.stop()
            locationConnectionNotice = nil
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        LocationSimulationSession.shared.startResending(at: coordinate) {
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: coordinate)
            }
        }
    }

    private func stopResendLoop() {
        LocationSimulationSession.shared.pauseResending()
        simulatedCoordinate = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        if wanderZoneCenter != nil {
            // While wandering, taps queue places to drive to, in order.
            if wanderGoPoints.count < 8 { wanderGoPoints.append(coordinate) }
            return
        }
        if wanderMode && wanderZoneKind == .polygon && !isRouteRunning {
            if wanderPolygon.count < 40 { wanderPolygon.append(coordinate) }
            if self.coordinate == nil { self.coordinate = coordinate }
            return
        }
        guard !isRouteRunning else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        self.coordinate = coordinate
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
    }

    private func refreshRoute() {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        setRoutePlan(nil)
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.requestsAlternateRoutes = false
        request.transportType = .automobile

        routeLoadTask = Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled else { return }
                guard let route = response.routes.first else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No drivable route was returned."]
                    )
                }

                let displayCoordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: RouteSimulationDefaults.pathSamplingDistance
                )
                let routePlan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: route.distance,
                    expectedTravelTime: route.expectedTravelTime
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    self.setRoutePlan(routePlan)
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = true
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                }

                let fallbackSpeed = route.expectedTravelTime > 0
                    ? route.distance / route.expectedTravelTime
                    : 13.4

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    routeSpeedPrefetchTask?.cancel()
                    routeSpeedPrefetchTask = Task.detached(priority: .utility) {
                        let playbackSamples = await prefetchRoutePlaybackSamples(
                            displayCoordinates: displayCoordinates,
                            fallbackSpeedMetersPerSecond: fallbackSpeed
                        )
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routePlaybackSamples = playbackSamples
                            isPrefetchingRouteSpeeds = false
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "Route Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback(routeID: UUID) {
        let original = routePlaybackSamples
        guard !original.isEmpty else { return }
        routeTrail = []
        if let firstSample = original.first { recordTrail(firstSample.coordinate) }
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate: CLLocationCoordinate2D? = original.first?.coordinate
            var forward = true
            var path = original

            while true {
                let finished = await playSamples(
                    Array(path.dropFirst()),
                    routeID: routeID,
                    lastSuccessfulCoordinate: &lastSuccessfulCoordinate
                )
                guard finished else { return }

                let mode = await MainActor.run { routeLoopMode }
                guard mode != .off,
                      !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    break
                }

                switch mode {
                case .pingPong:
                    forward.toggle()
                    path = forward ? original : reversedPlaybackSamples(original)
                case .circular:
                    forward = true
                    // Jump from the end back to the start, then replay the route.
                    var restart = original
                    restart[0] = RoutePlaybackSample(
                        coordinate: original[0].coordinate,
                        delayFromPrevious: RouteSimulationDefaults.playbackTickInterval
                    )
                    let here = RoutePlaybackSample(
                        coordinate: lastSuccessfulCoordinate ?? original[0].coordinate,
                        delayFromPrevious: 0
                    )
                    path = [here] + restart
                case .off:
                    break
                }
            }

            await MainActor.run {
                guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                routePlaybackTask = nil
                // The route has ended; while it stays set, isRouteRunning keeps
                // map taps, search, bookmarks and Reset disabled.
                LocationSimulationSession.shared.clearRoute()
                if let lastSuccessfulCoordinate {
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                }
            }
        }
    }

    /// Plays every given sample in order. Returns false if playback was
    /// cancelled, replaced or failed (the failure alert is shown here).
    private func playSamples(
        _ samples: [RoutePlaybackSample],
        routeID: UUID,
        lastSuccessfulCoordinate: inout CLLocationCoordinate2D?,
        stopWhen: (() -> Bool)? = nil
    ) async -> Bool {
        for sample in samples {
            var remaining = sample.delayFromPrevious
            // Long stops are split so the position keeps being re-sent meanwhile.
            while remaining > 2.5 {
                try? await Task.sleep(for: .seconds(2.5))
                remaining -= 2.5
                guard !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    return false
                }
                if let stopWhen, stopWhen() { return true }
                if let here = lastSuccessfulCoordinate {
                    _ = await sendLocationUpdate(for: here)
                }
            }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled,
                  LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                return false
            }
            if let stopWhen, stopWhen() { return true }

            let code = await sendLocationUpdate(for: sample.coordinate)
            guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return false }
            guard code == 0 else {
                let fallback = lastSuccessfulCoordinate
                await MainActor.run {
                    routePlaybackTask = nil
                    wanderZoneCenter = nil
                    wanderGoPoints = []
                    wanderActivePolygon = []
                    wanderGoRequested = nil
                    wanderParked = false
                    wanderResumeRequested = false
                    routePlaybackCoordinate = fallback
                    LocationSimulationSession.shared.clearRoute()
                    if let fallback {
                        startResendLoop(with: fallback)
                    }
                    alertTitle = "Route Simulation Failed"
                    alertMessage = "Could not continue route simulation (error \(code))."
                    connectionErrorMessage = "Code \(code): Could not continue route simulation."
                    locationConnectionNotice = nil
                    showAlert = true
                }
                return false
            }

            lastSuccessfulCoordinate = sample.coordinate
            await MainActor.run {
                routePlaybackCoordinate = sample.coordinate
                LocationSimulationSession.shared.updateCoordinate(sample.coordinate)
                recordTrail(sample.coordinate)
            }
        }
        return true
    }

    private func recordTrail(_ coordinate: CLLocationCoordinate2D) {
        if let last = routeTrail.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard moved >= 8 else { return }
        }
        routeTrail.append(
            TrailPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, time: Date())
        )
        if routeTrail.count > 20_000 { routeTrail.removeFirst(5_000) }
    }

    @ViewBuilder
    private var trailControls: some View {
        if routeTrail.count > 1 {
            HStack(spacing: 12) {
                ShareLink(
                    item: GPXExport(points: routeTrail),
                    preview: SharePreview("StikDebug-trail.gpx")
                ) {
                    Label("Export GPX", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button("Clear trail", role: .destructive) { routeTrail = [] }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func resetWanderState() {
        wanderStatusText = nil
        wanderZoneCenter = nil
        wanderActivePolygon = []
        wanderGoPoints = []
        wanderGoRequested = nil
        wanderParked = false
        wanderResumeRequested = false
    }

    private func saveWanderZone() {
        guard let pin = coordinate else { return }
        let trimmed = newZoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Zone \(wanderZones.count + 1)" : trimmed
        let zone: WanderZone
        if wanderZoneKind == .polygon, wanderPolygon.count >= 3 {
            let shape = WanderZoneShape(polygon: wanderPolygon)
            zone = WanderZone(
                name: name,
                latitude: shape.center.latitude,
                longitude: shape.center.longitude,
                radius: shape.radius,
                polygon: wanderPolygon.map { WanderPoint($0) }
            )
        } else {
            zone = WanderZone(
                name: name,
                latitude: pin.latitude,
                longitude: pin.longitude,
                radius: wanderRadius,
                polygon: nil
            )
        }
        wanderZones.append(zone)
        WanderZoneStore.save(wanderZones)
        newZoneName = ""
    }

    private func applyWanderZone(_ zone: WanderZone) {
        coordinate = zone.coordinate
        wanderRadius = min(max(zone.radius, 200), 5000)
        if let points = zone.polygon, points.count >= 3 {
            wanderZoneKind = .polygon
            wanderPolygon = points.map { $0.coordinate }
        } else {
            wanderZoneKind = .circle
        }
        wanderMode = true
        position = .region(
            MKCoordinateRegion(
                center: zone.coordinate,
                latitudinalMeters: zone.radius * 3,
                longitudinalMeters: zone.radius * 3
            )
        )
    }

    private func deleteWanderZone(_ zone: WanderZone) {
        wanderZones.removeAll { $0.id == zone.id }
        WanderZoneStore.save(wanderZones)
    }

    private func startWander() {
        guard pairingExists, !isBusy, !wanderStarting, let pin = coordinate else { return }
        let usePolygon = wanderZoneKind == .polygon
        guard !usePolygon || wanderPolygon.count >= 3 else { return }

        let zone = usePolygon
            ? WanderZoneShape(polygon: wanderPolygon)
            : WanderZoneShape(center: pin, radius: wanderRadius)
        let start = usePolygon ? zone.randomPoint() : pin
        let travelFromHere = wanderTravelFromHere
        let speedFactor = wanderSpeedFactor
        let humanize = wanderHumanize
        let transport = WanderTravel(
            mode: wanderTransport,
            topSpeed: wanderTopSpeedKmh / 3.6,
            avoidHighways: wanderAvoidHighways
        )

        wanderStarting = true
        Task {
            let origin = travelFromHere ? await currentWanderOrigin() : nil
            await MainActor.run {
                wanderStarting = false
                launchWander(
                    zone: zone,
                    start: start,
                    origin: origin,
                    travelRequested: travelFromHere,
                    speedFactor: speedFactor,
                    humanize: humanize,
                    transport: transport
                )
            }
        }
    }

    /// Where the phone is right now: the simulated spot if one is active,
    /// otherwise the real location.
    private func currentWanderOrigin() async -> CLLocationCoordinate2D? {
        let session = LocationSimulationSession.shared
        if session.isActive, let simulated = session.coordinate { return simulated }
        return await OneShotLocationProvider().current()
    }

    /// Decides whether to travel to the zone from `origin` or just jump there.
    private func wanderApproachPlan(
        origin: CLLocationCoordinate2D?,
        start: CLLocationCoordinate2D,
        travelRequested: Bool
    ) -> (first: CLLocationCoordinate2D, approachTo: CLLocationCoordinate2D?, notice: String?) {
        guard let origin else {
            let notice = travelRequested
                ? "Could not read your current location (check that location access is allowed for StikDebug), so it jumped to the zone."
                : nil
            return (start, nil, notice)
        }
        let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
        if distance > 50_000 {
            return (start, nil, "The zone is \(Int(distance / 1000)) km away, so it jumped there instead of traveling.")
        }
        if distance > 30 {
            return (origin, start, nil)
        }
        return (start, nil, nil)
    }

    private func launchWander(
        zone: WanderZoneShape,
        start: CLLocationCoordinate2D,
        origin: CLLocationCoordinate2D?,
        travelRequested: Bool,
        speedFactor: Double,
        humanize: Bool,
        transport: WanderTravel
    ) {
        let plan = wanderApproachPlan(origin: origin, start: start, travelRequested: travelRequested)
        let first = plan.first
        let approachTo = plan.approachTo
        let notice = plan.notice

        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "Wander Failed",
            errorMessage: { code in
                "Could not start wander simulation (error \(code)). Make sure the device is connected and the DDI is mounted."
            },
            operation: { locationUpdateCode(for: first) }
        ) {
            beginBackgroundTask()
            let routeID = LocationSimulationSession.shared.startRoute(at: first, coordinates: [first])
            simulatedCoordinate = nil
            routePlaybackCoordinate = first
            routeTrail = []
            recordTrail(first)
            wanderGoPoints = []
            wanderZoneCenter = zone.center
            wanderActivePolygon = zone.polygon
            wanderStatusText = nil
            if let origin, approachTo != nil {
                let km = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                    .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude)) / 1000
                wanderStatusText = String(format: "Traveling to the zone (%.1f km away)…", km)
            }
            if let notice {
                alertTitle = "Jumped to the zone"
                alertMessage = notice
                showAlert = true
            }
            startWanderPlayback(
                routeID: routeID,
                zone: zone,
                start: first,
                approachTo: approachTo,
                speedFactor: speedFactor,
                humanize: humanize,
                transport: transport
            )
        }
    }

    private func startWanderPlayback(
        routeID: UUID,
        zone: WanderZoneShape,
        start: CLLocationCoordinate2D,
        approachTo: CLLocationCoordinate2D?,
        speedFactor: Double,
        humanize: Bool,
        transport: WanderTravel
    ) {
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate: CLLocationCoordinate2D? = start
            var current = start
            var upcoming: [RoutePlaybackSample]?
            var heading: CLLocationDirection?
            var emptyRounds = 0

            // First travel from where the phone is to the zone, then start wandering.
            if let target = approachTo {
                if let approach = await goLeg(from: start, to: target, transport: transport), approach.count > 1 {
                    let scaled = humanizedSamples(approach, speedFactor: speedFactor, humanize: humanize, stopSpacing: transport.stopSpacing, rampDistance: transport.rampDistance)
                    let arrived = await playSamples(
                        Array(scaled.dropFirst()),
                        routeID: routeID,
                        lastSuccessfulCoordinate: &lastSuccessfulCoordinate,
                        stopWhen: { wanderGoRequested != nil }
                    )
                    guard arrived else { return }
                    current = lastSuccessfulCoordinate ?? target
                    heading = bearingDegrees(
                        from: approach[approach.count - 2].coordinate,
                        to: approach[approach.count - 1].coordinate
                    )
                } else {
                    let code = await sendLocationUpdate(for: target)
                    guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                    if code == 0 {
                        lastSuccessfulCoordinate = target
                        current = target
                        await MainActor.run {
                            routePlaybackCoordinate = target
                            LocationSimulationSession.shared.updateCoordinate(target)
                            alertTitle = "Jumped to the zone"
                            alertMessage = "Could not find a route from where you are to the zone, so it jumped there instead."
                            showAlert = true
                        }
                    }
                }

                await MainActor.run { wanderStatusText = nil }

                if await MainActor.run(body: { wanderGoRequested != nil }) {
                    let keepGoing = await driveToRequestedPlaces(
                        routeID: routeID,
                        speedFactor: speedFactor,
                        humanize: humanize,
                        transport: transport,
                        lastSuccessfulCoordinate: &lastSuccessfulCoordinate
                    )
                    guard keepGoing else { return }
                    current = lastSuccessfulCoordinate ?? current
                }
            }

            while !Task.isCancelled, LocationSimulationSession.shared.isCurrentRoute(routeID) {
                var leg = upcoming
                upcoming = nil
                if leg == nil {
                    leg = await wanderLeg(from: current, zone: zone, heading: heading, transport: transport)
                }

                guard let samples = leg, samples.count > 1 else {
                    emptyRounds += 1
                    if emptyRounds >= 4 {
                        let last = lastSuccessfulCoordinate
                        await MainActor.run {
                            guard LocationSimulationSession.shared.isCurrentRoute(routeID) else { return }
                            routePlaybackTask = nil
                            resetWanderState()
                            LocationSimulationSession.shared.clearRoute()
                            if let last {
                                routePlaybackCoordinate = last
                                startResendLoop(with: last)
                            }
                            alertTitle = "Wander Stopped"
                            alertMessage = "Could not find a route that stays inside the zone. Try a larger zone or a spot with more streets."
                            showAlert = true
                        }
                        return
                    }
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                emptyRounds = 0

                let end = samples[samples.count - 1].coordinate
                let newHeading = bearingDegrees(from: samples[samples.count - 2].coordinate, to: end)
                // Compute the next leg while this one is playing.
                let prefetch = Task {
                    await wanderLeg(from: end, zone: zone, heading: newHeading, transport: transport)
                }
                let scaled = humanizedSamples(samples, speedFactor: speedFactor, humanize: humanize, stopSpacing: transport.stopSpacing, rampDistance: transport.rampDistance)
                let finished = await playSamples(
                    Array(scaled.dropFirst()),
                    routeID: routeID,
                    lastSuccessfulCoordinate: &lastSuccessfulCoordinate,
                    stopWhen: { wanderGoRequested != nil }
                )
                guard finished else {
                    prefetch.cancel()
                    return
                }
                current = lastSuccessfulCoordinate ?? end
                heading = newHeading

                if humanize {
                    // Short stop at each destination, ended early by a "Go" request.
                    let pause = Double.random(in: 3...15)
                    var waited = 0.0
                    var ticks = 0
                    while waited < pause,
                          !Task.isCancelled,
                          await MainActor.run(body: { wanderGoRequested == nil }) {
                        try? await Task.sleep(for: .milliseconds(300))
                        waited += 0.3
                        ticks += 1
                        if ticks % 10 == 0, let here = lastSuccessfulCoordinate {
                            _ = await sendLocationUpdate(for: here)
                        }
                    }
                }

                if await MainActor.run(body: { wanderGoRequested != nil }) {
                    prefetch.cancel()
                    upcoming = nil
                    let keepGoing = await driveToRequestedPlaces(
                        routeID: routeID,
                        speedFactor: speedFactor,
                        humanize: humanize,
                        transport: transport,
                        lastSuccessfulCoordinate: &lastSuccessfulCoordinate
                    )
                    guard keepGoing else { return }
                    current = lastSuccessfulCoordinate ?? current
                    continue
                }
                upcoming = await prefetch.value
            }
        }
    }

    /// Drives through the places the user queued while wandering (in order, ignoring
    /// the zone), parks at the last one and waits for "Resume wandering" or a new queue.
    /// Returns false when the wander task should stop.
    private func driveToRequestedPlaces(
        routeID: UUID,
        speedFactor: Double,
        humanize: Bool,
        transport: WanderTravel,
        lastSuccessfulCoordinate: inout CLLocationCoordinate2D?
    ) async -> Bool {
        while true {
            guard let targets = await MainActor.run(body: { wanderGoRequested }) else { return true }
            await MainActor.run { wanderGoRequested = nil }

            var interrupted = false
            for (index, target) in targets.enumerated() {
                guard LocationSimulationSession.shared.isCurrentRoute(routeID),
                      let from = lastSuccessfulCoordinate else {
                    return false
                }

                guard let samples = await goLeg(from: from, to: target, transport: transport),
                      samples.count > 1 else {
                    await MainActor.run {
                        alertTitle = "Go Here Failed"
                        alertMessage = "Could not find a route to one of the places. Skipping it."
                        showAlert = true
                    }
                    continue
                }

                let scaled = humanizedSamples(samples, speedFactor: speedFactor, humanize: humanize, stopSpacing: transport.stopSpacing, rampDistance: transport.rampDistance)
                let finished = await playSamples(
                    Array(scaled.dropFirst()),
                    routeID: routeID,
                    lastSuccessfulCoordinate: &lastSuccessfulCoordinate,
                    stopWhen: { wanderGoRequested != nil }
                )
                guard finished else { return false }
                if await MainActor.run(body: { wanderGoRequested != nil }) {
                    interrupted = true
                    break
                }

                // Short stop at the places in between.
                if index < targets.count - 1 {
                    let hold = humanize ? Double.random(in: 4...10) : 1
                    var waited = 0.0
                    while waited < hold,
                          !Task.isCancelled,
                          await MainActor.run(body: { wanderGoRequested == nil }) {
                        try? await Task.sleep(for: .milliseconds(300))
                        waited += 0.3
                    }
                    if await MainActor.run(body: { wanderGoRequested != nil }) {
                        interrupted = true
                        break
                    }
                }
            }
            if interrupted { continue }

            let parkMinutes = await MainActor.run { wanderParkMinutes }
            let parkLimit = parkMinutes * 60
            let parkStart = Date()

            await MainActor.run {
                wanderGoPoints.removeAll { point in
                    targets.contains { $0.latitude == point.latitude && $0.longitude == point.longitude }
                }
                wanderParked = true
                wanderStatusText = parkLimit > 0
                    ? "Parked. Resuming in \(Int((parkLimit / 60).rounded(.up))) min"
                    : nil
            }

            // Stay parked here until the user resumes wandering, queues other places,
            // or the chosen stay time runs out.
            var ticks = 0
            while true {
                guard !Task.isCancelled,
                      LocationSimulationSession.shared.isCurrentRoute(routeID) else {
                    return false
                }
                let (goRequested, resumeRequested) = await MainActor.run {
                    (wanderGoRequested != nil, wanderResumeRequested)
                }
                let timeUp = parkLimit > 0 && Date().timeIntervalSince(parkStart) >= parkLimit
                if goRequested {
                    await MainActor.run {
                        wanderParked = false
                        wanderStatusText = nil
                    }
                    break
                }
                if resumeRequested || timeUp {
                    await MainActor.run {
                        wanderParked = false
                        wanderResumeRequested = false
                        wanderStatusText = nil
                    }
                    return true
                }
                try? await Task.sleep(for: .milliseconds(300))
                ticks += 1
                if ticks % 16 == 0 {
                    // Keep re-sending the parked position so it does not drift back.
                    if let here = lastSuccessfulCoordinate {
                        _ = await sendLocationUpdate(for: here)
                    }
                    if parkLimit > 0 {
                        let remaining = max(0, parkLimit - Date().timeIntervalSince(parkStart))
                        let minutes = Int((remaining / 60).rounded(.up))
                        await MainActor.run {
                            wanderStatusText = "Parked. Resuming in \(minutes) min"
                        }
                    }
                }
            }
        }
    }

    private func routeSamples(
        for route: MKRoute,
        transport: WanderTravel
    ) async -> [RoutePlaybackSample] {
        let coordinates = route.polyline.coordinateArray
        let display = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )
        let fallbackSpeed = route.expectedTravelTime > 0 ? route.distance / route.expectedTravelTime : 13.4
        switch transport.mode {
        case .driving:
            // Same speed-limit lookup as "Play Route".
            return await prefetchRoutePlaybackSamples(
                displayCoordinates: display,
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
        case .moto:
            // Always at the chosen top speed, ignoring speed limits.
            return buildPlaybackSamples(
                from: display,
                speedWays: [],
                fallbackSpeedMetersPerSecond: transport.topSpeed
            )
        case .walking:
            return buildPlaybackSamples(
                from: display,
                speedWays: [],
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
        }
    }

    private func goLeg(
        from start: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transport: WanderTravel
    ) async -> [RoutePlaybackSample]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.requestsAlternateRoutes = false
        transport.configure(request)

        guard let route = try? await MKDirections(request: request).calculate().routes.first,
              route.polyline.pointCount > 1 else {
            return nil
        }
        return await routeSamples(for: route, transport: transport)
    }

    /// Picks a destination ahead of the current heading (so the drive keeps
    /// flowing instead of zig-zagging) and asks MapKit for a route, which
    /// respects one-way streets. Routes that leave the zone, start with a
    /// U-turn or take a big detour are discarded.
    private func wanderLeg(
        from start: CLLocationCoordinate2D,
        zone: WanderZoneShape,
        heading: CLLocationDirection?,
        transport: WanderTravel
    ) async -> [RoutePlaybackSample]? {
        let startLocation = CLLocation(latitude: start.latitude, longitude: start.longitude)
        // After a manual trip outside the zone, come back in without the zone limits.
        let startsOutside = !zone.contains(start)
        let radius = zone.radius

        for attempt in 0..<10 {
            guard !Task.isCancelled else { return nil }
            let strict = attempt < 7

            let destination: CLLocationCoordinate2D
            if let heading, !startsOutside, attempt < 6 {
                let angle = heading + Double.random(in: -100...100)
                let lower = min(300 * transport.reach, radius * 0.4)
                let upper = max(min(1200 * transport.reach, radius * 1.2), 350)
                destination = offsetCoordinate(from: start, distance: Double.random(in: lower...upper), bearing: angle)
            } else {
                destination = zone.randomPoint()
            }

            guard zone.contains(destination) else { continue }
            let destinationLocation = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            let straightDistance = destinationLocation.distance(from: startLocation)
            guard straightDistance >= min(150, radius / 2) else { continue }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.requestsAlternateRoutes = false
            transport.configure(request)

            guard let route = try? await MKDirections(request: request).calculate().routes.first else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let coordinates = route.polyline.coordinateArray
            guard coordinates.count > 1 else { continue }

            let staysInside = coordinates.allSatisfy { zone.contains($0) }
            guard staysInside || startsOutside else { continue }

            if strict && !startsOutside {
                guard route.distance <= straightDistance * 2.5 + 250 else { continue }

                if let heading {
                    let origin = CLLocation(latitude: coordinates[0].latitude, longitude: coordinates[0].longitude)
                    let reference = coordinates.dropFirst().first { point in
                        CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: origin) > 15
                    }
                    if let reference {
                        let routeHeading = bearingDegrees(from: coordinates[0], to: reference)
                        if angularDifference(routeHeading, heading) > 120 { continue }
                    }
                }
            }

            let samples = await routeSamples(for: route, transport: transport)
            if samples.count > 1 { return samples }
        }
        return nil
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: RouteSearchSelection?
    let initialEnd: RouteSearchSelection?
    let onApply: (RouteSearchSelection, RouteSearchSelection) -> Void

    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: RouteSearchField?

    init(
        initialStart: RouteSearchSelection?,
        initialEnd: RouteSearchSelection?,
        onApply: @escaping (RouteSearchSelection, RouteSearchSelection) -> Void
    ) {
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onApply = onApply
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start:
            return startCompleter.results
        case .end:
            return endCompleter.results
        case .none:
            return []
        }
    }

    private var canApply: Bool {
        startSelection != nil && endSelection != nil && !isResolvingSelection
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                routeField(
                    title: "Start".localized,
                    icon: "circle.fill",
                    tint: .green,
                    text: $startQuery,
                    selection: startSelection,
                    field: .start
                )

                routeField(
                    title: "End".localized,
                    icon: "flag.checkered.circle.fill",
                    tint: .red,
                    text: $endQuery,
                    selection: endSelection,
                    field: .end
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isResolvingSelection {
                    ProgressView("Resolving location…")
                        .font(.footnote)
                } else if !activeResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(activeResults.enumerated()), id: \.element) { index, result in
                                Button {
                                    resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)

                                if index < activeResults.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("Search for a start and destination to build the route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Simulate Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Route") {
                        guard let startSelection, let endSelection else { return }
                        onApply(startSelection, endSelection)
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if startSelection == nil {
                focusedField = .start
            } else if endSelection == nil {
                focusedField = .end
            }
        }
    }

    private func routeField(
        title: String,
        icon: String,
        tint: Color,
        text: Binding<String>,
        selection: RouteSearchSelection?,
        field: RouteSearchField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                TextField(title, text: text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        errorMessage = nil
                        update(query: newValue, for: field)
                    }
                    .onSubmit {
                        if field == .start {
                            focusedField = .end
                        } else {
                            focusedField = nil
                        }
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func update(query: String, for field: RouteSearchField) {
        switch field {
        case .start:
            if query != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: query)
        case .end:
            if query != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: query)
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? .start
        let request = MKLocalSearch.Request(completion: completion)
        isResolvingSelection = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isResolvingSelection = false

                guard let item = response?.mapItems.first else {
                    errorMessage = error?.localizedDescription ?? "Could not resolve that location."
                    return
                }

                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                let selection = RouteSearchSelection(title: title, coordinate: item.placemark.coordinate)

                switch field {
                case .start:
                    startSelection = selection
                    startQuery = title
                    startCompleter.results = []
                    focusedField = .end
                case .end:
                    endSelection = selection
                    endQuery = title
                    endCompleter.results = []
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark.slash",
                        description: Text("Drop a pin on the map and tap the bookmark icon to save a location.")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
