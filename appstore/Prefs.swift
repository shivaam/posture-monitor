// Prefs.swift — App Store build. An Amphetamine-style Preferences window (detailed
// settings live here, not crammed into the menu) and a simple About window.

import AppKit

// MARK: - About

enum AboutController {
    private static var window: NSWindow?

    static func show() {
        if window == nil { window = build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 380),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About Don't Let Me Slouch"
        w.isReleasedWhenClosed = false
        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]; bg.material = .windowBackground; bg.state = .active
        w.contentView = bg

        // App mark: a teal→green rounded gradient with a seated-figure glyph.
        let mark = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        mark.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = mark.bounds; grad.cornerRadius = 21
        grad.colors = [NSColor(srgbRed: 0.06, green: 0.73, blue: 0.71, alpha: 1).cgColor,
                       NSColor(srgbRed: 0.13, green: 0.75, blue: 0.42, alpha: 1).cgColor]
        grad.startPoint = CGPoint(x: 0, y: 1); grad.endPoint = CGPoint(x: 1, y: 0)
        mark.layer = grad; mark.wantsLayer = true
        let glyph = NSImageView(frame: mark.bounds)
        let sym = NSImage(systemSymbolName: "figure.seated.side", accessibilityDescription: nil)
        sym?.isTemplate = true
        glyph.image = sym; glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        mark.addSubview(glyph)

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let name = label("Don't Let Me Slouch", 20, .bold, .labelColor)
        let ver = label("Version \(version)", 12, .regular, .secondaryLabelColor)
        let tag = label("Gentle posture nudges — 100% on your Mac.", 13, .regular, .labelColor)
        let privacy = label("Your video is never recorded or sent anywhere.", 11, .regular, .secondaryLabelColor)
        for l in [tag, privacy] {
            l.maximumNumberOfLines = 2
            l.lineBreakMode = .byWordWrapping
            (l.cell as? NSTextFieldCell)?.usesSingleLineMode = false
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let copyright = label("© 2026 · MIT-licensed", 11, .regular, .tertiaryLabelColor)

        let stack = NSStackView(views: [mark, name, ver, tag, privacy, copyright])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.setCustomSpacing(14, after: mark)
        stack.setCustomSpacing(14, after: ver)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 96), mark.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        return w
    }

    private static func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight); t.textColor = color; t.alignment = .center
        return t
    }
}

// MARK: - Preferences

final class PreferencesController: NSObject {
    private let model: AppModel
    private let onChange: () -> Void          // rebuild menu + sync window controls
    private let onDock: (Bool) -> Void        // flip Dock icon / activation policy
    private var window: NSWindow?

    private var modeSeg: NSSegmentedControl!
    private var intervalPopup: NSPopUpButton!
    private var twoCheck: NSButton!
    private var sens: NSSlider!
    private var gracePopup: NSPopUpButton!
    private var soundCheck, flashCheck, bannerCheck, speakCheck, dockCheck, bgCheck: NSButton!

    private let intervals = [1, 3, 5, 10]
    private let graces = [3, 5, 8, 12]

    init(model: AppModel, onChange: @escaping () -> Void, onDock: @escaping (Bool) -> Void) {
        self.model = model; self.onChange = onChange; self.onDock = onDock
    }

