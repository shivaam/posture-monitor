// main.swift — PostureMonitor: a camera + MediaPipe skeleton overlay and a calm
// status. Lives in the menu bar; can run a window OR quietly in the background.
//
// Two modes:
//   • Continuous — camera always on, real-time detection + grace period.
//   • Periodic   — camera OFF; wakes every N minutes for a short check, then off.
// Alerts are pick-your-style: sound, screen flash, and/or an on-screen banner.

import AppKit
import AVFoundation

// Shared logger -> /tmp/posture-monitor.log (handy for debugging).
let posLogURL = URL(fileURLWithPath: "/tmp/posture-monitor.log")
func plog(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: posLogURL) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
    else { try? d.write(to: posLogURL) }
}

// MARK: - App model (calibration + slouch detection + alerts)

final class AppModel {
    enum Mode: String { case continuous, periodic }

    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    let config = Config.load()
    var muted = false
    var paused = false
    var slouchThresh = 0.87        // live sensitivity (the slider sets this)

    // Background / periodic mode + alert styles (initialized from config).
    var mode: Mode = .continuous
    var intervalMin = 5.0
    var needsTwo = true
    var alertSound = true, alertFlash = false, alertBanner = false

    // Two front slouch signals, both baseline-relative:
    private var baseHeadAbove = 0.0, emaHeadAbove = 0.0   // head height ABOVE shoulders (MediaPipe)
    private var baseHeadY = 0.0, emaHeadY = 0.0           // absolute head height (Apple Vision) — catches whole-body sink
    var sideActive = false                               // an optional side camera is selected
    private var emaSideDeg = 0.0, sideBaseDeg: Double?    // forward-head angle (side camera) + its calibrated neutral
    private var sideSeen = false
    private var slouchSince = 0.0
    private var slouchState = false    // hysteresis-stabilized (no flicker)
    private var lastSlouchAlert = -1e9

    // Periodic state machine.
    private enum Phase { case calibrating, idle, sampling }
    private var phase: Phase = .calibrating
    private var ticker: Timer?
    private var nextSampleAt = 0.0
    private var sampleUntil = 0.0
    private var burstPresent = 0, burstSlouch = 0
    private var consecutive = 0

    private var lastVision = VisionReading()
    private var lastMP = MPReading()
    private var lastPresent = 0.0
    private var wasAlerted = false
    private var wasCalibrated = false
    private var frames = 0

    var calibrated: Bool { logic.calibrated }

    struct State {
        var status: PostureLogic.Status
        var score: Int
        var headFrac: Double
        var slouchHold: Double = 0     // seconds the current slouch has been held (0 = not slouching)
        var grace: Double = 8          // seconds before the alarm fires
        var points: [String: (CGPoint, Double)]   // MediaPipe landmarks for the overlay
        var camW: Double
        var camH: Double
    }
    var onState: ((State) -> Void)?
    var onCameraDenied: (() -> Void)?
    // Background-status updates (periodic mode, when no frames are flowing).
    var onModeStatus: ((_ text: String, _ status: PostureLogic.Status) -> Void)?
    // Alert delivery the UI handles (flash + banner). Sound/speech are played here.
    var onAlert: ((_ message: String, _ good: Bool, _ flash: Bool, _ banner: Bool) -> Void)?

    func start() {
        slouchThresh = config.slouchThresh
        mode = Mode(rawValue: config.monitorMode) ?? .continuous
        intervalMin = config.sampleIntervalMin
        needsTwo = config.periodicNeedsTwo
        alertSound = config.alertSound; alertFlash = config.alertFlash; alertBanner = config.alertBanner
        vision.onVision = { [weak self] r in self?.feedVision(r) }
        vision.onFrameJPEG = { [weak self] d in if self?.paused == false { self?.mp.send(d) } }
        vision.onCameraDenied = { [weak self] in self?.onCameraDenied?() }
        mp.onReading = { [weak self] r in self?.lastMP = r }
        vision.start()
    }
    func recalibrate() { logic.recalibrate(); wasCalibrated = false; sideBaseDeg = nil; phase = .calibrating; vision.resumeCamera() }

