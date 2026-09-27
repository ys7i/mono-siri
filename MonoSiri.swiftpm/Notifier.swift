import Foundation
import UserNotifications

/// ローカル通知。送りすぎないよう、ここで回数を絞る。
struct Notifier {
    /// 発見通知は1日3回まで
    static let discoveryPerDay = 3
    /// 復習通知は2時間に1回まで
    static let reviewMinGap: TimeInterval = 2 * 3600

    private var center: UNUserNotificationCenter { .current() }
    private var defaults: UserDefaults { .standard }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyReview(pageID: Int, title: String, dueCount: Int) async {
        let key = "lastReviewNotificationAt"
        if let last = defaults.object(forKey: key) as? Date, Date().timeIntervalSince(last) < Self.reviewMinGap { return }
        defaults.set(Date(), forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "ここで覚えたこと、覚えてる？"
        content.body = dueCount > 1
            ? "「\(title)」を30秒で説明できる？（ほかに\(dueCount - 1)枚）"
            : "「\(title)」を30秒で説明できる？"
        content.sound = .default
        content.userInfo = ["kind": "review", "pageID": pageID]
        await add(content, id: "review-\(pageID)")
    }

    func wasNotified(_ pageID: Int) -> Bool {
        notifiedPageIDs.contains(pageID)
    }

    func notifyDiscovery(pageID: Int, tier: Tier, title: String, extract: String) async {
        let dayKey = "discoveryCount-" + Self.dayString(Date())
        let count = defaults.integer(forKey: dayKey)
        guard count < Self.discoveryPerDay, !wasNotified(pageID) else { return }
        defaults.set(count + 1, forKey: dayKey)
        notifiedPageIDs = Array((notifiedPageIDs + [pageID]).suffix(1000))

        let content = UNMutableNotificationContent()
        content.title = "\(tier.label)：\(title)"
        content.body = String(extract.prefix(80))
        content.sound = .default
        content.userInfo = ["kind": "discovery", "pageID": pageID]
        await add(content, id: "discovery-\(pageID)")
    }

    private var notifiedPageIDs: [Int] {
        get { defaults.array(forKey: "notifiedPageIDs") as? [Int] ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "notifiedPageIDs") }
    }

    private func add(_ content: UNNotificationContent, id: String) async {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }

    private static func dayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
