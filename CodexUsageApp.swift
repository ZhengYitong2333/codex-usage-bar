import AppKit
import SwiftUI

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
        var raw: Int
    }

    struct Day: Codable, Equatable, Identifiable {
        var date: String
        var tokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var text: String
        var id: String { date }
    }

    struct Icon: Codable, Equatable {
        var labelSize: Double?
        var valueSize: Double?
        var weight: String?
        var width: Double?
        var valueOffset: Double?
    }

    var title: String
    var tooltip: String
    var iconValue: String
    var stale: Bool
    var displayedKey: String?
    var headline: Headline?
    var windows: [Window]
    var lowQuota: [String]
    var tokens: Tokens?
    var history: [Day]
    var details: [String]
    var updated: String
    var error: String?
    var source: String
    var refreshMinutes: Int
    var queryEnabled: Bool
    var mode: String
    var showCodex: Bool
    var showOpenCode: Bool
    var icon: Icon?
}

// MARK: - Data loading

@MainActor
final class UsageStore: ObservableObject {
    @Published var model: UIModel?
    @Published var refreshing = false
    @Published var message: String?
    var onModel: ((UIModel?) -> Void)?

    private var loading = false
    private var loadingOpenCode = false
    private let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexUsage/codex_usage.py")

    func refresh() {
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
    static func make(value: String, stale: Bool, icon: UIModel.Icon?) -> NSImage {
        let label = stale ? "Codex ·" : "Codex"
        let labelFont = NSFont.systemFont(ofSize: CGFloat(icon?.labelSize ?? 7), weight: .light)
        let weight: NSFont.Weight = icon?.weight == "semibold" ? .semibold : icon?.weight == "medium" ? .medium : .regular
        let valueFont = NSFont.systemFont(ofSize: CGFloat(icon?.valueSize ?? 12), weight: weight)
        let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
        let labelAttributes = base.merging([.font: labelFont]) { $1 }
        let valueAttributes = base.merging([.font: valueFont]) { $1 }
        let labelWidth = (label as NSString).size(withAttributes: labelAttributes).width
        let valueWidth = (value as NSString).size(withAttributes: valueAttributes).width
        let contentWidth = ceil(max(labelWidth, valueWidth)) + 2
        let width = max(contentWidth, CGFloat(icon?.width ?? 30))
        let image = NSImage(size: NSSize(width: width, height: 22))
        image.lockFocus()
        let left = max(0, (width - max(labelWidth, valueWidth)) / 2)
        (label as NSString).draw(at: NSPoint(x: left, y: 12), withAttributes: labelAttributes)
        (value as NSString).draw(at: NSPoint(x: left, y: CGFloat(icon?.valueOffset ?? 0)),
                                 withAttributes: valueAttributes)
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
    private var hideWorkItem: DispatchWorkItem?
    private var panelGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.image = StatusIcon.make(value: "—", stale: false, icon: nil)
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
            Task { @MainActor in self?.store.refresh() }
        }
        store.refresh()
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
        statusItem.button?.image = StatusIcon.make(
            value: model?.iconValue ?? "—",
            stale: model?.stale ?? false,
            icon: model?.icon
        )
        statusItem.button?.toolTip = model?.tooltip ?? "Codex 额度"
        schedule(minutes: model?.refreshMinutes ?? 5)
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
            onHoverChange: { [weak self] hovering in self?.chartHoverChanged(hovering) }
        ))
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = controller
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        store.refresh()
    }

    private func chartHoverChanged(_ hovering: Bool) {
        if hovering {
            cancelHide()
            showChartPanel()
        } else {
            scheduleHide()
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        if hovering {
            cancelHide()
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        cancelHide()
        let item = DispatchWorkItem { [weak self] in self?.hideChartPanel() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: item)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func showChartPanel() {
        guard let days = store.model?.history, days.count > 1,
              let popoverWindow = popover.contentViewController?.view.window else { return }
        let size = NSSize(width: 320, height: 190)
        let visible = (popoverWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(popoverWindow.frame.maxX - 18, visible.maxX - size.width)
        let panelTop = popoverWindow.frame.maxY - 160
        var y = panelTop - size.height
        y = max(y, visible.minY + 8)
        let finalFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        let panel: NSPanel
        if let existing = chartPanel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: finalFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            chartPanel = panel
        }
        if panel.isVisible {
            panelGeneration += 1
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            return
        }
        panelGeneration += 1
        let hosting = NSHostingView(rootView: ChartPanelView(days: days) { [weak self] hovering in
            self?.panelHoverChanged(hovering)
        })
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let startFrame = NSRect(origin: NSPoint(x: finalFrame.origin.x + 24, y: finalFrame.origin.y),
                                size: size)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hideChartPanel() {
        hideWorkItem = nil
        guard let panel = chartPanel, panel.isVisible else { return }
        let frame = panel.frame
        let target = NSRect(origin: NSPoint(x: frame.origin.x + 20, y: frame.origin.y),
                            size: frame.size)
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
                panel.alphaValue = 1
            }
        }
    }

    private func hideChartPanelImmediately() {
        cancelHide()
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
    var onHoverChange: ((Bool) -> Void)?

    var body: some View {
        let showCodex = store.model?.showCodex ?? true
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
                        if let error = model.error ?? store.message {
                            Text(error)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    hairline
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
            hairline
            footer
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(VisualEffectView().ignoresSafeArea())
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
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
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func summary(_ model: UIModel) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let tokens = model.tokens {
                    Text("今日 \(tokens.text) tokens")
                        .font(.system(size: 11.5, weight: .medium))
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 8.5))
                    Text("更新于 \(model.updated)").font(.system(size: 10))
                    if model.stale {
                        Text("已过时")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if model.history.count > 1 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("近 7 日").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Sparkline(days: model.history)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { onHoverChange?($0) }
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

struct ChartPanelView: View {
    let days: [UIModel.Day]
    var previewIndex: Int? = nil
    let onHover: (Bool) -> Void

    var body: some View {
        UsageChartCard(days: days, previewIndex: previewIndex)
            .padding(10)
            .frame(width: 320, height: 190)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
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
        .onChange(of: openID) { _ in
            guard animate else { return }
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
                    Text("共 \(compactTokens(total))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            if let index = hover.index, days.indices.contains(index) {
                let day = days[index]
                Text("输入 \(compactTokens(day.inputTokens)) · 输出 \(compactTokens(day.outputTokens)) · 总计 \(day.text)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("悬停柱子查看当天输入 / 输出")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
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
                    .onHover { inside in
                        if inside {
                            hover.index = index
                        } else if hover.index == index {
                            hover.index = nil
                        }
                    }
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.07)))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
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
        let hosting = NSHostingView(rootView: ChartPanelView(days: days) { _ in })
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
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

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
