import Foundation

struct NearbyArticle: Identifiable, Hashable, Sendable {
    let pageID: Int
    let title: String
    let latitude: Double
    let longitude: Double
    /// 現在地からの距離（m）。おすすめ記事のように場所と関係ないものは nil
    let distance: Double?
    let tier: Tier
    let extract: String
    let thumbnailURL: URL?

    var id: Int { pageID }
    var articleURL: URL { WikipediaClient.articleURL(pageID: pageID) }
}

/// 日本語版Wikipediaから、近くの記事とおすすめ記事を取ってくる。
///
/// 近くの記事は2つの方法で集める。
/// - 足元：GeoSearch（座標の近い順）。歩いて見に行けるもの
/// - 町・広域：全文検索の `nearcoord:` で、その範囲にある記事のうち「由来」「伝説」「合戦」などの
///   話が書かれたものを探す。近い順だと駅・学校・ビルばかりになるため
struct WikipediaClient: Sendable {
    static let endpoint = URL(string: "https://ja.wikipedia.org/w/api.php")!
    /// Wikimedia の方針で、連絡先の分かる User-Agent が求められている
    static let userAgent = "MonoSiri/0.1 (personal learning app; https://github.com/ys7i/mono-siri)"

    static func articleURL(pageID: Int) -> URL {
        URL(string: "https://ja.wikipedia.org/?curid=\(pageID)")!
    }

    /// 話のネタになりやすい言葉。本文にこのどれかを含む記事を検索する
    static let storyWords = ["由来", "語源", "伝説", "伝承", "逸話", "合戦", "事件", "遺跡", "古墳", "史跡", "発祥", "創建", "旧跡"]
    /// 検索の段階で外す題名
    static let excludedTitleWords = ["小学校", "中学校", "高等学校", "マンション", "郵便局", "交差点", "インターチェンジ"]

    // MARK: - 近くの記事

    func nearby(latitude: Double, longitude: Double, perTier: Int = 5) async throws -> [Tier: [NearbyArticle]] {
        async let footHits = geosearch(latitude, longitude, radius: 300, limit: 40)
        async let townHits = storySearch(latitude, longitude, radiusKm: 2, limit: 30)
        async let regionHits = storySearch(latitude, longitude, radiusKm: 10, limit: 30)

        // 足元は検索に失敗しても、ほかの段階は出したい（逆も同じ）
        let foot = (try? await footHits) ?? []
        let town = (try? await townHits) ?? []
        let region = (try? await regionHits) ?? []
        if foot.isEmpty && town.isEmpty && region.isEmpty {
            throw URLError(.cannotLoadFromNetwork)
        }

        // 候補ID → 検索順位（0 が最上位）。順位は「その土地らしさ」の目安として使う
        var searchRank: [Int: Int] = [:]
        for (rank, hit) in town.enumerated() { searchRank[hit.pageid] = min(searchRank[hit.pageid] ?? .max, rank) }
        for (rank, hit) in region.enumerated() { searchRank[hit.pageid] = min(searchRank[hit.pageid] ?? .max, rank) }

        // 足元はつまらない題名を先に落としてから、近い15件に絞る
        let footIDs = foot
            .filter { !Interest.isDull(title: $0.title) || Interest.isStation(title: $0.title) }
            .sorted { $0.dist < $1.dist }
            .prefix(15)
            .map(\.pageid)

        var ids: [Int] = []
        var seen = Set<Int>()
        for id in footIDs + town.map(\.pageid) + region.map(\.pageid) where seen.insert(id).inserted {
            ids.append(id)
        }

        let infos = try await pages(ids: ids)

        var candidates: [Tier: [Interest.Candidate]] = [:]
        for id in ids {
            guard let info = infos[id],
                  let title = info.title,
                  let coordinate = info.coordinates?.first,
                  let extract = info.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !extract.isEmpty else { continue }

            let distance = Self.distance(latitude, longitude, coordinate.lat, coordinate.lon)
            let tier: Tier
            if distance <= 300 {
                tier = .footstep
            } else if distance <= 2_000 {
                tier = .town
            } else if distance <= 10_000 {
                tier = .region
            } else {
                continue
            }

            let article = NearbyArticle(
                pageID: id,
                title: title,
                latitude: coordinate.lat,
                longitude: coordinate.lon,
                distance: distance,
                tier: tier,
                extract: Self.trim(extract),
                thumbnailURL: info.thumbnail.flatMap { URL(string: $0.source) }
            )
            let score = Interest.score(
                title: title,
                extract: extract,
                length: info.length ?? 0,
                searchRank: searchRank[id],
                distance: distance,
                tier: tier
            )
            candidates[tier, default: []].append(
                Interest.Candidate(article: article, score: score, isStation: Interest.isStation(title: title))
            )
        }

        var result: [Tier: [NearbyArticle]] = [:]
        for (tier, list) in candidates {
            result[tier] = Interest.pick(list, count: perTier)
        }
        return result
    }

    // MARK: - おすすめ（場所と関係なく、秀逸な記事・良質な記事からランダム）

