// main.swift — PostureMonitor v2: LEFT = live camera + MediaPipe skeleton
// overlay; RIGHT = score / status / bars. Native camera + Vision (fast face
// metrics) + MediaPipe (server, real shoulders + landmarks).

import AppKit
import AVFoundation

// Shared logger — both AppModel and the side-camera path write to one file so
// the whole pipeline (front fusion + side cam) is visible in one timeline.
let posLogURL = URL(fileURLWithPath: "/tmp/posture-monitor.log")
func plog(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: posLogURL) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
    else { try? d.write(to: posLogURL) }
}

// MARK: - App model (fusion + alerts)

final class AppModel {
    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    let config = Config.load()
    var muted = false
    var paused = false
    var sideActive = false         // a side camera is wired (shows the Shoulders bar)
    var sideTrusted = false        // LLM confirms the side view is a usable profile -> count it
    var sideForwardFrac = 1.0      // 1 = no side cam / good; drops with forward-head
    private var emaSideDeg = 0.0   // smoothed side forward-head angle (raw is jittery)
    private var sideBaseDeg: Double?   // neutral angle captured at calibration
    private var sideSeen = false
    private var lastJudgeAlert = -1e9

    private var lastVision = VisionReading()
    private var lastMP = MPReading()
    private var lastPresent = 0.0
    private var wasAlerted = false
    private var wasCalibrated = false
    private var emaTilt = 0.0          // smoothed shoulder tilt for the (jittery) lean bar
    private var frames = 0
    private let cueDir = Bundle.main.resourcePath ?? "cues"

    struct State {
        var status: PostureLogic.Status
        var score: Int
        var headFrac: Double
        var leanFrac: Double
        var distFrac: Double
        var shoulderFrac: Double = 1               // side-cam forward-head (1 = at neutral)
        var sideActive: Bool = false               // show the Shoulders bar?
        var sideTrusted: Bool = false              // does it count toward the score?
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
        // clip knows "where the user started" for later analysis/training. Capture
        // the side-cam neutral angle at the same moment so it's baseline-relative too.
        if logic.calibrated && !wasCalibrated {
            if sideSeen { sideBaseDeg = emaSideDeg }
            vision.recorder.event(["type": "calibrate",
                                   "baseHead": logic.baseHead ?? 0,
                                   "baseTilt": logic.baseTilt,
                                   "baseWidth": logic.baseWidth,
                                   "baseSideDeg": sideBaseDeg ?? -1])
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
        // Composite score = the weakest dimension. The side camera only counts when
        // the LLM has confirmed it's a usable profile (sideTrusted) — otherwise a
        // poor side view would drag the score down on noise. sideFrac is 1 when the
        // side is absent/untrusted, so it's a no-op then.
        let sideFrac = (sideActive && sideTrusted) ? sideForwardFrac : 1.0
        let score = (present && logic.calibrated)
            ? Int((min(headFrac, leanFrac, distFrac, sideFrac) * 100).rounded()) : -1

        onState?(State(
            status: res.status, score: score,
            headFrac: headFrac, leanFrac: leanFrac, distFrac: distFrac,
            shoulderFrac: sideForwardFrac, sideActive: sideActive, sideTrusted: sideTrusted,
            points: lastMP.points,
            camW: r.frameW > 0 ? r.frameW : 16, camH: r.frameH > 0 ? r.frameH : 9,
            recording: vision.isRecording,
            visionText: r.faceFound ? String(format: "Vision  head %.2f · size %.2f", r.headY, r.faceSize) : "Vision  (no face)",
            mpText: lastMP.ok ? String(format: "MediaPipe  %@ · %d pts",
                                       lastMP.shouldersFound ? "shoulders ✓" : "no shoulders", lastMP.points.count)
                              : "MediaPipe  (server off?)"))
    }

