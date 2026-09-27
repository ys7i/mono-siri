import Foundation

struct NearbyArticle: Identifiable, Hashable, Sendable {
    let pageID: Int
    let title: String
    let latitude: Double
    let longitude: Double
    let distance: Double
    let tier: Tier
    let extract: String
    let thumbnailURL: URL?

    var id: Int { pageID }
    var articleURL: URL { WikipediaClient.articleURL(pageID: pageID) }
}

/// 日本語版Wikipediaの GeoSearch と TextExtracts を使って、近くの記事を3段階に分けて返す。
struct WikipediaClient: Sendable {
    static let endpoint = URL(string: "https://ja.wikipedia.org/w/api.php")!
    /// Wikimedia の方針で、連絡先の分かる User-Agent が求められている。公開前に自分のURLに差し替える。
    static let userAgent = "MonoSiri/0.1 (personal learning app; https://example.com/monosiri)"

    static func articleURL(pageID: Int) -> URL {
        URL(string: "https://ja.wikipedia.org/?curid=\(pageID)")!
    }

    func nearby(latitude: Double, longitude: Double, perTier: Int = 5) async throws -> [Tier: [NearbyArticle]] {
        // 1回の検索は最大500件で近い順なので、都市部で広域の記事を拾うために半径を変えて3回引く
        async let near = geosearch(latitude, longitude, radius: 300, limit: 50)
        async let mid = geosearch(latitude, longitude, radius: 2_000, limit: 300)
        async let far = geosearch(latitude, longitude, radius: 10_000, limit: 500)
        let hits = try await near + mid + far

        var unique: [Int: GeoHit] = [:]
        for hit in hits {
            if let existing = unique[hit.pageid], existing.dist <= hit.dist { continue }
            unique[hit.pageid] = hit
        }

        var buckets: [Tier: [GeoHit]] = [:]
        for hit in unique.values {
            if let tier = TierClassifier.classify(hit) {
                buckets[tier, default: []].append(hit)
            }
        }
        for (tier, list) in buckets {
            let sorted: [GeoHit]
            switch tier {
            case .region:
                // 広域は「大きいもの」を優先（dim = 対象物のおおよその大きさ）
                sorted = list.sorted { ($0.dim ?? 0, -$0.dist) > ($1.dim ?? 0, -$1.dist) }
            case .footstep, .town:
                sorted = list.sorted { $0.dist < $1.dist }
            }
            // 面白さで選び直すので、候補は多めに残す
            buckets[tier] = Array(sorted.prefix(perTier * 4))
        }

        let infos = try await pages(ids: buckets.values.flatMap { $0 }.map(\.pageid))

        var result: [Tier: [NearbyArticle]] = [:]
        for (tier, list) in buckets {
            let candidates: [Interest.Candidate] = list.compactMap { hit in
                guard let info = infos[hit.pageid],
                      let extract = info.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !extract.isEmpty else { return nil }
                let article = NearbyArticle(
                    pageID: hit.pageid,
                    title: hit.title,
                    latitude: hit.lat,
                    longitude: hit.lon,
                    distance: hit.dist,
                    tier: tier,
                    extract: Self.trim(extract),
                    thumbnailURL: info.thumbnail.flatMap { URL(string: $0.source) }
                )
                return Interest.Candidate(
                    article: article,
                    score: Interest.score(title: hit.title, extract: extract, length: info.length ?? 0, distance: hit.dist, tier: tier),
                    isStation: Interest.isStation(hit)
                )
            }
            result[tier] = Interest.pick(candidates, count: perTier)
        }
        return result
    }

    // MARK: - API

    private func geosearch(_ lat: Double, _ lon: Double, radius: Int, limit: Int) async throws -> [GeoHit] {
        let response: GeoSearchResponse = try await get([
            "action": "query",
            "list": "geosearch",
            "gscoord": "\(lat)|\(lon)",
            "gsradius": "\(radius)",
            "gslimit": "\(limit)",
            "gsprop": "type|dim",
            "gsnamespace": "0",
        ])
        return response.query?.geosearch ?? []
    }

