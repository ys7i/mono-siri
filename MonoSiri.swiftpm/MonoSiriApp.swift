import SwiftUI
import SwiftData
import UserNotifications

@main
struct MonoSiriApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppEnvironment.shared.router)
                .environment(AppEnvironment.shared.location)
        }
        .modelContainer(AppEnvironment.shared.container)
    }
}

/// アプリ全体で共有するオブジェクト。
/// 位置情報でバックグラウンド起動されたときも、画面なしで同じものを使う。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let container: ModelContainer
    let router = AppRouter()
    let location: LocationService

    private init() {
        do {
            container = try ModelContainer(for: KnowledgeCard.self)
        } catch {
            fatalError("データベースを開けませんでした: \(error)")
        }
        location = LocationService(container: container, wiki: WikipediaClient())
    }
}

@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable { case nearby, review, library }

    var tab: Tab = .nearby
    /// 復習通知から開かれたときの対象カード
    var reviewFocusPageID: Int?

    func open(kind: String?, pageID: Int?) {
        switch kind {
        case "review":
            tab = .review
            reviewFocusPageID = pageID
        default:
            tab = .nearby
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 大きな移動・滞在・領域進入でバックグラウンド起動された場合もここを通る
        AppEnvironment.shared.location.resumeIfAuthorized()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        let pageID = info["pageID"] as? Int
        Task { @MainActor in
            AppEnvironment.shared.router.open(kind: kind, pageID: pageID)
            completionHandler()
        }
    }
}
