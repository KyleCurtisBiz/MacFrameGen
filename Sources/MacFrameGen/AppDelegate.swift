import AppKit
import AVFoundation
import ScreenCaptureKit

/// The window, the menus and the glue between the capture card and the engine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let options: Options
    private var window: NSWindow!
    private let layer = AVSampleBufferDisplayLayer()
    private var engine: Engine!
    private var card: CardSource?
    private var activeDevice: AVCaptureDevice?
    private var starting = false

    private var hud: HUD!
    private let message = NSTextField(wrappingLabelWithString: "")
    private var measuring = false
    private var selfTestSeconds = 0
    private var silentSeconds = 0, blackSeconds = 0, warning: String?
    private var stressTimer: Timer?

    private var logHandle: FileHandle?
    private var statsTimer: Timer?, layoutTimer: Timer?
    private var link: CADisplayLink?
    private let sourceMenu = NSMenu(title: "Source")
    private let defaults = UserDefaults.standard

    private enum Key {
        static let gen = "frameGeneration", upscale = "upscaler", turbo = "turbo", even = "evenPacing", display = "showDisplay", detail = "detailedStats", device = "deviceID"
    }
    private static let noCard = "No capture card found.\n\nPlug in a USB HDMI capture card. It will start by itself."

    init(options: Options) { self.options = options }

    // MARK: Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        openLog()
        buildWindow()
        buildMenus()

        defaults.register(defaults: [Key.gen: true, Key.upscale: true, Key.turbo: true, Key.even: true, Key.display: true, Key.detail: false])
        engine = Engine(layer: layer)
        engine.genOn = defaults.bool(forKey: Key.gen)
        engine.upscaleOn = defaults.bool(forKey: Key.upscale) && !options.has("--no-upscale")
        engine.turbo = defaults.bool(forKey: Key.turbo) && !options.has("--no-turbo")
        engine.evenPacing = defaults.bool(forKey: Key.even) && options.value("--pacing") != "immediate"
        hud.visible = defaults.bool(forKey: Key.display); hud.detailed = defaults.bool(forKey: Key.detail)
        if let p = options.value("--frames") {
            FileManager.default.createFile(atPath: p, contents: nil)
            engine.frameLog = FileHandle(forWritingAtPath: p)
        }

        // Plain letter keys while the window is in front (the menus show the same letters).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let key = e.charactersIgnoringModifiers?.lowercased() ?? "", mods = e.modifierFlags
            let used = MainActor.assumeIsolated { self?.handleKey(key, mods) ?? false }
            return used ? nil : e
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statsTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(statsTick), userInfo: nil, repeats: true)

        if options.has("--selftest") { runSelfTest(); return }

        layoutTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateOutputSize), userInfo: nil, repeats: true)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(deviceConnected(_:)), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        nc.addObserver(self, selector: #selector(deviceDisconnected(_:)), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        // A capture session does not always come back by itself after the Mac sleeps or the card hiccups.
        nc.addObserver(self, selector: #selector(restartDevice), name: AVCaptureSession.runtimeErrorNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restartDevice), name: NSWorkspace.didWakeNotification, object: nil)
        startPreferredDevice()
    }

    func applicationWillTerminate(_ n: Notification) { engine?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    private func openLog() {
        // One stats line per second. The file starts fresh on every launch.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacFrameGen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = options.value("--log") ?? dir.appendingPathComponent("macframegen.log").path
        FileManager.default.createFile(atPath: p, contents: nil)
        logHandle = FileHandle(forWritingAtPath: p)
    }

    private func log(_ s: String) {
        print(s)
        if let h = logHandle, let d = (s + "\n").data(using: .utf8) { h.write(d) }
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1280, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "MacFrameGen"
        w.collectionBehavior = [.fullScreenPrimary]
        w.backgroundColor = .black
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor
        // Keep the picture's shape: a 16:9 picture on a 16:10 screen gets thin black bars in full screen.
        layer.videoGravity = .resizeAspect; layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(layer)

        message.font = .systemFont(ofSize: 18, weight: .medium)
        message.textColor = .white; message.alignment = .center
        message.frame = NSRect(x: 40, y: v.bounds.midY - 60, width: v.bounds.width - 80, height: 120)
        message.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        message.isHidden = true
        v.addSubview(message)
        w.contentView = v
        window = w
        hud = HUD(in: v)

        // Asks the display for 120 Hz where it has it, so a frame handed over is shown within about 8 ms.
        let dl = v.displayLink(target: self, selector: #selector(displayTick(_:)))
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        dl.add(to: .main, forMode: .common)
        link = dl
    }
    @objc private func displayTick(_ l: CADisplayLink) {}

    private func showMessage(_ s: String?) {
        message.stringValue = s ?? ""
        message.isHidden = s == nil
    }

    private func fail(_ msg: String) {
        log("FATAL: " + msg)
        let al = NSAlert(); al.messageText = "MacFrameGen"; al.informativeText = msg
        al.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Capture device

    private func startPreferredDevice() {
        let all = CardSource.devices(includeBuiltIn: options.has("--include-built-in"))
        var pick: AVCaptureDevice?
        if let want = options.value("--device")?.lowercased() { pick = all.first { $0.localizedName.lowercased().contains(want) } }
        else if let saved = defaults.string(forKey: Key.device) { pick = all.first { $0.uniqueID == saved } }
        if let d = pick ?? all.first { start(d) } else { showMessage(AppDelegate.noCard) }
    }

    private func start(_ device: AVCaptureDevice) {
        guard !starting else { return }
        starting = true
        showMessage("Starting \(device.localizedName)...")
        Task {
            defer { starting = false }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                fail("Camera permission is needed to read the capture card.\n\nOpen System Settings > Privacy & Security > Camera, switch on MacFrameGen, then start it again.")
                return
            }
            _ = await AVCaptureDevice.requestAccess(for: .audio)     // for the card's sound; video still works if refused
            let c = CardSource()
            do { try engine.start(card: c, device: device) } catch {
                activeDevice = nil; card = nil
                showMessage("Could not start \(device.localizedName):\n\(error.localizedDescription)")
                log("could not start \(device.localizedName): \(error.localizedDescription)")
                return
            }
            card = c; activeDevice = device
            log("capture device: " + c.summary)
            log("modes offered: " + CardSource.formats(of: device).map { $0.description }.joined(separator: " | "))
            log("processing at \(engine.width)x\(engine.height)")
            if c.summary.contains("COMPRESSED") { log("warning: this device only offers compressed video at its best mode; expect extra delay") }
            window.contentAspectRatio = NSSize(width: engine.width, height: engine.height)
            showMessage(nil)
            hud.live = true
            updateOutputSize()
        }
    }

    @objc private func selectDevice(_ item: NSMenuItem) {
        guard let d = item.representedObject as? AVCaptureDevice, d != activeDevice else { return }
        defaults.set(d.uniqueID, forKey: Key.device)
        start(d)
    }
    @objc private func restartDevice() {
        guard let d = activeDevice else { return }
        log("restarting \(d.localizedName)")
        start(d)
    }
    @objc private func deviceConnected(_ n: Notification) { if activeDevice == nil { startPreferredDevice() } }
    @objc private func deviceDisconnected(_ n: Notification) {
        guard let d = n.object as? AVCaptureDevice, d == activeDevice else { return }
        engine.stop(); activeDevice = nil; card = nil; hud.live = false
        log("capture device disconnected")
        showMessage(AppDelegate.noCard)
    }

    // MARK: Timers

    @objc private func statsTick() {
        guard activeDevice != nil || options.has("--selftest") else { return }
        let s = engine.takeStats()
        hud.update(s)
        log(s.line)
        checkSignal(s)
        if options.has("--selftest") { selfTestSeconds += 1; if selfTestSeconds >= Int(options.value("--selftest-seconds") ?? "") ?? 6 { NSApp.terminate(nil) } }
    }

    /// Says so on screen when the card is connected but nothing useful is coming from it.
    private func checkSignal(_ s: Engine.Stats) {
        guard let d = activeDevice, !starting else { silentSeconds = 0; blackSeconds = 0; return }
        silentSeconds = s.arrived == 0 ? silentSeconds + 1 : 0
        blackSeconds = (s.arrived > 0 && s.brightness < 20) ? blackSeconds + 1 : 0
        var w: String?
        if silentSeconds >= 3 {
            w = "No picture from \(d.localizedName).\n\nCheck the HDMI cable and that the console is switched on."
        } else if blackSeconds >= 12 {
            // Long enough that an ordinary loading screen does not trigger it.
            w = "The picture is black.\n\nIf it stays black, the console may be sending copy-protected video. On a PlayStation, turn HDCP off in Settings > System > HDMI."
        }
        if w != warning {
            warning = w
            showMessage(w)
            if let w { log("warning: " + w.replacingOccurrences(of: "\n", with: " ")) }
        }
    }

    /// Aims the upscaler at the largest box of the picture's shape that fits the window, in real pixels.
    @objc private func updateOutputSize() {
        guard let v = window.contentView, engine.height > 0 else { return }
        let sc = window.screen?.backingScaleFactor ?? 2
        let aspect = CGFloat(engine.width) / CGFloat(engine.height)
        let w = min(v.bounds.width, v.bounds.height * aspect)
        engine.setOutputPixels(Int(w * sc), Int(w / aspect * sc))
    }

    private func runSelfTest() {
        let fps = Double(options.value("--selftest-fps") ?? "") ?? 30
        let size = (options.value("--selftest-size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let (w, h) = size.count == 2 ? (size[0], size[1]) : (1920, 1080)
        do { try engine.startSelfTest(file: options.value("--selftest-file"), fps: fps, width: w, height: h) } catch { fail("self-test: \(error.localizedDescription)"); return }
        engine.setOutputPixels(3024, 1702)      // a 14-inch MacBook Pro's full-screen 16:9 box
        hud.live = true
        log("self-test: \(Int(fps)) fps in a 60 Hz stream at \(engine.width)x\(engine.height), upscaling to 3024x1702")
        if options.has("--selftest-stress") {
            // Tears the pipeline down and rebuilds it while frames are flowing, as switching capture devices does.
            stressTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(stressTick), userInfo: nil, repeats: true)
        }
    }

    @objc private func stressTick() {
        let fps = Double(options.value("--selftest-fps") ?? "") ?? 30
        do { try engine.startSelfTest(fps: fps, width: engine.width, height: engine.height) } catch { log("stress: restart failed: \(error.localizedDescription)") }
    }

    // MARK: Controls

    private func handleKey(_ key: String, _ mods: NSEvent.ModifierFlags) -> Bool {
        guard mods.intersection([.command, .control, .option]).isEmpty else { return false }
        switch key {
        case "g": toggleGen()
        case "u": toggleUpscale()
        case "a": toggleSound()
        case "s": toggleDisplay()
        case "f": window.toggleFullScreen(nil)
        default: return false
        }
        return true
    }

    @objc private func toggleGen() { engine.genOn.toggle(); defaults.set(engine.genOn, forKey: Key.gen); hud.say("Frame generation \(engine.genOn ? "on" : "off")") }
    @objc private func toggleUpscale() { engine.upscaleOn.toggle(); defaults.set(engine.upscaleOn, forKey: Key.upscale); hud.say("Upscaler \(engine.upscaleOn ? "on" : "off")") }
    @objc private func toggleTurbo() { engine.turbo.toggle(); defaults.set(engine.turbo, forKey: Key.turbo); hud.say("Fast generation \(engine.turbo ? "on" : "off")") }
    @objc private func togglePacing() { engine.evenPacing.toggle(); defaults.set(engine.evenPacing, forKey: Key.even); hud.say("Even frame pacing \(engine.evenPacing ? "on" : "off")") }
    @objc private func toggleDisplay() {
        hud.visible.toggle(); defaults.set(hud.visible, forKey: Key.display)
        if !hud.visible { hud.say("Display hidden (S to show)") }
    }
    @objc private func toggleDetail() { hud.detailed.toggle(); defaults.set(hud.detailed, forKey: Key.detail) }
    @objc private func toggleSound() {
        guard let a = card?.audioOut else { return }
        a.volume = a.volume > 0 ? 0 : 1
        log("sound \(a.volume > 0 ? "on" : "off")")
        hud.say("Sound \(a.volume > 0 ? "on" : "off")")
    }

    /// Times what really reaches the screen for 10 seconds, then shows and logs the result.
    @objc private func measure() {
        guard !measuring, window.isVisible else { return }
        measuring = true
        hud.say("Measuring what reaches the screen...", seconds: 10)
        Task {
            guard await startProbe() else {
                finishMeasure("Needs Screen Recording permission (System Settings > Privacy & Security)", "on-screen measurement: no Screen Recording permission")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let r = await engine.finishProbe()
            finishMeasure(r.short, r.full)
        }
    }
    private func finishMeasure(_ short: String, _ full: String) {
        log(full); hud.say(short, seconds: 8); measuring = false
    }
    private func startProbe() async -> Bool {
        let num = CGWindowID(window.windowNumber)
        for _ in 0..<10 {
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let w = c.windows.first(where: { $0.windowID == num }) {
                return await engine.startOutputProbe(window: w)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        func add(_ m: NSMenu) { let i = NSMenuItem(); i.submenu = m; main.addItem(i) }
        func item(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String, bare: Bool = true, target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if bare { i.keyEquivalentModifierMask = [] }
            i.target = target
            m.addItem(i)
        }
        let appMenu = NSMenu()
        item(appMenu, "About MacFrameGen", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", bare: false)
        appMenu.addItem(.separator())
        item(appMenu, "Hide MacFrameGen", #selector(NSApplication.hide(_:)), "h", bare: false)
        item(appMenu, "Quit MacFrameGen", #selector(NSApplication.terminate(_:)), "q", bare: false)
        add(appMenu)

        let c = NSMenu(title: "Controls")
        item(c, "Frame Generation", #selector(toggleGen), "g", target: self)
        item(c, "Upscaler", #selector(toggleUpscale), "u", target: self)
        item(c, "Sound", #selector(toggleSound), "a", target: self)
        c.addItem(.separator())
        item(c, "Show Frame Rate", #selector(toggleDisplay), "s", target: self)
        add(c)

        // Things nobody needs while playing: they exist for diagnosing problems and for experiments.
        let adv = NSMenu(title: "Advanced")
        item(adv, "Fast Generation (keeps one CPU core busy)", #selector(toggleTurbo), "", bare: false, target: self)
        item(adv, "Even Frame Pacing", #selector(togglePacing), "", bare: false, target: self)
        adv.addItem(.separator())
        item(adv, "Show Detailed Numbers", #selector(toggleDetail), "", bare: false, target: self)
        item(adv, "Measure What Reaches the Screen (10 s)", #selector(measure), "", bare: false, target: self)
        add(adv)

        sourceMenu.delegate = self
        add(sourceMenu)

        let w = NSMenu(title: "Window")
        item(w, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", bare: false)
        item(w, "Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
        add(w)
        NSApp.mainMenu = main
        NSApp.windowsMenu = w
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sourceMenu else { return }
        menu.removeAllItems()
        let all = CardSource.devices(includeBuiltIn: options.has("--include-built-in"))
        if all.isEmpty {
            let i = NSMenuItem(title: "No capture card found", action: nil, keyEquivalent: ""); i.isEnabled = false
            menu.addItem(i)
        }
        for d in all {
            let i = NSMenuItem(title: d.localizedName, action: #selector(selectDevice(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = d; i.state = d == activeDevice ? .on : .off
            menu.addItem(i)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleGen): item.state = engine.genOn ? .on : .off
        case #selector(toggleUpscale): item.state = engine.upscaleOn ? .on : .off
        case #selector(toggleTurbo): item.state = engine.turbo ? .on : .off
        case #selector(togglePacing): item.state = engine.evenPacing ? .on : .off
        case #selector(toggleDisplay): item.state = hud.visible ? .on : .off
        case #selector(toggleDetail): item.state = hud.detailed ? .on : .off
        case #selector(toggleSound):
            item.state = (card?.audioOut?.volume ?? 0) > 0 ? .on : .off
            return card?.audioOut != nil
        case #selector(measure): return !measuring
        default: break
        }
        return true
    }
}