    private func pages(ids: [Int]) async throws -> [Int: PageInfo] {
        var out: [Int: PageInfo] = [:]
        // exintro 付きの TextExtracts は1回20件まで
        for start in stride(from: 0, to: ids.count, by: 20) {
            let chunk = ids[start..<min(start + 20, ids.count)]
            let response: PagesResponse = try await get([
                "action": "query",
                "prop": "extracts|pageimages|info",
                "exintro": "1",
                "explaintext": "1",
                "exlimit": "20",
                "piprop": "thumbnail",
                "pithumbsize": "480",
                "pageids": chunk.map(String.init).joined(separator: "|"),
            ])
            for page in response.query?.pages ?? [] {
                if let id = page.pageid { out[id] = page }
            }
        }
        return out
    }

    private func get<T: Decodable>(_ params: [String: String]) async throws -> T {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        let all = params.merging(["format": "json", "formatversion": "2"]) { current, _ in current }
        components.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 冒頭の段落を、句点で切れる範囲で短くする
    static func trim(_ text: String, limit: Int = 280) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let period = head.range(of: "。", options: .backwards) {
            return String(head[...period.lowerBound])
        }
        return head + "…"
    }
}

// MARK: - 3段階への振り分け

enum TierClassifier {
    /// Wikipedia の座標テンプレートに付く type
    static let regionTypes: Set<String> = ["river", "mountain", "waterbody", "isle", "forest", "glacier", "pass", "adm1st", "adm2nd"]
    static let townTypes: Set<String> = ["city", "adm3rd", "railwaystation"]
    /// type が付いていない記事も多いので、題名の末尾でも判定する
    static let regionSuffixes = ["川", "山", "岳", "湖", "池", "湾", "峠", "島", "街道", "平野", "盆地", "丘陵", "山地", "山脈"]
    static let townSuffixes = ["駅", "町", "村", "区", "市", "丁目", "通", "筋"]

    static func classify(_ hit: GeoHit) -> Tier? {
        let name = baseName(hit.title)
        let type = hit.type ?? ""

        if regionTypes.contains(type) || regionSuffixes.contains(where: { name.hasSuffix($0) }) {
            return hit.dist <= 10_000 ? .region : nil
        }
        if townTypes.contains(type) || townSuffixes.contains(where: { name.hasSuffix($0) }) {
            return hit.dist <= 2_000 ? .town : nil
        }
        return hit.dist <= 300 ? .footstep : nil
    }

    /// 「梅田 (大阪市)」→「梅田」
    static func baseName(_ title: String) -> String {
        if let paren = title.range(of: " (") { return String(title[..<paren.lowerBound]) }
        return title
    }
}

// MARK: - レスポンス

struct GeoHit: Decodable, Sendable {
    let pageid: Int
    let title: String
    let lat: Double
    let lon: Double
    let dist: Double
    let type: String?
    let dim: Int?

    private enum CodingKeys: String, CodingKey { case pageid, title, lat, lon, dist, type, dim }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageid = try c.decode(Int.self, forKey: .pageid)
        title = try c.decode(String.self, forKey: .title)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        dist = try c.decode(Double.self, forKey: .dist)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        // dim は数値のことも文字列のこともあるので両方受ける
        if let number = try? c.decodeIfPresent(Int.self, forKey: .dim) {
            dim = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .dim) {
            dim = Int(text)
        } else {
            dim = nil
        }
    }
}

private struct GeoSearchResponse: Decodable {
    struct Query: Decodable { let geosearch: [GeoHit]? }
    let query: Query?
}

struct PageInfo: Decodable, Sendable {
    struct Thumbnail: Decodable, Sendable { let source: String }
    let pageid: Int?
    let title: String?
    let extract: String?
    let thumbnail: Thumbnail?
    /// 記事の長さ（バイト）。読みごたえの目安
    let length: Int?
}

private struct PagesResponse: Decodable {
    struct Query: Decodable { let pages: [PageInfo]? }
    let query: Query?
}
