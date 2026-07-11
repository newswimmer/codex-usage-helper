import AppKit
import Carbon
import ImageIO
import Foundation
import UniformTypeIdentifiers

private let codexExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"
private let fiveHourMinutes = 300
private let weeklyMinutes = 10_080
private let autoRefreshIntervalSeconds: TimeInterval = 5 * 60

struct UsageWindow {
    let name: String
    let shortName: String
    let remainingPercent: Int
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date?
}

struct UsageSummary {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let planType: String?
    let resetCredits: Int?
    let fetchedAt: Date

    var menuBarTitle: String {
        let five = fiveHour.map { "5h \($0.remainingPercent)%" } ?? "5h --"
        let week = weekly.map { "W \($0.remainingPercent)%" } ?? "W --"
        return "\(five) · \(week)"
    }
}

enum UsageError: Error, LocalizedError {
    case codexMissing
    case launchFailed(String)
    case timedOut
    case protocolError(String)
    case serverError(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "ChatGPT app was not found."
        case .launchFailed(let message):
            return "Could not start Codex usage service: \(message)"
        case .timedOut:
            return "Codex usage service did not respond."
        case .protocolError(let message):
            return "Codex usage response changed: \(message)"
        case .serverError(let message):
            return message
        case .unavailable(let message):
            return message
        }
    }
}

final class CodexUsageClient {
    typealias Completion = (Result<UsageSummary, UsageError>) -> Void

    func fetch(completion: @escaping Completion) {
        guard FileManager.default.isExecutableFile(atPath: codexExecutable) else {
            completion(.failure(.codexMissing))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexExecutable)
        process.arguments = ["app-server", "--stdio"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = RequestState(process: process, input: stdinPipe.fileHandleForWriting, completion: completion)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            state.appendStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            state.appendStderr(handle.availableData)
        }
        process.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.processTerminated()
        }

        do {
            try process.run()
        } catch {
            completion(.failure(.launchFailed(error.localizedDescription)))
            return
        }

        state.startTimeout()
        state.send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-usage-helper",
                    "title": "Codex Usage Helper",
                    "version": "1.0.1",
                ],
                "capabilities": NSNull(),
            ],
        ])
    }
}

private final class RequestState {
    private let process: Process
    private let input: FileHandle
    private let completion: CodexUsageClient.Completion
    private let queue = DispatchQueue(label: "CodexUsageHelper.RequestState")
    private var stdoutBuffer = Data()
    private var stderrText = ""
    private var completed = false
    private var timeout: DispatchSourceTimer?

    init(process: Process, input: FileHandle, completion: @escaping CodexUsageClient.Completion) {
        self.process = process
        self.input = input
        self.completion = completion
    }

