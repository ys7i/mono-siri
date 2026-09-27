import Foundation

/// 近くの記事から「話のネタになりそうなもの」を選ぶ。
/// 都市部では座標付き記事の多くが駅・学校・ビルなので、近い順に並べるとそればかりになる。
enum Interest {
    struct Candidate {
        let article: NearbyArticle
        let score: Double
        let isStation: Bool
    }

    /// 駅の記事を混ぜる確率。混ぜるときも1段階につき1枚まで
    static let stationChance = 0.25

    /// 冒頭にこれがあると、うんちくになりやすい
    static let hooks: [(word: String, bonus: Double)] = [
        ("由来", 3), ("語源", 3), ("名付け", 2), ("呼ばれ", 1), ("旧称", 1.5),
        ("伝説", 2), ("伝承", 2), ("逸話", 2),
        ("古墳", 2), ("遺跡", 2), ("城跡", 2), ("跡", 1), ("史跡", 1.5),
        ("縄文", 1.5), ("弥生", 1.5), ("奈良時代", 1.5), ("平安", 1.5), ("鎌倉", 1.5), ("戦国", 1.5),
        ("江戸時代", 1), ("明治", 0.5), ("創建", 1), ("かつて", 1), ("最古", 2), ("唯一", 1.5), ("日本初", 2),
    ]

    /// 話のネタになりにくい題名（除外はせず、ほかに候補がなければ出す）
    static let dullSuffixes = [
        "小学校", "中学校", "高等学校", "高校", "大学", "学園", "幼稚園",
        "郵便局", "銀行", "支店", "病院", "クリニック", "警察署", "消防署", "図書館", "センター",
        "ビル", "タワー", "マンション", "ホテル", "店", "ストア", "本社", "会社", "工場",
        "線", "道路", "交差点", "インターチェンジ", "出入口", "ジャンクション", "停留場", "停留所",
    ]

    static func isStation(_ hit: GeoHit) -> Bool {
        hit.type == "railwaystation" || TierClassifier.baseName(hit.title).hasSuffix("駅")
    }

    static func score(title: String, extract: String, length: Int, distance: Double, tier: Tier) -> Double {
        let name = TierClassifier.baseName(title)
        // 長い記事ほど読みごたえがある（対数なので長さの効きはゆるやか）
        var score = log(Double(max(length, 1_000)))
        for hook in hooks where extract.contains(hook.word) {
            score += hook.bonus
        }
        if dullSuffixes.contains(where: { name.hasSuffix($0) }) {
            score -= 4
        }
        if tier == .footstep {
            // 足元は近いほうが見に行ける
            score -= distance / 300
        }
        // 同じ場所でも日によって少し違う顔ぶれになるように
        score += Double.random(in: 0..<1.5)
        return score
    }

    static func pick(_ candidates: [Candidate], count: Int) -> [NearbyArticle] {
        let ranked = candidates.sorted { $0.score > $1.score }
        let allowStation = Double.random(in: 0..<1) < stationChance

        var chosen: [NearbyArticle] = []
        var usedStation = false
        for candidate in ranked where chosen.count < count {
            if candidate.isStation {
                guard allowStation, !usedStation else { continue }
                usedStation = true
            }
            chosen.append(candidate.article)
        }
        // 駅以外が足りない土地では、駅で埋める
        if chosen.count < count {
            let picked = Set(chosen.map(\.pageID))
            chosen += ranked
                .filter { $0.isStation && !picked.contains($0.article.pageID) }
                .prefix(count - chosen.count)
                .map(\.article)
        }
        return chosen
    }
}
