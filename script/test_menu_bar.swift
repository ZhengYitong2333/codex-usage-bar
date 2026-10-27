import Foundation

@main
enum MenuBarTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("codex_usage.py").path, "--metrics", "--catalog"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        assert(process.terminationStatus == 0)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let catalog = try decoder.decode([MenuBarMetric].self, from: data)
        let auto = catalog.first { $0.automatic }!
        let fixed = catalog.first { $0.provider == auto.provider && !$0.automatic }!
        let other = catalog.first { $0.provider != auto.provider }!
        assert(MenuBarMetric.selection([auto.id], metric: auto, enabled: false, catalog: catalog) == [auto.id])
        assert(MenuBarMetric.selection([auto.id, other.id], metric: fixed, enabled: true, catalog: catalog) == [other.id, fixed.id])
        assert(MenuBarMetric.selection([fixed.id, other.id], metric: auto, enabled: true, catalog: catalog) == [other.id, auto.id])
        assert(MenuBarMetric.selection([fixed.id, other.id], metric: fixed, enabled: false, catalog: catalog) == [other.id])
        assert(auto.reading(used: 18, display: "remaining").value == "82%")
        assert(auto.reading(used: 18, display: "used").value == "18%")
        for invalid in [Double.nan, .infinity] {
            assert(auto.reading(used: invalid, display: "remaining").value == "—")
        }
        assert(auto.reading(used: nil, display: "used").tooltip.contains("暂无数据"))
        assert(auto.reading(used: 101, display: "used").value == "100%")
        assert(auto.reading(used: -1, display: "remaining").value == "100%")
        let stale = auto.reading(used: 18, display: "used", stale: true)
        assert(stale.value == "18%!" && stale.tooltip.contains("已过时"))
        assert(Set(catalog.map(\.shortLabel)).count == catalog.count)
        assert(catalog.first { $0.provider == "opencode" && $0.meter == "rolling" }?.shortLabel == "OpenCode")
        let future = try decoder.decode(MenuBarMetric.self, from: Data("""
        {"provider":"future","meter":"daily","label":"新指标","short_label":"新", "automatic":false,
         "display_key":"future_display", "display":"used", "used":20}
        """.utf8))
        assert(future.reading(used: future.used, display: future.display).value == "20%")
        print("Runtime metric catalog, selection, labels, display and stale checks passed.")
    }
}
