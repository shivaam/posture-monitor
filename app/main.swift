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

// A dimension score 0..1: a full 1 within a DEADZONE of the calibrated baseline,
// then linear down to 0 at the "bad" threshold. So small natural drift reads as
// 100 and the score only falls once you've meaningfully moved. `dev` is how far
// past baseline you are; `thresh` is the deviation that means bad.
func tolFrac(_ dev: Double, _ thresh: Double, dead: Double = 0.35) -> Double {
    let d = thresh * dead
    return max(0, min(1, 1 - max(0, dev - d) / max(0.001, thresh - d)))
}

// MARK: - App model (fusion + alerts)

final class AppModel {
    let vision = VisionEngine()
    let mp = MediaPipeClient()
    let logic = PostureLogic()
    let config = Config.load()
    var muted = false
    var paused = false
    var slouchThresh = 0.87        // live sensitivity (head-drop ratio); the slider sets this
    var sideActive = false         // a side camera is wired (shows the Shoulders bar)
    var sideTrusted = false        // LLM confirms the side view is a usable profile -> count it
    var sideForwardFrac = 1.0      // 1 = no side cam / good; drops with forward-head
    private(set) var lastMetrics: [String: Any] = [:]   // latest raw metrics + call, for the self-loop
    private var emaSideDeg = 0.0   // smoothed side forward-head angle (raw is jittery)
    private var sideBaseDeg: Double?   // neutral angle captured at calibration
    private var sideSeen = false
    private var baseShoulderW = 0.0    // MediaPipe shoulder width at calibration (for rotation guard)
    private var lastJudgeAlert = -1e9
    private var leanOKUntil = 0.0      // LLM recently confirmed "not leaning" -> trust it over the noisy tilt
    // SIMPLE SLOUCH CORE — the one signal that works (head height above shoulders).
    private var baseHeadAbove = 0.0    // calibrated upright value
    private var emaHeadAbove = 0.0     // smoothed live value
    private var baseHeadY = 0.0        // calibrated absolute head position (Vision face-Y)
    private var emaHeadY = 0.0         // smoothed live head-Y (catches whole-body sink)
    private var slouchSince = 0.0      // when the current slouch started (0 = not slouching)
    private var slouchState = false    // hysteresis-stabilized slouch flag (no flicker)
    private var lastSlouchAlert = -1e9

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
        var slouchHold: Double = 0                 // seconds the current slouch has been held (0 = not slouching)
        var grace: Double = 8                      // seconds of slouch before the alarm fires
        var points: [String: (CGPoint, Double)]   // MediaPipe landmarks for the overlay
        var camW: Double
        var camH: Double
        var recording: Bool
        var visionText: String
        var mpText: String
    }
    var onState: ((State) -> Void)?
    var onCameraDenied: (() -> Void)?
    var onAlert: ((_ message: String, _ good: Bool) -> Void)?   // drives the on-screen toast

    func start() {
        slouchThresh = config.slouchThresh             // live sensitivity from config
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
        emaTilt = emaTilt * 0.9 + tiltDeg * 0.1     // heavy smoothing -> the lean bar glides

        // ROTATION GUARD: when you TURN (yaw) your shoulders foreshorten — the
        // shoulder line looks tilted in 2D even though you're upright. Detect the
        // turn via shrinking shoulder width and DON'T count it as lean (that was
        // the "I turn and get 0" bug). Lean is only trusted when facing forward.
        let shoulderW = lastMP.shouldersFound ? (lastMP.width ?? 0) : 0
        let turned = baseShoulderW > 0 && shoulderW > 0 && (shoulderW / baseShoulderW) < 0.82
        // SLOUCH SIGNAL: head height above shoulders (shoulder-relative; the labeled
        // test showed this is the one metric that separates upright from slouch).
        let headAbove = lastMP.shouldersFound ? (lastMP.headAbove ?? 0) : 0
        if headAbove > 0 { emaHeadAbove = emaHeadAbove > 0 ? emaHeadAbove * 0.8 + headAbove * 0.2 : headAbove }
        // ABSOLUTE head position (Vision) — drops when the whole body sinks, which the
        // shoulder-relative headAbove can miss. Second, independent slouch signal.
        if r.faceFound { emaHeadY = emaHeadY > 0 ? emaHeadY * 0.8 + r.headY * 0.2 : r.headY }
        // Suppress the lean heuristic when turned OR when the LLM recently confirmed
        // you're not leaning (it's the reliable judge; tilt is noisy).
        let leanMuted = turned || now < leanOKUntil
        // Feed the logic a non-leaning tilt while muted, so it won't false-alarm.
        let tilt: Double? = present ? (leanMuted ? logic.baseTilt : tiltDeg) : nil

        _ = logic.update(now: now, present: present, head: head, tilt: tilt, width: width)  // drives calibration

        // SLOUCH = head drops (front) OR head juts forward (side). Two clean,
        // baseline-relative signals OR'd; the grace period filters brief look-downs.
        let slouchRatio = (logic.calibrated && baseHeadAbove > 0 && emaHeadAbove > 0) ? emaHeadAbove / baseHeadAbove : 1
        let sideDev = (sideActive && sideSeen && sideBaseDeg != nil) ? max(0, emaSideDeg - (sideBaseDeg ?? 0)) : 0
        let headYDrop = (logic.calibrated && baseHeadY > 0 && emaHeadY > 0) ? max(0, baseHeadY - emaHeadY) : 0
        let slouchFront = slouchRatio < slouchThresh                                // head-above-shoulders drops
        let slouchSide = sideActive && sideSeen && sideBaseDeg != nil && sideDev > config.sideSlouchMargin  // head juts forward
        let slouchSink = headYDrop > config.headYMargin                             // whole head sinks (absolute)
        // HYSTERESIS: flip to slouching on a clear drop, flip back only after a clear
        // recovery on ALL signals — so it doesn't flicker good/bad right at the threshold.
        if slouchFront || slouchSide || slouchSink { slouchState = true }
        else if slouchRatio > slouchThresh + 0.05 && sideDev < max(0, config.sideSlouchMargin - 2)
                && headYDrop < config.headYMargin * 0.6 { slouchState = false }
        let slouching = present && logic.calibrated && slouchState
        if slouching {
            if slouchSince == 0 { slouchSince = now }
            if now - slouchSince >= config.slouchGrace && now - lastSlouchAlert >= config.slouchCooldown {
                lastSlouchAlert = now; wasAlerted = true
                let why = (slouchSide && !slouchFront && !slouchSink) ? "your head's gone forward" : "you're slouching"
                alertSound(); speak("sit up straight")
                onAlert?("Sit up tall — \(why)", false)
                notify("Posture — sit up tall and lengthen your spine.")
            }
        } else {
            slouchSince = 0
            if wasAlerted && slouchRatio > slouchThresh + 0.05 && sideDev < config.sideSlouchMargin {
                wasAlerted = false; recoverSound(); onAlert?("Nice — back to good posture", true)
            }
        }

        // Record the calibration baseline into the clip's sidecar — so a recorded
        // clip knows "where the user started" for later analysis/training. Capture
        // the side-cam neutral angle at the same moment so it's baseline-relative too.
        if logic.calibrated && !wasCalibrated {
            if sideSeen { sideBaseDeg = emaSideDeg }
            baseShoulderW = shoulderW
            baseHeadAbove = emaHeadAbove > 0 ? emaHeadAbove : (lastMP.headAbove ?? 0)
            baseHeadY = emaHeadY > 0 ? emaHeadY : r.headY
            vision.recorder.event(["type": "calibrate",
                                   "baseHead": logic.baseHead ?? 0,
                                   "baseTilt": logic.baseTilt,
                                   "baseWidth": logic.baseWidth,
                                   "baseShoulderW": baseShoulderW,
                                   "baseSideDeg": sideBaseDeg ?? -1])
        }
        wasCalibrated = logic.calibrated

        // Score: 100 at/above your upright baseline, 0 well into a slouch — the worse
        // of the two signals (head-drop front, head-forward side).
        let slouchFloor = slouchThresh - 0.10
        let frontFrac = max(0, min(1, (slouchRatio - slouchFloor) / max(0.001, 1 - slouchFloor)))
        let sideFrac = (sideActive && sideSeen && sideBaseDeg != nil)
            ? max(0, min(1, 1 - sideDev / (config.sideSlouchMargin + 6))) : 1
        let headYFrac = (logic.calibrated && baseHeadY > 0) ? max(0, min(1, 1 - headYDrop / (config.headYMargin + 0.04))) : 1
        let postureFrac = min(frontFrac, sideFrac, headYFrac)
        let score = (present && logic.calibrated) ? Int((postureFrac * 100).rounded()) : -1
        let status: PostureLogic.Status = !present ? .away
            : (!logic.calibrated ? .settling : (slouching ? .slumping : .good))

        frames += 1
        if frames % 30 == 0 {
            log("slouch ratio=\(String(format: "%.2f", slouchRatio)) headYdrop=\(String(format: "%.3f", headYDrop)) sideDev=\(String(format: "%.0f", sideDev)) front=\(slouchFront) sink=\(slouchSink) side=\(slouchSide) slouching=\(slouching) score=\(score)")
            vision.recorder.event(["type": "sample", "status": "\(status)",
                                   "slouchRatio": (slouchRatio * 1000).rounded() / 1000,
                                   "headAbove": (emaHeadAbove * 1000).rounded() / 1000,
                                   "mpShoulders": lastMP.shouldersFound])
        }

        onState?(State(
            status: status, score: score,
            headFrac: postureFrac, leanFrac: 1, distFrac: 1,
            shoulderFrac: sideForwardFrac, sideActive: sideActive, sideTrusted: sideTrusted,
            slouchHold: (slouching && slouchSince > 0) ? (now - slouchSince) : 0, grace: config.slouchGrace,
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
        // The shoulder-tilt lean heuristic is noisy (false-fires facing forward). Let
        // the LLM arbitrate: when it's confident you're NOT leaning, trust that over
        // the tilt for ~2 cycles; when it confirms a lean, hand control back.
        let now = ProcessInfo.processInfo.systemUptime
        if j.confidence >= 0.6 {
            leanOKUntil = (j.posture == "leaning") ? 0 : now + 2 * config.judgeInterval
        }
        guard !paused, j.bad, j.confidence >= minConfidence else { return }
        guard now - lastJudgeAlert >= logic.cooldown else { return }
        lastJudgeAlert = now
        let close = (j.posture == "too_close")
        playCue(close ? "posture_close.wav" : "posture_slump.wav")
        notify("Posture check — \(j.note.isEmpty ? j.posture : j.note). Reset and sit tall.")
        log("judge ALERT posture=\(j.posture) conf=\(String(format: "%.2f", j.confidence)) note=\(j.note)")
    }

    // Candidate slouch metrics for the guided test harness — raw signals we'll mine
    // to find the SINGLE simplest one that separates upright from slouch.
    func slouchMetrics() -> [String: Any] {
        func pt(_ k: String) -> CGPoint? { if let v = lastMP.points[k], v.1 > 0.4 { return v.0 }; return nil }
        var m: [String: Any] = [
            "visHeadY": (lastVision.headY * 1000).rounded() / 1000,      // Vision face midY (y up): slouch -> lower
            "visFaceSize": (lastVision.faceSize * 1000).rounded() / 1000, // grows when you lean forward
            "mpShoulders": lastMP.shouldersFound,
            "mpTilt": ((lastMP.tiltDeg ?? 0) * 10).rounded() / 10,
            "mpShoulderWidth": ((lastMP.width ?? 0) * 1000).rounded() / 1000,
            "mpHeadAbove": ((lastMP.headAbove ?? 0) * 1000).rounded() / 1000, // (shoulderMidY-noseY)/shoulderW: slouch -> lower
        ]
        let nose = pt("nose"), ls = pt("leftShoulder"), rs = pt("rightShoulder")
        if let nose { m["noseY"] = (Double(nose.y) * 1000).rounded() / 1000 }
        if let ls, let rs {
            let shMidY = Double(ls.y + rs.y) / 2
            m["shoulderMidY"] = (shMidY * 1000).rounded() / 1000
            if let nose { m["noseToShoulderY"] = ((shMidY - Double(nose.y)) * 1000).rounded() / 1000 } // head height above shoulders (MP y down)
        }
        if let le = pt("leftEar"), let ls { m["earToShoulderY"] = ((Double(ls.y) - Double(le.y)) * 1000).rounded() / 1000 }
        return m
    }

    private func playCue(_ name: String) { if !muted { run("/usr/bin/afplay", [cueDir + "/" + name]) } }
    // Clearer, more noticeable alert audio (system sounds), + optional spoken nudge.
    private func alertSound() { if !muted { run("/usr/bin/afplay", ["/System/Library/Sounds/Funk.aiff"]) } }
    private func recoverSound() { if !muted { run("/usr/bin/afplay", ["/System/Library/Sounds/Glass.aiff"]) } }
    private func speak(_ s: String) { if !muted && config.speakAlerts { run("/usr/bin/say", [s]) } }
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
    // Alert toast (slouch nudge) — prominent, auto-dismissing
    private var alertBanner: NSTextField!
    private var toastTimer: Timer?
    // Guided test harness (on-screen prompts -> ground-truth labeled capture)
    private var testOverlay: NSTextField!
    private var testTimer: Timer?
    private var testSteps: [(String, String)] = []
    private var testIdx = 0, testT = 0, testSampleCount = 0
    private var sideCams: [SideCamera] = []     // all side cameras (BRIO + iPhone …)
    private var sidePanels: [CameraPanel] = []
    private var sideLabel: NSTextField!
    private var sideHint: NSTextField!
    private let placement = PlacementClient()
    private var statusColor = Palette.settling

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1120, height: 520)
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
        sideLabel.frame = NSRect(x: 760, y: 78, width: 330, height: 16); sideLabel.isHidden = true
        content.addSubview(sideLabel)
        sideHint = mk("", 11, .regular, Palette.warn)        // LLM camera-placement guidance
        sideHint.frame = NSRect(x: 760, y: 56, width: 330, height: 18)
        sideHint.maximumNumberOfLines = 2; sideHint.lineBreakMode = .byWordWrapping; sideHint.isHidden = true
        content.addSubview(sideHint)

        if model.config.sideCamera {
            let devs = SideCamera.sideDevices()
            plog("side: devices = [\(devs.map { $0.localizedName }.joined(separator: ", "))]")
            for (idx, dev) in devs.enumerated() {
                let sc = SideCamera(device: dev); sideCams.append(sc)
                let sp = CameraPanel(session: sc.session); sidePanels.append(sp)
                content.addSubview(sp); panels.append(sp)
                let primary = (idx == 0)        // the first side drives the forward-head score
                var sideLast = 0.0
                sc.onFrame = { [weak self, sp] pts, w, h, deg, present in
                    guard let self else { return }
                    sp.setLandmarks(pts, color: self.statusColor, camSize: CGSize(width: w, height: h))
                    guard primary else { return }
                    let frac = self.model.feedSide(deg: deg, present: present)   // smoothed + baseline-relative
                    self.sideLabel.stringValue = present ? String(format: "Side  forward-head %.0f°", deg ?? 0) : "Side  (no person)"
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - sideLast > 3 {
                        sideLast = now
                        plog(String(format: "side: present=%@ deg=%.0f frac=%.2f pts=%d",
                                    present ? "true" : "false", deg ?? -1, frac, pts.count))
                    }
                }
                sc.start()
            }
            model.sideActive = !sideCams.isEmpty
            sideLabel.stringValue = sideCams.isEmpty ? "Side  connect a 2nd camera / iPhone" : "Side  starting…"
        }

        // Once cameras have a frame, let the vision LLM diagnose the setup (works
        // front-only too; re-run anytime via Calibrate or the 🔍 Diagnose button).
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.diagnoseSetup(showModal: false) }

        // lay the active panels across the camera region (no per-camera branching)
        let region = NSRect(x: 16, y: 64, width: 720, height: 440)
        let gap: CGFloat = 8
        let pw = (region.width - gap * CGFloat(panels.count - 1)) / CGFloat(panels.count)
        for (i, p) in panels.enumerated() {
            p.frame = NSRect(x: region.minX + CGFloat(i) * (pw + gap), y: region.minY, width: pw, height: region.height)
        }

        recIndicator = mk("● REC", 13, .bold, Palette.alert)
        recIndicator.frame = NSRect(x: 30, y: 432, width: 90, height: 20)
        content.addSubview(recIndicator)

        let rx: CGFloat = 760
        // Minimal, calm readout: ONE clear status. No score number, no bars, no debug.
        statusLabel = mk("Calibrating…", 34, .bold, Palette.settling)
        statusLabel.frame = NSRect(x: rx, y: 300, width: 340, height: 130)
        statusLabel.maximumNumberOfLines = 3
        content.addSubview(statusLabel)
        // Kept (so render references stay valid) but hidden — UI is intentionally bare.
        scoreLabel = mk("", 1, .regular, Palette.settling); scoreLabel.isHidden = true
        visLabel = mk("", 1, .regular, Palette.textMuted); visLabel.isHidden = true
        mpLabel = mk("", 1, .regular, Palette.textMuted); mpLabel.isHidden = true

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
        // Left = less sensitive (alert only on bigger slouches), right = more sensitive.
        let sens = NSSlider(value: model.slouchThresh, minValue: 0.75, maxValue: 0.95, target: self, action: #selector(sens(_:)))
        sens.frame = NSRect(x: 464, y: 20, width: 150, height: 22); content.addSubview(sens)
        // Vision-LLM setup diagnosis — looks at front (+ side) and explains the setup.
        let diag = NSButton(title: "🔍 Diagnose", target: self, action: #selector(diagnose))
        diag.frame = NSRect(x: 624, y: 16, width: 108, height: 30); diag.bezelStyle = .rounded
        content.addSubview(diag)
        // Guided test — prompts you through postures and captures ground-truth labels.
        let test = NSButton(title: "🎯 Test", target: self, action: #selector(startTest))
        test.frame = NSRect(x: 740, y: 16, width: 90, height: 30); test.bezelStyle = .rounded
        content.addSubview(test)

        // Big prompt banner used during the guided test (hidden otherwise).
        testOverlay = mk("", 17, .bold, .white)
        testOverlay.alignment = .center
        testOverlay.maximumNumberOfLines = 2
        testOverlay.drawsBackground = true
        testOverlay.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.82)
        testOverlay.frame = NSRect(x: 16, y: 456, width: 1088, height: 48)   // thin top band (over panels' empty top)
        testOverlay.isHidden = true
        content.addSubview(testOverlay)

        // Slouch-alert toast — big, centered, auto-dismissing.
        alertBanner = mk("", 26, .bold, .white)
        alertBanner.alignment = .center
        alertBanner.drawsBackground = true
        alertBanner.frame = NSRect(x: 120, y: 250, width: 520, height: 60)
        alertBanner.wantsLayer = true; alertBanner.layer?.cornerRadius = 12
        alertBanner.isHidden = true
        content.addSubview(alertBanner)

        window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        model.onState = { [weak self] s in self?.render(s) }
        model.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.onAlert = { [weak self] msg, good in self?.showToast(msg, good: good) }
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
        let side = sideCams.first?.lastJPEG
        let metrics = model.lastMetrics      // the algorithm's call at this instant
        placement.judge(front: front, side: side) { [weak self] j in
            guard let self, let j else { return }
            self.model.applyJudge(j, minConfidence: self.model.config.judgeConfidence)
            plog("judge posture=\(j.posture) conf=\(String(format: "%.2f", j.confidence)) sideUsable=\(j.sideUsable) note=\(j.note)")
            if self.model.sideActive {
                self.sideHint.stringValue = (j.sideUsable ? "✓ side counts · " : "⚠︎ side not counted · ") + (j.note.isEmpty ? j.posture : j.note)
                self.sideHint.textColor = j.sideUsable ? Palette.good : Palette.warn
            }
            self.saveLoopSample(front: front, side: side, metrics: metrics, judge: j)
        }
    }

    // SELF-TUNING LOOP (data half): every judge pairs the algorithm's metrics +
    // call with the LLM's vision ground-truth, appended to a dataset selfloop.py
    // optimizes against. The app generates labeled training data continuously.
    private func saveLoopSample(front: Data, side: Data?, metrics: [String: Any], judge j: JudgeResult) {
        guard !metrics.isEmpty else { return }   // only when calibrated + present
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/PostureMonitor/loop")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        try? front.write(to: dir.appendingPathComponent("front_\(stamp).jpg"))
        if let side { try? side.write(to: dir.appendingPathComponent("side_\(stamp).jpg")) }
        var row: [String: Any] = metrics
        row["t"] = stamp
        row["llm_posture"] = j.posture; row["llm_confidence"] = j.confidence
        row["llm_side_usable"] = j.sideUsable; row["llm_note"] = j.note
        if let d = try? JSONSerialization.data(withJSONObject: row),
           let line = String(data: d, encoding: .utf8)?.appending("\n"),
           let bytes = line.data(using: .utf8) {
            let url = dir.appendingPathComponent("dataset.jsonl")
            if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(bytes); try? fh.close() }
            else { try? bytes.write(to: url) }
        }
    }

    private func render(_ s: AppModel.State) {
        let c = Palette.color(s.status); statusColor = c
        cam.setLandmarks(s.points, color: c, camSize: CGSize(width: s.camW, height: s.camH))
        // ONE calm readout. Good ✓ / countdown / SIT UP — nothing else.
        if s.slouchHold > 0 {
            let left = Int(ceil(max(0, s.grace - s.slouchHold)))
            statusLabel.stringValue = left > 0 ? "Slouching\nsit up in \(left)s" : "SLOUCHING\nsit up!"
            statusLabel.textColor = left > 0 ? Palette.warn : Palette.alert
        } else if s.status == .good {
            statusLabel.stringValue = "Good posture ✓"; statusLabel.textColor = Palette.good
        } else {
            statusLabel.stringValue = Palette.label(s.status); statusLabel.textColor = c
        }
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

    // Big auto-dismissing slouch toast (red) / recovery toast (green).
    private func showToast(_ msg: String, good: Bool) {
        alertBanner.stringValue = "  \(msg)  "
        alertBanner.layer?.backgroundColor = (good ? Palette.good : Palette.alert).withAlphaComponent(0.95).cgColor
        alertBanner.isHidden = false
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: good ? 2.5 : 5.0, repeats: false) { [weak self] _ in
            self?.alertBanner.isHidden = true
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

    // GUIDED TEST: walk the user through prompted postures; each "HOLD" second
    // captures all candidate metrics + frames from every camera, labeled by the
    // prompt (ground truth). labeled_analyze.py then finds the simplest slouch metric.
    @objc private func startTest() {
        if testTimer != nil {                       // already running -> cancel
            testTimer?.invalidate(); testTimer = nil
            testOverlay.stringValue = "Test cancelled"
            plog("TEST cancelled")
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.testOverlay.isHidden = true }
            return
        }
        testSteps = [
            ("Sit up TALL — best posture", "good"),
            ("FORWARD HEAD — head forward, eyes UP", "forward_head"),
            ("Sit up TALL", "good"),
            ("LOOK DOWN — back stays straight", "look_down"),
            ("Sit up TALL", "good"),
            ("SLOUCH — round your whole back", "slouch"),
            ("FORWARD HEAD — head forward, eyes UP", "forward_head"),
            ("Sit up TALL", "good"),
        ]
        testIdx = 0; testT = 0; testSampleCount = 0
        plog("TEST started")
        testOverlay.isHidden = false
        testTimer?.invalidate()
        testTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickTest() }
        tickTest()
    }

    private func tickTest() {
        guard testIdx < testSteps.count else { endTest(); return }
        let (prompt, label) = testSteps[testIdx]
        let stepLen = 6                       // 2s get-ready + 4s hold/capture
        if testT < 2 {
            testOverlay.stringValue = "GET READY (\(2 - testT))…\n\(prompt)"
        } else {
            testOverlay.stringValue = "HOLD \(stepLen - testT)s\n\(prompt)"
            captureLabeled(label)
        }
        testT += 1
        if testT >= stepLen { testIdx += 1; testT = 0 }
    }

    private func endTest() {
        testTimer?.invalidate(); testTimer = nil
        testOverlay.stringValue = "✅ Test complete — \(testSampleCount) samples saved"
        plog("TEST complete: \(testSampleCount) samples -> ~/Movies/PostureMonitor/labeled/")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.testOverlay.isHidden = true }
    }

    private func captureLabeled(_ label: String) {
        let m = model.slouchMetrics()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/PostureMonitor/labeled")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; let stamp = f.string(from: Date())
        if let front = model.vision.lastJPEG { try? front.write(to: dir.appendingPathComponent("front_\(label)_\(stamp).jpg")) }
        for (i, sc) in sideCams.enumerated() {
            if let d = sc.lastJPEG { try? d.write(to: dir.appendingPathComponent("side\(i)_\(label)_\(stamp).jpg")) }
        }
        var row = m; row["label"] = label; row["t"] = stamp
        if let d = try? JSONSerialization.data(withJSONObject: row),
           let line = String(data: d, encoding: .utf8)?.appending("\n"),
           let b = line.data(using: .utf8) {
            let url = dir.appendingPathComponent("dataset.jsonl")
            if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(b); try? fh.close() }
            else { try? b.write(to: url) }
        }
        testSampleCount += 1
    }
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
        let side = sideCams.first?.lastJPEG
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
    @objc private func sens(_ s: NSSlider) { model.slouchThresh = s.doubleValue; plog("sensitivity -> slouchThresh=\(String(format: "%.2f", s.doubleValue))") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
