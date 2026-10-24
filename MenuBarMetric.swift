import Foundation

enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case codex
    case codexPrimary = "codex_primary"
    case codexSecondary = "codex_secondary"
    case openCodeRolling = "opencode_rolling"
    case openCodeWeekly = "opencode_weekly"
    case openCodeMonthly = "opencode_monthly"

    static let allQuotas: [Self] = [.codexPrimary, .codexSecondary,
                                  .openCodeRolling, .openCodeWeekly, .openCodeMonthly]
    var id: String { rawValue }

    static func selection(_ selected: [Self], metric: Self, enabled: Bool) -> [Self] {
        var items = selected
        if enabled {
            if metric == .codex {
                items.removeAll { $0 == .codexPrimary || $0 == .codexSecondary }
            } else if metric == .codexPrimary || metric == .codexSecondary {
                items.removeAll { $0 == .codex }
            }
            if !items.contains(metric) { items.append(metric) }
        } else if items.count > 1 {
            items.removeAll { $0 == metric }
        }
        return allCases.filter { items.contains($0) }
    }

    var label: String {
        switch self {
        case .codex: return "Codex 当前主额度（自动）"
        case .codexPrimary: return "Codex · 5 小时"
        case .codexSecondary: return "Codex · 每周"
        case .openCodeRolling: return "OpenCode · 5 小时额度"
        case .openCodeWeekly: return "OpenCode · 每周"
        case .openCodeMonthly: return "OpenCode · 每月"
        }
    }

    var shortLabel: String {
        switch self {
        case .codex: return "Codex"
        case .codexPrimary: return "Codex 5h"
        case .codexSecondary: return "Codex 周"
        case .openCodeRolling: return "Go 5H"
        case .openCodeWeekly: return "OpenCode"
        case .openCodeMonthly: return "OpenCode"
        }
    }

    func reading(used: Double?, stale: Bool = false) -> MenuBarValue {
        let value = used.flatMap { $0.isFinite ? "\(Int((100 - min(100, max(0, $0))).rounded()))%" : nil }
        return MenuBarValue(label: shortLabel, value: value ?? "—", stale: stale,
                            tooltip: label + (value.map { "：剩余 " + $0 } ?? "：暂无数据")
                                + (stale ? "（记录已过时）" : ""))
    }
}

struct MenuBarValue: Equatable {
    let label: String
    let value: String
    var stale = false
    var tooltip: String
}
