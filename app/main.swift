// main.swift — PostureMonitor: one camera + MediaPipe skeleton overlay on the
// left, a single calm status on the right. Alerts when you slouch.

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
    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    let config = Config.load()
    var muted = false
    var paused = false
    var slouchThresh = 0.87        // live sensitivity (the slider sets this)

    // Two front slouch signals, both baseline-relative:
    private var baseHeadAbove = 0.0, emaHeadAbove = 0.0   // head height ABOVE shoulders (MediaPipe)
    private var baseHeadY = 0.0, emaHeadY = 0.0           // absolute head height (Apple Vision) — catches whole-body sink
    private var slouchSince = 0.0
    private var slouchState = false    // hysteresis-stabilized (no flicker)
    private var lastSlouchAlert = -1e9

    private var lastVision = VisionReading()
    private var lastMP = MPReading()
    private var lastPresent = 0.0
    private var wasAlerted = false
    private var wasCalibrated = false
    private var frames = 0

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
    var onAlert: ((_ message: String, _ good: Bool) -> Void)?

    func start() {
        slouchThresh = config.slouchThresh
        vision.onVision = { [weak self] r in self?.feedVision(r) }
        vision.onFrameJPEG = { [weak self] d in if self?.paused == false { self?.mp.send(d) } }
        vision.onCameraDenied = { [weak self] in self?.onCameraDenied?() }
        mp.onReading = { [weak self] r in self?.lastMP = r }
        vision.start()
    }
    func recalibrate() { logic.recalibrate(); wasCalibrated = false }

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

        // Capture both baselines the moment we calibrate.
        if logic.calibrated && !wasCalibrated {
            baseHeadAbove = emaHeadAbove > 0 ? emaHeadAbove : (lastMP.headAbove ?? 0)
            baseHeadY = emaHeadY > 0 ? emaHeadY : r.headY
        }
        wasCalibrated = logic.calibrated

        // SLOUCH = head drops vs shoulders (MediaPipe) OR whole head sinks (Vision).
        // ONE sensitivity slider (slouchThresh) drives BOTH signals: the head-Y margin
        // is derived from it, so dragging the slider visibly changes everything.
        let slouchRatio = (logic.calibrated && baseHeadAbove > 0 && emaHeadAbove > 0) ? emaHeadAbove / baseHeadAbove : 1
        let headYDrop = (logic.calibrated && baseHeadY > 0 && emaHeadY > 0) ? max(0, baseHeadY - emaHeadY) : 0
        let headYMargin = max(0.015, 0.095 - (slouchThresh - 0.80) * 0.45)   // more sensitive slider -> smaller margin
        let slouchFront = slouchRatio < slouchThresh
        let slouchSink = headYDrop > headYMargin
        // Hysteresis: flip to slouching on a clear drop, back only after a clear recovery.
        if slouchFront || slouchSink { slouchState = true }
        else if slouchRatio > slouchThresh + 0.05 && headYDrop < headYMargin * 0.6 { slouchState = false }
        let slouching = present && logic.calibrated && slouchState

        if slouching {
            if slouchSince == 0 { slouchSince = now }
            if now - slouchSince >= config.slouchGrace && now - lastSlouchAlert >= config.slouchCooldown {
                lastSlouchAlert = now; wasAlerted = true
                plog("ALERT fired (muted=\(muted))")
                alertSound(); speak("sit up straight")
                onAlert?("Sit up tall — you're slouching", false)
                notify("Posture — sit up tall and lengthen your spine.")
            }
        } else {
            slouchSince = 0
            if wasAlerted && slouchRatio > slouchThresh + 0.05 && headYDrop < headYMargin {
                wasAlerted = false; plog("RECOVER (muted=\(muted))"); recoverSound(); onAlert?("Nice — back to good posture", true)
            }
        }

        let slouchFloor = slouchThresh - 0.10
        let frontFrac = max(0, min(1, (slouchRatio - slouchFloor) / max(0.001, 1 - slouchFloor)))
        let headYFrac = (logic.calibrated && baseHeadY > 0) ? max(0, min(1, 1 - headYDrop / (headYMargin + 0.04))) : 1
        let postureFrac = min(frontFrac, headYFrac)
        let score = (present && logic.calibrated) ? Int((postureFrac * 100).rounded()) : -1
        let status: PostureLogic.Status = !present ? .away : (!logic.calibrated ? .settling : (slouching ? .slumping : .good))

        frames += 1
        if frames % 30 == 0 {
            plog("slouch ratio=\(String(format: "%.2f", slouchRatio)) headYdrop=\(String(format: "%.3f", headYDrop)) front=\(slouchFront) sink=\(slouchSink) slouching=\(slouching) score=\(score)")
        }

        onState?(State(
            status: status, score: score, headFrac: postureFrac,
            slouchHold: (slouching && slouchSince > 0) ? (now - slouchSince) : 0, grace: config.slouchGrace,
            points: lastMP.points,
            camW: r.frameW > 0 ? r.frameW : 16, camH: r.frameH > 0 ? r.frameH : 9))
    }

    private func alertSound() { if !muted { run("/usr/bin/afplay", ["/System/Library/Sounds/Funk.aiff"]) } }
    private func recoverSound() { if !muted { run("/usr/bin/afplay", ["/System/Library/Sounds/Glass.aiff"]) } }
    private func speak(_ s: String) { if !muted && config.speakAlerts { run("/usr/bin/say", [s]) } }
    private func notify(_ msg: String) { run("/usr/bin/osascript", ["-e", "display notification \"\(msg)\" with title \"Posture\""]) }
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