    // Side-camera forward-head -> a 0..1 score fraction, smoothed + baseline-relative
    // (mirrors the front metrics). Until calibrated, the current angle is treated as
    // neutral so it never falsely penalizes; once calibrated we score the deviation.
    // not-present -> the penalty eases back toward 1.
    func feedSide(deg: Double?, present: Bool) -> Double {
        guard present, let deg else { sideForwardFrac = sideForwardFrac * 0.9 + 0.1; return sideForwardFrac }
        if !sideSeen { emaSideDeg = deg; sideSeen = true }
        emaSideDeg = emaSideDeg * 0.8 + deg * 0.2          // smooth the jittery raw angle
        let dev = max(0, emaSideDeg - (sideBaseDeg ?? emaSideDeg))   // ° of forward-head beyond neutral
        sideForwardFrac = max(0, min(1, 1 - dev / 20))     // full at neutral, empty ~20° beyond
        return sideForwardFrac
    }

    // Apply a vision-LLM posture judgment: (1) decide whether the side camera is
    // a usable profile (gates its score contribution), (2) fire an alert when the
    // LLM is confident the posture is bad. Independent of the heuristic alerts.
    func applyJudge(_ j: JudgeResult, minConfidence: Double) {
        sideTrusted = j.sideUsable
        guard !paused, j.bad, j.confidence >= minConfidence else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastJudgeAlert >= logic.cooldown else { return }
        lastJudgeAlert = now
        let close = (j.posture == "too_close")
        playCue(close ? "posture_close.wav" : "posture_slump.wav")
        notify("Posture check — \(j.note.isEmpty ? j.posture : j.note). Reset and sit tall.")
        log("judge ALERT posture=\(j.posture) conf=\(String(format: "%.2f", j.confidence)) note=\(j.note)")
    }

