import Foundation
import Observation

/// 「めくる」画面の1枚。答え（記事名）を伏せた問いと、答えの記事
struct FeedItem: Identifiable, Hashable, Sendable {
    let id: String
    /// 答えを 〇〇〇 で伏せた問い
    let question: String
    /// 問いの前に添える一言（「1829年の今日」「ここから1.2km」など）
    let lead: String?
    let article: NearbyArticle
}

/// 問いかけカードを集めて、種類が偏らないように並べる。
///
/// 材料はすべて Wikipedia から取る。
/// - 新しい記事：メインページの「新しい記事」欄。太字の記事名を伏せる
/// - 今日は何の日：日付の記事（「9月29日」など）の「できごと」。いちばん詳しいリンク先を伏せる
/// - おすすめ：秀逸な記事・良質な記事。冒頭の記事名を伏せる
/// - 近く：現在地の近くの記事。たまに混ぜる
@MainActor
@Observable
final class FeedService {
    var items: [FeedItem] = []
    var isLoading = false
    var lastError: String?

    @ObservationIgnored private let wiki: WikipediaClient
    @ObservationIgnored private var usedIDs = Set<String>()
    /// 並べる順番。新しい記事を多めに、近くの記事は時々
    private static let pattern: [Source] = [.trivia, .featured, .today, .trivia, .nearby, .featured, .trivia, .today]

    private enum Source { case trivia, today, featured, nearby }

    init(wiki: WikipediaClient) {
        self.wiki = wiki
    }

    // MARK: - 読み込み

    /// 最初から並べ直す
    func reload(nearby: [NearbyArticle]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let trivia = triviaItems()
        async let today = todayItems()
        async let featured = featuredItems(count: 6)
        usedIDs = []
        let queues: [Source: [FeedItem]] = [
            .trivia: await trivia,
            .today: await today,
            .featured: await featured,
            .nearby: nearbyItems(nearby, limit: 3),
        ]
        let composed = compose(queues)
        if composed.isEmpty {
            lastError = "記事を取得できませんでした。通信状態を確認して、もう一度お試しください。"
        } else {
            lastError = nil
        }
        items = composed
        markUsed(composed)
    }

    /// 終わりが近づいたら足す（おすすめと、まだ使っていない近くの記事）
    func loadMore(nearby: [NearbyArticle]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let more = compose([
            .featured: await featuredItems(count: 6),
            .nearby: nearbyItems(nearby, limit: 2),
        ])
        items += more
        markUsed(more)
    }

    /// 答えを見たカードは、次からは出さない（新しい記事・おすすめ）
    func markSeen(_ item: FeedItem) {
        SeenStore.insert(item.id)
    }

    // MARK: - 並べる

    private func compose(_ queues: [Source: [FeedItem]]) -> [FeedItem] {
        var queues = queues
        var out: [FeedItem] = []
        var seen = usedIDs
        while queues.values.contains(where: { !$0.isEmpty }) {
            for source in Self.pattern {
                guard var queue = queues[source], !queue.isEmpty else { continue }
                let item = queue.removeFirst()
                queues[source] = queue
                // 同じ記事が別の種類で重なったら片方だけにする
                let keys = Self.keys(of: item)
                if keys.allSatisfy({ !seen.contains($0) }) {
                    seen.formUnion(keys)
                    out.append(item)
                }
            }
        }
        return out
    }

    private static func keys(of item: FeedItem) -> [String] {
        [item.id, "page:\(item.article.pageID)"]
    }

    private func markUsed(_ items: [FeedItem]) {
        for item in items { usedIDs.formUnion(Self.keys(of: item)) }
    }

    // MARK: - 新しい記事

    private func triviaItems() async -> [FeedItem] {
        guard let text = try? await wiki.wikitext(page: "Template:新しい記事") else { return [] }

        struct Draft { let id: String; let question: String; let answer: String }
        var drafts: [Draft] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*"), !trimmed.hasPrefix("**") else { continue }
            let body = String(trimmed.drop(while: { $0 == "*" || $0 == " " }))

            // 太字の部分が答え。太字の中のリンク先を記事名として使う
            guard let bold = WikiText.firstBoldRange(in: body) else { continue }
            let answer = WikiText.links(in: bold.inner).first?.target ?? WikiText.plain(bold.inner)
            guard !answer.isEmpty else { continue }
            let question = WikiText.plain(body, masking: bold.range)
            guard question.contains(WikiText.mask), question.count >= 15 else { continue }

            let id = "trivia:\(answer)"
            guard !SeenStore.contains(id) else { continue }
            drafts.append(Draft(id: id, question: question, answer: answer))
        }

