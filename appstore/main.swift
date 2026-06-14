// main.swift — App Store / Vision-only build of PostureMonitor.
// One window: a live camera preview that turns red and nudges you when your head
// sinks below the upright baseline you calibrate. Apple Vision only — no server.

import AppKit
import AVFoundation

func plog(_ s: String) {
    FileHandle.standardError.write(("[posture] " + s + "\n").data(using: .utf8) ?? Data())
}

// MARK: - State passed to the UI

struct UIState {
    var palette: Palette
    var detail: String
}

// MARK: - Model (detection + alerts)

final class AppModel {
    let vision = VisionEngine()
    let logic = PostureLogic()
    var config = Config.load()

    var muted = false
    var paused = false
    var slouchThresh: Double

    private var baseHeadY: Double?
    private var emaHeadY = 0.0
    private var slouchState = false
    private var slouchSince: Double?
    private var lastAlert = -1e9

    private let synth = AVSpeechSynthesizer()

    var onUpdate: ((UIState) -> Void)?
    var onFace: ((VisionReading) -> Void)?

    init() {
        slouchThresh = config.slouchThresh
        vision.onVision = { [weak self] r in self?.feed(r) }
    }

    func start() { vision.start() }

    func recalibrate() {
        logic.recalibrate(); baseHeadY = nil; slouchState = false; slouchSince = nil
        plog("recalibrating — sit up tall")
    }

    private func feed(_ r: VisionReading) {
        onFace?(r)
        let present = r.faceFound && !paused
        let status = logic.update(present: present, head: present ? r.headY : nil)

        if let b = logic.baseHead, baseHeadY == nil { baseHeadY = b; emaHeadY = b }
        if present { emaHeadY = emaHeadY * 0.8 + r.headY * 0.2 }

        // One slider scales the whole detector: lower thresh -> larger margin -> less sensitive.
        let margin = max(0.015, 0.095 - (slouchThresh - 0.80) * 0.45)
        let drop = (baseHeadY ?? emaHeadY) - emaHeadY     // head sits lower in frame when you slump
        if drop > margin { slouchState = true }
        else if drop < margin * 0.6 { slouchState = false }

        let slouching = present && logic.calibrated && slouchState
        let now = ProcessInfo.processInfo.systemUptime

        var detail = ""
        if slouching {
            if slouchSince == nil { slouchSince = now }
            let held = now - (slouchSince ?? now)
            let left = max(0, config.slouchGrace - held)
            detail = left > 0 ? String(format: "sit up in %.0fs…", left) : "sit up"
            if held >= config.slouchGrace && now - lastAlert > config.slouchCooldown {
                lastAlert = now
                alert()
            }
        } else {
            slouchSince = nil
        }

        let palette: Palette
        if !present { palette = .away }
        else if !logic.calibrated { palette = .settling }
        else if slouching { palette = .slouching }
        else { palette = .good }

        let text = paused ? "Paused" : (detail.isEmpty ? palette.label : "\(palette.label) — \(detail)")
        onUpdate?(UIState(palette: palette, detail: text))
        _ = status
    }

    private func alert() {
        plog("nudge: slouch held past grace")
        if !muted {
            if let s = NSSound(named: NSSound.Name("Submarine")) { s.play() } else { NSSound.beep() }
        }
        if config.speakAlerts {
            synth.speak(AVSpeechUtterance(string: "Sit up straight"))
        }
    }
}

// MARK: - Camera panel (preview + face box + status border)

final class CameraPanel: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let box = CAShapeLayer()

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 4
        layer?.borderColor = Palette.away.color.cgColor
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = 10
        layer?.addSublayer(preview)
        box.fillColor = NSColor.clear.cgColor
        box.lineWidth = 2
        box.strokeColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }

    func setState(_ p: Palette) {
        layer?.borderColor = p.color.cgColor
        box.strokeColor = p.color.cgColor
    }

    func setFace(_ r: VisionReading) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if r.faceFound {
            // Vision rect is bottom-left normalized; metadata rect is top-left.
            let meta = CGRect(x: r.faceRect.minX, y: 1 - r.faceRect.maxY,
                              width: r.faceRect.width, height: r.faceRect.height)
            let rect = preview.layerRectConverted(fromMetadataOutputRect: meta)
            box.path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            box.isHidden = false
        } else {
            box.isHidden = true
        }
        CATransaction.commit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var window: NSWindow!
    var panel: CameraPanel!
    var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "PostureMonitor"
        w.center()
        window = w

        let root = NSView(frame: w.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        w.contentView = root

        panel = CameraPanel(session: model.vision.session)
        panel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(panel)

        statusLabel = NSTextField(labelWithString: "Starting…")
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLabel)

        let calibrate = NSButton(title: "Calibrate", target: self, action: #selector(calibrate))
        let pause = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        let mute = NSButton(title: "Mute", target: self, action: #selector(toggleMute))
        let help = NSButton(title: "Help", target: self, action: #selector(showHelp))
        for b in [calibrate, pause, mute, help] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [calibrate, pause, mute, help])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        let sens = NSSlider(value: model.slouchThresh, minValue: 0.80, maxValue: 0.97,
                            target: self, action: #selector(sensChanged(_:)))
        sens.translatesAutoresizingMaskIntoConstraints = false
        let sensLabel = NSTextField(labelWithString: "Sensitivity")
        sensLabel.font = .systemFont(ofSize: 11)
        sensLabel.textColor = .secondaryLabelColor
        let sensRow = NSStackView(views: [sensLabel, sens])
        sensRow.spacing = 8
        sensRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sensRow)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            panel.heightAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 0.75),

            statusLabel.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 14),
            statusLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            sensRow.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            sensRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            sens.widthAnchor.constraint(equalToConstant: 220),

            buttons.topAnchor.constraint(equalTo: sensRow.bottomAnchor, constant: 14),
            buttons.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])

        model.onUpdate = { [weak self] s in
            self?.statusLabel.stringValue = s.detail
            self?.statusLabel.textColor = s.palette.color
            self?.panel.setState(s.palette)
        }
        model.onFace = { [weak self] r in self?.panel.setFace(r) }
        model.vision.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()

        if UserDefaults.standard.bool(forKey: "didShowHelp") == false { showHelp() }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func calibrate() { model.recalibrate() }
    @objc func togglePause(_ b: NSButton) { model.paused.toggle(); b.title = model.paused ? "Resume" : "Pause" }
    @objc func toggleMute(_ b: NSButton) { model.muted.toggle(); b.title = model.muted ? "Unmute" : "Mute" }

    @objc func sensChanged(_ s: NSSlider) {
        model.slouchThresh = s.doubleValue
        model.config.slouchThresh = s.doubleValue
        Config.set("slouchThresh", s.doubleValue)
    }

    @objc func showHelp() {
        UserDefaults.standard.set(true, forKey: "didShowHelp")
        let a = NSAlert()
        a.messageText = "Welcome to PostureMonitor"
        a.informativeText = """
        1. Sit up straight the way you want to hold yourself.
        2. Click Calibrate — that captures your upright baseline.
        3. Work normally. If your head sinks for a few seconds, you'll hear a nudge.

        Tune the Sensitivity slider and re-calibrate any time. Everything runs on \
        your Mac — your video is never recorded or sent anywhere.
        """
        a.addButton(withTitle: "Got it")
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    func cameraDenied() {
        statusLabel.stringValue = "Camera access denied — enable it in System Settings ▸ Privacy ▸ Camera."
        statusLabel.textColor = .systemRed
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
