import AppKit

// Menu bar indicator for Claude Code sessions.
// Source of truth: ~/.claude/sessions/*.json, the registry Claude Code maintains
// itself. No hooks, no polling of Claude, no network.

let home = FileManager.default.homeDirectoryForCurrentUser
let sessionDir = home.appendingPathComponent(".claude/sessions")
let projectDir = home.appendingPathComponent(".claude/projects")

struct Session {
    let id: String
    let pid: Int32
    let status: String
    let cwd: String
    let startedAt: Date
    let statusSince: Date

    // Anything not idle-ish is "attention"; busy is its own thing.
    var isBusy: Bool { status == "busy" }
    var needsYou: Bool { ["needs_input", "waiting", "blocked"].contains(status) }
}

func elapsed(_ since: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(since)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

func pidAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM   // alive but owned by someone else
}

// The desktop app's own sidebar titles, which is what the user actually sees.
// Stored under Application Support/Claude/claude-code-sessions/<...>/local_<uuid>.json
// and joined to the CLI registry by "cliSessionId". Files are ~400KB but both
// fields sit near the top, so only the first chunk is read.
let desktopSessionDir = home.appendingPathComponent(
    "Library/Application Support/Claude/claude-code-sessions")

func jsonString(_ hay: String, key: String) -> String? {
    guard let r = hay.range(of: "\"\(key)\":\"") else { return nil }
    var raw = ""
    var i = r.upperBound
    var escaped = false
    while i < hay.endIndex {
        let c = hay[i]
        if escaped { raw.append("\\"); raw.append(c); escaped = false }
        else if c == "\\" { escaped = true }
        else if c == "\"" { break }
        else { raw.append(c) }
        i = hay.index(after: i)
    }
    if let d = "\"\(raw)\"".data(using: .utf8),
       let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? String {
        return v
    }
    return raw.isEmpty ? nil : raw
}

final class DesktopTitles {
    static let shared = DesktopTitles()
    private var byCliId: [String: String] = [:]
    private var mtimes: [String: Date] = [:]
    private var lastScan = Date.distantPast
    private let lock = NSLock()

    func title(forCliId id: String) -> String? {
        rescanIfStale()
        lock.lock(); defer { lock.unlock() }
        return byCliId[id]
    }

    private func rescanIfStale() {
        lock.lock()
        guard Date().timeIntervalSince(lastScan) > 1.5 else { lock.unlock(); return }
        lastScan = Date()
        lock.unlock()

        guard let walk = FileManager.default.enumerator(
            at: desktopSessionDir,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        for case let url as URL in walk {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("local_") else { continue }
            let key = url.path
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()

            lock.lock()
            let unchanged = mtimes[key] == mtime
            lock.unlock()
            if unchanged { continue }

            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            let chunk = try? fh.read(upToCount: 32 * 1024)
            try? fh.close()
            guard let data = chunk, let head = String(data: data, encoding: .utf8) else { continue }

            lock.lock()
            mtimes[key] = mtime
            if let cli = jsonString(head, key: "cliSessionId"),
               let t = jsonString(head, key: "title"), !t.isEmpty {
                byCliId[cli] = t
            }
            lock.unlock()
        }
    }
}

// First real user message of a transcript, used as the session label.
// Cached forever per session id -- transcripts are large and this never changes.
final class TitleCache {
    static let shared = TitleCache()
    private var cache: [String: String] = [:]
    private var inflight: Set<String> = []
    private let lock = NSLock()

    func title(for s: Session) -> String? {
        if let t = DesktopTitles.shared.title(forCliId: s.id) { return t }
        lock.lock()
        if let t = cache[s.id] { lock.unlock(); return t }
        if inflight.contains(s.id) { lock.unlock(); return nil }
        inflight.insert(s.id)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let t = Self.extract(s) ?? (s.cwd as NSString).lastPathComponent
            self.lock.lock()
            self.cache[s.id] = t
            self.inflight.remove(s.id)
            self.lock.unlock()
        }
        return nil
    }

    private static func extract(_ s: Session) -> String? {
        let encoded = s.cwd.replacingOccurrences(of: "/", with: "-")
        let path = projectDir.appendingPathComponent(encoded)
                             .appendingPathComponent("\(s.id).jsonl")
        guard let fh = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? fh.close() }
        // The first user turn is near the top; 512KB is far more than enough.
        guard let chunk = try? fh.read(upToCount: 512 * 1024),
              let text = String(data: chunk, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }

            var body: String?
            if let str = msg["content"] as? String {
                body = str
            } else if let parts = msg["content"] as? [[String: Any]] {
                body = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard var t = body?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { continue }
            // Skip harness-injected turns: system reminders, slash command wrappers, resumes.
            if t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }

            t = t.split(separator: "\n").first.map(String.init) ?? t
            if t.count > 52 { t = String(t.prefix(52)) + "…" }
            return t
        }
        return nil
    }
}

