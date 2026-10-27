import AppKit
import Foundation

func hoverLog(_ line: String) {}

@main
enum SettingsTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let script = root.appendingPathComponent("codex_usage.py")
        let payload = try SettingsPayload.load(script: script, defaults: true)
        let defaults = try pythonOutput(script: script, arguments: ["--get-settings", "--defaults"])
        let pythonDefaults = try JSONSerialization.jsonObject(with: defaults) as! [String: Any]
        let swiftDefaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        assert(Set(pythonDefaults.keys) == Set(swiftDefaults.keys), "Swift/Python settings keys differ")
        assert(NSDictionary(dictionary: pythonDefaults).isEqual(to: swiftDefaults), "Swift/Python defaults differ")

        let unknown = MetricID(provider: "future", meter: "daily")
        var saved = payload.settings
        saved.menu_bar_items.append(unknown)
        var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        stored["future_setting"] = ["keep": true]
        let decoded = try Preferences.decode(JSONSerialization.data(withJSONObject: stored))
        assert(decoded.menu_bar_items.contains(unknown))
        var draft = decoded
        draft.value_size = 14
        let patch = try JSONSerialization.jsonObject(with: draft.changes(from: decoded)) as! [String: Any]
        assert(Set(patch.keys) == ["value_size"] && patch["value_size"] as? Int == 14)
        let unchanged = try decoded.changes(from: decoded)
        assert(unchanged == Data("{}".utf8))
        draft.display = "used"
        assert(draft.displayMode(for: payload.metrics[0]) == "used")
        assert(draft.displayMode(for: payload.metrics.last!) == "remaining")
        var restored = payload.settings
        restored.useAvailableWindow(["secondary"])
        assert(restored.window == "secondary")
        restored.window = "primary"
        restored.useAvailableWindow([])
        assert(restored.window == "primary")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("settings.json")
        try defaults.write(to: file, options: .atomic)
        let settings = AppSettings(file: file, load: {
            let prefs = try Preferences.decode(Data(contentsOf: file))
            var catalog = payload.metrics
            for i in catalog.indices { catalog[i].display = prefs.displayMode(for: catalog[i]) }
            return SettingsPayload(settings: prefs, metrics: catalog)
        })
        var refreshes = 0
        settings.onChange = { refreshes += 1 }
        var changed = payload.settings
        changed.display = "used"
        changed.stale_minutes = 60
        changed.menu_bar_items = [unknown]
        try JSONEncoder().encode(changed).write(to: file, options: .atomic)
        assert(settings.reloadIfChanged())
        assert(settings.staleMinutes == 60 && settings.menuBarItems == [unknown])
        assert(!settings.reloadIfChanged() && refreshes == 1)
        try Data("invalid".utf8).write(to: file, options: .atomic)
        assert(!settings.reloadIfChanged() && refreshes == 1 && settings.staleMinutes == 60)
        try JSONEncoder().encode(payload.settings).write(to: file, options: .atomic)
        assert(settings.reloadIfChanged() && refreshes == 2 && settings.staleMinutes == 15)

        var metrics = payload.metrics
        for index in metrics.indices { metrics[index].used = 18; metrics[index].updated = 1000 }
        let values = StatusIcon.values(selected: metrics.map(\.id), catalog: metrics, readings: metrics,
                                       staleMinutes: 60, now: 3000)
        assert(values.allSatisfy { $0.value == "82%" && !$0.stale })
        let stale = StatusIcon.values(selected: metrics.map(\.id), catalog: metrics, readings: metrics,
                                      staleMinutes: 15, now: 3000)
        assert(stale.allSatisfy { $0.value == "82%!" && $0.stale })
        metrics[0].display = "used"
        let mixed = StatusIcon.values(selected: metrics.map(\.id), catalog: metrics, readings: metrics,
                                      staleMinutes: 60, now: 3000)
        assert(mixed[0].value == "18%" && mixed.last!.value == "82%")
        let missing = StatusIcon.values(selected: [unknown], catalog: metrics, readings: [], staleMinutes: 15)
        assert(missing[0].value == "—")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let future = try decoder.decode(MenuBarMetric.self, from: Data("""
        {"provider":"future","meter":"daily","label":"新指标","short_label":"新", "automatic":false,
         "display_key":"future_display", "display":"used", "used":20}
        """.utf8))
        assert(StatusIcon.values(selected: [unknown], catalog: [future], readings: [future], staleMinutes: 15)[0].value == "20%")

        assert(AppLinks.usageURL(showCodex: false, openCodeURL: nil).host == "opencode.ai")
        assert(AppLinks.usageURL(showCodex: false, openCodeURL: "file:///tmp/test").scheme == "https")
        assert(AppLinks.usageURL(showCodex: true, openCodeURL: nil).host == "chatgpt.com")
        let sibling = temporary.appendingPathComponent("Codex Usage Settings.app")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        assert(AppLinks.settingsURL(beside: temporary.appendingPathComponent("Codex Usage.app"))?.path == sibling.path)
        let delegate = AppDelegate()
        delegate.schedule(minutes: 5)
        let timer = delegate.refreshTimer
        delegate.schedule(minutes: 5)
        assert(delegate.refreshTimer === timer)
        delegate.schedule(minutes: 2)
        assert(delegate.refreshTimer !== timer && delegate.refreshTimer?.timeInterval == 120)
        delegate.refreshTimer?.invalidate()
        print("Settings parity, preservation, single refresh, runtime metrics, stale thresholds and app links passed.")
    }
}
