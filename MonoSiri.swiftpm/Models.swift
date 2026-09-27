import Foundation
import SwiftData
import CoreLocation

/// 記事の分類。距離による3段階と、場所に関係ない「おすすめ」
enum Tier: String, Codable, CaseIterable, Identifiable, Sendable {
    case footstep, town, region, featured

    var id: String { rawValue }

    /// 現在地からの距離で分ける段階
    static let byDistance: [Tier] = [.footstep, .town, .region]

    var label: String {
        switch self {
        case .footstep: return "足元"
        case .town: return "町"
        case .region: return "広域"
        case .featured: return "おすすめ"
        }
    }

    var caption: String {
        switch self {
        case .footstep: return "〜300m・歩いて見に行けるもの"
        case .town: return "〜2km・この町の由来や出来事"
        case .region: return "〜10km・この辺りが舞台になった歴史"
        case .featured: return "場所を問わず・秀逸な記事と良質な記事からランダム"
        }
    }

    var symbol: String {
        switch self {
        case .footstep: return "figure.walk"
        case .town: return "building.2"
        case .region: return "map"
        case .featured: return "star"
        }
    }
}

/// 覚えたカード。復習は「覚えた場所」に戻ったときに出題する。
@Model
final class KnowledgeCard {
    @Attribute(.unique) var pageID: Int
    var title: String
    var extract: String
    var thumbnailURLString: String?
    var tierRaw: String

    var articleLatitude: Double
    var articleLongitude: Double
    /// 復習のトリガーになる場所（記事の座標ではなく、覚えたときに自分がいた場所）
    var learnedLatitude: Double
    var learnedLongitude: Double
    var placeName: String?
    var learnedAt: Date

    // 間隔反復
    var nextReviewAt: Date
    var intervalDays: Double
    var ease: Double
    var reviewCount: Int
    var lapseCount: Int
    var lastReviewedAt: Date?

    init(article: NearbyArticle, learnedAt location: CLLocation, placeName: String?, now: Date = .now) {
        pageID = article.pageID
        title = article.title
        extract = article.extract
        thumbnailURLString = article.thumbnailURL?.absoluteString
        tierRaw = article.tier.rawValue
        articleLatitude = article.latitude
        articleLongitude = article.longitude
        learnedLatitude = location.coordinate.latitude
        learnedLongitude = location.coordinate.longitude
        self.placeName = placeName
        learnedAt = now
        nextReviewAt = now.addingTimeInterval(ReviewScheduler.firstDelay)
        intervalDays = 1
        ease = 2.3
        reviewCount = 0
        lapseCount = 0
    }

    var tier: Tier { Tier(rawValue: tierRaw) ?? .town }
    var learnedLocation: CLLocation { CLLocation(latitude: learnedLatitude, longitude: learnedLongitude) }
    var articleURL: URL { WikipediaClient.articleURL(pageID: pageID) }
    var isDue: Bool { nextReviewAt <= .now }
}

enum Recall: CaseIterable {
    case forgot, vague, remembered

    var label: String {
        switch self {
        case .forgot: return "忘れた"
        case .vague: return "あいまい"
        case .remembered: return "説明できた"
        }
    }
}

/// SM-2 を簡略化した間隔反復。
/// 「戻ってきたとき」に出題するので、nextReviewAt は「これ以降なら出題してよい」時刻として扱う。
enum ReviewScheduler {
    /// 初回の復習は、覚えてから20時間以降（翌日の同じ通勤路などで出題される）
    static let firstDelay: TimeInterval = 20 * 3600
    /// 覚えた場所からこの距離以内にいれば「同じ場所」とみなす
    static let reviewRadius: CLLocationDistance = 300
    /// 毎日同じ時刻に通る場所で取りこぼさないための余裕
    private static let slack: TimeInterval = 4 * 3600

    static func apply(_ recall: Recall, to card: KnowledgeCard, now: Date = .now) {
        switch recall {
        case .forgot:
            card.intervalDays = 1
            card.ease = max(1.3, card.ease - 0.2)
            card.lapseCount += 1
        case .vague:
            card.intervalDays = max(1, card.intervalDays * 1.2)
            card.ease = max(1.3, card.ease - 0.1)
        case .remembered:
            card.intervalDays = card.reviewCount == 0 ? 3 : card.intervalDays * card.ease
            card.ease = min(3.0, card.ease + 0.05)
        }
        card.reviewCount += 1
        card.lastReviewedAt = now
        card.nextReviewAt = now.addingTimeInterval(card.intervalDays * 86_400 - slack)
    }
}

extension Double {
    /// メートルを「120m」「3.4km」の形にする
    var distanceText: String {
        self < 1000 ? "\(Int(self.rounded()))m" : String(format: "%.1fkm", self / 1000)
    }
}