func readSessions() -> [Session] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: sessionDir, includingPropertiesForKeys: nil) else { return [] }
    var out: [Session] = []
    for f in files where f.pathExtension == "json" {
        guard let data = try? Data(contentsOf: f),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = o["sessionId"] as? String,
              let pid = o["pid"] as? Int32 ?? (o["pid"] as? Double).map({ Int32($0) }),
              pidAlive(pid) else { continue }
        let started = (o["startedAt"] as? Double ?? 0) / 1000
        let statusAt = (o["statusUpdatedAt"] as? Double ?? o["updatedAt"] as? Double ?? 0) / 1000
        out.append(Session(id: sid,
                           pid: pid,
                           status: (o["status"] as? String) ?? "idle",
                           cwd: (o["cwd"] as? String) ?? "",
                           startedAt: Date(timeIntervalSince1970: started),
                           statusSince: Date(timeIntervalSince1970: statusAt)))
    }
    // Needs-you first, then busy, then longest-running.
    return out.sorted {
        if $0.needsYou != $1.needsYou { return $0.needsYou }
        if $0.isBusy != $1.isBusy { return $0.isBusy }
        return $0.statusSince < $1.statusSince
    }
}

// SF Symbols, tinted. Rendered as real menu-item images so they sit in the
// icon column and align the way AppKit menus expect.
func symbol(_ name: String, _ color: NSColor, size: CGFloat = 13,
            weight: NSFont.Weight = .medium) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
}

func templateSymbol(_ name: String, size: CGFloat = 13) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    img?.isTemplate = true
    return img
}

func statusIcon(_ s: Session, size: CGFloat = 13) -> NSImage? {
    switch s.status {
    case "busy":
        return symbol("progress.indicator", .labelColor, size: size)
    case "needs_input", "waiting":
        // Outline, not .fill: a single palette color floods every layer of a
        // filled symbol, which hides the exclamation mark inside it.
        return symbol("exclamationmark.circle", .systemYellow, size: size, weight: .semibold)
    case "blocked":
        return symbol("exclamationmark.triangle", .systemOrange, size: size, weight: .semibold)
    default:
        return symbol("circle", .tertiaryLabelColor, size: size)
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var panel: DesktopPanel?
    var spin = 0
    let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        if UserDefaults.standard.bool(forKey: "panelVisible") { showPanel() }
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        let all = readSessions()
        panel?.update(all)
        let attn = all.filter { $0.needsYou }
        let busy = all.filter { $0.isBusy }
        guard let button = statusItem.button else { return }

        let mark = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        mark?.isTemplate = true
        button.image = mark
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        if let a = attn.first {
            // Yellow reads against a light or a dark menu bar, so it is safe to force.
            button.contentTintColor = .systemYellow
            let text = attn.count > 1 ? " \(attn.count) waiting" : " " + elapsed(a.statusSince)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: button.font!, .foregroundColor: NSColor.systemYellow])
        } else {
            // Leave the tint alone. A template image and a plain title are recolored
            // by AppKit to match the menu bar, which is dark whenever the wallpaper
            // behind it is dark -- even in Light mode. Pinning labelColor here is what
            // painted the icon black on a dark bar and made it disappear.
            button.contentTintColor = nil
            if let b = busy.min(by: { $0.statusSince < $1.statusSince }) {
                spin = (spin + 1) % frames.count
                button.title = " " + frames[spin] + " " + elapsed(b.statusSince)
                    + (busy.count > 1 ? " +\(busy.count - 1)" : "")
            } else {
                button.title = ""
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = readSessions()
        if sessions.isEmpty {
            let i = NSMenuItem(title: "No Claude sessions running", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        for s in sessions {
            let label = TitleCache.shared.title(for: s) ?? (s.cwd as NSString).lastPathComponent
            let time = elapsed(s.statusSince).padding(toLength: 7, withPad: " ", startingAt: 0)
            let timeColor: NSColor = s.needsYou ? .systemYellow
                                   : s.isBusy ? .secondaryLabelColor : .tertiaryLabelColor

            let line = NSMutableAttributedString()
            line.append(NSAttributedString(string: time, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: timeColor]))
            line.append(NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: s.status == "idle" ? NSColor.secondaryLabelColor : NSColor.labelColor]))

            let i = NSMenuItem(title: "", action: #selector(reveal(_:)), keyEquivalent: "")
            i.attributedTitle = line
            i.image = statusIcon(s)
            i.target = self
            i.representedObject = s.cwd
            i.toolTip = "\(s.status) for \(elapsed(s.statusSince))\nsession up \(elapsed(s.startedAt))\npid \(s.pid)\n\(s.cwd)"
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: panel == nil ? "Show Desktop Panel" : "Hide Desktop Panel",
                                action: #selector(togglePanel), keyEquivalent: "d")
        toggle.target = self
        toggle.image = templateSymbol("widget.small")
        menu.addItem(toggle)

        let quit = NSMenuItem(title: "Quit Claude Status",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = templateSymbol("power")
        menu.addItem(quit)
    }

    func showPanel() {
        let p = DesktopPanel()
        p.update(readSessions())
        p.window.orderFront(nil)
        panel = p
    }

    @objc func togglePanel() {
        if let p = panel {
            p.window.orderOut(nil)
            panel = nil
            UserDefaults.standard.set(false, forKey: "panelVisible")
        } else {
            showPanel()
            UserDefaults.standard.set(true, forKey: "panelVisible")
        }
    }

    @objc func reveal(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String, !p.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
}

// MARK: - Desktop panel
// A real WidgetKit widget needs an app-extension target, an App Group entitlement
// and code signing, i.e. full Xcode. This is a borderless panel pinned at desktop
// level instead: same glanceable role, buildable with swiftc alone.

final class PanelView: NSView {
    var sessions: [Session] = []
    var opaqueBackground = false
    override var isFlipped: Bool { true }

    static let width: CGFloat = 330
    static let header: CGFloat = 32
    static let rowH: CGFloat = 26

    static func height(rows: Int) -> CGFloat {
        header + CGFloat(max(rows, 1)) * rowH + 12
    }

    override func draw(_ dirty: NSRect) {
        let bg = opaqueBackground
            ? NSColor.windowBackgroundColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 14, yRadius: 14)
        bg.setFill(); card.fill()
        NSColor.separatorColor.setStroke(); card.lineWidth = 1; card.stroke()

        let busy = sessions.filter { $0.isBusy }.count
        let attn = sessions.filter { $0.needsYou }.count
        var sub = "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"
        if busy > 0 { sub += " · \(busy) working" }
        if attn > 0 { sub += " · \(attn) waiting" }

        NSAttributedString(string: "Claude", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor]).draw(at: NSPoint(x: 14, y: 9))
        let subStr = NSAttributedString(string: sub, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor])
        subStr.draw(at: NSPoint(x: Self.width - 14 - subStr.size().width, y: 11))

        NSColor.separatorColor.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 12, y: Self.header - 1))
        rule.line(to: NSPoint(x: Self.width - 12, y: Self.header - 1))
        rule.lineWidth = 1; rule.stroke()

        if sessions.isEmpty {
            NSAttributedString(string: "No sessions running", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor])
                .draw(at: NSPoint(x: 14, y: Self.header + 6))
            return
        }

        for (i, s) in sessions.enumerated() {
            let y = Self.header + 6 + CGFloat(i) * Self.rowH
            if let icon = statusIcon(s, size: 12) {
                icon.draw(in: NSRect(x: 14, y: y + 2,
                                     width: icon.size.width, height: icon.size.height))
            }
            NSAttributedString(string: elapsed(s.statusSince), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: s.needsYou ? NSColor.systemYellow : NSColor.secondaryLabelColor])
                .draw(at: NSPoint(x: 38, y: y + 2))

            let label = TitleCache.shared.title(for: s) ?? (s.cwd as NSString).lastPathComponent
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: s.status == "idle" ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style])
                .draw(in: NSRect(x: 88, y: y + 1, width: Self.width - 102, height: 18))
        }
    }
}

