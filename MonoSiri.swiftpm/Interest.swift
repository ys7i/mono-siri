import Foundation

/// 近くの記事から「話のネタになりそうなもの」を選ぶ。
/// 建物・学校・駅・山のように「それ自体の説明で終わる記事」より、
/// 由来・出来事・伝承など、ほかの知識に話が広がる記事を優先する。
enum Interest {
    struct Candidate {
        let article: NearbyArticle
        let score: Double
        let isStation: Bool
    }

    /// 駅の記事を混ぜる確率。混ぜるときも1段階につき1枚まで
    static let stationChance = 0.25

    /// 冒頭にこれがあると、話が広がりやすい
    static let hooks: [(word: String, bonus: Double)] = [
        ("由来", 3), ("語源", 3), ("名付け", 2), ("呼ばれ", 1), ("旧称", 1.5),
        ("伝説", 2.5), ("伝承", 2.5), ("逸話", 2.5),
        ("合戦", 2.5), ("戦い", 1.5), ("事件", 2), ("一揆", 2), ("陣", 1),
        ("古墳", 2), ("遺跡", 2), ("城跡", 2), ("跡", 1), ("史跡", 1.5),
        ("縄文", 1.5), ("弥生", 1.5), ("飛鳥", 1.5), ("奈良時代", 1.5), ("平安", 1.5), ("鎌倉", 1.5), ("室町", 1.5), ("戦国", 1.5),
        ("江戸時代", 1), ("創建", 1), ("発祥", 2), ("かつて", 1), ("最古", 2), ("唯一", 1.5), ("日本初", 2),
    ]

    /// それ自体の説明で終わりやすい題名（除外はせず、大きく減点する）
    static let dullSuffixes = [
        "小学校", "中学校", "高等学校", "高校", "大学", "学園", "学院", "幼稚園", "保育園",
        "郵便局", "銀行", "支店", "病院", "クリニック", "警察署", "消防署", "図書館", "センター",
        "市役所", "区役所", "町役場", "庁舎", "会館", "ホール", "スタジアム", "ドーム", "団地",
        "ビル", "ビルディング", "タワー", "マンション", "ホテル", "店", "百貨店", "ストア", "モール",
        "本社", "会社", "工場", "寮",
        "線", "道路", "号線", "交差点", "インターチェンジ", "出入口", "ジャンクション", "停留場", "停留所", "トンネル",
    ]

    /// 山や川は話が広がるものもあるので、減点は軽め（合戦や伝説があれば上に来る）
    static let natureSuffixes = ["山", "岳", "峰", "川", "池", "湖"]

    static func isStation(title: String) -> Bool {
        WikipediaClient.baseName(title).hasSuffix("駅")
    }

    static func isDull(title: String) -> Bool {
        let name = WikipediaClient.baseName(title)
        return isStation(title: title) || dullSuffixes.contains(where: { name.hasSuffix($0) })
    }

    static func score(title: String, extract: String, length: Int, searchRank: Int?, distance: Double, tier: Tier) -> Double {
        let name = WikipediaClient.baseName(title)
        // 長い記事ほど読みごたえがある（対数なので長さの効きはゆるやか）
        var score = log(Double(max(length, 1_000)))

        for hook in hooks where extract.contains(hook.word) {
            score += hook.bonus
        }
        // 検索で上位に来た記事は、話のネタになる言葉が本文によく出てくる
        if let rank = searchRank {
            score += 3 * max(0, 1 - Double(rank) / 30)
        }
        if isDull(title: title) {
            score -= 6
        } else if natureSuffixes.contains(where: { name.hasSuffix($0) }) {
            score -= 2
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
