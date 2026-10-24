import AppKit
import SwiftUI
import OSLog

// MARK: - Model returned by codex_usage.py --ui-json

struct UIModel: Codable, Equatable {
    struct Headline: Codable, Equatable {
        var label: String
        var mode: String
        var amount: Double
        var used: Double
        var remaining: Double
    }

    struct Window: Codable, Equatable, Identifiable {
        var key: String
        var label: String
        var available: Bool
        var used: Double?
        var remaining: Double?
        var amount: Double?
        var status: String?
        var reason: String?
        var resetText: String?
        var resetAt: String?
        var id: String { key }
    }

    struct Tokens: Codable, Equatable {
        var text: String
        var raw: Int?
        var label: String?
    }

    struct Day: Codable, Equatable, Identifiable {
        var date: String
        var tokens: Int
        var inputTokens: Int?
        var outputTokens: Int?
        var text: String
        var available: Bool?
        var id: String { date }
    }

    struct Icon: Codable, Equatable {
        var labelSize: Double?
        var valueSize: Double?
        var weight: String?
        var width: Double?
        var valueOffset: Double?
    }

    var tooltip: String
    var iconValue: String
    var stale: Bool
    var displayedKey: String?
    var headline: Headline?
    var windows: [Window]
    var lowQuota: [String]
    var tokens: Tokens?
    var history: [Day]
    var tokensSource: String?
    var tokensNote: String?
    var tokensLabel: String?
    var updated: String
    var error: String?
    var authRequired: Bool?
    var source: String
    var mode: String
    var showCodex: Bool
    var showOpenCode: Bool
    var icon: Icon?
}

struct OpenCodeModel: Codable, Equatable {
    struct Meter: Codable, Equatable, Identifiable {
        var key: String
        var label: String
        var used: Double
        var remaining: Double
        var amount: Double
        var limited: Bool
        var resetsAt: Double?
        var resetText: String?
        var resetClock: String?
        var id: String { key }
    }

    struct Budget: Codable, Equatable, Identifiable {
        var label: String
        var limit: Double
        var spent: Double
        var remaining: Double
        var percent: Double
        var resetsAt: Double?
        var resetText: String?
        var id: String { label }
    }

    struct Tokens: Codable, Equatable {
        var input: Int
        var output: Int
        var reasoning: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    struct Activity: Codable, Equatable, Identifiable {
        var date: String
        var steps: Int
        var level: Int
        var id: String { date }
    }

    struct Stats: Codable, Equatable {
        var tokens: Tokens
        var total: Int
        var totalText: String
        var inputText: String
        var outputText: String
        var cost: Double?
        var sessions: Int
        var activeDays: Int
        var streak: Int
        var activity: [Activity]
        var todayText: String?
        var history: [UIModel.Day]?
        var error: String?
    }

    var available: Bool
    var reason: String?
    var days: Int?
    var display: String?
    var workspace: String?
    var usageUrl: String?
    var goMeters: [Meter]?
    var menuBarMeters: [Meter]?
    var budgets: [Budget]?
    var showGo: Bool?
    var limitsStatus: String?
    var stats: Stats?
    var updated: Double?
    var error: String?
}

// MARK: - Data loading

/// The settings the menu bar app needs, read from the shared settings file.
///
/// The card visibility and the refresh interval must not depend on a query
/// succeeding, so they come from disk rather than from a payload.
@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var showCodex = true
    @Published private(set) var showOpenCode = true
    @Published private(set) var refreshMinutes = 5
    @Published private(set) var menuBarItems: [MenuBarMetric] = [.codex]
    @Published private(set) var opencodeCLIPath = ""

    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexUsage/settings.json")