final class DesktopPanel: NSObject, NSWindowDelegate {
    let window: NSPanel
    let view = PanelView(frame: NSRect(x: 0, y: 0, width: PanelView.width,
                                       height: PanelView.height(rows: 1)))

    override init() {
        window = NSPanel(contentRect: view.frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // Desktop level: visible on the desktop, never covering real windows.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = view
        window.delegate = self

        if let f = UserDefaults.standard.string(forKey: "panelOrigin") {
            window.setFrameOrigin(NSPointFromString(f))
        } else if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - PanelView.width - 24,
                                          y: screen.visibleFrame.maxY - 240))
        }
    }

    func windowDidMove(_ n: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "panelOrigin")
    }

    func update(_ sessions: [Session]) {
        view.sessions = sessions
        let h = PanelView.height(rows: sessions.count)
        if abs(window.frame.height - h) > 0.5 {
            // Grow downward from the top edge, so the panel does not creep.
            let top = window.frame.maxY
            window.setFrame(NSRect(x: window.frame.minX, y: top - h,
                                   width: PanelView.width, height: h), display: true)
        }
        view.needsDisplay = true
    }
}

// `ClaudeStatus --dump` prints what the menu would show, for debugging.
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"),
   i + 1 < CommandLine.arguments.count {
    let sessions = readSessions()
    _ = sessions.map { TitleCache.shared.title(for: $0) }
    Thread.sleep(forTimeInterval: 0.6)
    let v = PanelView(frame: NSRect(x: 0, y: 0, width: PanelView.width,
                                    height: PanelView.height(rows: sessions.count)))
    v.sessions = sessions
    v.opaqueBackground = true
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print("wrote \(CommandLine.arguments[i + 1])")
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    let ss = readSessions()
    if ss.isEmpty { print("(no live sessions)") }
    for s in ss {
        let label = TitleCache.shared.title(for: s)
            ?? { Thread.sleep(forTimeInterval: 0.4)
                 return TitleCache.shared.title(for: s) ?? "(no transcript)" }()
        print("\(s.status.padding(toLength: 11, withPad: " ", startingAt: 0))"
            + "\(elapsed(s.statusSince).padding(toLength: 8, withPad: " ", startingAt: 0))"
            + "pid \(s.pid)  \(label)")
    }
    exit(0)
}

let app = NSApplication.shared
let c = Controller()
app.delegate = c
app.setActivationPolicy(.accessory)
app.run()
