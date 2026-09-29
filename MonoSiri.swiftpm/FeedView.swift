import SwiftUI
import SwiftData
import CoreLocation

/// 問いかけカードを1枚ずつ縦にめくる画面
struct FeedView: View {
    @Environment(FeedService.self) private var feed
    @Environment(LocationService.self) private var location
    @Query private var cards: [KnowledgeCard]
    @State private var revealed = Set<String>()

    private var learnedIDs: Set<Int> { Set(cards.map(\.pageID)) }
    private var nearbyArticles: [NearbyArticle] { Tier.byDistance.flatMap { location.nearby[$0] ?? [] } }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(feed.items) { item in
                    FeedCardView(
                        item: item,
                        isRevealed: revealed.contains(item.id),
                        isLearned: learnedIDs.contains(item.article.pageID),
                        reveal: {
                            withAnimation(.snappy) { _ = revealed.insert(item.id) }
                            feed.markSeen(item)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .containerRelativeFrame([.horizontal, .vertical])
                    .onAppear {
                        // 残り2枚になったら続きを足す
                        if let index = feed.items.firstIndex(of: item), index >= feed.items.count - 2 {
                            Task { await feed.loadMore(nearby: nearbyArticles) }
                        }
                    }
                }

                if feed.items.isEmpty {
                    emptyState
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .topTrailing) {
            Button {
                revealed = []
                Task { await feed.reload(nearby: nearbyArticles) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
            .disabled(feed.isLoading)
            .accessibilityLabel("新しく並べ直す")
        }
        .task {
            if feed.items.isEmpty { await feed.reload(nearby: nearbyArticles) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if feed.isLoading {
            ProgressView("ネタを集めています")
        } else {
            ContentUnavailableView {
                Label("ネタを集められませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(feed.lastError ?? "通信状態を確認して、もう一度お試しください。")
            } actions: {
                Button("もう一度") { Task { await feed.reload(nearby: nearbyArticles) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FeedCardView: View {
    let item: FeedItem
    let isRevealed: Bool
    let isLearned: Bool
    let reveal: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(LocationService.self) private var location

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(item.article.tier.label, systemImage: item.article.tier.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
            }

            if isRevealed {
                answer
            } else {
                question
            }
        }
        .padding(24)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: .infinity)
    }

    // MARK: - 問い

    private var question: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            if let lead = item.lead {
                Text(lead).font(.headline).foregroundStyle(.secondary)
            }
            Text(item.question)
                .font(.title2.weight(.semibold))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Text("〇〇〇 に入るのは？")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: reveal) {
                Text("答えを見る").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: reveal)
    }

    // MARK: - 答え

    private var answer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let url = item.article.thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Text(item.article.title)
                .font(.largeTitle.bold())
                .minimumScaleFactor(0.6)
                .lineLimit(2)

            if let lead = item.lead {
                Text(lead).font(.subheadline).foregroundStyle(.secondary)
            }

            ScrollView {
                Text(item.article.extract)
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button(action: learn) {
                    Label(isLearned ? "カードにしました" : "カードにして覚える",
                          systemImage: isLearned ? "checkmark.circle.fill" : "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLearned)

                Link(destination: item.article.articleURL) {
                    Label("続きを読む", systemImage: "book")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("出典: Wikipedia日本語版（CC BY-SA 4.0）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func learn() {
        guard !isLearned else { return }
        let article = item.article
        let here = location.currentLocation ?? CLLocation(latitude: article.latitude, longitude: article.longitude)
        context.insert(KnowledgeCard(article: article, learnedAt: here, placeName: location.placeName))
        try? context.save()
        location.refreshMonitoredSpots()
    }
}
