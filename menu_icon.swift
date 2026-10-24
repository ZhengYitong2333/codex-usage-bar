import AppKit

// A vector image keeps both text rows sharp at any display scale.
let percentageValue = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "—"
let stale = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "stale"
let foreground = CommandLine.arguments.count > 3 && CommandLine.arguments[3].uppercased() == "FFFFFF" ? NSColor.white : NSColor.black
let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsage/settings.json")
let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> CGFloat {
    let value = (config[key] as? NSNumber)?.doubleValue ?? fallback
    return CGFloat(value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback)
}
final class CodexMiniView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let label = stale ? "Codex ·" : "Codex"
        let labelFont = NSFont.systemFont(ofSize: number("label_size", 7, 6...10), weight: .light)
        let weight: NSFont.Weight = config["weight"] as? String == "semibold" ? .semibold : config["weight"] as? String == "medium" ? .medium : .regular
        let valueFont = NSFont.systemFont(ofSize: number("value_size", 12, 10...15), weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        let la = attrs.merging([.font: labelFont]) { $1 }
        let va = attrs.merging([.font: valueFont]) { $1 }
        let labelWidth = (label as NSString).size(withAttributes: la).width
        let valueWidth = (percentageValue as NSString).size(withAttributes: va).width
        let left = max(0, (bounds.width - max(labelWidth, valueWidth)) / 2)
        (label as NSString).draw(at: NSPoint(x: left, y: 12), withAttributes: la)
        (percentageValue as NSString).draw(at: NSPoint(x: left, y: number("value_offset", 0, -2...2)), withAttributes: va)
    }
}
// Allow 100% and larger font choices to fit without clipping.
let measureFont = NSFont.systemFont(ofSize: number("value_size", 12, 10...15), weight: .semibold)
let labelMeasureFont = NSFont.systemFont(ofSize: number("label_size", 7, 6...10), weight: .light)
let labelWidth = ((stale ? "Codex ·" : "Codex") as NSString).size(withAttributes: [.font: labelMeasureFont]).width
let neededWidth = ceil(max(labelWidth, (percentageValue as NSString).size(withAttributes: [.font: measureFont]).width)) + 2
let view = CodexMiniView(frame: NSRect(x: 0, y: 0, width: max(neededWidth, number("width", 30, 30...44)), height: 22))
print(view.dataWithPDF(inside: view.bounds).base64EncodedString())
