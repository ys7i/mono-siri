import SwiftUI
import SwiftData

struct ReviewView: View {
    @Environment(LocationService.self) private var location
    @Environment(AppRouter.self) private var router
    @Query(sort: \KnowledgeCard.nextReviewAt) private var cards: [KnowledgeCard]
    @State private var session: ReviewSession?

    private var due: [KnowledgeCard] { cards.filter(\.isDue) }

    private var dueHere: [KnowledgeCard] {
        guard let here = location.currentLocation else { return [] }
        return due.filter { $0.learnedLocation.distance(from: here) <= ReviewScheduler.reviewRadius }
    }

    private var dueElsewhere: [KnowledgeCard] {
        let hereIDs = Set(dueHere.map(\.pageID))
        return due.filter { !hereIDs.contains($0.pageID) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("ここで復習") {
                    if dueHere.isEmpty {
                        Text("この場所で覚えたカードのうち、復習待ちのものはありません。")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            session = ReviewSession(cards: dueHere)
                        } label: {
                            Label("\(dueHere.count)枚を復習する", systemImage: "play.circle.fill")
                                .font(.headline)
                        }
                        ForEach(dueHere) { CardRow(card: $0) }
                    }
                }

                if !dueElsewhere.isEmpty {
                    Section {
                        ForEach(dueElsewhere) { card in
                            Button {
                                session = ReviewSession(cards: [card])
                            } label: {
                                CardRow(card: card, showPlace: true)
                            }
                            .tint(.primary)
                        }
                    } header: {
                        Text("ほかの場所で待っているカード")
                    } footer: {
                        Text("覚えた場所に行くと通知でお知らせします。先に復習することもできます。")
                    }
                }
            }
            .navigationTitle("復習")
            .overlay {
                if cards.isEmpty {
                    ContentUnavailableView("まだカードがありません", systemImage: "rectangle.stack",
                                           description: Text("「近く」タブで記事をカードにすると、同じ場所に戻ったときに出題されます。"))
                }
            }
            .sheet(item: $session) { FlashcardSessionView(cards: $0.cards) }
            .onChange(of: router.reviewFocusPageID, initial: true) { _, pageID in
                guard let pageID, let focus = cards.first(where: { $0.pageID == pageID }) else { return }
                router.reviewFocusPageID = nil
                // 通知から開いた直後は現在地が未取得のことがあるので、カードを覚えた場所を基準にまとめる
                let sameSpot = due.filter {
                    $0.learnedLocation.distance(from: focus.learnedLocation) <= ReviewScheduler.reviewRadius
                }
                session = ReviewSession(cards: sameSpot.isEmpty ? [focus] : sameSpot)
            }
        }
    }
}

struct ReviewSession: Identifiable {
    let id = UUID()
    let cards: [KnowledgeCard]
}

struct FlashcardSessionView: View {
    let cards: [KnowledgeCard]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var index = 0
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if index < cards.count {
                    let card = cards[index]
                    ProgressView(value: Double(index), total: Double(cards.count))

                    VStack(spacing: 12) {
                        Label(card.tier.label, systemImage: card.tier.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(card.title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        if let place = card.placeName {
                            Text("\(place)で覚えたカード").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !revealed {
                            Text("人に30秒で説明できる？")
                                .font(.title3)
                                .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)

                    if revealed {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(card.extract).lineSpacing(4)
                                Link("Wikipediaで続きを読む", destination: card.articleURL).font(.footnote)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Spacer(minLength: 0)

                    if revealed {
                        HStack(spacing: 12) {
                            ForEach(Recall.allCases, id: \.self) { recall in
                                Button { grade(card, recall) } label: {
                                    Text(recall.label).frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(tint(for: recall))
                            }
                        }
                    } else {
                        Button {
                            withAnimation { revealed = true }
                        } label: {
                            Text("答えを見る").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    Spacer()
                    ContentUnavailableView("おつかれさま", systemImage: "checkmark.seal",
                                           description: Text("\(cards.count)枚の復習が終わりました。"))
                    Spacer()
                    Button("閉じる") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("復習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }

    private func grade(_ card: KnowledgeCard, _ recall: Recall) {
        ReviewScheduler.apply(recall, to: card)
        try? context.save()
        revealed = false
        index += 1
    }

    private func tint(for recall: Recall) -> Color {
        switch recall {
        case .forgot: return .red
        case .vague: return .orange
        case .remembered: return .green
        }
    }
}