    init() {
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let value = object["show_codex"] as? Bool { showCodex = value }
        if let value = object["show_opencode"] as? Bool { showOpenCode = value }
        if let value = object["refresh_minutes"] as? Int, value > 0 { refreshMinutes = value }
        if let path = object["opencode_cli"] as? String { opencodeCLIPath = path }
        if let items = object["menu_bar_items"] as? [String] {
            let metrics = items.compactMap(MenuBarMetric.init(rawValue:))
            if !metrics.isEmpty { menuBarItems = metrics }
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var model: UIModel?
    @Published var opencode: OpenCodeModel?
    @Published var refreshing = false
    @Published var opencodeRefreshing = false
    @Published var message: String?
    @Published var opencodeMessage: String?
    var onModel: ((UIModel?) -> Void)?

    private var loading = false
    private var loadingOpenCode = false
    private let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexUsage/codex_usage.py")
    let settings = AppSettings()


    func refresh() {
        onModel?(model)
        refreshCodex()
        refreshOpenCode()
    }

    func refreshCodex() {
        guard !loading else { return }
        loading = true
        refreshing = true
        let script = self.script
        DispatchQueue.global(qos: .utility).async {
            let (model, error) = Self.loadCodex(script: script)
            DispatchQueue.main.async {
                self.loading = false
                self.refreshing = false
                if let model {
                    self.model = model
                    self.message = nil
                    self.onModel?(model)
                } else {
                    self.message = error
                    self.onModel?(self.model)
                }
            }
        }
    }

    func refreshOpenCode() {
        guard !loadingOpenCode else { return }
        loadingOpenCode = true
        opencodeRefreshing = true
        let script = self.script
        DispatchQueue.global(qos: .utility).async {
            let (model, error) = Self.loadOpenCode(script: script)
            DispatchQueue.main.async {
                self.loadingOpenCode = false
                self.opencodeRefreshing = false
                if let model {
                    self.opencode = model
                    self.opencodeMessage = nil
                } else {
                    self.opencodeMessage = error
                }
                self.onModel?(self.model)
            }
        }
    }

    private nonisolated static func loadOpenCode(script: URL) -> (OpenCodeModel?, String?) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--opencode-json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (nil, "无法启动 OpenCode 查询")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let model = try? decoder.decode(OpenCodeModel.self, from: data) {
            return (model, nil)
        }
        return (nil, "OpenCode 查询失败")
    }

    private nonisolated static func loadCodex(script: URL) -> (UIModel?, String?) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--ui-json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (nil, "无法启动额度查询")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !data.isEmpty else {
            return (nil, "额度查询失败，请稍后重试")
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return (try decoder.decode(UIModel.self, from: data), nil)
        } catch {
            return (nil, "无法解析额度数据")
        }
    }
}

// MARK: - Menu bar icon

@MainActor
enum StatusIcon {
    static func values(metrics: [MenuBarMetric], codex: UIModel?, openCode: OpenCodeModel?,
                       now: Double = Date().timeIntervalSince1970) -> [MenuBarValue] {
        metrics.map { metric in
            let used: Double?
            let stale: Bool
            switch metric {
            case .codex:
                used = codex?.headline?.used
                stale = codex?.stale ?? false
            case .codexPrimary, .codexSecondary:
                let key = metric == .codexPrimary ? "primary" : "secondary"
                used = codex?.windows.first { $0.key == key && $0.available }?.used
                stale = codex?.stale ?? false
            case .openCodeRolling, .openCodeWeekly, .openCodeMonthly:
                let key = metric == .openCodeRolling ? "rolling" : metric == .openCodeWeekly ? "weekly" : "monthly"
                used = (openCode?.menuBarMeters ?? openCode?.goMeters)?.first { $0.key == key }?.used
                stale = openCode?.updated.map { now - $0 > 900 } ?? false
            }
            var reading = metric.reading(used: used, stale: stale)
            if metric == .codex, let headline = codex?.headline {
                reading.tooltip = "Codex · \(headline.label)：剩余 \(reading.value)"
                    + (stale ? "（记录已过时）" : "")
            }
            return reading
        }
    }

