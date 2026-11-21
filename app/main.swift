// 宠物指针：菜单栏小 App，启动即把当前宠物皮肤的指针登记进系统，菜单里可切换宠物。
// 主题文件 theme.cursor 由 build.py 生成（plist：Cursors -> 标识 -> 帧数/热点/尺寸/各倍率 PNG）。
import AppKit
import ServiceManagement

// MARK: - 系统未公开接口（只用这三个）
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSRegisterCursorWithImages")
func CGSRegisterCursorWithImages(_ cid: Int32, _ name: UnsafeMutablePointer<CChar>, _ setGlobally: Bool,
                                 _ instantly: Bool, _ size: CGSize, _ hotSpot: CGPoint, _ frameCount: UInt,
                                 _ frameDuration: CGFloat, _ images: CFArray, _ seed: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CoreCursorUnregisterAll")
func CoreCursorUnregisterAll(_ cid: Int32) -> Int32

@_silgen_name("CGSCopyRegisteredCursorImages")
func CGSCopyRegisteredCursorImages(_ cid: Int32, _ name: UnsafeMutablePointer<CChar>, _ size: UnsafeMutablePointer<CGSize>,
                                   _ hot: UnsafeMutablePointer<CGPoint>, _ frames: UnsafeMutablePointer<UInt>,
                                   _ dur: UnsafeMutablePointer<CGFloat>, _ images: UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32

// MARK: - 宠物皮肤
// 一个皮肤 = 一个文件夹：theme.cursor（37 个指针）+ idle.plist（跳舞/睡觉）+ MenuIcon.png，文件夹名就是宠物名。
// 来源两处：App 内置（Resources/Skins），用户自己加的（~/Library/Application Support/OrangeCatCursor/Skins），同名时用户的优先。
struct Skin {
    let name: String
    let dir: URL
    let builtIn: Bool
    var theme: URL { dir.appendingPathComponent("theme.cursor") }
    var idle: URL { dir.appendingPathComponent("idle.plist") }
    var icon: URL { dir.appendingPathComponent("MenuIcon.png") }
}

enum Skins {
    static var userDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrangeCatCursor/Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func scan(_ dir: URL?, builtIn: Bool) -> [Skin] {
        guard let dir, let subs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return subs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.cursor").path) }
            .map { Skin(name: $0.lastPathComponent, dir: $0, builtIn: builtIn) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func all() -> [Skin] {
        let user = scan(userDir, builtIn: false)
        let builtIn = scan(Bundle.main.resourceURL?.appendingPathComponent("Skins"), builtIn: true)
            .filter { b in !user.contains { $0.name == b.name } }
        return builtIn + user
    }

    static var currentName: String {
        get { UserDefaults.standard.string(forKey: "skin") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skin") }
    }

    static func current() -> Skin? {
        let list = all()
        return list.first { $0.name == currentName } ?? list.first { $0.name == "橘猫" } ?? list.first
    }
}

// MARK: - 套用 / 恢复
enum Cursors {
    /// 系统原图备份：~/Library/Application Support/OrangeCatCursor/SystemDefault.plist
    static var backupURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrangeCatCursor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SystemDefault.plist")
    }

    static func loadCursors(_ url: URL?) -> [String: [String: Any]]? {
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return root["Cursors"] as? [String: [String: Any]]
    }

    /// 第一次套用前，把系统当前登记的原图存下来（只存一次，之后不覆盖）
    static func backupDefaultsIfNeeded(names: [String]) {
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        let cid = CGSMainConnectionID()
        var out: [String: Any] = [:]
        for name in names {
            var size = CGSize.zero, hot = CGPoint.zero, frames: UInt = 0, dur: CGFloat = 0
            var arr: Unmanaged<CFArray>?
            let err = name.withCString { p in
                CGSCopyRegisteredCursorImages(cid, UnsafeMutablePointer(mutating: p), &size, &hot, &frames, &dur, &arr)
            }
            guard err == 0, let images = arr?.takeRetainedValue() as? [CGImage], !images.isEmpty else { continue }
            let reps: [Data] = images.compactMap { img in
                let d = NSMutableData()
                guard let dst = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(dst, img, nil)
                return CGImageDestinationFinalize(dst) ? d as Data : nil
            }
            out[name] = ["PointsWide": size.width, "PointsHigh": size.height, "HotSpotX": hot.x, "HotSpotY": hot.y,
                         "FrameCount": frames, "FrameDuration": dur, "Representations": reps]
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: ["Cursors": out], format: .binary, options: 0) {
            try? data.write(to: backupURL)
        }
    }

    static func apply() -> (ok: Int, failed: [String]) {
        guard let cursors = loadCursors(Skins.current()?.theme) else {
            return (0, ["没有可用的宠物皮肤"])
        }
        backupDefaultsIfNeeded(names: Array(cursors.keys))
        return register(cursors)
    }

    static func register(_ cursors: [String: [String: Any]]) -> (ok: Int, failed: [String]) {
        let cid = CGSMainConnectionID()
        var ok = 0
        var failed: [String] = []
        for (name, c) in cursors {
            let decoded = (c["Representations"] as? [Data] ?? []).compactMap { d -> CGImage? in
                guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            let w = (c["PointsWide"] as? NSNumber)?.doubleValue ?? 32
            let h = (c["PointsHigh"] as? NSNumber)?.doubleValue ?? w
            let hx = (c["HotSpotX"] as? NSNumber)?.doubleValue ?? 0
            let hy = (c["HotSpotY"] as? NSNumber)?.doubleValue ?? 0
            var frames = (c["FrameCount"] as? NSNumber)?.uintValue ?? 1
            var dur = (c["FrameDuration"] as? NSNumber)?.doubleValue ?? 0
            var reps = decoded
            // 系统最多收 24 帧（系统原版转球有 30 帧）：隔帧抽取，时长相应拉长
            if frames > 24 {
                let step = Int((frames + 23) / 24)
                let keep = Int(frames) / step
                reps = decoded.compactMap { subsample($0, frames: Int(frames), step: step, keep: keep) }
                frames = UInt(keep)
                dur *= Double(step)
            }
            guard !reps.isEmpty else { failed.append(name); continue }
            var seed: Int32 = 0
            let err = name.withCString { p in
                CGSRegisterCursorWithImages(cid, UnsafeMutablePointer(mutating: p), true, true,
                                            CGSize(width: w, height: h), CGPoint(x: hx, y: hy),
                                            frames, CGFloat(dur), reps as CFArray, &seed)
            }
            if err == 0 { ok += 1 } else { failed.append("\(name)(\(err))") }
        }
        return (ok, failed.sorted())
    }

    /// 竖排多帧图隔 step 帧取一帧，拼成 keep 帧的新图
    static func subsample(_ img: CGImage, frames: Int, step: Int, keep: Int) -> CGImage? {
        let fh = img.height / frames
        guard fh > 0, let ctx = CGContext(data: nil, width: img.width, height: fh * keep, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for i in 0..<keep {
            // CGImage 坐标从上往下切，CGContext 从下往上画
            guard let f = img.cropping(to: CGRect(x: 0, y: i * step * fh, width: img.width, height: fh)) else { return nil }
            ctx.draw(f, in: CGRect(x: 0, y: (keep - 1 - i) * fh, width: img.width, height: fh))
        }
        return ctx.makeImage()
    }

    /// 先清掉所有登记，再把备份的系统原图登记回去（箭头、输入光标、转球这类清不掉的靠这一步）
    static func restore() -> (ok: Int, failed: [String]) {
        _ = CoreCursorUnregisterAll(CGSMainConnectionID())
        guard let saved = loadCursors(backupURL) else { return (0, ["没有系统原图备份"]) }
        return register(saved)
    }
}

// MARK: - 待机动画：鼠标 5 秒不动 → 跳舞 3 秒 → 睡觉，一动就恢复
// 做法：系统指针不动它（后台程序换了登记的指针，屏幕不会刷新），而是先把指针藏起来，
// 在指针原位置放一个点击可穿透的透明小窗口播动画；一动鼠标就收窗口、显示指针。
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

// 系统设置 → 辅助功能 → 显示 → 指针大小 的倍数（1 = 默认）。登记的指针由系统自动放大，小窗口要自己乘
@_silgen_name("CGSGetCursorScale")
func CGSGetCursorScale(_ cid: Int32, _ scale: UnsafeMutablePointer<Float>) -> Int32

final class IdleCat {
    enum State: String { case normal, dance, sleep }
    static let idleAfter: TimeInterval = 5
    static let danceFor: TimeInterval = 3
    private(set) var state = State.normal
    private var stateStart = Date()
    private var pollTimer: Timer?
    private var animTimer: Timer?
    private var monitor: Any?
    private var cursorHidden = false
    private var frames: [State: (images: [NSImage], dur: Double)] = [:]
    private var size = NSSize(width: 40, height: 40)
    private var hot = CGPoint.zero
    private lazy var imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                      // 点击直接穿过
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        w.contentView = imageView
        return w
    }()

    init() { load(Skins.current()?.idle) }

    /// 换皮肤时重新读跳舞/睡觉帧
    func load(_ url: URL?) {
        frames = [:]
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return }
        for (key, st) in [("dance", State.dance), ("sleep", State.sleep)] {
            guard let e = root[key], let reps = e["Representations"] as? [Data], reps.count > 1,
                  let n = (e["FrameCount"] as? NSNumber)?.intValue, n > 0 else { continue }
            let w = (e["PointsWide"] as? NSNumber)?.doubleValue ?? 40
            size = NSSize(width: w, height: w)
            hot = CGPoint(x: (e["HotSpotX"] as? NSNumber)?.doubleValue ?? 0, y: (e["HotSpotY"] as? NSNumber)?.doubleValue ?? 0)
            // 用最大的一张（4 倍图），指针调大后放大也清楚；竖排多帧切开
            guard let src = CGImageSourceCreateWithData(reps[reps.count - 1] as CFData, nil),
                  let sheet = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let fh = sheet.height / n
            let imgs = (0..<n).compactMap { i -> NSImage? in
                guard let f = sheet.cropping(to: CGRect(x: 0, y: i * fh, width: sheet.width, height: fh)) else { return nil }
                return NSImage(cgImage: f, size: size)
            }
            frames[st] = (imgs, (e["FrameDuration"] as? NSNumber)?.doubleValue ?? 0.2)
        }
        imageView.frame = NSRect(origin: .zero, size: size)
    }

    var available: Bool { frames[.dance] != nil && frames[.sleep] != nil }

    /// 系统指针放大倍数；读不到时按 1 处理
    static func cursorScale() -> CGFloat {
        var s: Float = 1
        guard CGSGetCursorScale(CGSMainConnectionID(), &s) == 0, s >= 1, s <= 16 else { return 1 }
        return CGFloat(s)
    }

    /// 鼠标多久没动（移动、点击、滚轮、拖动里最近的一次）
    static func mouseIdle() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// 屏幕上现在显示的是不是「正常」箭头（停在文字上是输入光标时不触发）
    static func showingArrow(hot: CGPoint, size: NSSize) -> Bool {
        guard let c = NSCursor.currentSystem else { return false }
        return abs(c.hotSpot.x - hot.x) < 0.5 && abs(c.hotSpot.y - hot.y) < 0.5 && abs(c.image.size.width - size.width) < 0.5
    }

    func start() {
        guard available, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        // 一动鼠标立刻醒（看鼠标事件不需要额外授权）
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                               .leftMouseDragged, .rightMouseDragged, .scrollWheel]) { [weak self] _ in
            if self?.state != .normal { self?.wake() }
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        wake()
    }

    private func tick() {
        let idle = IdleCat.mouseIdle()
        log(idle)
        switch state {
        case .normal:
            if idle >= IdleCat.idleAfter, IdleCat.showingArrow(hot: hot, size: size) { enter(.dance) }
        case .dance:
            if idle < 0.3 { wake() } else if Date().timeIntervalSince(stateStart) >= IdleCat.danceFor { enter(.sleep) }
        case .sleep:
            if idle < 0.3 { wake() }
        }
    }

    func enter(_ s: State) {
        guard let f = frames[s] else { return }
        // 窗口左上角对齐「指针尖」：鼠标位置减去点击点（屏幕坐标原点在左下）
        // 尺寸和点击点都乘系统指针倍数，跟放大后的指针一样大，进出跳舞不跳变
        let loc = NSEvent.mouseLocation, k = IdleCat.cursorScale()
        let w = size.width * k, h = size.height * k
        window.setFrame(NSRect(x: loc.x - hot.x * k, y: loc.y + hot.y * k - h, width: w, height: h), display: false)
        imageView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        var i = 0
        imageView.image = f.images[0]
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: f.dur, repeats: true) { [weak self] _ in
            i = (i + 1) % f.images.count
            self?.imageView.image = f.images[i]
        }
        window.orderFrontRegardless()
        if !cursorHidden {
            let cid = CGSMainConnectionID()
            _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            CGDisplayHideCursor(CGMainDisplayID())
            cursorHidden = true
        }
        state = s
        stateStart = Date()
    }

    func wake() {
        animTimer?.invalidate(); animTimer = nil
        window.orderOut(nil)
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        state = .normal
        stateStart = Date()
    }

    // 排查用：ORANGECAT_DEBUG=1 时每次检查写一行日志
    private let debug = ProcessInfo.processInfo.environment["ORANGECAT_DEBUG"] == "1"
    private lazy var logHandle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OrangeCatCursor-debug.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    private func log(_ idle: TimeInterval) {
        guard debug else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = String(format: "%@ idle=%.2f state=%@ arrow=%@ hidden=%@ window=%@\n", f.string(from: Date()), idle,
                          state.rawValue, IdleCat.showingArrow(hot: hot, size: size) ? "y" : "n",
                          cursorHidden ? "y" : "n", window.isVisible ? "y" : "n")
        logHandle?.seekToEndOfFile(); logHandle?.write(line.data(using: .utf8)!)
    }
}

// MARK: - 菜单栏
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let idleCat = IdleCat()
    private let idleKey = "idleAnimation"
    private var idleOn: Bool {
        get { UserDefaults.standard.object(forKey: idleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: idleKey) }
    }
    private var item: NSStatusItem!
    private let appName = "宠物指针"
    private let enabledKey = "enabled"
    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // 命令行自检：--apply / --restore 跑完即退出，供脚本验证
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--skin"), i + 1 < args.count { Skins.currentName = args[i + 1]; idleCat.load(Skins.current()?.idle) }
        if args.contains("--skins") {
            print("skins:", Skins.all().map { "\($0.name)\($0.builtIn ? "" : "(自己加的)")" }, "current:", Skins.current()?.name ?? "无"); exit(0)
        }
        // 自检：--make-skin <总图> --name 名字 --out 目录 [--dump 切图目录]：总图生成宠物文件夹
        if let i = args.firstIndex(of: "--make-skin"), i + 1 < args.count {
            func val(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            do {
                let t0 = Date()
                let r = try SkinMaker.render(sheet: URL(fileURLWithPath: args[i + 1]))
                let skin = try SkinMaker.write(r, name: val("--name") ?? "新宠物", to: URL(fileURLWithPath: val("--out") ?? "."))
                if let d = val("--dump") { try SkinMaker.dump(r, to: URL(fileURLWithPath: d)) }
                print("skin:", skin.path, String(format: "%.1fs", Date().timeIntervalSince(t0)))
            } catch { print("error:", error.localizedDescription); exit(1) }
            exit(0)
        }
        if args.contains("--apply") { report(Cursors.apply()); exit(0) }
        if args.contains("--restore") { report(Cursors.restore()); exit(0) }
        // 自检：--idle dance|sleep|normal 直接切到对应待机状态
        if let i = args.firstIndex(of: "--idle"), i + 1 < args.count {
            let s: IdleCat.State = args[i + 1] == "sleep" ? .sleep : .dance
            print("available:", idleCat.available)
            self.idleCat.enter(s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let pid = ProcessInfo.processInfo.processIdentifier
                let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
                print("state:", self.idleCat.state.rawValue, "on-screen windows:", wins.map { $0[kCGWindowBounds as String] ?? "" },
                      "mouse:", NSEvent.mouseLocation)
                self.idleCat.wake()
                print("after wake state:", self.idleCat.state.rawValue)
                exit(0)
            }
            return
        }
        if args.contains("--login-on") || args.contains("--login-off") {
            do {
                if args.contains("--login-on") { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { print("login error:", error.localizedDescription) }
            print("login status:", SMAppService.mainApp.status.rawValue, "(0 未注册 1 已启用 2 需用户批准 3 找不到)")
            exit(0)
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
        if enabled {
            _ = Cursors.apply()
            if idleOn { idleCat.start() }
        }

        // 睡眠唤醒、切换用户回来后系统可能把指针还原，重新套一次
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard self?.enabled == true else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { _ = Cursors.apply() }
            }
        }
    }

    private func report(_ r: (ok: Int, failed: [String])) {
        print("applied:", r.ok, "failed:", r.failed)
    }

    private func updateIcon() {
        if let url = Skins.current()?.icon, let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            item.button?.image = img; item.button?.title = ""
        } else {
            item.button?.image = nil; item.button?.title = "🐾"
        }
    }

    // 每次打开菜单都重新扫描皮肤，新加的宠物不用重启 App
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(into: menu) }

    private func rebuildMenu() {
        let m = NSMenu(); m.delegate = self
        rebuildMenu(into: m)
        item.menu = m
    }

    private func rebuildMenu(into m: NSMenu) {
        m.removeAllItems()
        let toggle = NSMenuItem(title: enabled ? "恢复系统指针" : "使用宠物指针", action: #selector(toggleCursor), keyEquivalent: "")
        toggle.target = self
        m.addItem(toggle)
        // 切换宠物
        let pets = NSMenu()
        let cur = Skins.current()?.name
        for s in Skins.all() {
            let it = NSMenuItem(title: s.name, action: #selector(pickSkin(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = s.name
            it.state = s.name == cur ? .on : .off
            if let img = NSImage(contentsOf: s.icon) { img.size = NSSize(width: 16, height: 16); it.image = img }
            pets.addItem(it)
        }
        pets.addItem(.separator())
        let add = NSMenuItem(title: "添加宠物…", action: #selector(addSkin), keyEquivalent: "")
        add.target = self; pets.addItem(add)
        let pr = NSMenuItem(title: "复制出图提示词", action: #selector(copyPrompt), keyEquivalent: "")
        pr.target = self; pets.addItem(pr)
        let open = NSMenuItem(title: "打开宠物文件夹", action: #selector(openSkins), keyEquivalent: "")
        open.target = self; pets.addItem(open)
        let petsItem = NSMenuItem(title: "切换宠物", action: nil, keyEquivalent: "")
        petsItem.submenu = pets
        m.addItem(petsItem)
        if idleCat.available {
            let idle = NSMenuItem(title: "鼠标不动时跳舞", action: #selector(toggleIdle), keyEquivalent: "")
            idle.target = self
            idle.state = idleOn ? .on : .off
            idle.isEnabled = enabled
            m.addItem(idle)
        }
        let login = NSMenuItem(title: "开机自动启用", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出（指针保持不变）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
    }

    @objc private func pickSkin(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchTo(name)
    }

    private func switchTo(_ name: String) {
        Skins.currentName = name
        idleCat.stop()
        idleCat.load(Skins.current()?.idle)
        if enabled {
            _ = Cursors.apply()
            if idleOn { idleCat.start() }
        }
        updateIcon()
        rebuildMenu()
    }

    /// 添加宠物：选一张 AI 画好的总图（App 自己生成），或别人分享的宠物文件夹
    @objc private func addSkin() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.allowedContentTypes = [.png, .jpeg, .webP, .folder]
        p.message = "选一张 AI 画好的宠物总图（4 列 5 行），或别人分享的宠物文件夹"
        guard p.runModal() == .OK, let src = p.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
        if isDir.boolValue {
            guard FileManager.default.fileExists(atPath: src.appendingPathComponent("theme.cursor").path) else {
                alert("这个文件夹不是宠物", "宠物文件夹里要有 theme.cursor。要用自己的宠物，请选 AI 画好的那张总图。"); return
            }
            let dst = Skins.userDir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            do { try FileManager.default.copyItem(at: src, to: dst) } catch { alert("没能添加", error.localizedDescription); return }
            switchTo(src.lastPathComponent); return
        }
        guard let name = askName(), !name.isEmpty else { return }
        item.button?.title = "…"; item.button?.image = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SkinMaker.write(try SkinMaker.render(sheet: src), name: name, to: Skins.userDir) }
            DispatchQueue.main.async {
                switch result {
                case .success: self.switchTo(name)
                case .failure(let e): self.updateIcon(); self.alert("没能生成宠物", e.localizedDescription)
                }
            }
        }
    }

    private func askName() -> String? {
        let a = NSAlert()
        a.messageText = "给这只宠物起个名字"
        a.informativeText = "会显示在「切换宠物」菜单里。同名会替换掉原来那只。"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.placeholderString = "比如：团子"
        a.accessoryView = f
        a.addButton(withTitle: "生成"); a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }

    private func alert(_ title: String, _ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = msg; a.runModal()
    }

    @objc private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SkinMaker.prompt, forType: .string)
        alert("出图提示词已复制", """
        1. 打开 ChatGPT、豆包或 Gemini，上传宠物照片，粘贴提示词。
        2. 把方括号里那句换成你的宠物（品种、毛色、特征），图片比例选 4:5 竖图。
        3. 检查生成的图：20 只是同一只、4 列 5 行排齐、彼此不挨着、纯色背景。不合格就重新生成。
        4. 存下图片，回到这里点「切换宠物 → 添加宠物…」选这张图。
        """)
    }

    @objc private func openSkins() { NSWorkspace.shared.open(Skins.userDir) }

    @objc private func toggleCursor() {
        if enabled {
            idleCat.stop()
            _ = Cursors.restore()
        } else {
            _ = Cursors.apply()
            if idleOn { idleCat.start() }
        }
        enabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleIdle() {
        idleOn.toggle()
        if idleOn { idleCat.start() } else { idleCat.stop() }
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "没能设置开机启动"
            a.informativeText = "可以到 系统设置 > 通用 > 登录项 里手动添加「\(appName)」。\n\(error.localizedDescription)"
            a.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // 退出时如果正在跳舞或睡觉，先换回静止箭头，免得一直停在动画上
    func applicationWillTerminate(_ n: Notification) { idleCat.stop() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 只在菜单栏出现，不占程序坞
app.run()
