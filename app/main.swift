// main.swift — PostureMonitor v2: LEFT = live camera + MediaPipe skeleton
// overlay; RIGHT = score / status / bars. Native camera + Vision (fast face
// metrics) + MediaPipe (server, real shoulders + landmarks).

import AppKit
import AVFoundation

// MARK: - App model (fusion + alerts)

final class AppModel {
    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    let config = Config.load()
    var muted = false
    var paused = false

    private var lastVision = VisionReading()
    private var lastMP = MPReading()
    private var lastPresent = 0.0
    private var wasAlerted = false
    private var wasCalibrated = false
    private var emaTilt = 0.0          // smoothed shoulder tilt for the (jittery) lean bar
    private var frames = 0
    private let cueDir = Bundle.main.resourcePath ?? "cues"
    private let logURL = URL(fileURLWithPath: "/tmp/posture-monitor.log")

    struct State {
        var status: PostureLogic.Status
        var score: Int
        var headFrac: Double
        var leanFrac: Double
        var distFrac: Double
        var points: [String: (CGPoint, Double)]   // MediaPipe landmarks for the overlay
        var camW: Double
        var camH: Double
        var recording: Bool
        var visionText: String
        var mpText: String
    }
    var onState: ((State) -> Void)?
    var onCameraDenied: (() -> Void)?

    func start() {
        logic.sensitivity = config.sensitivity        // tunable defaults from config
        logic.tiltThresh = config.tiltThresh
        logic.proximityMargin = config.proximityMargin
        vision.onVision = { [weak self] r in self?.feedVision(r) }
        vision.onFrameJPEG = { [weak self] d in if self?.paused == false { self?.mp.send(d) } }
        vision.onCameraDenied = { [weak self] in self?.onCameraDenied?() }
        mp.onReading = { [weak self] r in self?.lastMP = r }
        vision.start()
        if config.autoRecord {
            vision.startRecording()    // auto-record from launch (for training clips)
            log("recording started (auto)")
        }
    }
    func recalibrate() { logic.recalibrate(); wasCalibrated = false }

    /// Toggle clip recording. Calls back with the new recording state.
    func toggleRecord(_ done: @escaping (Bool) -> Void) {
        if vision.isRecording {
            vision.stopRecording { [weak self] url in
                if let u = url { self?.log("saved clip -> \(u.path)") }
                done(false)
            }
        } else {
            vision.startRecording(); log("recording started"); done(true)
        }
    }

    private func feedVision(_ r: VisionReading) {
        lastVision = r
        let now = ProcessInfo.processInfo.systemUptime
        if r.faceFound { lastPresent = now }
        let present = !paused && r.faceFound && (now - lastPresent <= 1.0)

        // FUSION (both engines every frame, each for what it's best at):
        //   slump (head) + distance (width) ← Apple Vision (fast, always available)
        //   lean (tilt)                      ← MediaPipe shoulder tilt (Vision can't see lean)
        let head = present ? r.headY : nil
        let width = present ? r.faceSize : nil
        let tiltDeg = lastMP.shouldersFound ? (lastMP.tiltDeg ?? 0) : 0
        let tilt: Double? = present ? tiltDeg : nil
        emaTilt = emaTilt * 0.9 + tiltDeg * 0.1     // heavy smoothing -> the lean bar glides

        let res = logic.update(now: now, present: present, head: head, tilt: tilt, width: width)

        if res.fire {
            wasAlerted = true
            playCue(res.tooClose ? "posture_close.wav" : "posture_slump.wav")
            notify(res.tooClose ? "Ease back — you're leaning into the screen."
                                : "Sit up — your posture has drifted. Reset and breathe.")
        } else if res.status == .good && wasAlerted {
            wasAlerted = false; playCue("posture_good.wav")
        }

        // Record the calibration baseline into the clip's sidecar — so a recorded
        // clip knows "where the user started" for later analysis/training.
        if logic.calibrated && !wasCalibrated {
            vision.recorder.event(["type": "calibrate",
                                   "baseHead": logic.baseHead ?? 0,
                                   "baseTilt": logic.baseTilt,
                                   "baseWidth": logic.baseWidth])
        }
        wasCalibrated = logic.calibrated

        frames += 1
        if frames % 30 == 0 {
            log("fused status=\(res.status) ratio=\(String(format: "%.2f", res.ratio)) tilt=\(String(format: "%.0f", tiltDeg)) mpShoulders=\(lastMP.shouldersFound) pts=\(lastMP.points.count) rec=\(vision.isRecording)")
            vision.recorder.event(["type": "sample", "status": "\(res.status)",
                                   "ratio": (res.ratio * 100).rounded() / 100,
                                   "headY": (r.headY * 1000).rounded() / 1000,
                                   "faceSize": (r.faceSize * 1000).rounded() / 1000,
                                   "tilt": tiltDeg, "mpShoulders": lastMP.shouldersFound])
        }

        // Three dimensions, each 0..1 (1 = matches your calibrated baseline).
        let headFrac = max(0, min(1, res.ratio))
        let leanFrac = logic.calibrated ? max(0, 1 - abs(emaTilt - logic.baseTilt) / logic.tiltThresh) : 1
        let distFrac = (logic.calibrated && logic.baseWidth > 0)
            ? max(0, min(1, logic.baseWidth / max(0.0001, r.faceSize))) : 1
        // Composite score = the weakest dimension, so any problem pulls it below 100.
        // -1 = no score yet (calibrating / away) -> shown as "--", not a fake 100.
        let score = (present && logic.calibrated) ? Int((min(headFrac, leanFrac, distFrac) * 100).rounded()) : -1

        onState?(State(
            status: res.status, score: score,
            headFrac: headFrac, leanFrac: leanFrac, distFrac: distFrac,
            points: lastMP.points,
            camW: r.frameW > 0 ? r.frameW : 16, camH: r.frameH > 0 ? r.frameH : 9,
            recording: vision.isRecording,
            visionText: r.faceFound ? String(format: "Vision  head %.2f · size %.2f", r.headY, r.faceSize) : "Vision  (no face)",
            mpText: lastMP.ok ? String(format: "MediaPipe  %@ · %d pts",
                                       lastMP.shouldersFound ? "shoulders ✓" : "no shoulders", lastMP.points.count)
                              : "MediaPipe  (server off?)"))
    }

