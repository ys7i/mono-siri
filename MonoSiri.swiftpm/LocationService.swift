import CoreLocation
import SwiftData
import UIKit
import Observation

/// 位置情報まわりのすべて。
/// - 大きな移動・滞在（Visit）で近くの記事を取り直し、発見通知を出す
/// - カードを覚えた場所を領域監視し、戻ってきたら復習通知を出す
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    var authorization: CLAuthorizationStatus = .notDetermined
    var currentLocation: CLLocation?
    var placeName: String?
    var nearby: [Tier: [NearbyArticle]] = [:]
    var isLoading = false
    var lastError: String?
    /// ワープ中の地点名（nil なら実際の現在地を使う）
    var warpName: String?

    var isAuthorized: Bool {
        authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let wiki: WikipediaClient
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var cache: [String: (date: Date, result: [Tier: [NearbyArticle]])] = [:]
    @ObservationIgnored private var isMonitoring = false

    /// iOSの領域監視は1アプリ20件まで
    private static let maxMonitoredSpots = 19
    private static let spotRadius: CLLocationDistance = 150
    private static let spotPrefix = "spot:"

    init(container: ModelContainer, wiki: WikipediaClient) {
        self.container = container
        self.wiki = wiki
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    // MARK: - 操作

    func requestPermissions() {
        manager.requestWhenInUseAuthorization()
        Task { await notifier.requestAuthorization() }
    }

    func resumeIfAuthorized() {
        authorization = manager.authorizationStatus
        if isAuthorized { startMonitoring() }
    }

    /// iPadでは移動のシミュレーションができないので、指定した地点に「ワープ」して試す
    func warp(to spot: WarpSpot?) async {
        guard let spot else {
            warpName = nil
            manager.requestLocation()
            return
        }
        warpName = spot.name
        await handle(location: spot.location)
    }

    func refresh(force: Bool) async {
        guard isAuthorized || warpName != nil else { return }
        if warpName == nil { manager.requestLocation() }
        if let location = currentLocation {
            await loadNearby(for: location, force: force)
        }
    }

    private func startMonitoring() {
        if !isMonitoring {
            isMonitoring = true
            // どちらも省電力。「常に許可」ならアプリが終了していても起こしてもらえる
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        }
        manager.requestLocation()
    }

    // MARK: - 位置が変わったとき

    func handle(location: CLLocation) async {
        currentLocation = location
        let task = UIApplication.shared.beginBackgroundTask(withName: "MonoSiri.nearby", expirationHandler: nil)
        defer { UIApplication.shared.endBackgroundTask(task) }

        await updatePlaceName(for: location)
        await loadNearby(for: location, force: false)
        await notifyReviewsIfNeeded(at: location)
        await notifyDiscoveryIfNeeded()
        refreshMonitoredSpots(around: location)
    }

    private func loadNearby(for location: CLLocation, force: Bool) async {
        // 約100m単位でキャッシュ。同じ場所では1日1回しかAPIを叩かない
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        if !force, let cached = cache[key], Date().timeIntervalSince(cached.date) < 86_400 {
            nearby = cached.result
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await wiki.nearby(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            cache[key] = (Date(), result)
            nearby = result
            lastError = nil
        } catch {
            lastError = "Wikipediaの記事を取得できませんでした（\(error.localizedDescription)）"
        }
    }

    private func updatePlaceName(for location: CLLocation) async {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        let name = [placemark.locality, placemark.subLocality].compactMap { $0 }.joined(separator: " ")
        placeName = name.isEmpty ? nil : name
    }

    // MARK: - 通知

    /// 覚えた場所の近くにいて、復習時期が来ているカードがあれば通知する
    private func notifyReviewsIfNeeded(at location: CLLocation) async {
        // アプリを開いているときは「近く」タブのバナーで知らせる
        guard UIApplication.shared.applicationState != .active else { return }
        let now = Date()
        let descriptor = FetchDescriptor<KnowledgeCard>(
            predicate: #Predicate { $0.nextReviewAt <= now },
            sortBy: [SortDescriptor(\.nextReviewAt)]
        )
        guard let due = try? container.mainContext.fetch(descriptor) else { return }
        let here = due.filter { $0.learnedLocation.distance(from: location) <= ReviewScheduler.reviewRadius }
        guard let first = here.first else { return }
        await notifier.notifyReview(pageID: first.pageID, title: first.title, dueCount: here.count)
    }

    /// まだ覚えていない足元・町の記事を1つ知らせる
    private func notifyDiscoveryIfNeeded() async {
        guard UIApplication.shared.applicationState != .active else { return }
        let learned = Set(((try? container.mainContext.fetch(FetchDescriptor<KnowledgeCard>())) ?? []).map(\.pageID))
        let candidates = (nearby[.footstep] ?? []) + (nearby[.town] ?? [])
        guard let article = candidates.first(where: { !learned.contains($0.pageID) && !notifier.wasNotified($0.pageID) }) else { return }
        await notifier.notifyDiscovery(pageID: article.pageID, tier: article.tier, title: article.title, extract: article.extract)
    }

    // MARK: - 覚えた場所の領域監視

    /// 現在地に近い「覚えた場所」から順に最大19か所を監視する
    func refreshMonitoredSpots(around location: CLLocation? = nil) {
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let center = location ?? currentLocation else { return }

        let cards = (try? container.mainContext.fetch(FetchDescriptor<KnowledgeCard>())) ?? []
        // 同じ場所で覚えた複数のカードは1か所にまとめる（約100m単位）
        var spots: [String: CLLocationCoordinate2D] = [:]
        for card in cards {
            let key = Self.spotPrefix + String(format: "%.3f,%.3f", card.learnedLatitude, card.learnedLongitude)
            spots[key] = CLLocationCoordinate2D(latitude: card.learnedLatitude, longitude: card.learnedLongitude)
        }
        let nearest = spots
            .sorted {
                CLLocation(latitude: $0.value.latitude, longitude: $0.value.longitude).distance(from: center)
                    < CLLocation(latitude: $1.value.latitude, longitude: $1.value.longitude).distance(from: center)
            }
            .prefix(Self.maxMonitoredSpots)

        for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.spotPrefix) {
            manager.stopMonitoring(for: region)
        }
        for (key, coordinate) in nearest {
            let region = CLCircularRegion(center: coordinate, radius: Self.spotRadius, identifier: key)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            manager.startMonitoring(for: region)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            switch status {
            case .authorizedWhenInUse:
                // 戻ってきたときの復習通知には「常に許可」が必要
                self.manager.requestAlwaysAuthorization()
                self.startMonitoring()
            case .authorizedAlways:
                self.startMonitoring()
                self.refreshMonitoredSpots()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.warpName == nil else { return }
            await self.handle(location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // 到着時だけ扱う（出発時は departureDate が入る）
        guard visit.departureDate == .distantFuture else { return }
        let location = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        Task { @MainActor in
            guard self.warpName == nil else { return }
            await self.handle(location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circle = region as? CLCircularRegion else { return }
        let location = CLLocation(latitude: circle.center.latitude, longitude: circle.center.longitude)
        Task { @MainActor in await self.notifyReviewsIfNeeded(at: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = "位置情報を取得できませんでした（\(message)）" }
    }
}

struct WarpSpot: Identifiable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double

    var id: String { name }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    static let presets: [WarpSpot] = [
        WarpSpot(name: "大阪城", latitude: 34.6873, longitude: 135.5262),
        WarpSpot(name: "天王寺・四天王寺", latitude: 34.6545, longitude: 135.5163),
        WarpSpot(name: "京都・東山", latitude: 34.9967, longitude: 135.7850),
        WarpSpot(name: "奈良公園", latitude: 34.6851, longitude: 135.8430),
        WarpSpot(name: "神戸・旧居留地", latitude: 34.6880, longitude: 135.1920),
        WarpSpot(name: "堺・大仙陵古墳", latitude: 34.5640, longitude: 135.4870),
    ]
}