    func startTimeout() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 12)
            timer.setEventHandler { [weak self] in
                self?.finish(.failure(.timedOut))
            }
            self.timeout = timer
            timer.resume()
        }
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            self.stdoutBuffer.append(data)
            while let newline = self.stdoutBuffer.firstIndex(of: 10) {
                let lineData = self.stdoutBuffer[..<newline]
                self.stdoutBuffer.removeSubrange(...newline)
                guard !lineData.isEmpty else { continue }
                self.handleLine(Data(lineData))
            }
        }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            self.stderrText += String(data: data, encoding: .utf8) ?? ""
        }
    }

    func processTerminated() {
        queue.async {
            guard !self.completed else { return }
            let cleanError = self.stderrText
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasPrefix("WARNING: proceeding") }
                .joined(separator: "\n")
            if cleanError.isEmpty {
                self.finish(.failure(.unavailable("Codex usage unavailable.")))
            } else {
                self.finish(.failure(.unavailable(cleanError)))
            }
        }
    }

    func send(_ object: [String: Any]) {
        queue.async {
            self.write(object)
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let message = object as? [String: Any]
        else {
            finish(.failure(.protocolError("Invalid JSON from Codex.")))
            return
        }

        if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "Codex usage request failed."
                finish(.failure(.serverError(text)))
                return
            }

            if id == 1 {
                write(["method": "initialized"])
                write(["id": 2, "method": "account/rateLimits/read"])
                return
            }

            if id == 2 {
                guard let result = message["result"] as? [String: Any] else {
                    finish(.failure(.protocolError("Missing rate-limit result.")))
                    return
                }
                do {
                    finish(.success(try parseUsage(result)))
                } catch let error as UsageError {
                    finish(.failure(error))
                } catch {
                    finish(.failure(.protocolError(error.localizedDescription)))
                }
            }
        }
    }

    private func write(_ object: [String: Any]) {
        guard !completed else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            input.write(data)
            input.write(Data([10]))
        } catch {
            finish(.failure(.protocolError(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<UsageSummary, UsageError>) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        timeout = nil
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}

private func parseUsage(_ result: [String: Any]) throws -> UsageSummary {
    let snapshot = codexSnapshot(from: result)
    let windows = [snapshot["primary"], snapshot["secondary"]]
        .compactMap { $0 as? [String: Any] }
        .compactMap(parseWindow)

    let resetCredits = ((result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? NSNumber)?.intValue
    return UsageSummary(
        fiveHour: closestWindow(in: windows, duration: fiveHourMinutes, name: "5-hour usage limit", shortName: "5h"),
        weekly: closestWindow(in: windows, duration: weeklyMinutes, name: "Weekly usage limit", shortName: "W"),
        planType: snapshot["planType"] as? String,
        resetCredits: resetCredits,
        fetchedAt: Date()
    )
}

private func codexSnapshot(from result: [String: Any]) -> [String: Any] {
    if
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any],
        let codex = byLimit["codex"] as? [String: Any]
    {
        return codex
    }
    return result["rateLimits"] as? [String: Any] ?? [:]
}

private func parseWindow(_ dict: [String: Any]) -> UsageWindow? {
    guard
        let durationNumber = dict["windowDurationMins"] as? NSNumber,
        let usedNumber = dict["usedPercent"] as? NSNumber
    else {
        return nil
    }
    let duration = durationNumber.intValue
    let used = usedNumber.doubleValue
    let remaining = Int((100.0 - used).rounded())
    let resetNumber = dict["resetsAt"] as? NSNumber
    let resetDate = resetNumber.map { Date(timeIntervalSince1970: $0.doubleValue) }

    return UsageWindow(
        name: "\(duration)m usage limit",
        shortName: "\(duration)m",
        remainingPercent: min(max(remaining, 0), 100),
        usedPercent: used,
        windowDurationMins: duration,
        resetsAt: resetDate
    )
}

private func closestWindow(in windows: [UsageWindow], duration: Int, name: String, shortName: String) -> UsageWindow? {
    guard let best = windows.min(by: {
        abs($0.windowDurationMins - duration) < abs($1.windowDurationMins - duration)
    }), abs(best.windowDurationMins - duration) <= 1 else {
        return nil
    }
    return UsageWindow(
        name: name,
        shortName: shortName,
        remainingPercent: best.remainingPercent,
        usedPercent: best.usedPercent,
        windowDurationMins: best.windowDurationMins,
        resetsAt: best.resetsAt
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexUsageClient()
    private var summary: UsageSummary?
    private var lastError: String?
    private var isRefreshing = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var autoRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.title = "Codex usage"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        registerHotKey()
        startAutoRefresh()
        refresh(showMenuAfter: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        autoRefreshTimer?.invalidate()
    }

    @objc private func statusItemClicked() {
        showMenu()
    }

    @objc private func refreshFromMenu() {
        refresh(showMenuAfter: false)
    }

    @objc private func refreshFromTimer() {
        refresh(showMenuAfter: false)
    }

    @objc private func openCodexUsageSettings() {
        if let url = URL(string: "codex://settings/usage"), NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh(showMenuAfter: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusItem.button?.title = "Refreshing..."

        client.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let summary):
                self.summary = summary
                self.lastError = nil
                self.statusItem.button?.title = summary.menuBarTitle
            case .failure(let error):
                self.summary = nil
                self.lastError = error.errorDescription ?? "Codex usage unavailable."
                self.statusItem.button?.title = "Codex usage unavailable"
            }
            if showMenuAfter {
                self.showMenu()
            }
        }
    }

    private func startAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = Timer.scheduledTimer(
            timeInterval: autoRefreshIntervalSeconds,
            target: self,
            selector: #selector(refreshFromTimer),
            userInfo: nil,
            repeats: true
        )
    }

    private func showMenu() {
        let menu = makeMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self, weak menu] in
            if self?.statusItem.menu === menu {
                self?.statusItem.menu = nil
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Codex Usage", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let summary {
            menu.addItem(.separator())
            addWindow(summary.fiveHour, to: menu)
            addWindow(summary.weekly, to: menu)

            if let resetCredits = summary.resetCredits {
                let item = NSMenuItem(title: "Rate-limit resets available: \(resetCredits)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            let fetched = NSMenuItem(title: "Updated: \(timeFormatter.string(from: summary.fetchedAt))", action: nil, keyEquivalent: "")
            fetched.isEnabled = false
            menu.addItem(fetched)

            let autoRefresh = NSMenuItem(title: "Auto-refresh: every 5 minutes", action: nil, keyEquivalent: "")
            autoRefresh.isEnabled = false
            menu.addItem(autoRefresh)
        } else if let lastError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Click Refresh to read Codex usage.", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if isRefreshing {
            let refreshing = NSMenuItem(title: "Refreshing...", action: nil, keyEquivalent: "")
            refreshing.isEnabled = false
            menu.addItem(refreshing)
        }
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Codex Usage Settings", action: #selector(openCodexUsageSettings), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    private func addWindow(_ window: UsageWindow?, to menu: NSMenu) {
        guard let window else {
            let item = NSMenuItem(title: "Usage window unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let remaining = NSMenuItem(title: "\(window.name): \(window.remainingPercent)% left", action: nil, keyEquivalent: "")
        remaining.isEnabled = false
        menu.addItem(remaining)

        let resetText = window.resetsAt.map { "Resets: \(dateFormatter.string(from: $0))" } ?? "Reset time unavailable"
        let reset = NSMenuItem(title: resetText, action: nil, keyEquivalent: "")
        reset.isEnabled = false
        menu.addItem(reset)
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard
                let userData,
                let event
            else {
                return noErr
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr && hotKeyID.id == 1 {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.refresh(showMenuAfter: true)
                }
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CUXH"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
}()

private func fourCharCode(_ string: String) -> OSType {
    var result: UInt32 = 0
    for scalar in string.utf8.prefix(4) {
        result = (result << 8) + UInt32(scalar)
    }
    return result
}

private func printUsageAndExit() {
    CodexUsageClient().fetch { result in
        switch result {
        case .success(let summary):
            print(summary.menuBarTitle)
            if let fiveHour = summary.fiveHour {
                print("\(fiveHour.name): \(fiveHour.remainingPercent)% left")
            }
            if let weekly = summary.weekly {
                print("\(weekly.name): \(weekly.remainingPercent)% left")
            }
            if let credits = summary.resetCredits {
                print("Rate-limit resets available: \(credits)")
            }
            exit(0)
        case .failure(let error):
            fputs((error.errorDescription ?? "Codex usage unavailable.") + "\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
}

private func makeICNS(at path: String) {
    do {
        let entries: [(type: String, size: Int)] = [
            ("icp4", 16),
            ("icp5", 32),
            ("icp6", 64),
            ("ic07", 128),
            ("ic08", 256),
            ("ic09", 512),
            ("ic10", 1024),
        ]
        let payloads = try entries.map { entry in
            (type: entry.type, data: try drawAppIconPNG(size: entry.size))
        }

        var output = Data()
        output.appendFourCC("icns")
        output.appendUInt32BE(UInt32(8 + payloads.reduce(0) { $0 + 8 + $1.data.count }))
        for payload in payloads {
            output.appendFourCC(payload.type)
            output.appendUInt32BE(UInt32(8 + payload.data.count))
            output.append(payload.data)
        }

        try output.write(to: URL(fileURLWithPath: path), options: .atomic)
        exit(0)
    } catch {
        fputs("Could not create ICNS: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func drawAppIconPNG(size: Int) throws -> Data {
    let width = size
    let height = size
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw UsageError.protocolError("Could not create icon context.")
    }

    let canvas = CGFloat(size)
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    context.clear(bounds)

    let tile = bounds.insetBy(dx: canvas * 0.055, dy: canvas * 0.055)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: canvas * 0.22, cornerHeight: canvas * 0.22, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.018), blur: canvas * 0.035, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.24))
    context.addPath(tilePath)
    context.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.11, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colors = [
        CGColor(red: 0.10, green: 0.45, blue: 0.92, alpha: 1),
        CGColor(red: 0.10, green: 0.72, blue: 0.58, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.setLineWidth(max(1, canvas * 0.012))
    context.strokePath()

    let panel = tile.insetBy(dx: canvas * 0.13, dy: canvas * 0.18)
    fillRoundedRect(context, panel, radius: canvas * 0.065, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))

    drawUsageRow(context, rect: CGRect(x: panel.minX + panel.width * 0.13, y: panel.midY + panel.height * 0.15, width: panel.width * 0.74, height: panel.height * 0.20), fill: 0.72)
    drawUsageRow(context, rect: CGRect(x: panel.minX + panel.width * 0.13, y: panel.midY - panel.height * 0.34, width: panel.width * 0.74, height: panel.height * 0.20), fill: 0.46)

    let sparkRadius = canvas * 0.07
    fillRoundedRect(
        context,
        CGRect(x: panel.midX - sparkRadius, y: panel.maxY - sparkRadius * 3.3, width: sparkRadius * 2, height: sparkRadius * 2),
        radius: sparkRadius,
        color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.92)
    )

    guard let image = context.makeImage() else {
        throw UsageError.protocolError("Could not create icon image.")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw UsageError.protocolError("Could not create PNG destination.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw UsageError.protocolError("Could not finalize PNG.")
    }
    return data as Data
}

private extension Data {
    mutating func appendFourCC(_ string: String) {
        append(contentsOf: string.utf8.prefix(4))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private func drawUsageRow(_ context: CGContext, rect: CGRect, fill: CGFloat) {
    fillRoundedRect(context, rect, radius: rect.height / 2, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    let fillWidth = max(rect.height, rect.width * fill)
    let fillRect = CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
    fillRoundedRect(context, fillRect, radius: rect.height / 2, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
}

private func fillRoundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color)
    context.fillPath()
}

if CommandLine.arguments.contains("--print-usage") {
    printUsageAndExit()
} else if let index = CommandLine.arguments.firstIndex(of: "--make-icns"), CommandLine.arguments.count > index + 1 {
    makeICNS(at: CommandLine.arguments[index + 1])
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