    private func playCue(_ name: String) { if !muted { run("/usr/bin/afplay", [cueDir + "/" + name]) } }
    private func notify(_ msg: String) { run("/usr/bin/osascript", ["-e", "display notification \"\(msg)\" with title \"Posture\""]) }
    private func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; try? p.run()
    }
    private func log(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: logURL) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? d.write(to: logURL) }
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
        // The video is aspect-FIT inside our bounds. Compute that exact rect and
        // map normalized MediaPipe coords (top-left) into it. Preview is mirrored
        // (selfie), so mirror x to match.
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

// MARK: - Simple bar

final class BarView: NSView {
    private let fill = CALayer()
    var frac: CGFloat = 1 { didSet { relayout() } }
    var color = Palette.good { didSet { fill.backgroundColor = color.cgColor } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = Palette.track.cgColor; layer?.cornerRadius = 5
        fill.cornerRadius = 5; fill.backgroundColor = color.cgColor; layer?.addSublayer(fill); relayout()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); relayout() }
    private func relayout() { fill.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0, min(1, frac)), height: bounds.height) }
}

// MARK: - Window

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var window: NSWindow!
    private var cam: CameraPanel!
    private var scoreLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var visLabel: NSTextField!
    private var mpLabel: NSTextField!
    private var bars: [String: BarView] = [:]
    private var pauseButton: NSButton!
    private var recordButton: NSButton!
    private var recIndicator: NSTextField!
    private var blinkTimer: Timer?
    private var sideCam: SideCamera?
    private var sideLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 740, height: 480)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Posture Monitor"; window.center()
        let content = NSView(frame: rect); content.wantsLayer = true
        content.layer?.backgroundColor = Palette.bg.cgColor

        cam = CameraPanel(session: model.vision.session)
        cam.frame = NSRect(x: 16, y: 64, width: 420, height: 400)
        content.addSubview(cam)

        recIndicator = mk("● REC", 13, .bold, Palette.alert)
        recIndicator.frame = NSRect(x: 30, y: 432, width: 90, height: 20)
        content.addSubview(recIndicator)

        let rx: CGFloat = 460
        scoreLabel = mk("--", 60, .bold, Palette.settling); scoreLabel.frame = NSRect(x: rx, y: 386, width: 260, height: 70)
        content.addSubview(scoreLabel)
        statusLabel = mk("Calibrating…", 19, .semibold, Palette.settling); statusLabel.frame = NSRect(x: rx, y: 352, width: 260, height: 28)
        content.addSubview(statusLabel)

        var y: CGFloat = 300
        for name in ["Head height", "Lean", "Distance"] {
            let l = mk(name, 12, .regular, Palette.textMuted); l.frame = NSRect(x: rx, y: y, width: 260, height: 16)
            content.addSubview(l)
            let bar = BarView(frame: NSRect(x: rx, y: y - 16, width: 250, height: 10))
            content.addSubview(bar); bars[name] = bar
            y -= 50
        }

        visLabel = mk("Vision …", 11, .regular, Palette.textMuted); visLabel.frame = NSRect(x: rx, y: 120, width: 270, height: 16)
        content.addSubview(visLabel)
        mpLabel = mk("MediaPipe …", 11, .regular, NSColor(srgbRed: 0.36, green: 0.86, blue: 1, alpha: 1)); mpLabel.frame = NSRect(x: rx, y: 100, width: 270, height: 16)
        content.addSubview(mpLabel)

        // controls
        let cal = NSButton(title: "Calibrate", target: self, action: #selector(calibrate))
        cal.frame = NSRect(x: 16, y: 16, width: 100, height: 30); cal.bezelStyle = .rounded; cal.keyEquivalent = "\r"
        content.addSubview(cal)
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.frame = NSRect(x: 122, y: 16, width: 76, height: 30); pauseButton.bezelStyle = .rounded
        content.addSubview(pauseButton)
        let rec = model.config.autoRecord
        recordButton = NSButton(title: rec ? "⏸ Rec" : "● Rec", target: self, action: #selector(toggleRecord))
        recordButton.frame = NSRect(x: 204, y: 16, width: 96, height: 30); recordButton.bezelStyle = .rounded
        recordButton.contentTintColor = rec ? Palette.alert : nil
        content.addSubview(recordButton)
        let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(toggleMute))
        mute.frame = NSRect(x: 312, y: 20, width: 64, height: 22); content.addSubview(mute)
        let calLbl = mk("sensitivity", 11, .regular, Palette.textMuted)
        calLbl.frame = NSRect(x: 392, y: 20, width: 70, height: 18); content.addSubview(calLbl)
        let sens = NSSlider(value: model.config.sensitivity, minValue: 0.70, maxValue: 0.95, target: self, action: #selector(sens(_:)))
        sens.frame = NSRect(x: 470, y: 20, width: 250, height: 22); content.addSubview(sens)

        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()

        // EXPERIMENTAL side camera (gated). Default off -> stable app untouched.
        sideLabel = mk("", 12, .regular, NSColor(srgbRed: 0.36, green: 0.86, blue: 1, alpha: 1))
        sideLabel.frame = NSRect(x: 460, y: 78, width: 270, height: 16)
        content.addSubview(sideLabel)
        if model.config.sideCamera {
            let sc = SideCamera()
            sc.onSide = { [weak self] deg, present in
                self?.sideLabel.stringValue = present
                    ? String(format: "Side  forward-head %.0f°", deg ?? 0)
                    : "Side  (no person)"
            }
            sc.start()
            sideLabel.stringValue = sc.available ? "Side  starting…" : "Side  connect a 2nd camera / iPhone"
            sideCam = sc
        }

        // blink the REC dot while recording
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let r = self?.recIndicator, !r.isHidden else { return }
            r.alphaValue = r.alphaValue > 0.6 ? 0.25 : 1.0
        }
    }

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status)
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        scoreLabel.stringValue = s.score < 0 ? "--" : "\(s.score)"; scoreLabel.textColor = c
        statusLabel.stringValue = Palette.label(s.status); statusLabel.textColor = c
        bars["Head height"]?.frac = CGFloat(s.headFrac); bars["Head height"]?.color = c
        bars["Lean"]?.frac = CGFloat(s.leanFrac); bars["Lean"]?.color = c
        bars["Distance"]?.frac = CGFloat(s.distFrac); bars["Distance"]?.color = c
        visLabel.stringValue = s.visionText; mpLabel.stringValue = s.mpText
        recIndicator.isHidden = !s.recording
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

    @objc private func toggleRecord() {
        model.toggleRecord { [weak self] recording in
            self?.recordButton.title = recording ? "⏸ Rec" : "● Rec"
            self?.recordButton.contentTintColor = recording ? Palette.alert : nil
        }
    }
    @objc private func calibrate() { model.recalibrate() }
    @objc private func togglePause() { model.paused.toggle(); pauseButton.title = model.paused ? "Resume" : "Pause" }
    @objc private func toggleMute(_ b: NSButton) { model.muted = (b.state == .on) }
    @objc private func sens(_ s: NSSlider) { model.logic.sensitivity = s.doubleValue }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
