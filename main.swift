import AppKit
import Foundation

struct ThreadUsage {
    let id: String
    let title: String
    let tokens: Int
    let model: String
    let updatedAtMs: Int64
}

struct UsageSnapshot {
    let current: ThreadUsage?
    let recent: [ThreadUsage]
    let totalRecentTokens: Int
    let checkedAt: Date
    let error: String?
}

struct AccountUsage {
    let shortWindow: AccountUsageWindow?
    let totalWindow: AccountUsageWindow?
    let resetCredits: ResetCredits?
    let planType: String?
    let lastSuccessAt: Date

    var windows: [AccountUsageWindow] { [shortWindow, totalWindow].compactMap { $0 } }
    var planLabel: String {
        switch planType?.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        default: return planType?.capitalized ?? "Codex"
        }
    }
}

struct ResetCredits {
    let availableCount: Int
    let expirations: [Date]
}

struct AccountUsageWindow {
    let remainingPercent: Int
    let usedPercent: Int
    let windowLabel: String
    let resetsAt: Date?
    let durationMinutes: Double?
}

struct AppSnapshot {
    let accountUsage: AccountUsage?
    let threadUsage: UsageSnapshot
    let checkedAt: Date
    let nextRefreshAt: Date
    let accountError: String?
}

private enum UsageColors {
    static let good = NSColor(calibratedRed: 83 / 255, green: 145 / 255, blue: 105 / 255, alpha: 1)
    static let warning = NSColor(calibratedRed: 205 / 255, green: 151 / 255, blue: 67 / 255, alpha: 1)
    static let low = NSColor(calibratedRed: 184 / 255, green: 83 / 255, blue: 83 / 255, alpha: 1)
    static let empty = NSColor(calibratedRed: 246 / 255, green: 246 / 255, blue: 243 / 255, alpha: 1)
    static let unknown = NSColor(calibratedRed: 116 / 255, green: 121 / 255, blue: 128 / 255, alpha: 1)
    static let details = NSColor(calibratedRed: 250 / 255, green: 250 / 255, blue: 248 / 255, alpha: 1)
    static let detailText = NSColor(calibratedRed: 92 / 255, green: 95 / 255, blue: 99 / 255, alpha: 1)
    static let quotaBlue = NSColor(calibratedRed: 20 / 255, green: 128 / 255, blue: 245 / 255, alpha: 1)
    static let quotaAmber = NSColor(calibratedRed: 245 / 255, green: 156 / 255, blue: 33 / 255, alpha: 1)
    static let quotaCoral = NSColor(calibratedRed: 245 / 255, green: 74 / 255, blue: 64 / 255, alpha: 1)

    static func color(for remaining: Int?) -> NSColor {
        guard let remaining else { return unknown }
        if remaining <= 0 { return empty }
        if remaining <= 10 { return quotaCoral }
        if remaining <= 50 { return quotaAmber }
        return quotaBlue
    }

    static func textColor(on background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.deviceRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.62 ? NSColor(calibratedWhite: 0.16, alpha: 1) : .white
    }
}

private enum MenuBarQuotaGlyph {
    static func image(short: Int?, total: Int?) -> NSImage {
        let remaining = [short, total].compactMap { $0 }.min()
        return NSImage(size: NSSize(width: 16, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 8, y: 9)
            let track = NSBezierPath(ovalIn: NSRect(x: 2, y: 3, width: 12, height: 12))
            track.lineWidth = 1.6
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()
            if let remaining, remaining > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: 6, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(remaining) / 100, clockwise: true)
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                UsageColors.color(for: remaining).setStroke()
                arc.stroke()
            }
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.5, y: 7.5, width: 3, height: 3)).fill()
            return true
        }
    }
}