// MARK: - Window

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow!
    private var cam: CameraPanel!
    private var statusLabel: NSTextField!
    private var pauseButton: NSButton!
    private var statusColor = Palette.settling

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 980, height: 560)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Posture Monitor"; window.center()
        let content = NSView(frame: rect); content.wantsLayer = true
        content.layer?.backgroundColor = Palette.bg.cgColor

        cam = CameraPanel(session: model.vision.session)
        cam.frame = NSRect(x: 16, y: 64, width: 600, height: 480)
        content.addSubview(cam)

        let rx: CGFloat = 650
        statusLabel = mk("Calibrating…", 34, .bold, Palette.settling)
        statusLabel.frame = NSRect(x: rx, y: 300, width: 320, height: 130)
        statusLabel.maximumNumberOfLines = 3
        content.addSubview(statusLabel)

        // controls
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
        sens.frame = NSRect(x: 372, y: 20, width: 200, height: 22); content.addSubview(sens)

        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()
    }

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status); statusColor = c
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        if s.slouchHold > 0 {
            let left = Int(ceil(max(0, s.grace - s.slouchHold)))
            statusLabel.stringValue = left > 0 ? "Slouching\nsit up in \(left)s" : "SLOUCHING\nsit up!"
            statusLabel.textColor = left > 0 ? Palette.warn : Palette.alert
        } else if s.status == .good {
            statusLabel.stringValue = "Good posture ✓"; statusLabel.textColor = Palette.good
        } else {
            statusLabel.stringValue = Palette.label(s.status); statusLabel.textColor = c
        }
    }

    private func cameraDenied() {
        let a = NSAlert(); a.messageText = "Camera access needed"
        a.informativeText = "Enable the camera for PostureMonitor in System Settings → Privacy & Security → Camera, then reopen."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }
    }

    private func mk(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, _ col: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: size, weight: w); t.textColor = col; return t
    }

    @objc private func calibrate() { model.recalibrate() }
    @objc private func togglePause() { model.paused.toggle(); pauseButton.title = model.paused ? "Resume" : "Pause" }
    @objc private func toggleMute(_ b: NSButton) { model.muted = (b.state == .on) }
    @objc private func sens(_ s: NSSlider) { model.slouchThresh = s.doubleValue; plog("sensitivity -> slouchThresh=\(String(format: "%.2f", s.doubleValue))") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
