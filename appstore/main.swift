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
    var title: String       // the pill text
    var subtitle: String    // the calm secondary line (countdown / hint)
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

        var subtitle = ""
        if slouching {
            if slouchSince == nil { slouchSince = now }
            let held = now - (slouchSince ?? now)
            let left = max(0, config.slouchGrace - held)
            subtitle = left > 0 ? String(format: "sit up in %.0fs…", left) : "sit up straight"
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

        if paused {
            onUpdate?(UIState(palette: .away, title: "Paused", subtitle: "monitoring is off"))
        } else {
            if palette == .good && subtitle.isEmpty { subtitle = "keep it up" }
            if palette == .away { subtitle = "step into view to begin" }
            onUpdate?(UIState(palette: palette, title: palette.label, subtitle: subtitle))
        }
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

// MARK: - Status pill (tinted capsule with an icon)

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
        stack.spacing = 8
        stack.alignment = .centerY
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
        // Soft drop shadow on the outer layer (kept un-clipped).
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        container.cornerRadius = 14
        container.masksToBounds = true
        container.backgroundColor = NSColor.black.cgColor
        container.borderWidth = 4
        container.borderColor = Palette.away.color.cgColor
        layer?.addSublayer(container)

        preview.videoGravity = .resizeAspectFill
        container.addSublayer(preview)

        box.fillColor = NSColor.clear.cgColor
        box.lineWidth = 2.5
        box.strokeColor = NSColor.systemGreen.cgColor
        container.addSublayer(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = bounds
        preview.frame = bounds
        CATransaction.commit()
    }

    func setState(_ p: Palette) {
        container.borderColor = p.color.cgColor
        box.strokeColor = p.color.cgColor
    }

    func setFace(_ r: VisionReading) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if r.faceFound {
            // Vision rect is bottom-left normalized; metadata rect is top-left.
            let meta = CGRect(x: r.faceRect.minX, y: 1 - r.faceRect.maxY,
                              width: r.faceRect.width, height: r.faceRect.height)
            let rect = preview.layerRectConverted(fromMetadataOutputRect: meta)
            box.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
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
    var pill: PillView!
    var subtitle: NSTextField!

    func applicationDidFinishLaunching(_ note: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "PostureMonitor"
        w.titlebarAppearsTransparent = true
        w.center()
        window = w

        // Vibrancy background.
        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .windowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        w.contentView = bg

        panel = CameraPanel(session: model.vision.session)
        panel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(panel)

        pill = PillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(pill)

        subtitle = NSTextField(labelWithString: " ")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(subtitle)

        // Sensitivity row: "Less ── More".
        let less = caption("Less")
        let more = caption("More")
        let sens = NSSlider(value: model.slouchThresh, minValue: 0.80, maxValue: 0.97,
                            target: self, action: #selector(sensChanged(_:)))
        sens.translatesAutoresizingMaskIntoConstraints = false
        sens.controlSize = .small
        let sensRow = NSStackView(views: [less, sens, more])
        sensRow.spacing = 8
        sensRow.alignment = .centerY
        sensRow.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(sensRow)

        // Toolbar buttons with SF Symbols.
        let calibrate = toolButton("Calibrate", "arrow.clockwise", #selector(calibrate))
        let pause = toolButton("Pause", "pause.fill", #selector(togglePause))
        let mute = toolButton("Mute", "speaker.slash.fill", #selector(toggleMute))
        let help = toolButton("Help", "questionmark.circle", #selector(showHelp))
        let buttons = NSStackView(views: [calibrate, pause, mute, help])
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
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

        model.onUpdate = { [weak self] s in
            self?.pill.set(s.palette, s.title)
            self?.subtitle.stringValue = s.subtitle.isEmpty ? " " : s.subtitle
            self?.panel.setState(s.palette)
        }
        model.onFace = { [weak self] r in self?.panel.setFace(r) }
        model.vision.onCameraDenied = { [weak self] in self?.cameraDenied() }
        model.start()

        if UserDefaults.standard.bool(forKey: "didShowHelp") == false { showHelp() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .tertiaryLabelColor
        return t
    }

    private func toolButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: " " + title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }

    @objc func calibrate() { model.recalibrate() }
    @objc func togglePause(_ b: NSButton) {
        model.paused.toggle()
        b.title = model.paused ? " Resume" : " Pause"
        b.image = NSImage(systemSymbolName: model.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }
    @objc func toggleMute(_ b: NSButton) {
        model.muted.toggle()
        b.title = model.muted ? " Unmute" : " Mute"
        b.image = NSImage(systemSymbolName: model.muted ? "speaker.wave.2.fill" : "speaker.slash.fill", accessibilityDescription: nil)
    }

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
        pill.set(.slouching, "Camera access denied")
        subtitle.stringValue = "Enable it in System Settings ▸ Privacy ▸ Camera."
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