        let infos = (try? await wiki.pages(titles: drafts.map(\.answer))) ?? [:]
        return drafts.shuffled().compactMap { draft in
            guard let info = infos[draft.answer],
                  let article = WikipediaClient.article(from: info, tier: .trivia) else { return nil }
            return FeedItem(id: draft.id, question: draft.question, lead: nil, article: article)
        }
    }

    // MARK: - 今日は何の日

    private func todayItems(limit: Int = 6) async -> [FeedItem] {
        let date = Calendar.current.dateComponents([.month, .day], from: Date())
        guard let month = date.month, let day = date.day else { return [] }
        let page = "\(month)月\(day)日"
        guard let text = try? await wiki.wikitext(page: page) else { return [] }

        struct Draft { let id: String; let lead: String; let question: String; let answer: String }
        var drafts: [Draft] = []
        var inEvents = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("==") {
                // 「== できごと ==」の節だけを読む（下位の見出し「=== ... ===」は節の中とみなす）
                if !trimmed.hasPrefix("===") {
                    inEvents = trimmed.contains("できごと")
                }
                continue
            }
            guard inEvents, trimmed.hasPrefix("*"), !trimmed.hasPrefix("**") else { continue }

            // 「* [[1829年]] - イギリスの首都警察[[スコットランドヤード]]が発足」
            guard let yearLink = WikiText.links(in: trimmed).first,
                  yearLink.target.hasSuffix("年"),
                  let year = Int(yearLink.target.dropLast()) else { continue }
            let rest = trimmed[yearLink.range.upperBound...]
            guard let dash = rest.range(of: "-") ?? rest.range(of: "－") ?? rest.range(of: "–") else { continue }
            let body = String(rest[dash.upperBound...]).trimmingCharacters(in: .whitespaces)

            // いちばん長いリンク先を答えにする（国名や年より、出来事の主役になりやすい）
            let candidates = WikiText.links(in: body).filter { !$0.target.hasSuffix("年") }
            guard let answer = candidates.max(by: { $0.target.count < $1.target.count }) else { continue }
            let question = WikiText.plain(body, masking: answer.range)
            guard question.contains(WikiText.mask), question.count >= 10 else { continue }

            drafts.append(Draft(
                id: "today:\(month)-\(day):\(year):\(answer.target)",
                lead: "\(year)年の今日（\(month)月\(day)日）",
                question: question,
                answer: answer.target
            ))
        }

        let picked = Array(drafts.shuffled().prefix(limit * 2))
        let infos = (try? await wiki.pages(titles: picked.map(\.answer))) ?? [:]
        let items: [FeedItem] = picked.compactMap { draft in
            guard let info = infos[draft.answer],
                  let article = WikipediaClient.article(from: info, tier: .today) else { return nil }
            return FeedItem(id: draft.id, question: draft.question, lead: draft.lead, article: article)
        }
        return Array(items.prefix(limit))
    }

    // MARK: - おすすめ

    private func featuredItems(count: Int) async -> [FeedItem] {
        guard let articles = try? await wiki.featured(count: count * 2) else { return [] }
        let items: [FeedItem] = articles.compactMap { article in
            let id = "page:\(article.pageID)"
            guard !SeenStore.contains(id),
                  let masked = WikiText.cloze(article.extract, answer: article.title) else { return nil }
            return FeedItem(id: id, question: WikiText.sentences(masked, count: 2), lead: nil, article: article)
        }
        return Array(items.prefix(count))
    }

    // MARK: - 近く

    private func nearbyItems(_ articles: [NearbyArticle], limit: Int) -> [FeedItem] {
        let items: [FeedItem] = articles.shuffled().compactMap { article in
            let id = "page:\(article.pageID)"
            guard !usedIDs.contains(id),
                  let masked = WikiText.cloze(article.extract, answer: article.title) else { return nil }
            let lead = article.distance.map { "ここから\($0.distanceText)" }
            return FeedItem(id: id, question: WikiText.sentences(masked, count: 2), lead: lead, article: article)
        }
        return Array(items.prefix(limit))
    }
}

/// 答えを見たカードのID。端末に保存して、同じ問いを何度も出さないようにする
enum SeenStore {
    private static let key = "seenFeedIDs"
    private static let maxCount = 3000

    static func contains(_ id: String) -> Bool {
        (UserDefaults.standard.array(forKey: key) as? [String] ?? []).contains(id)
    }

    static func insert(_ id: String) {
        var ids = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        UserDefaults.standard.set(Array(ids.suffix(maxCount)), forKey: key)
    }
}
