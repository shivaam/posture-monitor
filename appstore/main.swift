// main.swift — App Store / Vision-only PostureMonitor.
// Apple Vision only (no server, no MediaPipe, no network). Lives in the menu bar;
// can run a window or quietly in the background. Continuous or periodic checking,
// with pick-your-style alerts (sound / screen-edge glow / banner).

import AppKit
import AVFoundation

func plog(_ s: String) {
    FileHandle.standardError.write(("[posture] " + s + "\n").data(using: .utf8) ?? Data())
}

// MARK: - State for the window UI

struct UIState {
    var palette: Palette
    var title: String
    var subtitle: String
}

// MARK: - Model (detection + alerts + modes)

final class AppModel {
    enum Mode: String { case continuous, periodic }

    let vision = VisionEngine()
    let logic = PostureLogic()
    var config = Config.load()

    var muted = false
    var paused = false
    var slouchThresh: Double
    var graceSec: Double
    var mode: Mode
    var intervalMin: Double
    var needsTwo: Bool
    var alertSound: Bool, alertFlash: Bool, alertBanner: Bool

    private var baseHeadY: Double?
    private var emaHeadY = 0.0
    private var slouchState = false
    private var slouchSince: Double?
    private var lastAlert = -1e9
    private var lastFaceSeen = -1e9     // for bridging brief face-detection dropouts
    private var wasAlerted = false      // a nudge fired this slouch episode → chime on recovery
    private let synth = AVSpeechSynthesizer()

    // Periodic state machine.
    private enum Phase { case calibrating, idle, sampling, watching }
    private var phase: Phase = .calibrating
    private var ticker: Timer?
    private var nextSampleAt = 0.0
    private var sampleUntil = 0.0
    private var burstPresent = 0, burstSlouch = 0
    private var consecutive = 0

    var calibrated: Bool { logic.calibrated }

    var onUpdate: ((UIState) -> Void)?
    var onFace: ((VisionReading) -> Void)?
    var onModeStatus: ((Palette, String, String) -> Void)?     // background status (camera off)
    var onAlert: ((String, Bool, Bool, Bool) -> Void)?         // message, good, flash, banner

    init() {
        slouchThresh = config.slouchThresh
        graceSec = config.slouchGrace
        mode = Mode(rawValue: config.monitorMode) ?? .continuous
        intervalMin = config.sampleIntervalMin
        needsTwo = config.periodicNeedsTwo
        alertSound = config.alertSound; alertFlash = config.alertFlash; alertBanner = config.alertBanner
        vision.onVision = { [weak self] r in self?.feed(r) }
    }

    private var napGuard: NSObjectProtocol?
    func start() {
        // Block App Nap so detection keeps running with the window CLOSED / app in the
        // background. .userInitiatedAllowingIdleSystemSleep prevents the nap but still
        // lets the Mac idle-sleep normally when you step away.
        napGuard = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Posture monitoring")
        vision.start()
    }

    func recalibrate() {
        logic.recalibrate(); baseHeadY = nil; slouchState = false; slouchSince = nil
        phase = .calibrating; vision.resumeCamera()
        plog("recalibrating")
    }