    func featured(count: Int = 5) async throws -> [NearbyArticle] {
        var hits = (try? await search("incategory:秀逸な記事|良質な記事", sort: "random", limit: count * 2)) ?? []
        if hits.isEmpty {
            // 並び替えの random が使えなかったときの予備：一覧からこちらで選ぶ
            hits = try await categoryMembers("Category:良質な記事", limit: 500).shuffled()
        }
        let ids = Array(hits.map(\.pageid).prefix(count * 2))
        let infos = try await pages(ids: ids)

        let articles: [NearbyArticle] = ids.compactMap { id in
            guard let info = infos[id],
                  let title = info.title,
                  let extract = info.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !extract.isEmpty else { return nil }
            let coordinate = info.coordinates?.first
            return NearbyArticle(
                pageID: id,
                title: title,
                latitude: coordinate?.lat ?? 0,
                longitude: coordinate?.lon ?? 0,
                distance: nil,
                tier: .featured,
                extract: Self.trim(extract),
                thumbnailURL: info.thumbnail.flatMap { URL(string: $0.source) }
            )
        }
        return Array(articles.prefix(count))
    }

    // MARK: - API

    private func geosearch(_ lat: Double, _ lon: Double, radius: Int, limit: Int) async throws -> [GeoHit] {
        let response: GeoSearchResponse = try await get([
            "action": "query",
            "list": "geosearch",
            "gscoord": "\(lat)|\(lon)",
            "gsradius": "\(radius)",
            "gslimit": "\(limit)",
            "gsnamespace": "0",
        ])
        return response.query?.geosearch ?? []
    }

    /// 範囲内にあって、話のネタになりそうな言葉を含む記事を検索する
    private func storySearch(_ lat: Double, _ lon: Double, radiusKm: Int, limit: Int) async throws -> [SearchHit] {
        let words = Self.storyWords.joined(separator: " OR ")
        let excluded = Self.excludedTitleWords.map { "-intitle:\($0)" }.joined(separator: " ")
        let query = "nearcoord:\(radiusKm)km,\(lat),\(lon) \(words) \(excluded)"
        return try await search(query, sort: nil, limit: limit)
    }

    private func search(_ query: String, sort: String?, limit: Int) async throws -> [SearchHit] {
        var params = [
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srnamespace": "0",
            "srlimit": "\(limit)",
            "srprop": "",
        ]
        if let sort { params["srsort"] = sort }
        let response: SearchResponse = try await get(params)
        return response.query?.search ?? []
    }

    private func categoryMembers(_ category: String, limit: Int) async throws -> [SearchHit] {
        let response: CategoryMembersResponse = try await get([
            "action": "query",
            "list": "categorymembers",
            "cmtitle": category,
            "cmnamespace": "0",
            "cmlimit": "\(limit)",
        ])
        return response.query?.categorymembers ?? []
    }

    private func pages(ids: [Int]) async throws -> [Int: PageInfo] {
        // exintro 付きの TextExtracts は1回20件までなので、20件ずつ並列に取る
        let chunks = stride(from: 0, to: ids.count, by: 20).map { Array(ids[$0..<min($0 + 20, ids.count)]) }
        return try await withThrowingTaskGroup(of: [PageInfo].self, returning: [Int: PageInfo].self) { group in
            for chunk in chunks {
                group.addTask {
                    let response: PagesResponse = try await self.get([
                        "action": "query",
                        "prop": "extracts|pageimages|info|coordinates",
                        "exintro": "1",
                        "explaintext": "1",
                        "exlimit": "20",
                        "piprop": "thumbnail",
                        "pithumbsize": "480",
                        "colimit": "max",
                        "pageids": chunk.map(String.init).joined(separator: "|"),
                    ])
                    return response.query?.pages ?? []
                }
            }
            var out: [Int: PageInfo] = [:]
            for try await list in group {
                for page in list {
                    if let id = page.pageid { out[id] = page }
                }
            }
            return out
        }
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

    // MARK: - 小物

    /// 冒頭の段落を、句点で切れる範囲で短くする
    static func trim(_ text: String, limit: Int = 280) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let period = head.range(of: "。", options: .backwards) {
            return String(head[...period.lowerBound])
        }
        return head + "…"
    }

    /// 2点間の距離（m）。ハバーサイン公式
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
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
    let dist: Double
}

struct SearchHit: Decodable, Sendable {
    let pageid: Int
    let title: String
}

private struct GeoSearchResponse: Decodable {
    struct Query: Decodable { let geosearch: [GeoHit]? }
    let query: Query?
}

private struct SearchResponse: Decodable {
    struct Query: Decodable { let search: [SearchHit]? }
    let query: Query?
}

private struct CategoryMembersResponse: Decodable {
    struct Query: Decodable { let categorymembers: [SearchHit]? }
    let query: Query?
}

struct PageInfo: Decodable, Sendable {
    struct Thumbnail: Decodable, Sendable { let source: String }
    struct Coordinate: Decodable, Sendable {
        let lat: Double
        let lon: Double
    }
    let pageid: Int?
    let title: String?
    let extract: String?
    let thumbnail: Thumbnail?
    /// 記事の長さ（バイト）。読みごたえの目安
    let length: Int?
    let coordinates: [Coordinate]?
}

private struct PagesResponse: Decodable {
    struct Query: Decodable { let pages: [PageInfo]? }
    let query: Query?
}