    private func playCue(_ name: String) { if !muted { run("/usr/bin/afplay", [cueDir + "/" + name]) } }
    private func notify(_ msg: String) { run("/usr/bin/osascript", ["-e", "display notification \"\(msg)\" with title \"Posture\""]) }
    private func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; try? p.run()
    }
    private func log(_ s: String) { plog(s) }
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
    private var judgeTimer: Timer?
    private var sideCam: SideCamera?
    private var sidePanel: CameraPanel?
    private var sideLabel: NSTextField!
    private var sideHint: NSTextField!
    private let placement = PlacementClient()
    private var statusColor = Palette.settling

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 740, height: 480)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Posture Monitor"; window.center()
        let content = NSView(frame: rect); content.wantsLayer = true
        content.layer?.backgroundColor = Palette.bg.cgColor

        // Cameras as FEEDS — front always; side when enabled & available. Layout and
        // rendering iterate this list, so switching 1<->2 cameras is data, not branches.
        cam = CameraPanel(session: model.vision.session)
        content.addSubview(cam)
        var panels: [CameraPanel] = [cam]

        sideLabel = mk("", 12, .regular, NSColor(srgbRed: 0.36, green: 0.86, blue: 1, alpha: 1))
        sideLabel.frame = NSRect(x: 460, y: 78, width: 270, height: 16)
        content.addSubview(sideLabel)
        sideHint = mk("", 11, .regular, Palette.warn)        // LLM camera-placement guidance
        sideHint.frame = NSRect(x: 460, y: 56, width: 270, height: 18)
        sideHint.maximumNumberOfLines = 2; sideHint.lineBreakMode = .byWordWrapping
        content.addSubview(sideHint)

        if model.config.sideCamera {
            let sc = SideCamera(); sideCam = sc
            plog("side: enabled; device=\(sc.deviceName ?? "none") available=\(sc.available)")
            if sc.available {
                model.sideActive = true
                let sp = CameraPanel(session: sc.session); sidePanel = sp
                content.addSubview(sp); panels.append(sp)
                var sideLast = 0.0
                sc.onFrame = { [weak self] pts, w, h, deg, present in
                    guard let self else { return }
                    self.sidePanel?.setLandmarks(pts, color: self.statusColor, camSize: CGSize(width: w, height: h))
                    let frac = self.model.feedSide(deg: deg, present: present)   // smoothed + baseline-relative
                    self.sideLabel.stringValue = present ? String(format: "Side  forward-head %.0f°", deg ?? 0) : "Side  (no person)"
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - sideLast > 3 {   // ~every 3s, don't flood
                        sideLast = now
                        plog(String(format: "side: present=%@ deg=%.0f frac=%.2f pts=%d",
                                    present ? "true" : "false", deg ?? -1, frac, pts.count))
                    }
                }
            }
            sc.start()
            sideLabel.stringValue = sc.available ? "Side  starting…" : "Side  connect a 2nd camera / iPhone"
        }

        // Once cameras have a frame, let the vision LLM diagnose the setup (works
        // front-only too; re-run anytime via Calibrate or the 🔍 Diagnose button).
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.diagnoseSetup(showModal: false) }

        // lay the active panels across the camera region (no per-camera branching)
        let region = NSRect(x: 16, y: 64, width: 420, height: 400)
        let gap: CGFloat = 8
        let pw = (region.width - gap * CGFloat(panels.count - 1)) / CGFloat(panels.count)
        for (i, p) in panels.enumerated() {
            p.frame = NSRect(x: region.minX + CGFloat(i) * (pw + gap), y: region.minY, width: pw, height: region.height)
        }

        recIndicator = mk("● REC", 13, .bold, Palette.alert)
        recIndicator.frame = NSRect(x: 30, y: 432, width: 90, height: 20)
        content.addSubview(recIndicator)

        let rx: CGFloat = 460
        scoreLabel = mk("--", 60, .bold, Palette.settling); scoreLabel.frame = NSRect(x: rx, y: 386, width: 260, height: 70)
        content.addSubview(scoreLabel)
        statusLabel = mk("Calibrating…", 19, .semibold, Palette.settling); statusLabel.frame = NSRect(x: rx, y: 352, width: 260, height: 28)
        content.addSubview(statusLabel)

        // The side camera adds a "Shoulders" dimension (forward-head / rounded
        // shoulders) — the axis a front camera can't see.
        var y: CGFloat = 300
        let dims = ["Head height", "Lean", "Distance"] + (model.sideActive ? ["Shoulders"] : [])
        for name in dims {
            let l = mk(name, 12, .regular, Palette.textMuted); l.frame = NSRect(x: rx, y: y, width: 260, height: 16)
            content.addSubview(l)
            let bar = BarView(frame: NSRect(x: rx, y: y - 16, width: 250, height: 10))
            content.addSubview(bar); bars[name] = bar
            y -= 45
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
        sens.frame = NSRect(x: 464, y: 20, width: 150, height: 22); content.addSubview(sens)
        // Vision-LLM setup diagnosis — looks at front (+ side) and explains the setup.
        let diag = NSButton(title: "🔍 Diagnose", target: self, action: #selector(diagnose))
        diag.frame = NSRect(x: 624, y: 16, width: 108, height: 30); diag.bezelStyle = .rounded
        content.addSubview(diag)

        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()

        // blink the REC dot while recording
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let r = self?.recIndicator, !r.isHidden else { return }
            r.alphaValue = r.alphaValue > 0.6 ? 0.25 : 1.0
        }

        // Periodic vision-LLM posture judge: gates the side camera's trust + alerts
        // on high-confidence bad posture. Cheap (one call every judgeInterval).
        if model.config.llmJudge {
            judgeTimer = Timer.scheduledTimer(withTimeInterval: max(10, model.config.judgeInterval),
                                              repeats: true) { [weak self] _ in self?.runJudge() }
        }
    }

    // Capture current front (+ side) frames and ask the LLM to judge posture.
    private func runJudge() {
        guard let front = model.vision.lastJPEG else { return }
        let side = sideCam?.lastJPEG
        placement.judge(front: front, side: side) { [weak self] j in
            guard let self, let j else { return }
            self.model.applyJudge(j, minConfidence: self.model.config.judgeConfidence)
            plog("judge posture=\(j.posture) conf=\(String(format: "%.2f", j.confidence)) sideUsable=\(j.sideUsable) note=\(j.note)")
            if self.model.sideActive {
                self.sideHint.stringValue = (j.sideUsable ? "✓ side counts · " : "⚠︎ side not counted · ") + (j.note.isEmpty ? j.posture : j.note)
                self.sideHint.textColor = j.sideUsable ? Palette.good : Palette.warn
            }
        }
    }

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status); statusColor = c
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        scoreLabel.stringValue = s.score < 0 ? "--" : "\(s.score)"; scoreLabel.textColor = c
        statusLabel.stringValue = Palette.label(s.status); statusLabel.textColor = c
        bars["Head height"]?.frac = CGFloat(s.headFrac); bars["Head height"]?.color = c
        bars["Lean"]?.frac = CGFloat(s.leanFrac); bars["Lean"]?.color = c
        bars["Distance"]?.frac = CGFloat(s.distFrac); bars["Distance"]?.color = c
        // Shoulders is muted gray when the side view isn't trusted (shown, not counted).
        bars["Shoulders"]?.frac = CGFloat(s.shoulderFrac)
        bars["Shoulders"]?.color = s.sideTrusted ? c : Palette.textMuted
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
    @objc private func calibrate() { model.recalibrate(); diagnoseSetup(showModal: false) }
    @objc private func diagnose() { diagnoseSetup(showModal: true) }

    // Vision-LLM setup diagnosis: send the front (+ side) frame and let the LLM
    // reason about the whole setup — why it works, what's wrong right now, the one
    // fix. showModal=true (the Diagnose button) shows the full explanation; the
    // auto/Calibrate path just updates the short hint. Frames + verdict are saved
    // for later use. Bounded calls (launch + Calibrate + button), not per-frame.
    private func diagnoseSetup(showModal: Bool) {
        guard let front = model.vision.lastJPEG else {
            if showModal { simpleAlert("No camera frame yet", "Grant camera access and wait a moment, then try again.") }
            return
        }
        let side = sideCam?.lastJPEG
        sideHint.stringValue = "Diagnosing setup with vision AI…"; sideHint.textColor = Palette.textMuted
        placement.assess(front: front, side: side) { [weak self] a in
            guard let self else { return }
            guard let a else {
                sideHint.stringValue = "Setup diagnosis unavailable (server?)"
                if showModal { self.simpleAlert("Diagnosis unavailable", "The vision server didn't respond. Is it running on :8000?") }
                return
            }
            let short = a.fix.isEmpty ? a.problem : a.fix
            sideHint.stringValue = (a.sideOK || (!a.hasSide && a.frontOK) ? "✓ " : "⚠︎ ") + short
            sideHint.textColor = (a.frontOK && (a.sideOK || !a.hasSide)) ? Palette.good : Palette.warn
            plog("diagnose: front_ok=\(a.frontOK) side_ok=\(a.sideOK) posture=\(a.posture) problem=\(a.problem) fix=\(a.fix)")
            self.saveDiagnosis(front: front, side: side, a: a)
            if showModal {
                let cams = "Front: \(a.frontOK ? "✓ usable" : "⚠︎ issue")   Side: \(a.hasSide ? (a.sideOK ? "✓ usable" : "⚠︎ issue") : "— none")"
                let body = "\(a.explanation)\n\n\(cams)\nPosture now: \(a.posture)" + (a.fix.isEmpty ? "" : "\n\nFix: \(a.fix)")
                self.simpleAlert("Camera setup diagnosis", body)
            }
        }
    }

    private func simpleAlert(_ title: String, _ body: String) {
        let al = NSAlert(); al.messageText = title; al.informativeText = body
        al.addButton(withTitle: "OK"); al.runModal()
    }

    // Save the front/side frames + the LLM verdict for later review / tuning.
    private func saveDiagnosis(front: Data, side: Data?, a: SetupAssessment) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/PostureMonitor/setups")
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = base.appendingPathComponent("setup_\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? front.write(to: dir.appendingPathComponent("front.jpg"))
        if let side { try? side.write(to: dir.appendingPathComponent("side.jpg")) }
        let verdict: [String: Any] = ["front_ok": a.frontOK, "side_ok": a.sideOK, "has_side": a.hasSide,
                                      "posture": a.posture, "problem": a.problem, "fix": a.fix, "explanation": a.explanation]
        if let d = try? JSONSerialization.data(withJSONObject: verdict, options: .prettyPrinted) {
            try? d.write(to: dir.appendingPathComponent("assessment.json"))
        }
    }
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
