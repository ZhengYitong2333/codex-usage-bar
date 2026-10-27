import Foundation

struct MetricID: Codable, Hashable, Identifiable {
    var provider: String
    var meter: String
    var id: Self { self }
}

struct MenuBarMetric: Codable, Equatable, Identifiable {
    var provider: String
    var meter: String
    var label: String
    var quotaLabel: String?
    var shortLabel: String
    var automatic: Bool
    var displayKey: String
    var display: String
    var used: Double?
    var updated: Double?
    var id: MetricID { MetricID(provider: provider, meter: meter) }

    static func selection(_ selected: [MetricID], metric: Self, enabled: Bool, catalog: [Self]) -> [MetricID] {
        var items = selected
        if enabled {
            let automaticIDs = Set(catalog.filter { $0.automatic }.map(\.id))
            items.removeAll { $0.provider == metric.provider && (metric.automatic || automaticIDs.contains($0)) }
            if !items.contains(metric.id) { items.append(metric.id) }
        } else if items.count > 1 {
            items.removeAll { $0 == metric.id }
        }
        return items
    }

    func reading(used: Double?, display: String, stale: Bool = false) -> MenuBarValue {
        let mode = display == "used" ? "已用" : "剩余"
        let value = used.flatMap { used -> String? in
            guard used.isFinite else { return nil }
            let bounded = min(100, max(0, used))
            return "\(Int((display == "used" ? bounded : 100 - bounded).rounded()))%"
        }
        return MenuBarValue(label: shortLabel, value: (value ?? "—") + (stale ? "!" : ""), stale: stale,
                            tooltip: label + (value.map { "：\(mode) " + $0 } ?? "：暂无数据")
                                + (stale ? "（记录已过时）" : ""))
    }
}

struct MenuBarValue: Equatable {
    let label: String
    let value: String
    var stale = false
    var tooltip: String
}