    /// (Re)configure the run loop for the current mode. Call after any mode/interval change.
    func applyMode() {
        ticker?.invalidate(); ticker = nil
        if mode == .continuous {
            vision.resumeCamera()
            onModeStatus?("", .good)
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
            onModeStatus?("Paused", .away)
            return
        }
        switch phase {
        case .calibrating:
            if logic.calibrated { phase = .idle; nextSampleAt = now + 3; vision.stopCamera() }
            else { onModeStatus?("Calibrating — sit up tall…", .settling) }
        case .idle:
            if now >= nextSampleAt { beginSample() }
            else {
                let m = max(1, Int(ceil((nextSampleAt - now) / 60)))
                onModeStatus?("Good — next check in \(m)m", .good)
            }
        case .sampling:
            if now >= sampleUntil { endSample() }
        }
    }

    private func beginSample() {
        phase = .sampling; burstPresent = 0; burstSlouch = 0
        vision.resumeCamera()
        sampleUntil = ProcessInfo.processInfo.systemUptime + max(2, config.sampleSeconds)
        onModeStatus?("Checking…", .settling)
        plog("periodic: sampling")
    }

    private func endSample() {
        vision.stopCamera()
        phase = .idle
        nextSampleAt = ProcessInfo.processInfo.systemUptime + max(60, intervalMin * 60)
        let mins = Int(intervalMin)
        if burstPresent == 0 {
            consecutive = 0
            onModeStatus?("Away — next check in \(mins)m", .away)
            plog("periodic: away (no face)")
            return
        }
        let slouch = burstSlouch * 2 > burstPresent     // majority of present frames slouching
        if slouch {
            consecutive += 1
            let trigger = needsTwo ? consecutive >= 2 : consecutive >= 1
            plog("periodic: slouch (\(burstSlouch)/\(burstPresent), streak \(consecutive), trigger=\(trigger))")
            if trigger { fireAlert("Sit up tall — you're slouching", good: false); consecutive = 0 }
            onModeStatus?("Slouching — next check in \(mins)m", .slumping)
        } else {
            consecutive = 0
            onModeStatus?("Good posture ✓ — next in \(mins)m", .good)
            plog("periodic: good (\(burstSlouch)/\(burstPresent))")
        }
    }

    // Side camera forward-head angle (smoothed). Drives the third slouch signal.
    func feedSide(deg: Double?, present: Bool) {
        guard present, let deg else { return }
        if !sideSeen { emaSideDeg = deg; sideSeen = true }
        emaSideDeg = emaSideDeg * 0.8 + deg * 0.2
    }
    var sideForwardDeg: Double { emaSideDeg }
    func clearSide() { sideActive = false; sideSeen = false; sideBaseDeg = nil; emaSideDeg = 0 }