    func show() {
        if window == nil { window = build() }
        sync()
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: build

    private func build() -> NSWindow {
        modeSeg = NSSegmentedControl(labels: ["Continuous", "Periodic"], trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged))
        intervalPopup = popup(intervals.map { "\($0) min" }, #selector(intervalChanged))
        twoCheck = checkbox("Nudge only after 2 checks in a row", #selector(twoChanged))
        sens = NSSlider(value: model.slouchThresh, minValue: 0.80, maxValue: 0.97, target: self, action: #selector(sensChanged))
        sens.controlSize = .small; sens.widthAnchor.constraint(equalToConstant: 170).isActive = true
        gracePopup = popup(graces.map { "\($0)s" }, #selector(graceChanged))
        soundCheck = checkbox("Sound", #selector(alertsChanged))
        flashCheck = checkbox("Screen-edge glow (ambient)", #selector(alertsChanged))
        bannerCheck = checkbox("On-screen banner", #selector(alertsChanged))
        speakCheck = checkbox("Speak “sit up straight”", #selector(alertsChanged))
        dockCheck = checkbox("Show Dock icon (uncheck to run in the background)", #selector(dockChanged))
        bgCheck = checkbox("Keep monitoring when window is closed (uses a little more power)", #selector(bgChanged))

        let stack = NSStackView(views: [
            header("Monitoring"),
            row("Mode", modeSeg),
            row("Check every", intervalPopup),
            indent(twoCheck),
            row("Sensitivity", sens),
            row("Nudge after (continuous)", gracePopup),
            gap(),
            header("Alerts"),
            indent(soundCheck), indent(flashCheck), indent(bannerCheck), indent(speakCheck),
            gap(),
            header("General"),
            indent(dockCheck),
            indent(bgCheck),
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Don't Let Me Slouch — Settings"; w.isReleasedWhenClosed = false
        let bg = NSVisualEffectView(frame: w.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]; bg.material = .windowBackground; bg.state = .active
        w.contentView = bg
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])
        w.setContentSize(NSSize(width: 460, height: stack.fittingSize.height))
        return w
    }

    private func header(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = .systemFont(ofSize: 11, weight: .bold); t.textColor = .secondaryLabelColor
        return t
    }
    private func gap() -> NSView { let v = NSView(); v.heightAnchor.constraint(equalToConstant: 6).isActive = true; return v }
    private func indent(_ v: NSView) -> NSStackView {
        let pad = NSView(); pad.widthAnchor.constraint(equalToConstant: 8).isActive = true
        let s = NSStackView(views: [pad, v]); s.spacing = 0; s.alignment = .centerY; return s
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 12)
        l.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let s = NSStackView(views: [l, control]); s.spacing = 10; s.alignment = .centerY
        return s
    }
    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action); b.font = .systemFont(ofSize: 12); return b
    }
    private func popup(_ items: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false); p.addItems(withTitles: items)
        p.target = self; p.action = action; p.controlSize = .small; return p
    }

    // MARK: sync controls <- model

    private func sync() {
        let periodic = model.mode == .periodic
        modeSeg.selectedSegment = periodic ? 1 : 0
        if let i = intervals.firstIndex(of: Int(model.intervalMin)) { intervalPopup.selectItem(at: i) }
        intervalPopup.isEnabled = periodic
        twoCheck.state = model.needsTwo ? .on : .off; twoCheck.isEnabled = periodic
        sens.doubleValue = model.slouchThresh
        if let i = graces.firstIndex(of: Int(model.graceSec.rounded())) { gracePopup.selectItem(at: i) }
        soundCheck.state = model.alertSound ? .on : .off
        flashCheck.state = model.alertFlash ? .on : .off
        bannerCheck.state = model.alertBanner ? .on : .off
        speakCheck.state = model.config.speakAlerts ? .on : .off
        dockCheck.state = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true ? .on : .off
        bgCheck.state = model.config.backgroundMonitor ? .on : .off
    }

    // MARK: handlers

    @objc private func modeChanged() {
        model.mode = modeSeg.selectedSegment == 1 ? .periodic : .continuous
        Config.set("monitorMode", model.mode.rawValue); model.applyMode(); sync(); onChange()
    }
    @objc private func intervalChanged() {
        model.intervalMin = Double(intervals[max(0, intervalPopup.indexOfSelectedItem)])
        Config.set("sampleIntervalMin", model.intervalMin)
        if model.mode == .periodic { model.applyMode() }
        onChange()
    }
    @objc private func twoChanged() { model.needsTwo = twoCheck.state == .on; Config.set("periodicNeedsTwo", model.needsTwo); onChange() }
    @objc private func sensChanged() { model.slouchThresh = sens.doubleValue; Config.set("slouchThresh", sens.doubleValue); onChange() }
    @objc private func graceChanged() {
        model.graceSec = Double(graces[max(0, gracePopup.indexOfSelectedItem)])
        Config.set("slouchGrace", model.graceSec); onChange()
    }
    @objc private func alertsChanged() {
        model.alertSound = soundCheck.state == .on; model.alertFlash = flashCheck.state == .on
        model.alertBanner = bannerCheck.state == .on; model.config.speakAlerts = speakCheck.state == .on
        Config.set("alertSound", model.alertSound); Config.set("alertFlash", model.alertFlash)
        Config.set("alertBanner", model.alertBanner); Config.set("speakAlerts", model.config.speakAlerts)
        onChange()
    }
    @objc private func dockChanged() {
        let on = dockCheck.state == .on
        Config.set("showDockIcon", on); onDock(on); onChange()
    }
    @objc private func bgChanged() {
        let on = bgCheck.state == .on
        Config.set("backgroundMonitor", on); model.setBackgroundMonitor(on); onChange()
    }
}
