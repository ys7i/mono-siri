import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \KnowledgeCard.learnedAt, order: .reverse) private var cards: [KnowledgeCard]

    var body: some View {
        NavigationStack {
            List {
                ForEach(cards) { card in
                    NavigationLink {
                        KnowledgeCardDetailView(card: card)
                    } label: {
                        CardRow(card: card, showPlace: true)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(cards[index]) }
                    try? context.save()
                }
            }
            .navigationTitle("図鑑（\(cards.count)）")
            .overlay {
                if cards.isEmpty {
                    ContentUnavailableView("まだカードがありません", systemImage: "books.vertical",
                                           description: Text("「近く」タブで気になる記事をカードにしましょう。"))
                }
            }
        }
    }
}

struct KnowledgeCardDetailView: View {
    let card: KnowledgeCard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let string = card.thumbnailURLString, let url = URL(string: string) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.1).frame(height: 180)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(card.extract).lineSpacing(4)
                Link(destination: card.articleURL) { Label("Wikipediaで続きを読む", systemImage: "book") }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("分類", value: card.tier.label)
                    if let place = card.placeName { LabeledContent("覚えた場所", value: place) }
                    LabeledContent("覚えた日", value: card.learnedAt.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("復習回数", value: "\(card.reviewCount)回")
                    LabeledContent("次の復習", value: card.nextReviewAt.formatted(.relative(presentation: .named)))
                }
                .font(.subheadline)
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                Text("出典: Wikipedia日本語版（CC BY-SA 4.0）").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(card.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