    private func feedVision(_ r: VisionReading) {
        lastVision = r
        let now = ProcessInfo.processInfo.systemUptime
        if r.faceFound { lastPresent = now }
        let present = !paused && r.faceFound && (now - lastPresent <= 1.0)
        let head = present ? r.headY : nil

        // Smooth both slouch signals.
        let headAbove = lastMP.shouldersFound ? (lastMP.headAbove ?? 0) : 0
        if headAbove > 0 { emaHeadAbove = emaHeadAbove > 0 ? emaHeadAbove * 0.8 + headAbove * 0.2 : headAbove }
        if r.faceFound { emaHeadY = emaHeadY > 0 ? emaHeadY * 0.8 + r.headY * 0.2 : r.headY }

        _ = logic.update(present: present, head: head)   // presence + auto-calibration

        // Capture all baselines the moment we calibrate.
        if logic.calibrated && !wasCalibrated {
            baseHeadAbove = emaHeadAbove > 0 ? emaHeadAbove : (lastMP.headAbove ?? 0)
            baseHeadY = emaHeadY > 0 ? emaHeadY : r.headY
            if sideActive && sideSeen { sideBaseDeg = emaSideDeg }
        }
        wasCalibrated = logic.calibrated

        // SLOUCH = head drops vs shoulders (MediaPipe) OR whole head sinks (Vision) OR
        // head juts forward (side camera). ONE sensitivity slider drives all signals.
        let slouchRatio = (logic.calibrated && baseHeadAbove > 0 && emaHeadAbove > 0) ? emaHeadAbove / baseHeadAbove : 1
        let headYDrop = (logic.calibrated && baseHeadY > 0 && emaHeadY > 0) ? max(0, baseHeadY - emaHeadY) : 0
        let headYMargin = max(0.015, 0.095 - (slouchThresh - 0.80) * 0.45)
        let sideDev = (sideActive && sideSeen && sideBaseDeg != nil) ? max(0, emaSideDeg - (sideBaseDeg ?? 0)) : 0
        let sideMargin = max(3.0, 14 - (slouchThresh - 0.80) * 60)
        let slouchFront = slouchRatio < slouchThresh
        let slouchSink = headYDrop > headYMargin
        let slouchSide = sideActive && sideDev > sideMargin
        let instSlouch = slouchFront || slouchSink || slouchSide
        // Hysteresis: flip to slouching on a clear drop, back only after a clear recovery.
        if instSlouch { slouchState = true }
        else if slouchRatio > slouchThresh + 0.05 && headYDrop < headYMargin * 0.6 && sideDev < sideMargin * 0.6 { slouchState = false }
        let slouching = present && logic.calibrated && slouchState

        if mode == .periodic {
            // No grace-based alerts; just tally this burst. endSample() decides.
            if phase == .sampling && present && logic.calibrated {
                burstPresent += 1; if instSlouch { burstSlouch += 1 }
            }
        } else {
            if slouching {
                if slouchSince == 0 { slouchSince = now }
                if now - slouchSince >= config.slouchGrace && now - lastSlouchAlert >= config.slouchCooldown {
                    lastSlouchAlert = now; wasAlerted = true
                    fireAlert("Sit up tall — you're slouching", good: false)
                }
            } else {
                slouchSince = 0
                if wasAlerted && slouchRatio > slouchThresh + 0.05 && headYDrop < headYMargin && sideDev < sideMargin {
                    wasAlerted = false; fireAlert("Nice — back to good posture", good: true)
                }
            }
        }

        let slouchFloor = slouchThresh - 0.10
        let frontFrac = max(0, min(1, (slouchRatio - slouchFloor) / max(0.001, 1 - slouchFloor)))
        let headYFrac = (logic.calibrated && baseHeadY > 0) ? max(0, min(1, 1 - headYDrop / (headYMargin + 0.04))) : 1
        let sideFrac = (sideActive && sideBaseDeg != nil) ? max(0, min(1, 1 - sideDev / (sideMargin + 6))) : 1
        let postureFrac = min(frontFrac, headYFrac, sideFrac)
        let score = (present && logic.calibrated) ? Int((postureFrac * 100).rounded()) : -1
        let status: PostureLogic.Status = !present ? .away : (!logic.calibrated ? .settling : (slouching ? .slumping : .good))

        frames += 1
        if frames % 30 == 0 {
            plog("slouch ratio=\(String(format: "%.2f", slouchRatio)) headYdrop=\(String(format: "%.3f", headYDrop)) sideDev=\(String(format: "%.0f", sideDev)) front=\(slouchFront) sink=\(slouchSink) side=\(slouchSide) slouching=\(slouching) score=\(score)")
        }

        onState?(State(
            status: status, score: score, headFrac: postureFrac,
            slouchHold: (slouching && slouchSince > 0) ? (now - slouchSince) : 0, grace: config.slouchGrace,
            points: lastMP.points,
            camW: r.frameW > 0 ? r.frameW : 16, camH: r.frameH > 0 ? r.frameH : 9))
    }