final class AccountUsageReader: NSObject, URLSessionWebSocketDelegate {
    private let codexPath: String = {
        let candidates = [ProcessInfo.processInfo.environment["CODEX_BINARY"],
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }()
    private let url = URL(string: "ws://127.0.0.1:47891")!
    private var serverProcess: Process?
    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex")
        .appendingPathComponent("codex-usage-bar-cache.json")

    func read() -> (AccountUsage?, String?) {
        if let usage = readFromServer() {
            saveCache(usage)
            return (usage, nil)
        }

        startServerIfNeeded()
        Thread.sleep(forTimeInterval: 1.0)

        if let usage = readFromServer() {
            saveCache(usage)
            return (usage, nil)
        }

        if let cached = loadCache() {
            return (cached, "使用上次成功缓存")
        }

        return (nil, "无法读取 account/rateLimits/read")
    }

    private func startServerIfNeeded() {
        guard serverProcess?.isRunning != true else { return }
        guard FileManager.default.fileExists(atPath: codexPath) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = [
            "-c", "features.code_mode_host=true",
            "app-server",
            "--analytics-default-enabled",
            "--listen", "ws://127.0.0.1:47891"
        ]

        let logURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("codex-usage-bar-appserver.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
            serverProcess = process
        } catch {
            serverProcess = nil
        }
    }

    private func readFromServer() -> AccountUsage? {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        let semaphore = DispatchSemaphore(value: 0)
        var result: AccountUsage?

        task.resume()

        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "CodexUsageBar", "title": NSNull(), "version": "0.2.0"],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false,
                        "optOutNotificationMethods": []
                    ]
                ]
            ],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read", "params": NSNull()]
        ]

        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let text = String(data: data, encoding: .utf8) else {
                task.cancel(with: .invalid, reason: nil)
                return nil
            }
            task.send(.string(text)) { _ in }
        }

        receive(task: task, attemptsRemaining: 8) { usage in
            result = usage
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        return result
    }

    private func receive(task: URLSessionWebSocketTask, attemptsRemaining: Int, completion: @escaping (AccountUsage?) -> Void) {
        guard attemptsRemaining > 0 else {
            completion(nil)
            return
        }

        task.receive { [weak self] message in
            guard let self else {
                completion(nil)
                return
            }

            switch message {
            case .success(.string(let text)):
                if let usage = self.parseUsageResponse(text) {
                    completion(usage)
                } else {
                    self.receive(task: task, attemptsRemaining: attemptsRemaining - 1, completion: completion)
                }
            case .success:
                self.receive(task: task, attemptsRemaining: attemptsRemaining - 1, completion: completion)
            case .failure:
                completion(nil)
            }
        }
    }

    func parseUsageResponse(_ text: String) -> AccountUsage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              id == 2,
              let response = object["result"] as? [String: Any] else {
            return nil
        }

        let limit = ((response["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? (response["rateLimits"] as? [String: Any])
        guard let limit else {
            return nil
        }

        let windows = [
            parseWindow(limit["primary"] as? [String: Any]),
            parseWindow(limit["secondary"] as? [String: Any])
        ].compactMap { $0 }

        guard !windows.isEmpty else { return nil }

        let sortedWindows = windows.sorted {
            ($0.durationMinutes ?? Double.greatestFiniteMagnitude) < ($1.durationMinutes ?? Double.greatestFiniteMagnitude)
        }
        // A Pro account may expose only a weekly primary window.
        // Classify by actual duration instead of assuming primary means five hours.
        let onlyLongWindow = sortedWindows.count == 1 && (sortedWindows[0].durationMinutes ?? 0) >= 1440
        let shortWindow = onlyLongWindow ? nil : sortedWindows.first
        let totalWindow = onlyLongWindow ? sortedWindows.first : (sortedWindows.count > 1 ? sortedWindows.last : nil)
        let plan = limit["planType"] as? String
        let resetCredits = parseResetCredits(response["rateLimitResetCredits"] as? [String: Any])

        return AccountUsage(
            shortWindow: shortWindow,
            totalWindow: totalWindow,
            resetCredits: resetCredits,
            planType: plan,
            lastSuccessAt: Date()
        )
    }

    private func parseResetCredits(_ object: [String: Any]?) -> ResetCredits? {
        guard let object else { return nil }
        let availableCount = object["availableCount"] as? Int ?? 0
        let credits = object["credits"] as? [[String: Any]] ?? []
        let expirations = credits.compactMap { credit -> Date? in
            guard let expiresAt = credit["expiresAt"] as? Double else { return nil }
            return Date(timeIntervalSince1970: expiresAt)
        }.sorted()
        return ResetCredits(availableCount: availableCount, expirations: expirations)
    }

    private func parseWindow(_ window: [String: Any]?) -> AccountUsageWindow? {
        guard let window,
              let used = window["usedPercent"] as? Double else {
            return nil
        }

        let duration = window["windowDurationMins"] as? Double
        let resetsAt = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let remaining = max(0, min(100, Int((100.0 - used).rounded())))

        return AccountUsageWindow(
            remainingPercent: remaining,
            usedPercent: Int(used.rounded()),
            windowLabel: windowLabel(minutes: duration),
            resetsAt: resetsAt,
            durationMinutes: duration
        )
    }

    private func loadCache() -> AccountUsage? {
        guard let data = try? Data(contentsOf: cacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int,
              version == 1,
              let lastSuccess = object["lastSuccessAt"] as? Double else {
            return nil
        }

        return AccountUsage(
            shortWindow: decodeCachedWindow(object["shortWindow"] as? [String: Any]),
            totalWindow: decodeCachedWindow(object["totalWindow"] as? [String: Any]),
            resetCredits: decodeCachedResetCredits(object["resetCredits"] as? [String: Any]),
            planType: object["planType"] as? String,
            lastSuccessAt: Date(timeIntervalSince1970: lastSuccess)
        )
    }

    private func saveCache(_ usage: AccountUsage) {
        var object: [String: Any] = [
            "version": 1,
            "lastSuccessAt": usage.lastSuccessAt.timeIntervalSince1970
        ]
        if let shortWindow = encodeCachedWindow(usage.shortWindow) {
            object["shortWindow"] = shortWindow
        }
        if let totalWindow = encodeCachedWindow(usage.totalWindow) {
            object["totalWindow"] = totalWindow
        }
        if let resetCredits = encodeCachedResetCredits(usage.resetCredits) {
            object["resetCredits"] = resetCredits
        }
        if let planType = usage.planType {
            object["planType"] = planType
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = cacheURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
            }
            try FileManager.default.moveItem(at: temporary, to: cacheURL)
        } catch {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func encodeCachedWindow(_ window: AccountUsageWindow?) -> [String: Any]? {
        guard let window else { return nil }
        var object: [String: Any] = [
            "remainingPercent": window.remainingPercent,
            "usedPercent": window.usedPercent,
            "windowLabel": window.windowLabel
        ]
        if let resetsAt = window.resetsAt {
            object["resetsAt"] = resetsAt.timeIntervalSince1970
        }
        if let duration = window.durationMinutes {
            object["durationMinutes"] = duration
        }
        return object
    }

    private func decodeCachedWindow(_ object: [String: Any]?) -> AccountUsageWindow? {
        guard let object,
              let remaining = object["remainingPercent"] as? Int,
              let used = object["usedPercent"] as? Int,
              let label = object["windowLabel"] as? String,
              (0...100).contains(remaining),
              (0...100).contains(used) else {
            return nil
        }

        let resetsAt = (object["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let duration = object["durationMinutes"] as? Double
        return AccountUsageWindow(
            remainingPercent: remaining,
            usedPercent: used,
            windowLabel: label,
            resetsAt: resetsAt,
            durationMinutes: duration
        )
    }

    private func encodeCachedResetCredits(_ credits: ResetCredits?) -> [String: Any]? {
        guard let credits else { return nil }
        return [
            "availableCount": credits.availableCount,
            "expirations": credits.expirations.map { $0.timeIntervalSince1970 }
        ]
    }

    private func decodeCachedResetCredits(_ object: [String: Any]?) -> ResetCredits? {
        guard let object else { return nil }
        let availableCount = object["availableCount"] as? Int ?? 0
        let expirations = (object["expirations"] as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
            .sorted()
        return ResetCredits(availableCount: availableCount, expirations: expirations)
    }

    private func windowLabel(minutes: Double?) -> String {
        guard let minutes else { return "用量窗口" }
        if minutes >= 10080 {
            return "\(Int((minutes / 10080).rounded()))周"
        }
        if minutes >= 1440 {
            return "\(Int((minutes / 1440).rounded()))天"
        }
        if minutes >= 60 {
            return "\(Int((minutes / 60).rounded()))小时"
        }
        return "\(Int(minutes.rounded()))分钟"
    }
}

final class CodexUsageReader {
    private let codexHome: String
    private let contextLimit = 244_800

    init(codexHome: String = NSHomeDirectory() + "/.codex") {
        self.codexHome = codexHome
    }

    func read() -> UsageSnapshot {
        let dbPath = codexHome + "/state_5.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return UsageSnapshot(current: nil, recent: [], totalRecentTokens: 0, checkedAt: Date(), error: "找不到 \(dbPath)")
        }

        let sql = """
        select id, replace(replace(title, char(10), ' '), '|', '/'), tokens_used, coalesce(model,''), coalesce(updated_at_ms, updated_at * 1000)
        from threads
        order by coalesce(updated_at_ms, updated_at * 1000) desc
        limit 8;
        """

        do {
            let output = try run("/usr/bin/sqlite3", args: ["-separator", "\t", dbPath, sql])
            let rows = output
                .split(separator: "\n")
                .compactMap(parseRow)
            let total = rows.reduce(0) { $0 + $1.tokens }
            return UsageSnapshot(current: rows.first, recent: rows, totalRecentTokens: total, checkedAt: Date(), error: nil)
        } catch {
            return UsageSnapshot(current: nil, recent: [], totalRecentTokens: 0, checkedAt: Date(), error: error.localizedDescription)
        }
    }

    func contextRemainingPercent(for thread: ThreadUsage?) -> Int? {
        guard let thread else { return nil }
        let remaining = max(0, contextLimit - thread.tokens)
        return Int((Double(remaining) / Double(contextLimit) * 100).rounded())
    }

    private func parseRow(_ row: Substring) -> ThreadUsage? {
        let parts = row.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 5,
              let tokens = Int(parts[2]),
              let updated = Int64(parts[4]) else {
            return nil
        }

        return ThreadUsage(
            id: String(parts[0]),
            title: String(parts[1]).isEmpty ? "未命名任务" : String(parts[1]),
            tokens: tokens,
            model: String(parts[3]).isEmpty ? "unknown" : String(parts[3]),
            updatedAtMs: updated
        )
    }

    private func run(_ launchPath: String, args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CodexUsageReader",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return output
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let accountReader = AccountUsageReader()
    private let reader = CodexUsageReader()
    private var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.toolTip = "Codex 本地用量"
        statusItem.button?.imagePosition = .imageLeft
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let threadUsage = self.reader.read()
            let account = self.accountReader.read()
            let snapshot = AppSnapshot(
                accountUsage: account.0,
                threadUsage: threadUsage,
                checkedAt: Date(),
                nextRefreshAt: Date().addingTimeInterval(60),
                accountError: account.1
            )
            DispatchQueue.main.async {
                self.updateTitle(snapshot)
                self.updateMenu(snapshot)
            }
        }
    }

    private func updateTitle(_ snapshot: AppSnapshot) {
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        if let accountUsage = snapshot.accountUsage {
            let shortRemaining = accountUsage.shortWindow?.remainingPercent
            let totalRemaining = accountUsage.totalWindow?.remainingPercent
            statusItem.button?.image = MenuBarQuotaGlyph.image(short: shortRemaining, total: totalRemaining)
            let values = accountUsage.windows.map {
                let label = $0.windowLabel == "1周" ? "周" : ($0.windowLabel == "5小时" ? "5h" : $0.windowLabel)
                return "\(label) \($0.remainingPercent)%"
            }
            let plan = accountUsage.planType?.lowercased() == "prolite" ? "Pro" : accountUsage.planLabel
            let title = NSMutableAttributedString(string: "  \(plan)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ])
            title.append(NSAttributedString(string: "  ·  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular)
            ]))
            title.append(NSAttributedString(string: values.isEmpty ? "--%" : values.joined(separator: "  /  "), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]))
            statusItem.button?.attributedTitle = title
            statusItem.button?.toolTip = "Codex \(accountUsage.planLabel) 剩余额度：" + values.joined(separator: " · ")
            return
        }

        statusItem.button?.image = MenuBarQuotaGlyph.image(short: nil, total: nil)
        guard snapshot.threadUsage.error == nil, let current = snapshot.threadUsage.current else {
            statusItem.button?.title = " --%"
            statusItem.button?.toolTip = "Codex 用量读取中"
            return
        }

        if let remaining = reader.contextRemainingPercent(for: current) {
            statusItem.button?.title = " \(remaining)%"
            statusItem.button?.toolTip = "当前任务上下文剩余 \(remaining)%"
        } else {
            statusItem.button?.title = " \(formatTokens(current.tokens))"
            statusItem.button?.toolTip = "当前任务已用 \(formatTokens(current.tokens)) tokens"
        }
    }

    private func updateMenu(_ snapshot: AppSnapshot) {
        let menu = NSMenu()

        if let accountUsage = snapshot.accountUsage {
            menu.addItem(disabled("剩余用量"))
            if let short = accountUsage.shortWindow {
                menu.addItem(disabled("\(short.windowLabel)    \(short.remainingPercent)%    重置：\(resetDateTimeFullLabel(short.resetsAt))"))
                menu.addItem(disabled("\(short.windowLabel)已用：\(short.usedPercent)%"))
            }
            if let total = accountUsage.totalWindow {
                menu.addItem(disabled("\(total.windowLabel)    \(total.remainingPercent)%    重置：\(resetDateTimeFullLabel(total.resetsAt))"))
                menu.addItem(disabled("\(total.windowLabel)已用：\(total.usedPercent)%"))
            }
            menu.addItem(disabled("计划：\(accountUsage.planLabel)"))
            if let resetCredits = accountUsage.resetCredits {
                menu.addItem(disabled("完整重置：\(resetCredits.availableCount) 次可用"))
                for (index, expiration) in resetCredits.expirations.prefix(3).enumerated() {
                    menu.addItem(disabled("重置券 \(index + 1) 过期：\(resetDateTimeLabel(expiration))"))
                }
            }
            if let accountError = snapshot.accountError {
                menu.addItem(disabled("状态：\(accountError)"))
            }
            menu.addItem(disabled("成功更新：\(timeFormatter.string(from: accountUsage.lastSuccessAt))"))
            menu.addItem(disabled("下次刷新：\(timeFormatter.string(from: snapshot.nextRefreshAt))"))
        } else {
            menu.addItem(disabled("剩余用量：读取中"))
            if let error = snapshot.accountError {
                menu.addItem(disabled(error))
            }
        }

        menu.addItem(.separator())

        let threadUsage = snapshot.threadUsage
        if let error = threadUsage.error {
            menu.addItem(disabled("读取失败：\(error)"))
        } else if let current = threadUsage.current {
            let percent = reader.contextRemainingPercent(for: current) ?? 0
            menu.addItem(disabled("当前任务剩余上下文：\(percent)%"))
            menu.addItem(disabled("当前任务已用：\(formatTokens(current.tokens)) tokens"))
            menu.addItem(disabled("模型：\(current.model)"))
            menu.addItem(disabled("任务：\(shorten(current.title, max: 42))"))
        } else {
            menu.addItem(disabled("没有找到 Codex 任务记录"))
        }

        menu.addItem(.separator())
        menu.addItem(disabled("最近 8 个任务合计：\(formatTokens(threadUsage.totalRecentTokens)) tokens"))
        menu.addItem(disabled("更新：\(timeFormatter.string(from: snapshot.checkedAt))"))

        if !threadUsage.recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("最近任务"))
            for thread in threadUsage.recent.prefix(5) {
                menu.addItem(disabled("\(formatTokens(thread.tokens))  \(shorten(thread.title, max: 36))"))
            }
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func manualRefresh() {
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private func shorten(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        let end = value.index(value.startIndex, offsetBy: max)
        return String(value[..<end]) + "..."
    }

    private func resetDateLabel(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func resetDateTimeFullLabel(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }

    private func resetDateTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter.string(from: date)
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private func clockLabelWithSeconds(_ date: Date?) -> String {
        guard let date else { return "--:--:--" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