    func applyMode() {
        ticker?.invalidate(); ticker = nil
        if mode == .continuous {
            vision.resumeCamera()
            plog("mode -> continuous")
        } else {
            phase = logic.calibrated ? .idle : .calibrating
            if phase == .idle { nextSampleAt = ProcessInfo.processInfo.systemUptime + 3; vision.stopCamera() }
            else { vision.resumeCamera() }
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            plog("mode -> periodic every \(Int(intervalMin))m")
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if paused {
            if phase != .calibrating { vision.stopCamera() }
            onModeStatus?(.away, "Paused", "monitoring is off")
            return
        }
        switch phase {
        case .calibrating:
            if logic.calibrated { phase = .idle; nextSampleAt = now + 3; vision.stopCamera() }
            else { onModeStatus?(.settling, "Calibrating", "sit up tall…") }
        case .idle:
            if now >= nextSampleAt { beginSample() }
            else {
                let m = max(1, Int(ceil((nextSampleAt - now) / 60)))
                onModeStatus?(.good, "Good posture ✓", "next check in \(m)m")
            }
        case .sampling:
            if now >= sampleUntil { endSample() }
        case .watching:
            vision.resumeCamera()   // keep the camera on while actively coaching (feed() drives it)
        }
    }

    private func beginSample() {
        phase = .sampling; burstPresent = 0; burstSlouch = 0
        vision.resumeCamera()
        sampleUntil = ProcessInfo.processInfo.systemUptime + max(2, config.sampleSeconds)
        onModeStatus?(.settling, "Checking…", "camera on briefly")
        plog("periodic: sampling")
    }

    private func endSample() {
        let now = ProcessInfo.processInfo.systemUptime
        let mins = Int(intervalMin)
        if burstPresent == 0 {
            consecutive = 0; vision.stopCamera(); phase = .idle
            nextSampleAt = now + max(60, intervalMin * 60)
            onModeStatus?(.away, "Away", "next check in \(mins)m"); return
        }
        // Decide on your CURRENT posture at the end of the check, not the burst average —
        // a slouch that starts late in the sample must not get out-voted and let the camera
        // sleep. slouchState is the (smoothed) state of the most recent frames.
        let slouchingNow = logic.calibrated && slouchState
        let majoritySlouch = burstSlouch * 2 > burstPresent
        if slouchingNow || majoritySlouch {
            consecutive += 1
            plog("periodic: slouch now=\(slouchingNow) maj \(burstSlouch)/\(burstPresent) streak \(consecutive)")
            // If you're slouching right now, watch immediately. Only the "recovered before the
            // sample ended" case (majority-only) waits for a 2nd confirming check.
            if slouchingNow || !needsTwo || consecutive >= 2 {
                consecutive = 0; phase = .watching; slouchSince = nil
                onModeStatus?(.slouching, "Slouching", "watching — sit up tall")
            } else {
                vision.stopCamera(); phase = .idle; nextSampleAt = now + 60
                onModeStatus?(.settling, "Re-checking soon", "again in 1m")
            }
        } else {
            consecutive = 0
            if wasAlerted { wasAlerted = false; fireAlert("Nice — back to good posture", good: true) }
            vision.stopCamera(); phase = .idle
            nextSampleAt = now + max(60, intervalMin * 60)
            onModeStatus?(.good, "Good posture ✓", "next check in \(mins)m")
        }
    }

    private func feed(_ r: VisionReading) {
        onFace?(r)
        let now = ProcessInfo.processInfo.systemUptime
        if r.faceFound { lastFaceSeen = now }
        let faceNow = r.faceFound && !paused
        // Bridge brief face-detection dropouts. When you slouch, your head dips/turns and
        // Apple Vision loses your face for a frame or two — without this, `present` flickers
        // false, which resets the grace timer and the nudge never fires ("keeps pending").
        let present = !paused && (now - lastFaceSeen <= 1.2)
        _ = logic.update(present: faceNow, head: faceNow ? r.headY : nil)
        if let b = logic.baseHead, baseHeadY == nil { baseHeadY = b; emaHeadY = b }
        if r.faceFound { emaHeadY = emaHeadY * 0.8 + r.headY * 0.2 }

        let margin = max(0.015, 0.095 - (slouchThresh - 0.80) * 0.45)
        let drop = (baseHeadY ?? emaHeadY) - emaHeadY
        if drop > margin { slouchState = true } else if drop < margin * 0.6 { slouchState = false }
        let slouching = present && logic.calibrated && slouchState

        var subtitle = ""
        if mode == .periodic {
            if phase == .sampling {
                if present && logic.calibrated { burstPresent += 1; if drop > margin { burstSlouch += 1 } }
            } else if phase == .watching {
                if !present {
                    // stepped away — stop watching, resume the periodic cadence
                    slouchSince = nil; phase = .idle; vision.stopCamera()
                    nextSampleAt = now + max(60, intervalMin * 60)
                } else if slouching {
                    if slouchSince == nil { slouchSince = now }
                    let held = now - (slouchSince ?? now)
                    let left = max(0, graceSec - held)
                    subtitle = left > 0 ? String(format: "sit up in %.0fs…", left) : "sit up straight"
                    if held >= graceSec && now - lastAlert > config.slouchCooldown {
                        lastAlert = now; wasAlerted = true; fireAlert("Sit up tall — you're slouching", good: false)
                    }
                } else {
                    // recovered — chime, then go back to sleep on the periodic interval
                    slouchSince = nil
                    if wasAlerted { wasAlerted = false; fireAlert("Nice — back to good posture", good: true) }
                    phase = .idle; vision.stopCamera()
                    nextSampleAt = now + max(60, intervalMin * 60)
                }
            }
        } else {
            if slouching {
                if slouchSince == nil { slouchSince = now }
                let held = now - (slouchSince ?? now)
                let left = max(0, graceSec - held)
                subtitle = left > 0 ? String(format: "sit up in %.0fs…", left) : "sit up straight"
                if held >= graceSec && now - lastAlert > config.slouchCooldown {
                    lastAlert = now; wasAlerted = true; fireAlert("Sit up tall — you're slouching", good: false)
                }
            } else {
                slouchSince = nil
                // Recovery chime — only if a nudge actually fired, and you're clearly back to good.
                if wasAlerted && present && logic.calibrated {
                    wasAlerted = false; fireAlert("Nice — back to good posture", good: true)
                }
            }
        }

        let palette: Palette = !present ? .away : (!logic.calibrated ? .settling : (slouching ? .slouching : .good))
        if paused {
            onUpdate?(UIState(palette: .away, title: "Paused", subtitle: "monitoring is off"))
        } else {
            if palette == .good && subtitle.isEmpty { subtitle = mode == .periodic ? "checking…" : "keep it up" }
            if palette == .away { subtitle = "step into view to begin" }
            onUpdate?(UIState(palette: palette, title: palette.label, subtitle: subtitle))
        }
    }

    private func fireAlert(_ message: String, good: Bool) {
        plog("alert(\(good ? "recover" : "nudge")) sound=\(alertSound) flash=\(alertFlash) banner=\(alertBanner) muted=\(muted)")
        if alertSound && !muted {
            if let s = NSSound(named: NSSound.Name(good ? "Glass" : "Submarine")) { s.play() } else { NSSound.beep() }
        }
        if !good && !muted && config.speakAlerts { synth.speak(AVSpeechUtterance(string: "Sit up straight")) }
        onAlert?(message, good, good ? false : alertFlash, alertBanner)
    }
}

// MARK: - Status pill

final class PillView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ p: Palette, _ text: String) {
        layer?.backgroundColor = p.color.withAlphaComponent(0.16).cgColor
        label.stringValue = text
        label.textColor = p.ink
        let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: text)
        img?.isTemplate = true
        icon.image = img
        icon.contentTintColor = p.ink
    }
}

