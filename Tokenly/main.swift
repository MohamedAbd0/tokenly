import AppKit
import UserNotifications

// MARK: - Model + parsers

struct Window { let percent: Double; let resetsAt: Date }
struct Usage { let fiveHour: Window?; let weekly: Window?; let updated: Date }

private func window(_ any: Any?, pct: String) -> Window? {
    guard let o = any as? [String: Any],
          let p = o[pct] as? Double,
          let r = o["resets_at"] as? Double else { return nil }
    return Window(percent: p, resetsAt: Date(timeIntervalSince1970: r))
}

/// ~/.claude/.usage.json = {"ts": epoch, "rate_limits": {five_hour:{used_percentage,resets_at}, seven_day:{...}}}
func parseClaude(_ data: Data) -> Usage? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rl = o["rate_limits"] as? [String: Any] else { return nil }
    let f = window(rl["five_hour"], pct: "used_percentage")
    let w = window(rl["seven_day"], pct: "used_percentage")
    if f == nil && w == nil { return nil }
    return Usage(fiveHour: f, weekly: w, updated: Date(timeIntervalSince1970: o["ts"] as? Double ?? 0))
}

/// Newest valid `payload.rate_limits` line wins; truncated/non-matching lines are skipped.
func parseCodex(lines: [String], updated: Date) -> Usage? {
    for line in lines.reversed() {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = o["payload"] as? [String: Any],
              let rl = p["rate_limits"] as? [String: Any] else { continue }
        let f = window(rl["primary"], pct: "used_percent")
        let w = window(rl["secondary"], pct: "used_percent")
        if f == nil && w == nil { continue }
        return Usage(fiveHour: f, weekly: w, updated: updated)
    }
    return nil
}

/// Newest session files by mtime (path dates lie for resumed sessions); read only the tail.
func loadCodex(root: URL) -> Usage? {
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
    var files: [(URL, Date)] = []
    for case let u as URL in en where u.pathExtension == "jsonl" {
        files.append((u, (try? u.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast))
    }
    for (url, mtime) in files.sorted(by: { $0.1 > $1.1 }).prefix(30) { // limit-reached sessions carry no windows, so look past a run of them
        guard let h = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0) // ponytail: tail only; first partial line is skipped as malformed
        guard let data = try? h.readToEnd(), let s = String(data: data, encoding: .utf8) else { continue }
        if let u = parseCodex(lines: s.components(separatedBy: "\n"), updated: mtime) { return u }
    }
    return nil
}

// MARK: - Formatting

func pctText(_ w: Window?, now: Date) -> String {
    guard let w = w else { return "—" }
    return w.resetsAt < now ? "0%" : "\(Int(w.percent.rounded()))%"
}

func label(_ u: Usage?, now: Date) -> String { pctText(u?.fiveHour, now: now) }

func remaining(_ d: Date, now: Date) -> String {
    let s = Int(d.timeIntervalSince(now))
    if s <= 0 { return "reset" }
    let (days, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60)
    if days > 0 { return "\(days)d \(h)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func bar(_ percent: Double, cells: Int = 10) -> String {
    let n = max(0, min(cells, Int((percent / 100 * Double(cells)).rounded())))
    return String(repeating: "▰", count: n) + String(repeating: "▱", count: cells - n)
}

func row(_ name: String, _ w: Window?, now: Date) -> String {
    guard let w = w else { return "\(name)  \(bar(0))  —" }
    let past = w.resetsAt < now
    return "\(name)  \(bar(past ? 0 : w.percent))  \(pctText(w, now: now)) — " + (past ? "reset" : "resets in \(remaining(w.resetsAt, now: now))")
}

// MARK: - Menu-bar progress image

struct BarSeg { let tag: String; let percent: Double?; let weekly: Double?; let text: String; let stale: Bool }

let color5h = NSColor.systemGreen, colorWeek = NSColor.systemPurple
/// Fixed color per window; red once a window is nearly used up (>= 90%).
func barColor(_ p: Double, base: NSColor) -> NSColor { p >= 90 ? .systemRed : base }

/// One row per tool, stacked: "C ▬▬▬▭▭ 42%" over "X ▬▭▭▭▭ 7%"; dynamic colors follow light/dark menu bar.
func barImage(_ segs: [BarSeg]) -> NSImage {
    let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    let barW: CGFloat = 40, barH: CGFloat = 5, gap: CGFloat = 4, h: CGFloat = 22
    let rowH = h / CGFloat(max(1, segs.count))
    func size(_ s: String) -> CGSize { (s as NSString).size(withAttributes: [.font: font]) }
    let tagW = segs.map { size($0.tag).width }.max() ?? 0
    let textW = size("100%").width // fixed column so bars line up
    let total = tagW + gap + barW + gap + textW
    return NSImage(size: NSSize(width: ceil(total), height: h), flipped: false) { _ in
        for (i, s) in segs.enumerated() {
            let y0 = h - CGFloat(i + 1) * rowH, alpha: CGFloat = s.stale ? 0.5 : 1
            func text(_ t: String, at x: CGFloat) {
                (t as NSString).draw(at: NSPoint(x: x, y: y0 + (rowH - size(t).height) / 2),
                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)])
            }
            text(s.tag, at: 0)
            // two thin bars per row: 5h on top, week below
            func drawBar(_ p: Double?, base: NSColor, y: CGFloat, height: CGFloat) {
                let track = NSRect(x: tagW + gap, y: y, width: barW, height: height)
                NSColor.labelColor.withAlphaComponent(0.25 * alpha).setFill()
                NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
                if let p = p, p > 0 {
                    var f = track; f.size.width = max(height, barW * CGFloat(min(p, 100)) / 100)
                    barColor(p, base: base).withAlphaComponent(alpha).setFill()
                    NSBezierPath(roundedRect: f, xRadius: height / 2, yRadius: height / 2).fill()
                }
            }
            drawBar(s.percent, base: color5h, y: y0 + rowH / 2 + 0.5, height: 4)
            drawBar(s.weekly, base: colorWeek, y: y0 + rowH / 2 - 4, height: 3.5)
            text(s.text, at: tagW + gap + barW + gap)
        }
        return true
    }
}

