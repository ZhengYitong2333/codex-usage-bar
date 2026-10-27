import Foundation

struct Preferences: Codable, Equatable {
    var refresh_minutes = 5
    var window = "primary"
    var display = "remaining"
    var show_tokens = true
    var show_countdown = true
    var label_size = 7
    var value_size = 12
    var weight = "regular"
    var width = 30
    var value_offset = 0
    var stale_minutes = 15
    var low_quota_warning = false
    var low_quota_threshold = 20
    var show_codex = true
    var show_opencode = true
    var opencode_display = "remaining"
    var opencode_days = 7
    var opencode_show_go = true
    var opencode_show_rolling = true
    var opencode_show_weekly = true
    var opencode_show_monthly = true
    var opencode_show_stats = true
    var opencode_show_cost = true
    var opencode_cli = ""
    var menu_bar_items: [MetricID] = [.init(provider: "codex", meter: "auto")]

    static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    func displayMode(for metric: MenuBarMetric) -> String {
        let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any]
        return object?[metric.displayKey] as? String ?? metric.display
    }

    func changes(from saved: Self) throws -> Data {
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: NSObject]
        let previous = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: NSObject]
        return try JSONSerialization.data(withJSONObject: current.filter { key, value in
            !value.isEqual(previous[key])
        })
    }

    mutating func useAvailableWindow(_ available: Set<String>) {
        if !available.isEmpty && !available.contains(window) {
            window = available.contains("primary") ? "primary" : "secondary"
        }
    }
}

func pythonOutput(script: URL, arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [script.path] + arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    return data
}

struct SettingsPayload {
    var settings: Preferences
    var metrics: [MenuBarMetric]

    static let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexUsage/codex_usage.py")

    static func load(script: URL = script, defaults: Bool = false) throws -> Self {
        let data = try pythonOutput(script: script, arguments: ["--get-settings", "--catalog"] + (defaults ? ["--defaults"] : []))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settingsObject = object["settings"], let metricObjects = object["metrics"]
        else { throw CocoaError(.fileReadCorruptFile) }
        let settings = try Preferences.decode(JSONSerialization.data(withJSONObject: settingsObject))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let metrics = try decoder.decode([MenuBarMetric].self, from: JSONSerialization.data(withJSONObject: metricObjects))
        return Self(settings: settings, metrics: metrics)
    }
}