    /// Deliver an alert via the enabled styles. Sound/speech here; flash + banner via the UI.
    private func fireAlert(_ message: String, good: Bool) {
        plog("alert(\(good ? "recover" : "nudge")) sound=\(alertSound) flash=\(alertFlash) banner=\(alertBanner) muted=\(muted)")
        if alertSound && !muted {
            run("/usr/bin/afplay", [good ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Funk.aiff"])
        }
        if !good && !muted && config.speakAlerts { run("/usr/bin/say", ["sit up straight"]) }
        onAlert?(message, good, good ? false : alertFlash, alertBanner)   // never flash on recovery
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; try? p.run()
    }
}

// MARK: - Camera + MediaPipe skeleton overlay

final class CameraPanel: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let overlay = CAShapeLayer()

    static let bones: [(String, String)] = [
        ("leftEar", "nose"), ("rightEar", "nose"),
        ("leftShoulder", "rightShoulder"),
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"), ("leftHip", "rightHip"),
    ]

    private var mirrorConfigured = false

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspect      // show the WHOLE frame so landmarks map 1:1
        layer?.addSublayer(preview)
        overlay.fillColor = Palette.settling.cgColor
        overlay.strokeColor = Palette.settling.cgColor
        overlay.lineWidth = 4
        overlay.lineCap = .round; overlay.lineJoin = .round
        layer?.addSublayer(overlay)
        layer?.cornerRadius = 14; layer?.masksToBounds = true
        layer?.borderWidth = 4; layer?.borderColor = Palette.settling.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds; overlay.frame = bounds }

