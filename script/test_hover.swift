import AppKit
import SwiftUI

func hoverLog(_ line: String) {}

@main
struct HoverTests {
    @MainActor static func main() throws {
        var presence = ChartHoverPresence()
        assert(presence.shouldHide)
        presence.rowID = "old-popover-codex"
        presence.rowID = "new-popover-opencode"
        presence.leaveRow("old-popover-codex")
        assert(presence.rowID == "new-popover-opencode" && !presence.shouldHide)
        presence.panel = true
        presence.leaveRow("new-popover-opencode")
        assert(!presence.shouldHide)
        presence.panel = false
        assert(presence.shouldHide)

        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let popover = NSRect(x: 1000, y: 300, width: 320, height: 500)
        let anchor = NSRect(x: 1016, y: 550, width: 288, height: 33)
        let placement = chartPanelFrame(size: UsageChartPanel.size, anchor: anchor,
                                        popover: popover, visible: visible)
        assert(placement.maxY == anchor.maxY)
        assert(placement.maxX == popover.minX - 2)
        assert(!placement.intersects(popover))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let days = (0..<7).map { UIModel.Day(date: "10-\(19+$0)", tokens: 10,
                                             inputTokens: 8, outputTokens: 2, text: "10") }
        let row = NSHostingView(rootView: UsageSummaryView(tokensText: "70", updated: "now", history: days))
        let rowWindow = window(row, size: NSSize(width: 288, height: 44))
        let chartState = ChartPanelState()
        chartState.days = days
        let chartWindow = UsageChartPanel(frame: NSRect(origin: NSPoint(x: -2400, y: -2000), size: UsageChartPanel.size),
                                          state: chartState) { _ in }
        assert(chartWindow.contentView is NSHostingView<ChartPanelView>)
        let chart = chartWindow.contentView!
        chartWindow.orderFront(nil)

        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let payload = try SettingsPayload.load(script: root.appendingPathComponent("codex_usage.py"), defaults: true)
        let settings = AppSettings(file: root.appendingPathComponent(".build/unused-settings-stamp"), load: { payload })
        let store = UsageStore(settings: settings)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        store.model = try decoder.decode(UIModel.self, from: Data(contentsOf: root.appendingPathComponent(".build/scroll-fixture.json")))
        store.opencode = Preview.sampleOpenCode
        let popoverView = NSHostingView(rootView: PopoverView(store: store, openID: UUID(), animateBar: false))
        let popoverWindow = window(popoverView, size: NSSize(width: 320, height: 720))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            popoverView.layoutSubtreeIfNeeded()
            let scrollers = scrollViews(in: popoverView)
            assert(scrollers.contains { ($0.documentView?.frame.height ?? 0) > $0.contentSize.height })
            assert(popoverView.fittingSize.height <= 740)
            assert(popoverView.fittingSize.height > 400)
            if let bitmap = popoverView.bitmapImageRepForCachingDisplay(in: popoverView.bounds) {
                popoverView.cacheDisplay(in: popoverView.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(".build/popover-scroll.png"))
            }
            row.layoutSubtreeIfNeeded()
            chart.layoutSubtreeIfNeeded()
            let rows = trackingViews(in: row).filter { $0.debugTag == "row" }
            let columns = trackingViews(in: chart).filter { $0.debugTag == "day" }
            let panels = trackingViews(in: chart).filter { $0.debugTag == "panel" }
            assert(rows.count == 1 && columns.count == 7 && panels.count == 1)
            assert(!rowWindow.isKeyWindow && !chartWindow.isKeyWindow)
            for view in rows + columns + panels {
                assert(view.bounds.width > 0 && view.bounds.height > 0)
                view.updateTrackingAreas()
                view.updateTrackingAreas()
                assert(view.trackingAreas.count == 1)
                let options = view.trackingAreas[0].options
                assert(options.contains(.activeAlways) && options.contains(.mouseMoved))
                var events: [Bool] = []
                view.onHover = { inside, _ in events.append(inside) }
                let local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                let point = view.window!.convertPoint(toScreen: view.convert(local, to: nil))
                view.updateHover(atScreenPoint: point)
                view.updateHover(atScreenPoint: point)
                assert(events == [true])
                view.updateHover(atScreenPoint: point, repeatInside: true)
                assert(events == [true, true])
                view.updateHover(atScreenPoint: NSPoint(x: 10000, y: 10000))
                assert(events == [true, true, false])
            }
            let tracker = rows[0]
            var exits: [Bool] = []
            tracker.onHover = { inside, _ in exits.append(inside) }
            let point = rowWindow.convertPoint(toScreen: tracker.convert(NSPoint(x: 5, y: 5), to: nil))
            tracker.updateHover(atScreenPoint: point)
            rowWindow.contentView = NSView()
            assert(exits == [true, false])
            rowWindow.orderOut(nil)
            chartWindow.orderOut(nil)
            popoverWindow.orderOut(nil)
            print("Hover and scroll checks passed: long errors, bounded height, inactive row, panel, refresh and late exits.")
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor static func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor static func trackingViews(in view: NSView) -> [HoverTrackingView] {
        let own = (view as? HoverTrackingView).map { [$0] } ?? []
        return own + view.subviews.flatMap { trackingViews(in: $0) }
    }

    @MainActor static func window(_ content: NSView, size: NSSize) -> NSWindow {
        content.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        return window
    }
}
