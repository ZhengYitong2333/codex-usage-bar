import Foundation

@main
enum MenuBarTests {
    static func main() throws {
        let all = MenuBarMetric.allQuotas
        assert(all.count == 5 && Set(all).count == 5 && !all.contains(.codex))
        assert(MenuBarMetric.selection([.codex], metric: .codex, enabled: false) == [.codex])
        assert(MenuBarMetric.selection([.codex], metric: .openCodeWeekly, enabled: true) == [.codex, .openCodeWeekly])
        assert(MenuBarMetric.selection(all, metric: .codex, enabled: true)
               == [.codex, .openCodeRolling, .openCodeWeekly, .openCodeMonthly])
        assert(MenuBarMetric.selection([.codex, .openCodeWeekly], metric: .codexPrimary, enabled: true)
               == [.codexPrimary, .openCodeWeekly])
        assert(MenuBarMetric.selection([.codexSecondary, .openCodeWeekly], metric: .codexSecondary, enabled: false) == [.openCodeWeekly])
        assert(MenuBarMetric.selection([.openCodeMonthly], metric: .codexPrimary, enabled: true) == [.codexPrimary, .openCodeMonthly])
        assert(MenuBarMetric.codexPrimary.reading(used: 18).value == "82%")
        assert(MenuBarMetric.openCodeWeekly.reading(used: 0).value == "100%")
        assert(MenuBarMetric.openCodeMonthly.reading(used: 100).value == "0%")
        assert(MenuBarMetric.codex.reading(used: nil).value == "—")
        assert(MenuBarMetric.codex.reading(used: .nan).value == "—")
        assert(MenuBarMetric.codex.reading(used: .infinity).value == "—")
        assert(MenuBarMetric.codex.reading(used: 101).value == "0%")
        assert(MenuBarMetric.codex.reading(used: -1).value == "100%")
        assert(MenuBarMetric.codex.reading(used: 18, stale: true).tooltip.contains("已过时"))
        let encoded = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([MenuBarMetric].self, from: encoded)
        assert(decoded == all)
        print("Menu bar selection and remaining-value checks passed.")
    }
}