    static func make(values: [MenuBarValue], icon: UIModel.Icon?) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: CGFloat(icon?.labelSize ?? 7), weight: .light)
        let weight: NSFont.Weight = icon?.weight == "semibold" ? .semibold : icon?.weight == "medium" ? .medium : .regular
        let valueFont = NSFont.systemFont(ofSize: CGFloat(icon?.valueSize ?? 12), weight: weight)
        let labelAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black, .font: labelFont]
        let valueAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black, .font: valueFont]
        // Measure with the stale marker in place so the item does not resize.
        let labels = values.map { $0.label + " ·" }
        let drawn = values.map { $0.stale ? $0.label + " ·" : $0.label }
        let widths = zip(labels, values).map { label, value in
            max(CGFloat(icon?.width ?? 30), ceil(max((label as NSString).size(withAttributes: labelAttributes).width,
                                                    (value.value as NSString).size(withAttributes: valueAttributes).width)) + 2)
        }
        let gap: CGFloat = 8
        let width = widths.reduce(0, +) + CGFloat(max(0, values.count - 1)) * gap
        let image = NSImage(size: NSSize(width: max(1, width), height: 22))
        image.lockFocus()
        var x: CGFloat = 0
        for index in values.indices {
            let label = drawn[index]
            let value = values[index].value
            let textWidth = max((label as NSString).size(withAttributes: labelAttributes).width,
                                (value as NSString).size(withAttributes: valueAttributes).width)
            let left = x + max(0, (widths[index] - textWidth) / 2)
            (label as NSString).draw(at: NSPoint(x: left, y: 12), withAttributes: labelAttributes)
            (value as NSString).draw(at: NSPoint(x: left, y: CGFloat(icon?.valueOffset ?? 0)), withAttributes: valueAttributes)
            x += widths[index] + gap
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private var refreshTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var chartPanel: NSPanel?
    private var chartPanelState = ChartPanelState()
    private var hideWorkItem: DispatchWorkItem?
    private var panelGeneration = 0
    private var hoverPresence = ChartHoverPresence()
    private var chartPanelAnchorID: String?
    private var chartPanelHiding = false
    private var chartPanelSlide: CGFloat = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--show-popover") ? .regular : .accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.image = StatusIcon.make(values: [MenuBarMetric.codex.reading(used: nil)], icon: nil)
            button.toolTip = "Codex 额度"
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.onModel = { [weak self] model in self?.apply(model) }
        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.codexusage.settingsChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.store.settings.reload()
                self?.store.refresh()
            }
        }
        store.refresh()
        if CommandLine.arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.togglePopover() }
        }
        if CommandLine.arguments.contains("--preview") {
            Preview.captureWhenReady(store: store, attempts: 40)
        }
        if CommandLine.arguments.contains("--preview-chart") {
            Preview.captureChartWhenReady(store: store, attempts: 40)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
        }
    }

    private func apply(_ model: UIModel?) {
        let values = StatusIcon.values(metrics: store.settings.menuBarItems, codex: model, openCode: store.opencode)
        statusItem.button?.image = StatusIcon.make(values: values, icon: model?.icon)
        statusItem.button?.toolTip = values.map(\.tooltip).joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(values.map(\.label).joined(separator: "、"))
        statusItem.button?.setAccessibilityValue(values.map(\.value).joined(separator: "、"))
        schedule(minutes: store.settings.refreshMinutes)
    }

    private func schedule(minutes: Int) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, minutes) * 60),
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = NSHostingController(rootView: PopoverView(
            store: store,
            openID: UUID(),
            onHoverChange: { [weak self] rowID, hovering, days, anchor in
                self?.chartHoverChanged(rowID: rowID, hovering: hovering, days: days, anchor: anchor)
            }
        ))
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = controller
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        store.refresh()
    }

    private func chartHoverChanged(rowID: String, hovering: Bool, days: [UIModel.Day], anchor: NSRect) {
        hoverLog("row hover=\(hovering) days=\(days.count)")
        if hovering && days.count > 1 {
            hoverPresence.rowID = rowID
            cancelHide()
            showChartPanel(rowID: rowID, days: days, anchor: anchor)
        } else if hoverPresence.rowID == rowID {
            hoverPresence.leaveRow(rowID)
            scheduleHide()
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        hoverPresence.panel = hovering
        if hovering { cancelHide() } else { scheduleHide() }
    }

    private func scheduleHide() {
        cancelHide()
        guard hoverPresence.shouldHide else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hoverPresence.shouldHide else { return }
            self.hideChartPanel()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func showChartPanel(rowID: String, days: [UIModel.Day], anchor: NSRect) {
        hoverLog("showChartPanel days=\(days.count) panel=\(chartPanel != nil)")
        guard days.count > 1,
              let popoverWindow = popover.contentViewController?.view.window else { return }
        let size = UsageChartPanel.size
        let visible = (popoverWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = chartPanelFrame(size: size, anchor: anchor,
                               popover: popoverWindow.frame, visible: visible)

        let panel: NSPanel
        if let existing = chartPanel {
            panel = existing
        } else {
            panel = UsageChartPanel(frame: frame, state: chartPanelState) { [weak self] hovering in
                self?.panelHoverChanged(hovering)
            }
            chartPanel = panel
        }
        if chartPanelState.days != days { chartPanelState.days = days }
        let hidden = !panel.isVisible
        let switchedRow = chartPanelAnchorID != rowID
        // Repeated enters/data updates must not cancel an in-flight entrance.
        guard hidden || switchedRow || chartPanelHiding else { return }
        chartPanelHiding = false
        chartPanelAnchorID = rowID
        chartPanelSlide = frame.midX < popoverWindow.frame.midX ? -12 : 12
        panel.appearance = popoverWindow.effectiveAppearance
        if hidden || switchedRow { chartPanelState.presentationID = UUID() }
        panelGeneration += 1
        if hidden {
            panel.setFrame(frame.offsetBy(dx: chartPanelSlide, dy: 0), display: false)
            panel.alphaValue = 0
            panel.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hideChartPanel() {
        hideWorkItem = nil
        guard let panel = chartPanel, panel.isVisible else { return }
        chartPanelHiding = true
        let target = panel.frame.offsetBy(dx: chartPanelSlide, dy: 0)
        panelGeneration += 1
        let generation = panelGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panelGeneration == generation else { return }
                panel.orderOut(nil)
                self.chartPanelHiding = false
                panel.alphaValue = 1
            }
        }
    }

    private func hideChartPanelImmediately() {
        cancelHide()
        hoverPresence = ChartHoverPresence()
        chartPanelHiding = false
        chartPanelAnchorID = nil
        panelGeneration += 1
        chartPanel?.orderOut(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(item("立即查询额度", #selector(refreshNow), "r"))
        menu.addItem(item("打开用量页面", #selector(openUsage), ""))
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refreshNow() { store.refresh() }

    @objc private func openUsage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Codex Usage Settings.app"))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        hideChartPanelImmediately()
    }
}

// MARK: - Popover content

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
    }
}

@MainActor
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let openID: UUID
    var animateBar = true
    var onHoverChange: ((String, Bool, [UIModel.Day], NSRect) -> Void)?

    var body: some View {
        let showCodex = store.settings.showCodex
        let showOpenCode = store.settings.showOpenCode
        VStack(alignment: .leading, spacing: 12) {
            if showCodex {
                header
                if let model = store.model {
                    VStack(alignment: .leading, spacing: 8) {
                        if let headline = model.headline {
                            quotaBlock(headline, window: displayedWindow(model))
                        } else {
                            Text("暂无额度数据")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let other = model.windows.first(where: { $0.key != model.displayedKey }) {
                            otherWindow(other, mode: model.mode)
                        }
                        if !model.lowQuota.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("\(model.lowQuota.joined(separator: "、"))剩余额度偏低")
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                        }
                        if model.authRequired == true {
                            LoginRow(message: "未登录 Codex",
                                     command: "codex login; echo '登录完成，可关闭此窗口'",
                                     help: "在终端中执行 codex login")
                        } else if let error = model.error ?? store.message {
                            Text(error)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Hairline()
                    summary(model)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(store.message ?? "正在查询额度…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if showOpenCode {
                if showCodex { Hairline() }
                OpenCodeCard(store: store, openID: openID, animateBar: animateBar,
                             onHoverChange: onHoverChange)
            }
            Hairline()
            footer
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(VisualEffectView().ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Codex 额度").font(.system(size: 13.5, weight: .semibold))
            Spacer()
            Button { store.refresh() } label: {
                Group {
                    if store.refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("立即查询额度")
            .disabled(store.refreshing)
        }
    }

    private func displayedWindow(_ model: UIModel) -> UIModel.Window? {
        model.windows.first(where: { $0.key == model.displayedKey })
    }

    private func quotaBlock(_ headline: UIModel.Headline, window: UIModel.Window?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(headline.mode)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("\(Int(headline.amount.rounded()))%")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            GlassProgressBar(fraction: max(0, min(1, headline.amount / 100)),
                             openID: openID, animate: animateBar)
                .frame(height: 9)
            if let reset = window?.resetText {
                Text(reset)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func otherWindow(_ window: UIModel.Window, mode: String) -> some View {
        HStack(spacing: 8) {
            Text(window.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            if window.available, let amount = window.amount {
                Text("\(mode) \(Int(amount.rounded()))%")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(window.status ?? "未提供")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .help(window.reason ?? "")
            }
        }
    }

    private func summary(_ model: UIModel) -> some View {
        UsageSummaryView(tokensText: model.tokens?.text, tokensLabel: model.tokens?.label,
                         updated: model.updated,
                         stale: model.stale, history: model.history, source: model.tokensSource) { hovering, anchor in
            onHoverChange?(openID.uuidString + "-codex", hovering, model.history, anchor)
        }
        .help("额度来源：\(model.source)。" + (model.tokensNote ?? "本机日志估算，按本机时区统计。"))
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(icon: "arrow.clockwise", title: "刷新") { store.refresh() }
            FooterButton(icon: "arrow.up.right.square", title: "用量") {
                NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
            }
            FooterButton(icon: "gearshape", title: "设置") {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Codex Usage Settings.app"))
            }
            FooterButton(icon: "power", title: "退出") { NSApp.terminate(nil) }
        }
    }
}

struct UsageSummaryView: View {
    let tokensText: String?
    var tokensLabel: String? = nil
    let updated: String
    var stale = false
    let history: [UIModel.Day]
    var source: String? = nil
    var onHover: ((Bool, NSRect) -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let tokensText {
                    Text(tokensText == "待同步"
                         ? "tokens 待同步"
                         : "\(tokensLabel ?? "今日") \(tokensText) tokens")
                        .font(.system(size: 11.5, weight: .medium))
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 8.5))
                    Text("更新于 \(updated)" + (source.map { " · " + $0 } ?? "")).font(.system(size: 10))
                    if stale {
                        Text("已过时")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if history.count > 1 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("近 7 日").font(.system(size: 9)).foregroundStyle(.secondary)
                    Sparkline(days: history)
                }
            }
        }
        .contentShape(Rectangle())
        .overlay(HoverTracking(debugTag: "row") { onHover?($0, $1) })
    }
}

// Fixed to the summary/mini-chart top edge, independent of cursor position.
func chartPanelFrame(size: NSSize, anchor: NSRect, popover: NSRect, visible: NSRect) -> NSRect {
    let gap: CGFloat = 2
    let margin: CGFloat = 8
    var y = anchor.maxY - size.height
    y = max(visible.minY + margin, min(y, visible.maxY - size.height - margin))

    let right = popover.maxX + gap
    if right + size.width <= visible.maxX - margin {
        return NSRect(x: right, y: y, width: size.width, height: size.height)
    }
    let left = popover.minX - gap - size.width
    if left >= visible.minX + margin {
        return NSRect(x: left, y: y, width: size.width, height: size.height)
    }
    // No room on either side: drop below the popover, right-aligned.
    var x = popover.maxX - size.width
    x = max(visible.minX + margin, min(x, visible.maxX - size.width - margin))
    let below = popover.minY - gap - size.height
    return NSRect(x: x, y: max(visible.minY + margin, below),
                  width: size.width, height: size.height)
}

struct ChartHoverPresence {
    var rowID: String?
    var panel = false
    var shouldHide: Bool { rowID == nil && !panel }

    mutating func leaveRow(_ id: String) {
        if rowID == id { rowID = nil }
    }
}

final class HoverTrackingView: NSView {
    var onHover: ((Bool, NSRect) -> Void)?
    var debugTag = "view"
    private var area: NSTrackingArea?
    private(set) var isInside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        refreshHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { report(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
        refreshHover()
    }

    func refreshHover(repeatInside: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.updateHover(atScreenPoint: NSEvent.mouseLocation, repeatInside: repeatInside)
        }
    }

    func updateHover(atScreenPoint point: NSPoint, repeatInside: Bool = false) {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
            report(false)
            return
        }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        report(visibleRect.contains(local), repeatInside: repeatInside)
    }

    private func report(_ inside: Bool, repeatInside: Bool = false) {
        guard inside != isInside || (inside && repeatInside) else { return }
        isInside = inside
        hoverLog("\(debugTag) hover=\(inside)")
        let frame = window.map { $0.convertToScreen(convert(bounds, to: nil)) } ?? .zero
        onHover?(inside, frame)
    }

    override func mouseEntered(with event: NSEvent) { report(true) }
    override func mouseExited(with event: NSEvent) { report(false) }
    override func mouseMoved(with event: NSEvent) {
        updateHover(atScreenPoint: NSEvent.mouseLocation)
    }
}

struct HoverTracking: NSViewRepresentable {
    var debugTag = "view"
    let onHover: (Bool, NSRect) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHover = onHover
        view.debugTag = debugTag
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onHover = onHover
        view.debugTag = debugTag
        // New usage can arrive while the pointer has stayed inside the row.
        view.refreshHover(repeatInside: true)
    }
}

final class ChartPanelState: ObservableObject {
    @Published var days: [UIModel.Day] = []
    @Published var presentationID = UUID()
}

final class UsageChartPanel: NSPanel {
    static let size = NSSize(width: 300, height: 170)
    init(frame: NSRect, state: ChartPanelState, onHover: @escaping (Bool) -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        // NSPanel already has an empty contentView; always install the chart.
        let hosting = NSHostingView(rootView: ChartPanelView(state: state, onHover: onHover))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting
    }
}

struct ChartPanelView: View {
    @ObservedObject var state: ChartPanelState
    var previewIndex: Int? = nil
    let onHover: (Bool) -> Void

    var body: some View {
        UsageChartCard(days: state.days, previewIndex: previewIndex)
            .id(state.presentationID)
            .frame(width: UsageChartPanel.size.width, height: UsageChartPanel.size.height)
            .contentShape(Rectangle())
            .overlay(HoverTracking(debugTag: "panel") { inside, _ in onHover(inside) })
    }
}

// MARK: - Interactive commands

enum TerminalCommand {
    /// Quotes a path so it can be pasted into a shell safely.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs an interactive command in Terminal, for sign-in flows that need a browser.
    static func run(_ command: String) {
        let script = "tell application \"Terminal\"\nactivate\ndo script \""
            + command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            + "\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

struct LoginRow: View {
    let message: String
    let command: String
    let help: String

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("登录") { TerminalCommand.run(command) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
                .foregroundStyle(.primary)
                .help(help)
        }
    }
}

// MARK: - OpenCode card

struct OpenCodeCard: View {
    @ObservedObject var store: UsageStore
    let openID: UUID
    var animateBar = true
    var onHoverChange: ((String, Bool, [UIModel.Day], NSRect) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let model = store.opencode, model.available {
                quota(model)
                if let stats = model.stats {
                    Hairline()
                    statsView(stats, model: model)
                }
            } else if store.opencodeRefreshing && store.opencode == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 OpenCode…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(store.opencode?.reason ?? store.opencodeMessage ?? "未检测到 OpenCode")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("安装 OpenCode 后自动显示 Go 额度与本地统计")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("OpenCode 额度").font(.system(size: 13.5, weight: .semibold))
            if store.opencode?.goMeters?.isEmpty == false {
                Text("GO")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.opencodeRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
    }

    @ViewBuilder
    private func quota(_ model: OpenCodeModel) -> some View {
        if let meters = model.goMeters, let primary = meters.first {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(primary.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.display == "remaining" ? "剩余" : "已用")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text("\(Int(primary.amount.rounded()))%")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                GlassProgressBar(fraction: max(0, min(1, primary.amount / 100)),
                                 openID: openID, animate: animateBar)
                    .frame(height: 9)
                if let reset = primary.resetText {
                    Text(reset).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(meters.dropFirst())) { meter in
                HStack(spacing: 8) {
                    Text(meter.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.display == "remaining" ? "剩余" : "已用") \(Int(meter.amount.rounded()))%")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if meters.contains(where: \.limited) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Go 额度已用尽，等待重置")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
            }
        } else if let budgets = model.budgets, let primary = budgets.first {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(primary.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.display == "remaining" ? "剩余" : "已用")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(dollars(model.display == "remaining" ? primary.remaining : primary.spent))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                GlassProgressBar(fraction: budgetFraction(primary, display: model.display),
                                 openID: openID, animate: animateBar)
                    .frame(height: 9)
                if let reset = primary.resetText {
                    Text(reset).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(budgets.dropFirst())) { budget in
                HStack(spacing: 8) {
                    Text(budget.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.display == "remaining" ? "剩余" : "已用") "
                         + dollars(model.display == "remaining" ? budget.remaining : budget.spent))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.showGo == false {
            EmptyView()
        } else if model.limitsStatus == "unsupported" {
            Text("当前 OpenCode 版本暂不支持 Go 额度接口")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if model.limitsStatus != "signed_out" {
            Text(model.error ?? "暂未获取到 OpenCode 额度，请稍后刷新")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            LoginRow(message: "未登录 OpenCode Go / Console",
                     command: loginCommand,
                     help: "在终端中执行 opencode auth login")
        }
    }

    /// The CLI to sign in with, honouring the configured path.
    private var loginCommand: String {
        let configured = store.settings.opencodeCLIPath
        let binary = configured.isEmpty ? "opencode" : TerminalCommand.quote(configured)
        return "\(binary) auth login; echo '登录完成，可关闭此窗口'"
    }

    private func statsView(_ stats: OpenCodeModel.Stats, model: OpenCodeModel) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let updated = model.updated.map { formatter.string(from: Date(timeIntervalSince1970: $0)) } ?? "—"
        let history = stats.history ?? []
        return UsageSummaryView(tokensText: stats.todayText ?? "—", updated: updated,
                                history: history, source: "本机统计") { hovering, anchor in
            onHoverChange?(openID.uuidString + "-opencode", hovering, history, anchor)
        }
        .help(stats.error ?? "近 \(model.days ?? 7) 日合计：\(stats.totalText) tokens · 趋势为近 7 日 · \(statsSubtitle(stats))")
    }

    private func statsSubtitle(_ stats: OpenCodeModel.Stats) -> String {
        var parts: [String] = []
        if let cost = stats.cost {
            parts.append(dollars(cost))
        }
        parts.append("\(stats.sessions) 会话")
        parts.append("\(stats.activeDays) 天活跃")
        parts.append("连续 \(stats.streak) 天")
        return parts.joined(separator: " · ")
    }

    private func budgetFraction(_ budget: OpenCodeModel.Budget, display: String?) -> Double {
        budget.limit > 0 ? max(0, min(1, (display == "remaining" ? budget.remaining : budget.spent) / budget.limit)) : 0
    }
}

func dollars(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

// MARK: - Glass bar

final class BarAnimator: ObservableObject {
    @Published var shown: Double

    init(shown: Double = 0) {
        self.shown = shown
    }
}

struct GlassProgressBar: View {
    let fraction: Double
    let openID: UUID
    let animate: Bool
    @StateObject private var animator: BarAnimator

    init(fraction: Double, openID: UUID, animate: Bool = true) {
        self.fraction = fraction
        self.openID = openID
        self.animate = animate
        _animator = StateObject(wrappedValue: BarAnimator(shown: animate ? 0 : fraction))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.primary.opacity(0.78), Color.primary.opacity(0.46)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, geometry.size.width * animator.shown))
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .onAppear {
            guard animate else {
                animator.shown = fraction
                return
            }
            animator.shown = 0
            withAnimation(.easeOut(duration: 0.8)) { animator.shown = fraction }
        }
        .onChange(of: fraction) { newValue in
            withAnimation(.easeOut(duration: 0.45)) { animator.shown = newValue }
        }
    }
}

final class ChartAnimator: ObservableObject {
    @Published var shown = false
}

final class DayHoverState: ObservableObject {
    @Published var index: Int?

    init(index: Int? = nil) {
        self.index = index
    }
}

struct UsageChartCard: View {
    let days: [UIModel.Day]
    @StateObject private var hover: DayHoverState
    @StateObject private var animator = ChartAnimator()

    init(days: [UIModel.Day], previewIndex: Int? = nil) {
        self.days = days
        _hover = StateObject(wrappedValue: DayHoverState(index: previewIndex))
    }

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        let total = days.reduce(0) { $0 + $1.tokens }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("近 7 日用量")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                if let index = hover.index, days.indices.contains(index) {
                    Text(days[index].date)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(days.contains(where: { $0.available == false })
                         ? "已同步 \(days.filter { $0.available != false }.count) 日 · \(compactTokens(total))"
                         : "共 \(compactTokens(total))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            if let index = hover.index, days.indices.contains(index) {
                let day = days[index]
                Text(dayDetail(day))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("悬停柱子查看当天用量")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let ratio = CGFloat(day.tokens) / CGFloat(peak)
                    let active = hover.index == index
                    let isToday = day.date == days.last?.date
                    let target = max(4, ratio * 56) + (active ? 5 : 0)
                    VStack(spacing: 4) {
                        Text(day.text)
                            .font(.system(size: 8, weight: active || isToday ? .semibold : .regular))
                            .foregroundStyle(active || isToday ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(height: 10)
                            .opacity(animator.shown ? 1 : 0)
                            .animation(.easeOut(duration: 0.18).delay(Double(index) * 0.035 + 0.12),
                                       value: animator.shown)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.primary.opacity(active ? 0.88 : isToday ? 0.72 : 0.40),
                                             Color.primary.opacity(active ? 0.42 : isToday ? 0.26 : 0.12)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                                .frame(height: animator.shown ? target : 1)
                                .animation(.interpolatingSpring(stiffness: 210, damping: 13)
                                    .delay(Double(index) * 0.035),
                                    value: animator.shown)
                                .animation(.spring(response: 0.30, dampingFraction: 0.68),
                                    value: hover.index)
                        }
                        .frame(height: 56, alignment: .bottom)
                        Text(day.date)
                            .font(.system(size: 8, weight: active || isToday ? .medium : .regular))
                            .foregroundStyle(active || isToday ? .secondary : .tertiary)
                            .frame(height: 10)
                            .opacity(animator.shown ? 1 : 0)
                            .animation(.easeOut(duration: 0.18).delay(Double(index) * 0.035 + 0.12),
                                       value: animator.shown)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.06)
                              : isToday ? Color.primary.opacity(0.03) : Color.clear))
                    .contentShape(Rectangle())
                    .overlay(HoverTracking(debugTag: "day") { inside, _ in
                        if inside {
                            if hover.index != index { hover.index = index }
                        } else if hover.index == index {
                            hover.index = nil
                        }
                    })
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hover.index)
        }
        .onAppear {
            animator.shown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                animator.shown = true
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
    }

    private func dayDetail(_ day: UIModel.Day) -> String {
        if day.available == false { return "当天用量待同步" }
        if let input = day.inputTokens, let output = day.outputTokens {
            return "输入 \(compactTokens(input)) · 输出 \(compactTokens(output)) · 总计 \(day.text)"
        }
        return "总计 \(day.text) tokens · 接口未提供输入 / 输出拆分"
    }

}

func compactTokens(_ value: Int) -> String {
    if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return "\(value)"
}

struct Sparkline: View {
    let days: [UIModel.Day]
    @StateObject private var animator = ChartAnimator()

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                let ratio = CGFloat(day.tokens) / CGFloat(peak)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(
                        colors: [Color.primary.opacity(day.date == days.last?.date ? 0.72 : 0.45),
                                 Color.primary.opacity(0.16)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 6, height: animator.shown ? max(2, ratio * 20) : 1)
                    .accessibilityLabel("\(day.date)：\(day.text) tokens")
                    .animation(.interpolatingSpring(stiffness: 240, damping: 14)
                        .delay(Double(index) * 0.03),
                        value: animator.shown)
                    .accessibilityLabel("\(day.date)：\(day.text) tokens")
            }
        }
        .frame(height: 20, alignment: .bottom)
        .onAppear {
            animator.shown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                animator.shown = true
            }
        }
    }
}

// MARK: - Shared views

final class HoverState: ObservableObject {
    @Published var hovering: Bool

    init(hovering: Bool = false) {
        self.hovering = hovering
    }
}

struct FooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @StateObject private var state = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(state.hovering ? Color.primary.opacity(0.07) : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { state.hovering = $0 }
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Offscreen preview (development only)

@MainActor
enum Preview {
    static let sampleOpenCode = OpenCodeModel(
        available: true,
        reason: nil,
        days: 7,
        display: "remaining",
        workspace: "Team",
        usageUrl: nil,
        goMeters: [
            .init(key: "rolling", label: "5 小时额度", used: 42, remaining: 58, amount: 58,
                  limited: false, resetsAt: nil, resetText: "3小时12分后重置", resetClock: nil),
            .init(key: "weekly", label: "每周额度", used: 20, remaining: 80, amount: 80,
                  limited: false, resetsAt: nil, resetText: nil, resetClock: nil),
            .init(key: "monthly", label: "每月额度", used: 8, remaining: 92, amount: 92,
                  limited: false, resetsAt: nil, resetText: nil, resetClock: nil),
        ],
        budgets: [],
        stats: .init(
            tokens: .init(input: 1_500_000, output: 250_000, reasoning: 0,
                          cacheRead: 100_000, cacheWrite: 0),
            total: 1_850_000, totalText: "1.9M", inputText: "1.5M", outputText: "250k",
            cost: 12.34, sessions: 12, activeDays: 5, streak: 3,
            activity: [
                .init(date: "10-19", steps: 12, level: 1),
                .init(date: "10-20", steps: 48, level: 4),
                .init(date: "10-21", steps: 20, level: 2),
                .init(date: "10-22", steps: 36, level: 3),
                .init(date: "10-23", steps: 8, level: 1),
                .init(date: "10-24", steps: 4, level: 0),
                .init(date: "10-25", steps: 16, level: 1),
            ],
            todayText: "120k",
            history: (0..<7).map { index in
                let tokens = [80_000, 240_000, 100_000, 180_000, 40_000, 20_000, 120_000][index]
                return UIModel.Day(date: "10-\(19 + index)", tokens: tokens,
                                   inputTokens: tokens * 4 / 5, outputTokens: tokens / 5,
                                   text: compactTokens(tokens))
            }
        ),
        updated: Date().timeIntervalSince1970,
        error: nil
    )

    static func captureWhenReady(store: UsageStore, attempts: Int) {
        guard attempts > 0 else { return }
        if store.model == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureWhenReady(store: store, attempts: attempts - 1)
            }
            return
        }
        capture(store: store)
    }

    static func captureChartWhenReady(store: UsageStore, attempts: Int) {
        guard attempts > 0 else { return }
        if store.model == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureChartWhenReady(store: store, attempts: attempts - 1)
            }
            return
        }
        captureChart(store: store)
    }

    static func captureChart(store: UsageStore) {
        guard let days = store.model?.history, days.count > 1 else {
            NSApp.terminate(nil)
            return
        }
        let state = ChartPanelState()
        state.days = days
        let hosting = NSHostingView(rootView: ChartPanelView(state: state) { _ in })
        hosting.frame = NSRect(origin: .zero, size: UsageChartPanel.size)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/codex-chart.png"))
            }
            window.orderOut(nil)
            NSApp.terminate(nil)
        }
    }

    static func capture(store: UsageStore) {
        store.opencode = sampleOpenCode
        let values = StatusIcon.values(metrics: MenuBarMetric.allQuotas, codex: store.model, openCode: sampleOpenCode)
        let icon = StatusIcon.make(values: values, icon: store.model?.icon)
        let canvas = NSImage(size: NSSize(width: icon.size.width + 32, height: 54))
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        icon.draw(at: NSPoint(x: 16, y: 16), from: .zero, operation: .sourceOver, fraction: 1)
        canvas.unlockFocus()
        if let data = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/codex-menu-bar.png"))
        }
        let hosting = NSHostingView(rootView: PopoverView(store: store, openID: UUID(), animateBar: false))
        hosting.frame = NSRect(x: 0, y: 0, width: 330, height: 540)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                NSApp.terminate(nil)
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/codex-popover.png"))
            window.orderOut(nil)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Entry point

private let hoverLogger = Logger(subsystem: "local.codexusage.menubar", category: "Hover")

func hoverLog(_ line: String) {
    hoverLogger.debug("\(line, privacy: .public)")
}

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
