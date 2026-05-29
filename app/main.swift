// main.swift — PostureMonitor v2: LEFT = live camera + MediaPipe skeleton
// overlay; RIGHT = score / status / bars. Native camera + Vision (fast face
// metrics) + MediaPipe (server, real shoulders + landmarks).

import AppKit
import AVFoundation

// MARK: - App model (fusion + alerts)

final class AppModel {
    enum Source { case vision, mediapipe }

    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    var source: Source = .vision
    var muted = false
    var paused = false

    private var lastVision = VisionReading()
    private var lastMP = MPReading()
    private var lastPresent = 0.0
    private var wasAlerted = false
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
        var visionText: String
        var mpText: String
    }
    var onState: ((State) -> Void)?
    var onCameraDenied: (() -> Void)?

    func start() {
        vision.onVision = { [weak self] r in self?.feedVision(r) }
        vision.onFrameJPEG = { [weak self] d in if self?.paused == false { self?.mp.send(d) } }
        vision.onCameraDenied = { [weak self] in self?.onCameraDenied?() }
        mp.onReading = { [weak self] r in self?.lastMP = r }
        vision.start()
    }
    func recalibrate() { logic.recalibrate() }
    func setSource(_ s: Source) { source = s; logic.recalibrate() }

    private func feedVision(_ r: VisionReading) {
        lastVision = r
        let now = ProcessInfo.processInfo.systemUptime
        if r.faceFound { lastPresent = now }
        let present = !paused && r.faceFound && (now - lastPresent <= 1.0)

        let head: Double?, tilt: Double?, width: Double?
        if source == .mediapipe, lastMP.shouldersFound, let ha = lastMP.headAbove {
            head = present ? ha : nil; tilt = lastMP.tiltDeg ?? 0; width = lastMP.width ?? 0
        } else {
            head = present ? r.headY : nil; tilt = r.roll; width = r.faceSize
        }

        let res = logic.update(now: now, present: present, head: head, tilt: tilt, width: width)

        if res.fire {
            wasAlerted = true
            playCue(res.tooClose ? "posture_close.wav" : "posture_slump.wav")
            notify(res.tooClose ? "Ease back — you're leaning into the screen."
                                : "Sit up — your posture has drifted. Reset and breathe.")
        } else if res.status == .good && wasAlerted {
            wasAlerted = false; playCue("posture_good.wav")
        }

        let tiltDeg = source == .mediapipe ? (lastMP.tiltDeg ?? 0) : r.roll
        frames += 1
        if frames % 30 == 0 {
            log("src=\(source) status=\(res.status) ratio=\(String(format: "%.2f", res.ratio)) mpShoulders=\(lastMP.shouldersFound) pts=\(lastMP.points.count)")
        }

        onState?(State(
            status: res.status, score: max(0, min(100, Int(res.ratio * 100))),
            headFrac: max(0, min(1, res.ratio)),
            leanFrac: max(0, 1 - abs(tiltDeg) / 15),
            distFrac: res.tooClose ? 0.35 : 0.85,
            points: lastMP.points,
            camW: r.frameW > 0 ? r.frameW : 16, camH: r.frameH > 0 ? r.frameH : 9,
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
        cal.frame = NSRect(x: 16, y: 18, width: 110, height: 30); cal.bezelStyle = .rounded; cal.keyEquivalent = "\r"
        content.addSubview(cal)
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pauseButton.frame = NSRect(x: 134, y: 18, width: 80, height: 30); pauseButton.bezelStyle = .rounded
        content.addSubview(pauseButton)
        let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(toggleMute))
        mute.frame = NSRect(x: 226, y: 22, width: 64, height: 22); content.addSubview(mute)
        let mpT = NSButton(checkboxWithTitle: "MediaPipe drives alerts", target: self, action: #selector(toggleSource))
        mpT.frame = NSRect(x: 300, y: 22, width: 210, height: 22); content.addSubview(mpT)
        let sens = NSSlider(value: 0.85, minValue: 0.70, maxValue: 0.95, target: self, action: #selector(sens(_:)))
        sens.frame = NSRect(x: 560, y: 22, width: 160, height: 22); content.addSubview(sens)

        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()
    }

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status)
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        scoreLabel.stringValue = "\(s.score)"; scoreLabel.textColor = c
        statusLabel.stringValue = Palette.label(s.status); statusLabel.textColor = c
        bars["Head height"]?.frac = CGFloat(s.headFrac); bars["Head height"]?.color = c
        bars["Lean"]?.frac = CGFloat(s.leanFrac); bars["Lean"]?.color = c
        bars["Distance"]?.frac = CGFloat(s.distFrac); bars["Distance"]?.color = c
        visLabel.stringValue = s.visionText; mpLabel.stringValue = s.mpText
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
    @objc private func toggleSource(_ b: NSButton) { model.setSource(b.state == .on ? .mediapipe : .vision) }
    @objc private func sens(_ s: NSSlider) { model.logic.sensitivity = s.doubleValue }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
