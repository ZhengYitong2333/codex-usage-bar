import SwiftUI
import AppKit

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
    var menu_bar_items: [MenuBarMetric] = [.codex]
}

@MainActor final class SettingsStore: ObservableObject {
    @Published var selectedTab = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--appearance") ? "appearance" : "codex"
    @Published var draft = Preferences()
    @Published var saved = Preferences()
    @Published var busy = false
    @Published private(set) var availableWindows: Set<String> = ["primary", "secondary"]
    @Published private(set) var availabilityKnown = false
    @Published var message = ""
    @Published var failed = false
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsage")

    init() {
        let url = support.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
                let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
                let merged = defaults.merging(stored) { _, savedValue in savedValue }
                draft = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: merged))
                saved = draft
            } catch {
                message = "无法读取设置，当前显示默认值。保存后可恢复。"
                failed = true
            }
        }
        if CommandLine.arguments.contains("--preview") {
            draft.menu_bar_items = MenuBarMetric.allQuotas
            saved = draft
            return
        }
        Task { await refreshAvailability() }
    }

    func canSelect(_ window: String) -> Bool { availableWindows.contains(window) }

    func refreshAvailability() async {
        let script = support.appendingPathComponent("codex_usage.py").path
        let result: Set<String>? = await Task.detached {
            do {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [script, "--available-windows"]
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let values = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Bool]
                else { return nil }
                return Set(values.compactMap { $0.value ? $0.key : nil })
            } catch { return nil }
        }.value
        guard let result else { return }
        availabilityKnown = true
        availableWindows = result
        guard !result.isEmpty, !result.contains(draft.window) else { return }
        draft.window = result.contains("primary") ? "primary" : "secondary"
        message = "所选额度暂无数据，已切换为\(draft.window == "primary" ? "5 小时" : "每周")；请保存"
    }

    func refresh() {
        notifyMenuBar()
        message = "已请求查询最新额度；查询结果将在菜单中更新"
    }

    private func notifyMenuBar() {
        DistributedNotificationCenter.default().post(name: Notification.Name("local.codexusage.settingsChanged"),
                                                     object: nil)
    }

    func save() {
        let proposed = draft
        let script = support.appendingPathComponent("codex_usage.py").path
        busy = true
        message = "正在应用…"
        failed = false
        Task {
            let errorText: String? = await Task.detached {
                do {
                    let process = Process()
                    let input = Pipe(), output = Pipe(), errors = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [script, "--save-settings"]
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    input.fileHandleForWriting.write(try JSONEncoder().encode(proposed))
                    try input.fileHandleForWriting.close()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        return "保存失败，请检查设置目录是否可写。\n" + String(detail.suffix(240))
                    }
                    return nil
                } catch { return "保存失败：\(error.localizedDescription)" }
            }.value
            busy = false
            if let errorText {
                message = errorText
                failed = true
            } else {
                saved = proposed
                notifyMenuBar()
                message = "已应用 · 每 \(proposed.refresh_minutes) 分钟刷新"
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var store = SettingsStore()
    private var valueWeight: Font.Weight {
        store.draft.weight == "semibold" ? .semibold : store.draft.weight == "medium" ? .medium : .regular
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("用量设置").font(.title2.weight(.semibold))
                Text("Codex 与 OpenCode 的菜单栏配置").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.draft.menu_bar_items) { metric in
                            let reading = metric.reading(used: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(reading.label)
                                    .font(.system(size: CGFloat(store.draft.label_size), weight: .light))
                                Text(reading.value)
                                    .font(.system(size: CGFloat(store.draft.value_size), weight: valueWeight))
                                    .offset(y: -CGFloat(store.draft.value_offset))
                            }
                            .frame(minWidth: CGFloat(store.draft.width), minHeight: 22)
                        }
                    }
                    .foregroundStyle(.white)
                }
                .frame(height: 22)
                .padding(12)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                .help("菜单栏示例；数字为示意数据")
            }.padding(24)

            TabView(selection: $store.selectedTab) {
                codexSettings.tabItem { Label("Codex", systemImage: "terminal") }.tag("codex")
                openCodeSettings.tabItem { Label("OpenCode", systemImage: "curlybraces") }.tag("openCode")
                generalSettings.tabItem { Label("通用", systemImage: "slider.horizontal.3") }.tag("general")
                appearanceSettings.tabItem { Label("外观", systemImage: "textformat.size") }.tag("appearance")
            }
            .padding(.horizontal, 16)
            .disabled(store.busy)
            Divider()
            HStack {
                Button("恢复默认") { store.draft = Preferences(); store.message = "默认值已填入，点击保存以应用" }
                Spacer()
                Button("撤销更改") { store.draft = store.saved; store.message = "" }
                    .disabled(store.draft == store.saved)
                Button("保存并应用") { store.save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.draft == store.saved)
            }.disabled(store.busy).padding([.horizontal, .top], 20)
            Text(store.message.isEmpty ? (store.draft == store.saved ? "设置仅保存在这台 Mac 上" : "有未保存的更改") : store.message)
                .font(.caption).foregroundStyle(store.failed ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 550, height: 760)
        .onChange(of: store.draft) { _ in store.message = ""; store.failed = false }
    }

    private var codexVisible: Binding<Bool> {
        Binding(
            get: { store.draft.show_codex },
            set: { value in
                store.draft.show_codex = value
                if !value && !store.draft.show_opencode { store.draft.show_opencode = true }
            }
        )
    }

    private var openCodeVisible: Binding<Bool> {
        Binding(
            get: { store.draft.show_opencode },
            set: { value in
                store.draft.show_opencode = value
                if !value && !store.draft.show_codex { store.draft.show_codex = true }
            }
        )
    }

    private var codexSettings: some View {
        Form {
            Section {
                Toggle("显示 Codex 卡片", isOn: codexVisible)
                Text("控制弹层中的 Codex 卡片；菜单栏显示项在“外观”中单独设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Codex 卡片") }
            Section {
                Picker("当前主额度", selection: Binding(
                    get: { store.draft.window },
                    set: { selected in
                        if store.canSelect(selected) { store.draft.window = selected }
                    }
                )) {
                    Text(store.canSelect("primary") ? "5 小时额度" : "5 小时额度（暂无数据）")
                        .tag("primary").disabled(!store.canSelect("primary"))
                    Text(store.canSelect("secondary") ? "每周" : "每周（暂无数据）")
                        .tag("secondary").disabled(!store.canSelect("secondary"))
                }
                Text(store.availabilityKnown && store.availableWindows.isEmpty
                     ? "当前查询与本机记录均未提供可用额度，暂不能选择。"
                     : "下拉菜单始终同时显示 5 小时和每周额度；暂无数据的选项不可选择。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("数字含义", selection: $store.draft.display) {
                    Text("剩余百分比").tag("remaining")
                    Text("已用百分比").tag("used")
                }
                Toggle("显示今日 tokens", isOn: $store.draft.show_tokens)
                Toggle("显示重置倒计时", isOn: $store.draft.show_countdown)
            } header: { Text("用量显示") }
            Section {
                Toggle("菜单内低额度提示", isOn: $store.draft.low_quota_warning)
                if store.draft.low_quota_warning {
                    Picker("剩余不超过", selection: $store.draft.low_quota_threshold) {
                        ForEach([10, 20, 30], id: \.self) { value in Text("\(value)%").tag(value) }
                    }
                }
                Picker("额度记录过时提醒", selection: $store.draft.stale_minutes) {
                    ForEach([15, 30, 60, 120], id: \.self) { minute in Text("超过 \(minute) 分钟").tag(minute) }
                }
                Text("低额度提示检查两个窗口，仅在数据未过时时显示；过时以额度记录时间计算。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("提醒") }
        }.formStyle(.grouped)
    }

    private var openCodeSettings: some View {
        Form {
            Section {
                Toggle("显示 OpenCode 卡片", isOn: openCodeVisible)
                Picker("数字含义", selection: $store.draft.opencode_display) {
                    Text("剩余百分比").tag("remaining")
                    Text("已用百分比").tag("used")
                }
                Picker("详情统计范围", selection: $store.draft.opencode_days) {
                    Text("近 7 日").tag(7)
                    Text("近 30 日").tag(30)
                }
                Text("OpenCode 需要安装 opencode CLI；至少保留一张卡片。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("OpenCode 卡片") }
            Section {
                Toggle("显示 Go 额度", isOn: $store.draft.opencode_show_go)
                Toggle("滚动额度", isOn: $store.draft.opencode_show_rolling)
                    .disabled(!store.draft.opencode_show_go)
                Toggle("每周额度", isOn: $store.draft.opencode_show_weekly)
                    .disabled(!store.draft.opencode_show_go)
                Toggle("每月额度", isOn: $store.draft.opencode_show_monthly)
                    .disabled(!store.draft.opencode_show_go)
                Text("Go 额度从 OpenCode 本地服务读取，需要 OpenCode 已登录。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Go 额度") }
            Section {
                Toggle("显示本地统计", isOn: $store.draft.opencode_show_stats)
                Toggle("详情中显示费用", isOn: $store.draft.opencode_show_cost)
                    .disabled(!store.draft.opencode_show_stats)
                Text("显示今日本机 tokens 和近 7 日趋势；悬停可查看每日输入、输出，说明中保留费用和会话统计。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("本地统计") }
            Section {
                TextField("CLI 路径", text: $store.draft.opencode_cli, prompt: Text("留空自动探测"))
                Text("自动查找 PATH、nvm、Homebrew 等位置的 opencode。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("OpenCode CLI") }
        }.formStyle(.grouped)
    }

    private func menuBarSelection(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { store.draft.menu_bar_items.contains(metric) },
            set: { enabled in
                store.draft.menu_bar_items = MenuBarMetric.selection(store.draft.menu_bar_items,
                                                                     metric: metric, enabled: enabled)
            }
        )
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker("刷新间隔", selection: $store.draft.refresh_minutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minute in
                        Text("每 \(minute) 分钟" + (minute == 5 ? "（默认）" : "")).tag(minute)
                    }
                }
                Text("同时刷新 Codex 与 OpenCode；查询失败时只影响对应卡片。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("立即查询额度") { store.refresh() }
                    Spacer()
                    Link("打开 Codex 官方用量页面", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                }
            } header: { Text("刷新") }
        }.formStyle(.grouped)
    }

    private var appearanceSettings: some View {
        Form {
            Section {
                HStack {
                    Button("全部显示") { store.draft.menu_bar_items = MenuBarMetric.allQuotas }
                    Button("仅 Codex 主额度") { store.draft.menu_bar_items = [.codex] }
                }
                ForEach(MenuBarMetric.allCases) { metric in
                    Toggle(metric.label, isOn: menuBarSelection(metric))
                        .disabled(store.draft.menu_bar_items == [metric])
                }
                Text("可同时勾选 Codex 和 OpenCode，至少保留一项；全部显示时并排展示 5 项剩余额度。暂无数据显示 —，选择与卡片开关独立。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("菜单栏显示内容") }
                Section {
                    Stepper("标签字号：\(store.draft.label_size) pt", value: $store.draft.label_size, in: 6...10)
                    Stepper("数字字号：\(store.draft.value_size) pt", value: $store.draft.value_size, in: 10...15)
                    Picker("数字字重", selection: $store.draft.weight) {
                        Text("常规 Regular").tag("regular")
                        Text("中等 Medium").tag("medium")
                        Text("半粗 Semibold").tag("semibold")
                    }
                    Stepper("组件宽度：\(store.draft.width) pt", value: $store.draft.width, in: 30...44)
                    Stepper("数字向上偏移：\(store.draft.value_offset) pt", value: $store.draft.value_offset, in: -2...2)
                } header: { Text("菜单栏外观") }
        }.formStyle(.grouped)
    }
}

@main struct CodexUsageSettingsApp: App {
    var body: some Scene {
        Window("Codex 用量设置", id: "settings") {
            SettingsView().onAppear {
                NSApp.activate(ignoringOtherApps: true)
                if CommandLine.arguments.contains("--preview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if let view = NSApp.keyWindow?.contentView,
                           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            let image = NSImage(size: view.bounds.size)
                            image.lockFocus()
                            NSColor.windowBackgroundColor.setFill()
                            NSRect(origin: .zero, size: image.size).fill()
                            rep.draw(in: NSRect(origin: .zero, size: image.size))
                            image.unlockFocus()
                            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                                try? bitmap.representation(using: .png, properties: [:])?
                                    .write(to: URL(fileURLWithPath: "/tmp/codex-settings.png"))
                            }
                        }
                        NSApp.terminate(nil)
                    }
                }
            }
        }.windowResizability(.contentSize)
    }
}