// MARK: - Dropdown meter row (same bars as the menu-bar image)

final class MeterRow: NSView {
    let label: String, base: NSColor
    var percent: Double? { didSet { needsDisplay = true } }
    var pct = "—" { didSet { needsDisplay = true } }
    var reset = "" { didSet { needsDisplay = true } }
    init(label: String, base: NSColor) {
        self.label = label; self.base = base
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ w: Window?, now: Date) {
        let past = w.map { $0.resetsAt < now } ?? false
        percent = w.map { past ? 0 : $0.percent }
        pct = pctText(w, now: now)
        reset = w == nil ? "no data" : past ? "reset" : "resets in \(remaining(w!.resetsAt, now: now))"
    }
    override func draw(_ r: NSRect) {
        func text(_ t: String, x: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: weight), .foregroundColor: color]
            let h = (t as NSString).size(withAttributes: a).height
            (t as NSString).draw(at: NSPoint(x: x, y: (bounds.height - h) / 2), withAttributes: a)
        }
        text(label, x: 14, color: .labelColor, weight: .medium)
        let track = NSRect(x: 48, y: (bounds.height - 6) / 2, width: 110, height: 6)
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        if let p = percent, p > 0 {
            var f = track; f.size.width = max(6, track.width * CGFloat(min(p, 100)) / 100)
            barColor(p, base: base).setFill()
            NSBezierPath(roundedRect: f, xRadius: 3, yRadius: 3).fill()
        }
        text(pct, x: 166, color: .labelColor, weight: .semibold)
        text(reset, x: 204, color: .secondaryLabelColor)
    }
}

/// Plain text line as a view so it can be updated while the menu is open.
final class TextRow: NSView {
    var text: String { didSet { needsDisplay = true } }
    let bold: Bool
    init(_ text: String, bold: Bool = false) {
        self.text = text; self.bold = bold
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let a: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 11),
            .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor]
        let h = (text as NSString).size(withAttributes: a).height
        (text as NSString).draw(at: NSPoint(x: 14, y: (bounds.height - h) / 2), withAttributes: a)
    }
}

// MARK: - Live Claude usage (works from VS Code / Desktop / CLI)

func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

/// GET api/oauth/usage -> {"five_hour":{"utilization":37.0,"resets_at":"ISO"},"seven_day":{...},...}
func parseClaudeAPI(_ data: Data, now: Date) -> Usage? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    func w(_ k: String) -> Window? {
        guard let d = o[k] as? [String: Any], let u = d["utilization"] as? Double,
              let r = d["resets_at"] as? String, let date = isoDate(r) else { return nil }
        return Window(percent: u, resetsAt: date)
    }
    let f = w("five_hour"), wk = w("seven_day")
    return f == nil && wk == nil ? nil : Usage(fiveHour: f, weekly: wk, updated: now)
}