// MARK: - Camera panel (preview + face box + status border)

final class CameraPanel: NSView {
    private let container = CALayer()
    private let preview: AVCaptureVideoPreviewLayer
    private let box = CAShapeLayer()

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22; layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -3)
        container.cornerRadius = 14; container.masksToBounds = true
        container.backgroundColor = NSColor.black.cgColor
        container.borderWidth = 4; container.borderColor = Palette.away.color.cgColor
        layer?.addSublayer(container)
        preview.videoGravity = .resizeAspectFill
        container.addSublayer(preview)
        box.fillColor = NSColor.clear.cgColor; box.lineWidth = 2.5; box.strokeColor = NSColor.systemGreen.cgColor
        container.addSublayer(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = bounds; preview.frame = bounds
        CATransaction.commit()
    }

    func setState(_ p: Palette) { container.borderColor = p.color.cgColor; box.strokeColor = p.color.cgColor }

    func setFace(_ r: VisionReading) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if r.faceFound {
            let meta = CGRect(x: r.faceRect.minX, y: 1 - r.faceRect.maxY, width: r.faceRect.width, height: r.faceRect.height)
            let rect = preview.layerRectConverted(fromMetadataOutputRect: meta)
            box.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            box.isHidden = false
        } else { box.isHidden = true }
        CATransaction.commit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow!
    var panel: CameraPanel!
    var pill: PillView!
    var subtitle: NSTextField!
    var sensSlider: NSSlider?
    var pauseBtn: NSButton?
    var muteBtn: NSButton?

    // Menu bar.
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem?
    var lastStatusText = "Starting…"
    var showDock = true
    var flashWins: [NSWindow] = []
    var bannerWin: NSWindow?
    var prefs: PreferencesController?
    var cameras: [AVCaptureDevice] = []
    var currentCameraID: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        showDock = model.config.showDockIcon
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "PostureMonitor"; w.titlebarAppearsTransparent = true; w.center()
        w.isReleasedWhenClosed = false
        window = w

        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .windowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        w.contentView = bg

        panel = CameraPanel(session: model.vision.session)
        panel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(panel)

        pill = PillView(); pill.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(pill)

        subtitle = NSTextField(labelWithString: " ")
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor; subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(subtitle)

        let less = caption("Less"); let more = caption("More")
        let sens = NSSlider(value: model.slouchThresh, minValue: 0.80, maxValue: 0.97,
                            target: self, action: #selector(sensChanged(_:)))
        sens.translatesAutoresizingMaskIntoConstraints = false; sens.controlSize = .small; sensSlider = sens
        let sensRow = NSStackView(views: [less, sens, more])
        sensRow.spacing = 8; sensRow.alignment = .centerY; sensRow.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sensRow)

        let calibrate = toolButton("Calibrate", "arrow.clockwise", #selector(calibrate))
        let pauseB = toolButton("Pause", "pause.fill", #selector(togglePause)); pauseBtn = pauseB
        let muteB = toolButton("Mute", "speaker.slash.fill", #selector(toggleMute)); muteBtn = muteB
        let help = toolButton("Help", "questionmark.circle", #selector(showHelp))
        let buttons = NSStackView(views: [calibrate, pauseB, muteB, help])
        buttons.spacing = 8; buttons.distribution = .fillEqually; buttons.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(buttons)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 38),
            panel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            panel.heightAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 0.75),
            pill.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 18),
            pill.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 8),
            subtitle.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            sensRow.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            sensRow.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            sens.widthAnchor.constraint(equalToConstant: 200),
            buttons.topAnchor.constraint(equalTo: sensRow.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor, constant: -20),
        ])

        // Camera selection (single camera — pick which one; remembered across launches).
        cameras = availableCameras()
        if let saved = UserDefaults.standard.string(forKey: "cameraID"),
           let dev = cameras.first(where: { $0.uniqueID == saved }) {
            model.vision.preferredDevice = dev; currentCameraID = saved
        } else {
            currentCameraID = (cameras.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? cameras.first)?.uniqueID
        }

        // Menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuStatus(.settling, "Starting…")
        buildMenu()

        model.onUpdate = { [weak self] s in
            self?.pill.set(s.palette, s.title)
            self?.subtitle.stringValue = s.subtitle.isEmpty ? " " : s.subtitle
            self?.panel.setState(s.palette)
            self?.setMenuStatus(s.palette, s.title)
        }
        model.onFace = { [weak self] r in self?.panel.setFace(r) }
        model.onModeStatus = { [weak self] p, title, sub in
            self?.pill.set(p, title)
            self?.subtitle.stringValue = sub.isEmpty ? " " : sub
            self?.panel.setState(p)
            self?.setMenuStatus(p, title)
        }
        model.onAlert = { [weak self] msg, good, flash, banner in
            if flash { self?.flashScreen() }
            if banner { self?.showBanner(msg, good: good) }
        }
        model.vision.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()
        model.applyMode()

        let firstRun = UserDefaults.standard.bool(forKey: "didShowHelp") == false
        if showDock || firstRun { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        if firstRun { showHelp() }
    }

    // MARK: helpers

    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 11); t.textColor = .tertiaryLabelColor; return t
    }
    private func toolButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: " " + title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading; b.bezelStyle = .rounded; b.controlSize = .large
        return b
    }
    private func syncControls() {
        pauseBtn?.title = " " + (model.paused ? "Resume" : "Pause")
        pauseBtn?.image = NSImage(systemSymbolName: model.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        muteBtn?.title = " " + (model.muted ? "Unmute" : "Mute")
        muteBtn?.image = NSImage(systemSymbolName: model.muted ? "speaker.wave.2.fill" : "speaker.slash.fill", accessibilityDescription: nil)
    }

    // MARK: menu bar

    private func setMenuStatus(_ p: Palette, _ text: String) {
        lastStatusText = text
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: text)
            img?.isTemplate = true
            b.image = img
            // For the neutral "away" state, leave the icon as a TEMPLATE (no tint) so
            // macOS auto-renders it black on a light menu bar / white on a dark one —
            // a fixed gray tint disappears in dark mode. Active states keep their
            // bright status color (green/orange/red), which reads on both appearances.
            b.contentTintColor = (p == .away) ? nil : p.color
            b.toolTip = text
        }
        statusMenuItem?.title = text.isEmpty ? "PostureMonitor" : text
    }

    private func check(_ title: String, _ action: Selector, _ on: Bool, tag: Int = 0, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.state = on ? .on : .off; it.tag = tag; it.isEnabled = enabled; it.target = self
        return it
    }

    private func buildMenu() {
        let m = NSMenu()
        let status = NSMenuItem(title: lastStatusText, action: nil, keyEquivalent: ""); status.isEnabled = false
        m.addItem(status); statusMenuItem = status
        m.addItem(.separator())

        // Quick actions.
        m.addItem(check("Calibrate (sit up tall)", #selector(calibrate), false))
        m.addItem(check(model.paused ? "Resume monitoring" : "Pause monitoring", #selector(togglePause), false))
        m.addItem(check("Mute all sounds", #selector(toggleMuteMenu), model.muted))
        m.addItem(check("Show window", #selector(showWindow), false))

        // Quick mode switch (detailed tuning lives in Preferences).
        let modeMenu = NSMenu()
        modeMenu.addItem(check("Continuous", #selector(setContinuous), model.mode == .continuous))
        for mins in [1, 3, 5, 10] {
            modeMenu.addItem(check("Every \(mins) min", #selector(setInterval(_:)),
                                   model.mode == .periodic && Int(model.intervalMin) == mins, tag: mins))
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: ""); modeItem.submenu = modeMenu
        m.addItem(modeItem)

        // Camera picker (choose which camera; switches live + recalibrates).
        let camMenu = NSMenu()
        if cameras.isEmpty {
            let it = NSMenuItem(title: "No camera found", action: nil, keyEquivalent: ""); it.isEnabled = false
            camMenu.addItem(it)
        } else {
            for (i, cam) in cameras.enumerated() {
                let it = NSMenuItem(title: cam.localizedName, action: #selector(setCamera(_:)), keyEquivalent: "")
                it.tag = i; it.state = (cam.uniqueID == currentCameraID) ? .on : .off; it.target = self
                camMenu.addItem(it)
            }
        }
        let camItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: ""); camItem.submenu = camMenu
        m.addItem(camItem)
        m.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self; m.addItem(prefsItem)
        m.addItem(check("About PostureMonitor", #selector(showAbout), false))
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit PostureMonitor", action: #selector(quit), keyEquivalent: "q")
        q.target = self; m.addItem(q)
        statusItem.menu = m
    }

    // MARK: overlays

    private func flashScreen() {
        flashWins.forEach { $0.orderOut(nil) }; flashWins.removeAll()
        // One glow per screen, so it reaches whichever monitor you're looking at.
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear
            w.level = .screenSaver; w.ignoresMouseEvents = true; w.hasShadow = false; w.alphaValue = 0
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let glow = CAGradientLayer()
            glow.frame = v.bounds; glow.type = .radial
            let tint = NSColor.systemOrange
            glow.colors = [tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(0.5).cgColor]
            glow.locations = [0.0, 0.6, 1.0]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1.0, y: 1.0)
            v.layer = glow; v.wantsLayer = true
            w.contentView = v; w.orderFrontRegardless(); flashWins.append(w)
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; w.animator().alphaValue = 1 }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    NSAnimationContext.runAnimationGroup({ c in c.duration = 1.0; w.animator().alphaValue = 0 }) {
                        w.orderOut(nil); self.flashWins.removeAll { $0 === w }
                    }
                }
            }
        }
    }

    private func showBanner(_ message: String, good: Bool) {
        bannerWin?.orderOut(nil)
        // Show on whichever screen the cursor is on (likely the one you're working on).
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = NSSize(width: 380, height: 66)
        let f = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 170, width: size.width, height: size.height)
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = .screenSaver; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        v.material = .hudWindow; v.state = .active; v.wantsLayer = true
        v.layer?.cornerRadius = 16; v.layer?.masksToBounds = true
        let dot = NSView(frame: NSRect(x: 20, y: size.height / 2 - 7, width: 14, height: 14)); dot.wantsLayer = true
        dot.layer?.backgroundColor = (good ? NSColor.systemGreen : NSColor.systemRed).cgColor; dot.layer?.cornerRadius = 7
        v.addSubview(dot)
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 46, y: 0, width: size.width - 60, height: size.height)
        label.font = .systemFont(ofSize: 15, weight: .semibold); label.textColor = .labelColor
        label.alignment = .left; label.maximumNumberOfLines = 2; label.lineBreakMode = .byWordWrapping
        (label.cell as? NSTextFieldCell)?.usesSingleLineMode = false
        v.addSubview(label)
        w.contentView = v; w.alphaValue = 0; w.orderFrontRegardless(); bannerWin = w
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; w.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; w.animator().alphaValue = 0 }) {
                w.orderOut(nil); if self.bannerWin === w { self.bannerWin = nil }
            }
        }
    }

    private func cameraDenied() {
        pill.set(.slouching, "Camera access denied")
        subtitle.stringValue = "Enable it in System Settings ▸ Privacy ▸ Camera."
    }

    @objc func showHelp() {
        UserDefaults.standard.set(true, forKey: "didShowHelp")
        let a = NSAlert()
        a.messageText = "Welcome to PostureMonitor"
        a.informativeText = """
        1. Sit up straight, then click Calibrate to set your baseline.
        2. Work normally — it nudges you when you slump.
        3. The menu-bar icon (top right) has everything: Continuous vs Periodic \
        checking, how you're alerted (sound / screen glow / banner), sensitivity, \
        and a background mode (uncheck Show Dock icon).

        Everything runs on your Mac — your video is never recorded or sent anywhere.
        """
        a.addButton(withTitle: "Got it")
        if let w = window, w.isVisible { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: actions

    @objc func calibrate() { model.recalibrate() }
    @objc func setCamera(_ s: NSMenuItem) {
        guard s.tag >= 0, s.tag < cameras.count else { return }
        let dev = cameras[s.tag]
        currentCameraID = dev.uniqueID; Config.set("cameraID", dev.uniqueID)
        model.vision.switchTo(dev); model.recalibrate(); buildMenu()
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPreferences() {
        if prefs == nil {
            prefs = PreferencesController(
                model: model,
                onChange: { [weak self] in
                    self?.buildMenu(); self?.syncControls()
                    if let v = self?.model.slouchThresh { self?.sensSlider?.doubleValue = v }
                },
                onDock: { [weak self] on in
                    self?.showDock = on
                    NSApp.setActivationPolicy(on ? .regular : .accessory)
                    if on { NSApp.activate(ignoringOtherApps: true) }
                })
        }
        prefs?.show()
    }
    @objc func showAbout() { AboutController.show() }
    @objc func togglePause() { model.paused.toggle(); syncControls(); buildMenu() }
    @objc func toggleMute() { model.muted.toggle(); syncControls(); buildMenu() }
    @objc func toggleMuteMenu() { model.muted.toggle(); syncControls(); buildMenu() }

    @objc func sensChanged(_ s: NSSlider) {
        model.slouchThresh = s.doubleValue; model.config.slouchThresh = s.doubleValue
        Config.set("slouchThresh", s.doubleValue); buildMenu()
    }
    @objc func setSensitivity(_ s: NSMenuItem) {
        guard let v = s.representedObject as? Double else { return }
        model.slouchThresh = v; Config.set("slouchThresh", v); sensSlider?.doubleValue = v; buildMenu()
    }
    @objc func setGrace(_ s: NSMenuItem) { model.graceSec = Double(s.tag); Config.set("slouchGrace", Double(s.tag)); buildMenu() }

    @objc func setContinuous() { model.mode = .continuous; Config.set("monitorMode", "continuous"); model.applyMode(); buildMenu() }
    @objc func setInterval(_ s: NSMenuItem) {
        model.mode = .periodic; model.intervalMin = Double(s.tag)
        Config.set("monitorMode", "periodic"); Config.set("sampleIntervalMin", Double(s.tag))
        model.applyMode(); buildMenu()
    }
    @objc func toggleTwo() { model.needsTwo.toggle(); Config.set("periodicNeedsTwo", model.needsTwo); buildMenu() }
    @objc func toggleSound() { model.alertSound.toggle(); Config.set("alertSound", model.alertSound); buildMenu() }
    @objc func toggleFlash() { model.alertFlash.toggle(); Config.set("alertFlash", model.alertFlash); buildMenu() }
    @objc func toggleBanner() { model.alertBanner.toggle(); Config.set("alertBanner", model.alertBanner); buildMenu() }
    @objc func toggleDock() {
        showDock.toggle(); Config.set("showDockIcon", showDock)
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        if showDock { NSApp.activate(ignoringOtherApps: true) }
        buildMenu()
    }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// Disable App Nap for this app: a posture monitor must keep watching even when its
// window is hidden / it isn't the front app. This throttles only THIS app's nap
// behavior — the Mac still sleeps normally when globally idle.
UserDefaults.standard.set(true, forKey: "NSAppSleepDisabled")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
