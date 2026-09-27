import SwiftUI

struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(LocationService.self) private var location
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var bindableRouter = router
        TabView(selection: $bindableRouter.tab) {
            NearbyView()
                .tabItem { Label("近く", systemImage: "location") }
                .tag(AppRouter.Tab.nearby)
            ReviewView()
                .tabItem { Label("復習", systemImage: "arrow.counterclockwise") }
                .tag(AppRouter.Tab.review)
            LibraryView()
                .tabItem { Label("図鑑", systemImage: "books.vertical") }
                .tag(AppRouter.Tab.library)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await location.refresh(force: false) }
            }
        }
    }
}

/// カード一覧の1行
struct CardRow: View {
    let card: KnowledgeCard
    var showPlace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.headline)
            HStack(spacing: 8) {
                Label(card.tier.label, systemImage: card.tier.symbol)
                if showPlace, let place = card.placeName {
                    Label(place, systemImage: "mappin")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(card.isDue ? "復習待ち" : "次の復習 \(card.nextReviewAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(card.isDue ? Color.orange : Color.secondary)
        }
    }
}