    func setLandmarks(_ pts: [String: (CGPoint, Double)], color: NSColor, camSize: CGSize) {
        configureMirror()
        // The video is aspect-FIT inside our bounds. Map normalized MediaPipe coords
        // (top-left) into that rect, mirrored to match the selfie preview.
        let fit = AVMakeRect(aspectRatio: camSize, insideRect: bounds)
        func cv(_ p: CGPoint) -> CGPoint {
            CGPoint(x: fit.minX + (1 - p.x) * fit.width,     // mirror x for selfie view
                    y: fit.minY + (1 - p.y) * fit.height)    // macOS layer y is up; image y is down
        }
        func vp(_ k: String) -> CGPoint? { guard let v = pts[k], v.1 > 0.3 else { return nil }; return cv(v.0) }
        let path = CGMutablePath()
        for (_, v) in pts where v.1 > 0.3 {
            let c = cv(v.0); path.addEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        }
        for (a, b) in Self.bones {
            if let pa = vp(a), let pb = vp(b) { path.move(to: pa); path.addLine(to: pb) }
        }
        if let n = vp("nose"), let ls = vp("leftShoulder"), let rs = vp("rightShoulder") {
            let mid = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2); path.move(to: n); path.addLine(to: mid)
        }
        overlay.strokeColor = color.cgColor; overlay.fillColor = color.cgColor
        layer?.borderColor = color.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true); overlay.path = path; CATransaction.commit()
    }

    private func configureMirror() {
        guard !mirrorConfigured, let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
        mirrorConfigured = true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow!
    private var content: NSView!
    private var cam: CameraPanel!
    private var sidePanel: CameraPanel?
    private var sideCam: SideCamera?
    private var statusLabel: NSTextField!
    private var pauseButton: NSButton!
    private var frontPopup: NSPopUpButton?
    private var sidePopup: NSPopUpButton?
    private var statusColor = Palette.settling
    private var cameras: [AVCaptureDevice] = []
    private let region = NSRect(x: 16, y: 64, width: 600, height: 500)

    // Menu bar.
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem?
    private var lastStatusText = "Starting…"
    // Overlays (held so they survive their animations).
    private var flashWin: NSWindow?
    private var bannerWin: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Posture Monitor"; window.center()
        window.isReleasedWhenClosed = false   // closing just hides it; the app lives in the menu bar
        content = NSView(frame: rect); content.wantsLayer = true
        content.layer?.backgroundColor = Palette.bg.cgColor

        cam = CameraPanel(session: model.vision.session)
        content.addSubview(cam)

        let rx: CGFloat = 650
        statusLabel = mk("Calibrating…", 34, .bold, Palette.settling)
        statusLabel.frame = NSRect(x: rx, y: 380, width: 330, height: 120)
        statusLabel.maximumNumberOfLines = 3
        content.addSubview(statusLabel)

        // Camera pickers — only when there's a choice (one camera = no clutter).
        cameras = availableCameras()
        var helpY: CGFloat = 340
        if cameras.count > 1 {
            let fl = mk("Front view (facing you)", 11, .semibold, Palette.textMuted)
            fl.frame = NSRect(x: rx, y: 320, width: 320, height: 16); content.addSubview(fl)
            let fp = NSPopUpButton(frame: NSRect(x: rx, y: 294, width: 300, height: 24))
            cameras.forEach { fp.addItem(withTitle: $0.localizedName) }
            if let i = cameras.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) { fp.selectItem(at: i) }
            fp.target = self; fp.action = #selector(frontChanged); content.addSubview(fp); frontPopup = fp

            let sl = mk("Side view (optional — catches forward-head)", 11, .semibold, Palette.textMuted)
            sl.frame = NSRect(x: rx, y: 258, width: 330, height: 16); content.addSubview(sl)
            let sp = NSPopUpButton(frame: NSRect(x: rx, y: 232, width: 300, height: 24))
            sp.addItem(withTitle: "None")
            cameras.forEach { sp.addItem(withTitle: $0.localizedName) }
            sp.target = self; sp.action = #selector(sideChanged); content.addSubview(sp); sidePopup = sp
            helpY = 190
        }
        let help = NSButton(title: "?  Help", target: self, action: #selector(showHelp))
        help.frame = NSRect(x: rx, y: helpY, width: 90, height: 28); help.bezelStyle = .rounded
        content.addSubview(help)

        // controls row
        let cal = NSButton(title: "Calibrate", target: self, action: #selector(calibrate))
        cal.frame = NSRect(x: 16, y: 16, width: 100, height: 30); cal.bezelStyle = .rounded; cal.keyEquivalent = "\r"
        content.addSubview(cal)
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.frame = NSRect(x: 122, y: 16, width: 80, height: 30); pauseButton.bezelStyle = .rounded
        content.addSubview(pauseButton)
        let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(toggleMute))
        mute.frame = NSRect(x: 214, y: 20, width: 64, height: 22); content.addSubview(mute)
        let sensLbl = mk("sensitivity", 11, .regular, Palette.textMuted)
        sensLbl.frame = NSRect(x: 300, y: 20, width: 70, height: 18); content.addSubview(sensLbl)
        let sens = NSSlider(value: model.slouchThresh, minValue: 0.80, maxValue: 0.97,
                            target: self, action: #selector(sens(_:)))
        sens.frame = NSRect(x: 372, y: 20, width: 220, height: 22); content.addSubview(sens)

        if let fp = frontPopup, fp.indexOfSelectedItem >= 0 { model.vision.preferredDevice = cameras[fp.indexOfSelectedItem] }
        relayoutPanels()
        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

        // Menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setMenuStatus(.settling, "Starting…")
        buildMenu()

        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.onModeStatus = { [weak self] text, st in self?.applyBackgroundStatus(text, st) }
        model.onAlert = { [weak self] msg, good, flash, banner in
            if flash { self?.flashScreen() }
            if banner { self?.showBanner(msg, good: good) }
        }
        model.start()
        model.applyMode()    // honor the saved mode (continuous / periodic)

        // First launch: show the setup guide once.
        if !UserDefaults.standard.bool(forKey: "didShowHelp") {
            UserDefaults.standard.set(true, forKey: "didShowHelp")
            DispatchQueue.main.async { [weak self] in self?.showHelp() }
        }
    }

    // MARK: layout / cameras

    private func relayoutPanels() {
        if let sp = sidePanel {
            let half = (region.width - 8) / 2
            cam.frame = NSRect(x: region.minX, y: region.minY, width: half, height: region.height)
            sp.frame = NSRect(x: region.minX + half + 8, y: region.minY, width: half, height: region.height)
        } else {
            cam.frame = region
        }
    }

    @objc private func frontChanged() {
        guard let fp = frontPopup, fp.indexOfSelectedItem >= 0 else { return }
        model.vision.switchTo(cameras[fp.indexOfSelectedItem]); model.recalibrate()
    }

    @objc private func sideChanged() {
        sideCam?.stop(); sideCam = nil
        sidePanel?.removeFromSuperview(); sidePanel = nil
        model.clearSide()
        if let sp = sidePopup, sp.indexOfSelectedItem >= 1 {   // 0 = None
            let dev = cameras[sp.indexOfSelectedItem - 1]
            let sc = SideCamera(device: dev); sideCam = sc
            let panel = CameraPanel(session: sc.session); sidePanel = panel; content.addSubview(panel)
            sc.onFrame = { [weak self] pts, w, h, deg, present in
                guard let self else { return }
                self.sidePanel?.setLandmarks(pts, color: self.statusColor, camSize: CGSize(width: w, height: h))
                self.model.feedSide(deg: deg, present: present)
            }
            sc.start(); model.sideActive = true
        }
        relayoutPanels(); model.recalibrate()
    }

    @objc private func showHelp() {
        let a = NSAlert(); a.messageText = "How to use PostureMonitor"
        a.informativeText = """
        1. Sit up TALL and click Calibrate — that sets your baseline.
        2. Slouch and hold a few seconds; it nudges you.
        3. Menu-bar icon (top right): switch between Continuous and Periodic mode, \
        pick how you're alerted (sound / screen flash / banner), pause, or quit.

        Periodic mode keeps the camera OFF and wakes it briefly every few minutes — \
        lighter and more private for all-day use. Close this window any time; the app \
        keeps running in the menu bar.
        """
        a.addButton(withTitle: "Got it")
        a.beginSheetModal(for: window)
    }

    // MARK: rendering

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status); statusColor = c
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        var text: String
        if s.slouchHold > 0 {
            let left = Int(ceil(max(0, s.grace - s.slouchHold)))
            text = left > 0 ? "Slouching\nsit up in \(left)s" : "SLOUCHING\nsit up!"
            statusLabel.stringValue = text
            statusLabel.textColor = left > 0 ? Palette.warn : Palette.alert
        } else if s.status == .good {
            text = "Good posture ✓"; statusLabel.stringValue = text; statusLabel.textColor = Palette.good
        } else {
            text = Palette.label(s.status); statusLabel.stringValue = text; statusLabel.textColor = c
        }
        if model.mode == .continuous { setMenuStatus(s.status, text.replacingOccurrences(of: "\n", with: " ")) }
    }

    /// Periodic-mode background status (camera off between checks).
    private func applyBackgroundStatus(_ text: String, _ st: PostureLogic.Status) {
        guard !text.isEmpty else { return }
        setMenuStatus(st, text)
        statusLabel.stringValue = text
        statusLabel.textColor = Palette.color(st)
        statusColor = Palette.color(st)
    }

    private func cameraDenied() {
        let a = NSAlert(); a.messageText = "Camera access needed"
        a.informativeText = "Enable the camera for PostureMonitor in System Settings → Privacy & Security → Camera, then reopen."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }
    }

    // MARK: menu bar

    private func glyph(_ st: PostureLogic.Status) -> String {
        switch st {
        case .good:     return "checkmark.circle.fill"
        case .slumping: return "exclamationmark.triangle.fill"
        case .settling: return "hourglass"
        case .away:     return "circle.dashed"
        }
    }

    private func setMenuStatus(_ st: PostureLogic.Status, _ text: String) {
        lastStatusText = text
        if let b = statusItem.button {
            let img = NSImage(systemSymbolName: glyph(st), accessibilityDescription: text)
            img?.isTemplate = true
            b.image = img
            b.contentTintColor = Palette.color(st)
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

        m.addItem(check("Calibrate (sit up tall)", #selector(calibrate), false))
        m.addItem(check("Show camera window", #selector(showWindow), false))
        m.addItem(.separator())

        let header = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: ""); header.isEnabled = false
        m.addItem(header)
        m.addItem(check("Continuous (camera always on)", #selector(setContinuous), model.mode == .continuous))
        for mins in [1, 3, 5, 10] {
            m.addItem(check("Periodic — every \(mins) min", #selector(setInterval(_:)),
                            model.mode == .periodic && Int(model.intervalMin) == mins, tag: mins))
        }
        m.addItem(check("   ↳ nudge only after 2 checks", #selector(toggleTwo), model.needsTwo,
                        enabled: model.mode == .periodic))
        m.addItem(.separator())

        let ah = NSMenuItem(title: "Alert me with", action: nil, keyEquivalent: ""); ah.isEnabled = false
        m.addItem(ah)
        m.addItem(check("   Sound", #selector(toggleSound), model.alertSound))
        m.addItem(check("   Screen flash", #selector(toggleFlash), model.alertFlash))
        m.addItem(check("   On-screen banner", #selector(toggleBanner), model.alertBanner))
        m.addItem(check("Mute all sounds", #selector(toggleMuteMenu), model.muted))
        m.addItem(.separator())

        m.addItem(check(model.paused ? "Resume monitoring" : "Pause monitoring", #selector(togglePause), false))
        let q = NSMenuItem(title: "Quit PostureMonitor", action: #selector(quit), keyEquivalent: "q"); q.target = self
        m.addItem(q)
        statusItem.menu = m
    }

    // MARK: overlays

    /// A gentle peripheral edge-glow — not a full-screen wash. Only the screen edges
    /// warm up; the center stays clear so your work is never covered. Eases in/out
    /// slowly so it reads as an ambient cue in your peripheral vision, not a strobe.
    private func flashScreen() {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear
        w.level = .screenSaver; w.ignoresMouseEvents = true; w.hasShadow = false; w.alphaValue = 0

        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let glow = CAGradientLayer()
        glow.frame = v.bounds
        glow.type = .radial
        let tint = NSColor.systemOrange                 // warm + calm, not alarm-red
        glow.colors = [tint.withAlphaComponent(0).cgColor,
                       tint.withAlphaComponent(0).cgColor,
                       tint.withAlphaComponent(0.5).cgColor]
        glow.locations = [0.0, 0.6, 1.0]                // clear center → glow only near the edges
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1.0, y: 1.0)         // radius reaches the corners
        v.layer = glow; v.wantsLayer = true
        w.contentView = v
        w.orderFrontRegardless(); flashWin = w

        // Slow, soft pulse: ~0.4s up, brief hold, ~1.0s down.
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; w.animator().alphaValue = 1 }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NSAnimationContext.runAnimationGroup({ c in c.duration = 1.0; w.animator().alphaValue = 0 }) {
                    w.orderOut(nil); if self.flashWin === w { self.flashWin = nil }
                }
            }
        }
    }

    private func showBanner(_ message: String, good: Bool) {
        bannerWin?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 380, height: 66)
        let f = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 170, width: size.width, height: size.height)
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.level = .floating; w.ignoresMouseEvents = true

        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        v.material = .hudWindow; v.state = .active; v.wantsLayer = true
        v.layer?.cornerRadius = 16; v.layer?.masksToBounds = true
        let dot = NSView(frame: NSRect(x: 20, y: size.height / 2 - 7, width: 14, height: 14))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (good ? NSColor.systemGreen : NSColor.systemRed).cgColor
        dot.layer?.cornerRadius = 7
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

    private func mk(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ col: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: size, weight: w); t.textColor = col; return t
    }

    // MARK: actions

    @objc private func calibrate() { model.recalibrate() }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func togglePause() {
        model.paused.toggle(); pauseButton.title = model.paused ? "Resume" : "Pause"; buildMenu()
    }
    @objc private func toggleMute(_ b: NSButton) { model.muted = (b.state == .on); buildMenu() }
    @objc private func toggleMuteMenu() { model.muted.toggle(); buildMenu() }
    @objc private func sens(_ s: NSSlider) { model.slouchThresh = s.doubleValue; plog("sensitivity -> slouchThresh=\(String(format: "%.2f", s.doubleValue))") }

    @objc private func setContinuous() {
        model.mode = .continuous; Config.set("monitorMode", "continuous"); model.applyMode(); buildMenu()
    }
    @objc private func setInterval(_ s: NSMenuItem) {
        model.mode = .periodic; model.intervalMin = Double(s.tag)
        Config.set("monitorMode", "periodic"); Config.set("sampleIntervalMin", Double(s.tag))
        model.applyMode(); buildMenu()
    }
    @objc private func toggleTwo() { model.needsTwo.toggle(); Config.set("periodicNeedsTwo", model.needsTwo); buildMenu() }
    @objc private func toggleSound() { model.alertSound.toggle(); Config.set("alertSound", model.alertSound); buildMenu() }
    @objc private func toggleFlash() { model.alertFlash.toggle(); Config.set("alertFlash", model.alertFlash); buildMenu() }
    @objc private func toggleBanner() { model.alertBanner.toggle(); Config.set("alertBanner", model.alertBanner); buildMenu() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
