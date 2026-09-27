import SwiftUI
import SwiftData
import CoreLocation

struct NearbyView: View {
    @Environment(LocationService.self) private var location
    @Environment(AppRouter.self) private var router
    @Query private var cards: [KnowledgeCard]

    private var learnedIDs: Set<Int> { Set(cards.map(\.pageID)) }

    private var dueHereCount: Int {
        guard let here = location.currentLocation else { return 0 }
        return cards.filter { $0.isDue && $0.learnedLocation.distance(from: here) <= ReviewScheduler.reviewRadius }.count
    }

    private var isEmpty: Bool { location.nearby.values.allSatisfy(\.isEmpty) }

    var body: some View {
        NavigationStack {
            List {
                if !location.isAuthorized {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("今いる場所にまつわる記事を探すために、位置情報と通知を使います。")
                            Button("位置情報と通知を許可する") { location.requestPermissions() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if dueHereCount > 0 {
                    Section {
                        Button {
                            router.tab = .review
                        } label: {
                            Label("ここで覚えたカードが\(dueHereCount)枚、復習を待っています", systemImage: "arrow.counterclockwise.circle.fill")
                        }
                    }
                }

                if let error = location.lastError {
                    Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }

                if (location.isAuthorized || location.warpName != nil) && isEmpty {
                    Section {
                        if location.isLoading || location.currentLocation == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("近くの記事を探しています").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("近くに記事が見つかりません。少し移動してから引っぱって更新してください。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(Tier.byDistance) { tier in
                    let items = location.nearby[tier] ?? []
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { article in
                                NavigationLink(value: article) {
                                    ArticleRow(article: article, learned: learnedIDs.contains(article.pageID))
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(tier.label, systemImage: tier.symbol).font(.headline)
                                Text(tier.caption).font(.caption).textCase(nil)
                            }
                        }
                    }
                }

                Section {
                    if location.featured.isEmpty {
                        if location.isLoadingFeatured {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("おすすめ記事を選んでいます").foregroundStyle(.secondary)
                            }
                        } else {
                            Text("まだ記事がありません。下のボタンで読み込みます。").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(location.featured) { article in
                        NavigationLink(value: article) {
                            ArticleRow(article: article, learned: learnedIDs.contains(article.pageID))
                        }
                    }
                    Button {
                        Task { await location.loadFeatured() }
                    } label: {
                        Label("ほかの記事にする", systemImage: "shuffle")
                    }
                    .disabled(location.isLoadingFeatured)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(Tier.featured.label, systemImage: Tier.featured.symbol).font(.headline)
                        Text(Tier.featured.caption).font(.caption).textCase(nil)
                    }
                }
            }
            .navigationTitle(location.warpName.map { "\($0)（ワープ中）" } ?? location.placeName ?? "近く")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(WarpSpot.presets) { spot in
                            Button(spot.name) { Task { await location.warp(to: spot) } }
                        }
                        if location.warpName != nil {
                            Divider()
                            Button("現在地に戻る", systemImage: "location.fill") { Task { await location.warp(to: nil) } }
                        }
                    } label: {
                        Label("ワープ", systemImage: "airplane")
                    }
                }
            }
            .navigationDestination(for: NearbyArticle.self) { ArticleDetailView(article: $0) }
            .refreshable {
                await location.refresh(force: true)
                await location.loadFeatured()
            }
            .task {
                if location.featured.isEmpty { await location.loadFeatured() }
            }
        }
    }
}

struct ArticleRow: View {
    let article: NearbyArticle
    let learned: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(article.title).font(.headline)
                    if learned {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    }
                }
                Text(article.extract).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let distance = article.distance {
                Text(distance.distanceText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct ArticleDetailView: View {
    let article: NearbyArticle

    @Environment(\.modelContext) private var context
    @Environment(LocationService.self) private var location
    @Query private var existing: [KnowledgeCard]

    init(article: NearbyArticle) {
        self.article = article
        let id = article.pageID
        _existing = Query(filter: #Predicate<KnowledgeCard> { $0.pageID == id })
    }

    private var learned: Bool { !existing.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let url = article.thumbnailURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.1).frame(height: 180)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 12) {
                    Label(article.tier.label, systemImage: article.tier.symbol)
                    if let distance = article.distance {
                        Label(distance.distanceText, systemImage: "location")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(article.extract).font(.body).lineSpacing(4)

                Link(destination: article.articleURL) {
                    Label("Wikipediaで続きを読む", systemImage: "book")
                }

                Button(action: learn) {
                    Label(learned ? "カードにしました" : "カードにして覚える",
                          systemImage: learned ? "checkmark.circle.fill" : "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(learned)

                if learned {
                    Text("またこの場所に来たとき（20時間以降）に、復習の通知が届きます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("出典: Wikipedia日本語版（CC BY-SA 4.0）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func learn() {
        guard !learned else { return }
        let here = location.currentLocation ?? CLLocation(latitude: article.latitude, longitude: article.longitude)
        context.insert(KnowledgeCard(article: article, learnedAt: here, placeName: location.placeName))
        try? context.save()
        location.refreshMonitoredSpots()
    }
}