/// `codex app-server` account/rateLimits/read reply. An unused 5h window slides (reset = now + 5h): it hasn't started, so report it as over.
func parseCodexLive(_ data: Data, now: Date) -> Usage? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rl = (o["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return nil }
    func w(_ k: String, sliding: Bool) -> Window? {
        guard let d = rl[k] as? [String: Any], let p = d["usedPercent"] as? Double, let r = d["resetsAt"] as? Double else { return nil }
        let mins = d["windowDurationMins"] as? Double ?? 0
        let unstarted = sliding && p == 0 && mins > 0 && r - now.timeIntervalSince1970 >= mins * 60 - 60
        return Window(percent: p, resetsAt: unstarted ? now.addingTimeInterval(-1) : Date(timeIntervalSince1970: r))
    }
    let f = w("primary", sliding: true), wk = w("secondary", sliding: false)
    return f == nil && wk == nil ? nil : Usage(fiveHour: f, weekly: wk, updated: now)
}

/// Asks the official Codex CLI for the account's current limits (same data as /status). Uses no quota; Codex handles its own login.
func readCodexLive(timeout: TimeInterval = 20) -> (Usage?, String) {
    guard let bin = findBinary("codex") else { return (nil, "codex not found") }
    let p = cliProcess(bin, ["app-server"])
    let input = Pipe(), output = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0), lock = NSLock()
    var buffer = Data(), reply: Data?
    output.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        lock.lock(); defer { lock.unlock() }
        if chunk.isEmpty { h.readabilityHandler = nil; done.signal(); return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<nl]); buffer.removeSubrange(buffer.startIndex...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], o["id"] as? Int == 1 { reply = line; done.signal() }
        }
    }
    do { try p.run() } catch { return (nil, "could not start codex") }
    let requests = #"""
    {"method":"initialize","id":0,"params":{"clientInfo":{"name":"tokenly","title":"Tokenly","version":"1.0"}}}
    {"method":"initialized","params":{}}
    {"method":"account/rateLimits/read","id":1}

    """#
    try? input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
    let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
    output.fileHandleForReading.readabilityHandler = nil
    p.terminate()
    lock.lock(); defer { lock.unlock() }
    guard let r = reply else { return (nil, timedOut ? "timeout" : "no reply") }
    let u = parseCodexLive(r, now: Date())
    return (u, u == nil ? "unexpected reply" : "")
}

let agyGroups = [("gemini", "agy · Gemini")]   // (bucket id prefix, title) shown; the CLI also reports "3p" (Claude/GPT), not wanted

/// `agy -p /usage --output-format json` reply. Nil for anything else, including a model answering the text as a prompt.
func parseAgy(_ data: Data, now: Date) -> [String: Usage]? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["num_turns"] as? Int == 0,
          let cmd = o["command"] as? [String: Any], cmd["name"] as? String == "usage",
          let groups = (cmd["data"] as? [String: Any])?["groups"] as? [[String: Any]] else { return nil }
    var result: [String: Usage] = [:]
    for b in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) {
        guard let id = b["id"] as? String, let dash = id.lastIndex(of: "-"), let kind = b["window"] as? String,
              let left = b["remaining_fraction"] as? Double,
              let r = b["reset_time"] as? String, let reset = isoDate(r) else { continue }
        let key = String(id[..<dash]), length: TimeInterval = kind == "5h" ? 5 * 3600 : 7 * 86400
        let unstarted = left >= 1 && reset.timeIntervalSince(now) >= length - 60   // unused windows slide, like Codex
        let w = Window(percent: (1 - left) * 100, resetsAt: unstarted ? now.addingTimeInterval(-1) : reset)
        let old = result[key]
        result[key] = Usage(fiveHour: kind == "5h" ? w : old?.fiveHour, weekly: kind == "5h" ? old?.weekly : w, updated: now)
    }
    return result.isEmpty ? nil : result
}

/// The official CLI's own /usage command: no tokens used. `--log-file /dev/null` so polling doesn't pile up log files.
/// `spentQuota` = the CLI treated "/usage" as a prompt, so we must not ask again.
func readAgyLive(timeout: TimeInterval = 60) -> (usage: [String: Usage]?, note: String, spentQuota: Bool) {
    guard let bin = findBinary("agy") else { return (nil, "agy not found", false) }
    let p = cliProcess(bin, ["-p", "/usage", "--output-format", "json", "--print-timeout", "40s", "--log-file", "/dev/null"])
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return (nil, "could not start agy", false) }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (nil, "timeout", false) }
    let data = out.fileHandleForReading.readDataToEndOfFile()   // ponytail: reply is ~2 KB, far below the pipe buffer
    if let u = parseAgy(data, now: Date()) { return (u, "", false) }
    let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if (o?["num_turns"] as? Int ?? 0) > 0 { return (nil, "update agy (no /usage)", true) }
    return (nil, p.terminationStatus == 0 ? "unexpected reply" : "exit \(p.terminationStatus)", false)
}

/// Claude Code's own login token. Read by this app at runtime (macOS asks you to allow it); never logged or stored.
func readKeychainToken() -> (token: String, expires: Date)? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    guard p.terminationStatus == 0,
          let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let c = o["claudeAiOauth"] as? [String: Any], let t = c["accessToken"] as? String else { return nil }
    return (t, (c["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture)
}

/// Throttled (default 60s) so the 5s UI refresh never hammers the source; `fetch` runs off the main thread.
class LiveSource<Value> {
    private let q = DispatchQueue(label: "tokenly.live")
    private var busy = false, last = Date.distantPast        // main only
    private(set) var latest: Value?, note = ""                // main only
    func expedite() { last = .distantPast }                   // poll again on the next tick

    func fetch() -> (Value?, String) { (nil, "") }
    func poll(every: TimeInterval = 60, done: @escaping () -> Void) {
        guard !busy, Date().timeIntervalSince(last) >= every else { return }
        busy = true; last = Date()
        q.async {
            let (usage, note) = self.fetch()
            DispatchQueue.main.async {
                self.busy = false; self.note = note
                if let u = usage { self.latest = u }
                done()
            }
        }
    }
}

final class AgyLive: LiveSource<[String: Usage]> {
    private var stopped = false   // fetch queue only
    override func fetch() -> ([String: Usage]?, String) {
        if stopped { return (nil, "update agy (no /usage)") }
        let r = readAgyLive()
        stopped = r.spentQuota
        return (r.usage, r.note)
    }
}

final class CodexLive: LiveSource<Usage> {
    override func fetch() -> (Usage?, String) { readCodexLive() }
}

final class ClaudeLive: LiveSource<Usage> {
    private var token: String?, expires = Date.distantPast   // fetch queue only
    override func fetch() -> (Usage?, String) {
        var note = "", usage: Usage?
        if self.token == nil || self.expires < Date() {
            if let k = readKeychainToken() { (self.token, self.expires) = (k.token, k.expires) } else { self.token = nil; note = "no keychain access" }
        }
        if let t = self.token, self.expires > Date() {
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 10)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("Tokenly/1.0", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let d = data { usage = parseClaudeAPI(d, now: Date()); if usage == nil { note = "unexpected reply" } }
                else { note = err != nil ? "offline" : "HTTP \(code)"; if code == 401 || code == 403 { self.token = nil } }
                sem.signal()
            }.resume()
            sem.wait()
        } else if note.isEmpty { note = "token expired" }
        return (usage, note)
    }
}

// MARK: - Auto-start: begin a new 5h window by sending one tiny message through the official CLI

/// Prime only when we positively know the 5h window is over: data present + fresh, window gone or past its reset,
/// not within 5h of our last successful prime (that window cannot have ended), not within 10 min of the last attempt.
func shouldPrime(enabled: Bool, usage: Usage?, fresh: Bool, now: Date, lastSuccess: Date, lastAttempt: Date, running: Bool) -> Bool {
    guard enabled, !running, fresh, let u = usage else { return false }
    if let w = u.fiveHour, w.resetsAt >= now { return false }
    if let w = u.weekly, w.percent >= 100, w.resetsAt >= now { return false } // the message would only fail
    return now.timeIntervalSince(lastSuccess) >= 5 * 3600 && now.timeIntervalSince(lastAttempt) >= 600
}

func findBinary(_ name: String) -> URL? {
    let h = NSHomeDirectory(), fm = FileManager.default
    var dirs = ["\(h)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    dirs += ((try? fm.contentsOfDirectory(atPath: "\(h)/.nvm/versions/node")) ?? []).map { "\(h)/.nvm/versions/node/\($0)/bin" }
    return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { fm.isExecutableFile(atPath: $0.path) }
}

/// launchd gives apps a bare PATH, so node's dir is added. Runs from the temp dir (no project context).
func cliProcess(_ bin: URL, _ args: [String]) -> Process {
    let p = Process(); p.executableURL = bin; p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(bin.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    return p
}

/// Runs the CLI once. Returns nil on success, else a short reason.
func runCLI(_ name: String, _ args: [String], timeout: TimeInterval = 120) -> String? {
    guard let bin = findBinary(name) else { return "\(name) not found" }
    let p = cliProcess(bin, args)
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return "could not start" }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return "timeout" }
    return p.terminationStatus == 0 ? nil : "exit \(p.terminationStatus)"
}

final class Primer {
    let name: String, tool: String, args: [String]
    var lastAttempt = Date.distantPast, running = false, failure = ""
    var onEvent: ((String, Bool) -> Void)?   // (message, loud)
    init(name: String, tool: String, args: [String]) { self.name = name; self.tool = tool; self.args = args }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "auto" + name) }
        set { UserDefaults.standard.set(newValue, forKey: "auto" + name) }
    }
    var lastSuccess: Date { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "primed" + name)) } // persisted: survives restarts

    func maybe(usage: Usage?, fresh: Bool, now: Date, done: @escaping () -> Void) {
        guard shouldPrime(enabled: enabled, usage: usage, fresh: fresh, now: now, lastSuccess: lastSuccess, lastAttempt: lastAttempt, running: running) else { return }
        running = true; lastAttempt = now
        DispatchQueue.global().async {
            let err = runCLI(self.tool, self.args)
            DispatchQueue.main.async {
                self.running = false
                if let e = err {
                    if e != self.failure { self.onEvent?("\(self.name) auto-start failed: \(e)", true) }   // once per distinct failure
                    self.failure = e
                } else {
                    self.failure = ""
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "primed" + self.name)
                    self.onEvent?("\(self.name): new 5h window started", false)
                }
                done()
            }
        }
    }

    func status() -> String {
        if running { return "starting window…" }
        if !failure.isEmpty { return "auto-start failed: \(failure)" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return lastSuccess.timeIntervalSince1970 > 0 ? "primed \(f.string(from: lastSuccess))" : "auto-start on"
    }
}

// MARK: - Alerts

let alertLevels = [95, 80]

/// Highest alert level reached that has not fired yet in this window (caller marks it and all lower levels as fired).
func nextAlert(percent: Double, fired: Set<Int>) -> Int? { alertLevels.first { percent >= Double($0) && !fired.contains($0) } }

/// Per-window watcher (tool + "5h"/"week"): threshold alerts once per window + one "window reset" when a window ends.
final class Alerts {
    private var end: [String: Date] = [:], fired: [String: Set<Int>] = [:]
    func update(_ name: String, _ label: String, _ w: Window?, now: Date, notify: (String, Bool) -> Void) {
        let key = "\(name)|\(label)"
        guard let w = w, w.resetsAt > now else {   // no active window
            if let e = end[key], e <= now { notify("\(name): \(label) window reset", false); end[key] = nil; fired[key] = [] }
            return
        }
        if let e = end[key], abs(e.timeIntervalSince(w.resetsAt)) > 120 { notify("\(name): \(label) window reset", false); fired[key] = [] } // new window seen directly
        end[key] = w.resetsAt
        if let t = nextAlert(percent: w.percent, fired: fired[key] ?? []) {
            fired[key, default: []].formUnion(alertLevels.filter { $0 <= t })
            notify("\(name): \(label) at \(Int(w.percent.rounded()))% — resets in \(remaining(w.resetsAt, now: now))", t >= 95)
        }
    }
}

/// Banner always; sound only when `loud` (95% alerts and failures). Routine events stay silent so night-time auto-start never wakes you.
func notify(_ title: String, _ body: String, loud: Bool = false) {
    guard Bundle.main.bundleIdentifier != nil else { return }   // needs the .app bundle
    let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = loud ? .default : nil
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// MARK: - Self-check

func selftest() {
    var failed = false
    func check(_ ok: Bool, _ msg: String) { if !ok { print("FAIL: \(msg)"); failed = true } }
    let now = Date(timeIntervalSince1970: 1_795_000_000)
    let ev = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":6.0,"window_minutes":300,"resets_at":1795415302},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1795757096}}}}"#
    let noRL = #"{"type":"event_msg","payload":{"type":"other"}}"#

    let a = parseCodex(lines: [noRL, ev, #"{"type":"ev"#], updated: now)
    check(a?.fiveHour?.percent == 6.0, "codex 5h = 6.0 (skips truncated last line)")
    check(a?.weekly?.percent == 7.0, "codex weekly = 7.0")
    check(parseCodex(lines: [noRL, "garbage"], updated: now) == nil, "codex without rate_limits -> nil")

    let c = parseClaude(#"{"ts":1795000000,"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1795415302},"seven_day":{"used_percentage":9,"resets_at":1795757096}}}"#.data(using: .utf8)!)
    check(c?.fiveHour?.percent == 42.4 && c?.weekly?.percent == 9, "claude parse")
    check(parseClaude(#"{"ts":1,"rate_limits":null}"#.data(using: .utf8)!) == nil, "claude null -> nil")

    check(label(a, now: now) == "6%", "label 6.0 -> 6%")
    check(label(nil, now: now) == "—", "label nil -> dash")
    let past = Usage(fiveHour: Window(percent: 88, resetsAt: now.addingTimeInterval(-5)), weekly: nil, updated: now)
    check(label(past, now: now) == "0%", "label past reset -> 0%")
    check(remaining(now.addingTimeInterval(7800), now: now) == "2h 10m", "remaining 2h 10m")

    check(bar(42) == "▰▰▰▰▱▱▱▱▱▱", "bar 42% -> 4 of 10 cells")
    check(bar(0) == "▱▱▱▱▱▱▱▱▱▱" && bar(150) == "▰▰▰▰▰▰▰▰▰▰", "bar clamps 0..100")
    check(row("5h", nil, now: now) == "5h  ▱▱▱▱▱▱▱▱▱▱  —", "row without data")

    let api = parseClaudeAPI(#"{"five_hour":{"utilization":37.0,"resets_at":"2026-11-25T10:00:00.123456+00:00"},"seven_day":{"utilization":12,"resets_at":"2026-11-30T10:00:00Z"},"seven_day_opus":null}"#.data(using: .utf8)!, now: now)
    check(api?.fiveHour?.percent == 37.0 && api?.weekly?.percent == 12, "api percents")
    check(abs((api?.weekly?.resetsAt.timeIntervalSince(api!.fiveHour!.resetsAt) ?? 0) - 432000) < 1, "api reset dates parse (fractional + plain)")
    check(parseClaudeAPI(#"{"five_hour":null,"seven_day":null}"#.data(using: .utf8)!, now: now) == nil, "api all null -> nil")

    let idle = Usage(fiveHour: Window(percent: 50, resetsAt: now.addingTimeInterval(-60)), weekly: nil, updated: now)
    let busy = Usage(fiveHour: Window(percent: 50, resetsAt: now.addingTimeInterval(600)), weekly: nil, updated: now)
    let noFive = Usage(fiveHour: nil, weekly: Window(percent: 5, resetsAt: now.addingTimeInterval(9999)), updated: now)
    let long = Date.distantPast
    func sp(_ u: Usage?, en: Bool = true, fresh: Bool = true, ok: Date = long, att: Date = long, run: Bool = false) -> Bool {
        shouldPrime(enabled: en, usage: u, fresh: fresh, now: now, lastSuccess: ok, lastAttempt: att, running: run)
    }
    check(sp(idle), "prime: expired window")
    check(sp(noFive), "prime: 5h window absent")
    check(!sp(busy), "no prime: window active")
    check(!sp(idle, en: false), "no prime: disabled")
    check(!sp(nil), "no prime: no data")
    check(!sp(idle, fresh: false), "no prime: stale data")
    check(!sp(idle, run: true), "no prime: already running")
    check(!sp(idle, ok: now.addingTimeInterval(-3600)), "no prime: primed 1h ago")
    check(sp(idle, ok: now.addingTimeInterval(-5 * 3600 - 1)), "prime: primed 5h+ ago")
    check(!sp(idle, att: now.addingTimeInterval(-300)), "no prime: attempt 5 min ago")
    check(sp(idle, att: now.addingTimeInterval(-601)), "prime: attempt 10+ min ago")

    let rpc = parseCodexLive(#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1795015000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1795500000}}}}"#.data(using: .utf8)!, now: now)
    check(rpc?.fiveHour?.percent == 100 && rpc?.weekly?.percent == 20, "codex live percents")
    check(rpc?.fiveHour?.resetsAt.timeIntervalSince1970 == 1795015000, "codex live reset")
    let unstarted = parseCodexLive(#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1795018000},"secondary":null}}}"#.data(using: .utf8)!, now: now)
    check(unstarted?.fiveHour.map { $0.resetsAt < now } == true, "codex live: unused sliding window counts as over")
    check(parseCodexLive(#"{"id":1,"error":{"message":"no"}}"#.data(using: .utf8)!, now: now) == nil, "codex live error -> nil")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tokenly-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    for i in 0...6 {
        let u = tmp.appendingPathComponent("\(i).jsonl")
        try? (i == 0 ? ev : #"{"payload":{"rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#).write(to: u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i) * 60)], ofItemAtPath: u.path)
    }
    check(loadCodex(root: tmp)?.fiveHour?.percent == 6.0, "codex: limit-reached sessions don't hide the last real numbers")
    try? FileManager.default.removeItem(at: tmp)
    let weekOut = Usage(fiveHour: nil, weekly: Window(percent: 100, resetsAt: now.addingTimeInterval(9999)), updated: now)
    check(!sp(weekOut), "no prime: weekly limit used up")

    let agyReply = #"{"num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.66,"reset_time":"2026-11-25T10:00:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0,"reset_time":"2026-11-18T12:00:00Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":1,"reset_time":"%@"}]}]}}}"#
    let sliding = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
    let ag = parseAgy(Data(agyReply.replacingOccurrences(of: "%@", with: sliding).utf8), now: now)
    check(abs((ag?["gemini"]?.weekly?.percent ?? 0) - 34) < 0.01 && ag?["gemini"]?.fiveHour?.percent == 100, "agy: remaining -> used")
    check(ag?["3p"]?.fiveHour.map { $0.percent == 0 && $0.resetsAt < now } == true, "agy: unused sliding window counts as over")
    check(parseAgy(Data(#"{"num_turns":1,"response":"Hello"}"#.utf8), now: now) == nil, "agy: a model reply is not usage")

    // alerts
    check(nextAlert(percent: 70, fired: []) == nil, "alert: below 80")
    check(nextAlert(percent: 85, fired: []) == 80, "alert: 85 -> 80")
    check(nextAlert(percent: 96, fired: []) == 95, "alert: 96 -> 95")
    check(nextAlert(percent: 96, fired: [80]) == 95, "alert: 95 after 80")
    check(nextAlert(percent: 96, fired: [80, 95]) == nil, "alert: nothing left")
    func win(_ p: Double, ends: TimeInterval) -> Usage { Usage(fiveHour: Window(percent: p, resetsAt: now.addingTimeInterval(ends)), weekly: nil, updated: now) }
    let al = Alerts(); var msgs: [String] = [], loud: [Bool] = []
    func step(_ u: Usage?, _ at: Date? = nil) { al.update("T", "5h", u?.fiveHour, now: at ?? now, notify: { msgs.append($0); loud.append($1) }) }
    step(win(50, ends: 3600)); check(msgs.isEmpty, "alerts: 50% silent")
    step(win(85, ends: 3600)); check(msgs.count == 1 && msgs[0].contains("85%"), "alerts: 85% fires once")
    step(win(86, ends: 3600)); check(msgs.count == 1, "alerts: no repeat at 86%")
    step(win(96, ends: 3600)); check(msgs.count == 2, "alerts: 96% fires 95")
    step(win(97, ends: 3600)); check(msgs.count == 2, "alerts: no repeat at 97%")
    step(nil, now.addingTimeInterval(3601)); check(msgs.count == 3 && msgs[2].contains("reset"), "alerts: window end -> reset once")
    step(nil, now.addingTimeInterval(3700)); check(msgs.count == 3, "alerts: reset not repeated")
    let later = now.addingTimeInterval(4000)
    al.update("T", "5h", Window(percent: 85, resetsAt: later.addingTimeInterval(18000)), now: later, notify: { msgs.append($0); loud.append($1) })
    check(msgs.count == 4, "alerts: next window can alert again")
    al.update("T", "week", Window(percent: 82, resetsAt: later.addingTimeInterval(400_000)), now: later, notify: { msgs.append($0); loud.append($1) })
    check(msgs.count == 5 && msgs[4].contains("week at 82%"), "alerts: weekly window alerts on its own, independent of 5h")
    al.update("T", "week", Window(percent: 83, resetsAt: later.addingTimeInterval(400_000)), now: later, notify: { msgs.append($0); loud.append($1) })
    check(msgs.count == 5, "alerts: weekly no repeat")
    // sound: only the 95% alert is loud; 80% and window reset are silent
    check(loud == [false, true, false, false, false], "alerts: only 95% is loud (80% quiet, reset quiet, 85% of next window quiet, weekly 80% quiet)")

    print(failed ? "selftest FAILED" : "selftest ok")
    exit(failed ? 1 : 0)
}

// MARK: - Menu-bar app

final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let staleAfter: TimeInterval = 3600, pollEvery: TimeInterval = 5
    var lastRefresh = Date()
    let live = ClaudeLive(), codexLive = CodexLive(), agyLive = AgyLive()
    let alerts = Alerts()
    // Minimal messages: no tools, no session saved, cheapest model. Run from the temp dir (no project context).
    lazy var primers = [
        Primer(name: "Claude", tool: "claude", args: ["-p", "ok", "--model", "haiku", "--no-session-persistence", "--tools", "", "--disable-slash-commands"]),
        Primer(name: "Codex", tool: "codex", args: ["exec", "--skip-git-repo-check", "-s", "read-only", "-c", "model_reasoning_effort=low", "ok"]),
    ]
    let footer = TextRow("Refreshed 0s ago")
    var panels: [String: (five: MeterRow, week: MeterRow, info: TextRow)] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if CommandLine.arguments.contains("--notify-test") { // debug: fire one notification and quit
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { notify("Tokenly", "Test notification") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }
        primers.forEach { $0.onEvent = { notify("Tokenly", $0, loud: $1) } }
        // Menu is built once; refresh() updates the views in place so it stays live while open.
        let menu = NSMenu()
        func addView(_ v: NSView) { let i = NSMenuItem(); i.view = v; menu.addItem(i) }
        let agyTitles = findBinary("agy") == nil ? [] : agyGroups.map { $0.1 }   // dropdown only, hidden without agy
        for name in ["Claude", "Codex"] + agyTitles {
            let p = (five: MeterRow(label: "5h", base: color5h), week: MeterRow(label: "Week", base: colorWeek), info: TextRow(""))
            addView(TextRow(name, bold: true)); addView(p.five); addView(p.week); addView(p.info)
            panels[name] = p
            menu.addItem(.separator())
        }
        addView(footer)
        menu.addItem(.separator())
        for (i, pr) in primers.enumerated() {
            let t = NSMenuItem(title: "Auto-start \(pr.name) window", action: #selector(toggleAuto(_:)), keyEquivalent: "")
            t.target = self; t.tag = i; t.state = pr.enabled ? .on : .off
            menu.addItem(t)
        }
        menu.addItem(.separator())
        let testItem = NSMenuItem(title: "Send test notification", action: #selector(testNotification), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        refresh()
        // .common mode: keeps ticking while the menu is open (default mode pauses during menu tracking)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }, forMode: .common)
    }

    @objc func testNotification() { notify("Tokenly", "Test notification") }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done([.banner, .sound]) }

    @objc func toggleAuto(_ s: NSMenuItem) {
        primers[s.tag].enabled.toggle()
        s.state = primers[s.tag].enabled ? .on : .off
        refresh()
    }

    func tick() {
        let age = Date().timeIntervalSince(lastRefresh)
        if age >= pollEvery { refresh() } else { footer.text = "Refreshed \(Int(age))s ago" }
    }

    @objc func refresh() {
        let now = Date()
        lastRefresh = now
        footer.text = "Refreshed 0s ago"
        live.poll { [weak self] in self?.lastRefresh = .distantPast } // new data -> refresh on next tick
        let fromFile = (try? Data(contentsOf: home.appendingPathComponent(".claude/.usage.json"))).flatMap(parseClaude)
        let claude = [live.latest, fromFile].compactMap { $0 }.max { $0.updated < $1.updated } // freshest source wins
        let isLive = claude != nil && claude?.updated == live.latest?.updated
        codexLive.poll { [weak self] in self?.lastRefresh = .distantPast }
        // live wins while current (it sees usage from every device); session files are the offline fallback
        let liveX = codexLive.latest
        let fromSessions = loadCodex(root: home.appendingPathComponent(".codex/sessions"))
        let codex = liveX.map { now.timeIntervalSince($0.updated) < 180 } == true ? liveX
            : [liveX, fromSessions].compactMap { $0 }.max { $0.updated < $1.updated }
        let isCodexLive = codex != nil && codex?.updated == liveX?.updated

        func seg(_ tag: String, _ u: Usage?) -> BarSeg {
            let stale = u.map { now.timeIntervalSince($0.updated) > staleAfter } ?? true
            func p(_ w: Window?) -> Double? { w.map { $0.resetsAt < now ? 0 : $0.percent } }
            return BarSeg(tag: tag, percent: p(u?.fiveHour), weekly: p(u?.weekly), text: label(u, now: now), stale: stale)
        }
        let soon: () -> Void = { [weak self] in self?.lastRefresh = .distantPast }
        primers[0].maybe(usage: claude, fresh: isLive && now.timeIntervalSince(claude!.updated) < 180, now: now) { [weak self] in
            self?.live.expedite(); soon()
        }
        primers[1].maybe(usage: codex, fresh: isCodexLive && now.timeIntervalSince(codex!.updated) < 180, now: now) { [weak self] in
            self?.codexLive.expedite(); soon()
        }
        item.button?.title = ""
        item.button?.image = barImage([seg("C", claude), seg("X", codex)])

        let f = DateFormatter(); f.dateFormat = "HH:mm"
        // after a failure, back off: a signed-out agy shouldn't be launched every minute
        if panels[agyGroups[0].1] != nil { agyLive.poll(every: agyLive.note.isEmpty ? 60 : 600) { [weak self] in self?.lastRefresh = .distantPast } }
        var shown: [(name: String, u: Usage?, source: String, onLive: Bool, note: String)] = [
            ("Claude", claude, isLive ? "live" : "CLI", isLive, live.note),
            ("Codex", codex, isCodexLive ? "live" : "sessions", isCodexLive, codexLive.note),
        ]
        shown += agyGroups.map { ($0.1, agyLive.latest?[$0.0], "live", agyLive.note.isEmpty, agyLive.note) }
        for (name, u, source, onLive, note) in shown {
            guard let p = panels[name] else { continue }
            alerts.update(name, "5h", u?.fiveHour, now: now) { notify("Tokenly", $0, loud: $1) }   // threshold + reset notifications
            alerts.update(name, "week", u?.weekly, now: now) { notify("Tokenly", $0, loud: $1) }
            p.five.set(u?.fiveHour, now: now)
            p.week.set(u?.weekly, now: now)
            var info = u.map { "\(source) · updated \(f.string(from: $0.updated))" } ?? "no data yet"
            if !onLive && !note.isEmpty { info += " · live: \(note)" }
            if let pr = primers.first(where: { $0.name == name }), pr.enabled { info += " · " + pr.status() }
            p.info.text = info
        }
    }
}

if CommandLine.arguments.contains("--selftest") { selftest() }
/// Docs only: view with a rounded background, used to compose the README images.
final class Backdrop: NSView {
    let fill: NSColor, radius: CGFloat
    init(_ frame: NSRect, fill: NSColor, radius: CGFloat = 0) { self.fill = fill; self.radius = radius; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ r: NSRect) { fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
}

if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), i + 1 < CommandLine.arguments.count { // render README images from sample data
    _ = NSApplication.shared
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    func win(_ p: Double, _ secs: TimeInterval) -> Window { Window(percent: p, resetsAt: now.addingTimeInterval(secs)) }
    let claude = Usage(fiveHour: win(42, 8_000), weekly: win(68, 3 * 86_400), updated: now)
    let codex = Usage(fiveHour: win(7, 16_000), weekly: win(31, 5 * 86_400), updated: now)
    func save(_ v: NSView, _ name: String) {   // 2x render
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
    func seg(_ tag: String, _ u: Usage) -> BarSeg { BarSeg(tag: tag, percent: u.fiveHour?.percent, weekly: u.weekly?.percent, text: label(u, now: now), stale: false) }
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    for dark in [true, false] {
        let mode = dark ? "dark" : "light", look = NSAppearance(named: dark ? .darkAqua : .aqua)
        // menu-bar strip
        let img = barImage([seg("C", claude), seg("X", codex)])
        let strip = Backdrop(NSRect(x: 0, y: 0, width: img.size.width + 28, height: 30), fill: NSColor(white: dark ? 0.13 : 0.88, alpha: 1), radius: 7)
        let iv = NSImageView(image: img); iv.frame = NSRect(x: 14, y: 4, width: img.size.width, height: 22); strip.addSubview(iv)
        strip.appearance = look; save(strip, "menubar-\(mode).png")
        // dropdown
        var rows: [NSView] = []
        let gemini = Usage(fiveHour: win(55, 9_000), weekly: win(34, 6 * 86_400), updated: now)
        for (name, u) in [("Claude", claude), ("Codex", codex), (agyGroups[0].1, gemini)] {
            let five = MeterRow(label: "5h", base: color5h), week = MeterRow(label: "Week", base: colorWeek)
            five.set(u.fiveHour, now: now); week.set(u.weekly, now: now)
            rows += [TextRow(name, bold: true), five, week, TextRow("live · updated \(f.string(from: now))")]
            rows.append(Backdrop(NSRect(x: 0, y: 0, width: 292, height: 1), fill: NSColor(white: dark ? 1 : 0, alpha: 0.15)))
        }
        rows.append(TextRow("Refreshed 2s ago"))
        let panel = Backdrop(NSRect(x: 0, y: 0, width: 320, height: rows.reduce(16) { $0 + max($1.frame.height, 1) + ($1 is Backdrop ? 8 : 0) }),
                             fill: NSColor(white: dark ? 0.17 : 0.96, alpha: 1), radius: 12)
        var y: CGFloat = 8
        for v in rows {
            if v is Backdrop { y += 4; v.frame.origin = NSPoint(x: 14, y: y); y += 5 } else { v.frame.origin = NSPoint(x: 0, y: y); y += v.frame.height }
            panel.addSubview(v)
        }
        panel.appearance = look; save(panel, "dropdown-\(mode).png")
    }
    exit(0)
}
if CommandLine.arguments.contains("--print") { // debug: show what the app would display
    let h = FileManager.default.homeDirectoryForCurrentUser, now = Date()
    let c = (try? Data(contentsOf: h.appendingPathComponent(".claude/.usage.json"))).flatMap(parseClaude)
    let (liveX, note) = readCodexLive()
    let x = liveX ?? loadCodex(root: h.appendingPathComponent(".codex/sessions"))
    print("Codex source: \(liveX != nil ? "live" : "sessions (live: \(note))")")
    print("C \(label(c, now: now)) · X \(label(x, now: now))")
    let agy = readAgyLive()
    if agy.usage == nil { print("agy: \(agy.note)") }
    for (n, u) in [("Claude", c), ("Codex", x)] + agyGroups.compactMap({ g in agy.usage?[g.0].map { (g.1, Optional($0)) } }) { print(n, row("5h", u?.fiveHour, now: Date()), row("Week", u?.weekly, now: Date())) }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
