// Config.swift — App Store build. Settings live in UserDefaults, NOT a home-dir
// JSON file: the App Store sandbox blocks reading arbitrary files in ~. The
// in-app slider is the primary control; these are just the persisted values.

import Foundation

struct Config {
    var slouchThresh = 0.90       // sensitivity: lower = less sensitive. Also derives the head-sink margin.
    var slouchGrace = 8.0         // seconds of slouch before it nudges you
    var slouchCooldown = 45.0     // min seconds between nudges
    var speakAlerts = false       // also say "sit up straight" out loud

    // Modes + alert styles (menu-driven, persisted in UserDefaults).
    var monitorMode = "continuous"   // "continuous" | "periodic"
    var sampleIntervalMin = 5.0      // periodic: minutes between checks
    var sampleSeconds = 4.0          // periodic: camera-on time per check (incl. warm-up)
    var periodicNeedsTwo = true      // periodic: nudge only after 2 slouchy checks in a row
    var alertSound = true            // 🔊 sound
    var alertFlash = false           // ⚡ screen-edge glow
    var alertBanner = false          // 💬 floating banner
    var showDockIcon = true          // false = background menu-bar-only app

    static func load() -> Config {
        var c = Config()
        let d = UserDefaults.standard
        if d.object(forKey: "slouchThresh") != nil { c.slouchThresh = d.double(forKey: "slouchThresh") }
        if d.object(forKey: "slouchGrace") != nil { c.slouchGrace = d.double(forKey: "slouchGrace") }
        if d.object(forKey: "slouchCooldown") != nil { c.slouchCooldown = d.double(forKey: "slouchCooldown") }
        if d.object(forKey: "speakAlerts") != nil { c.speakAlerts = d.bool(forKey: "speakAlerts") }
        if d.object(forKey: "monitorMode") != nil { c.monitorMode = d.string(forKey: "monitorMode") ?? c.monitorMode }
        if d.object(forKey: "sampleIntervalMin") != nil { c.sampleIntervalMin = d.double(forKey: "sampleIntervalMin") }
        if d.object(forKey: "periodicNeedsTwo") != nil { c.periodicNeedsTwo = d.bool(forKey: "periodicNeedsTwo") }
        if d.object(forKey: "alertSound") != nil { c.alertSound = d.bool(forKey: "alertSound") }
        if d.object(forKey: "alertFlash") != nil { c.alertFlash = d.bool(forKey: "alertFlash") }
        if d.object(forKey: "alertBanner") != nil { c.alertBanner = d.bool(forKey: "alertBanner") }
        if d.object(forKey: "showDockIcon") != nil { c.showDockIcon = d.bool(forKey: "showDockIcon") }
        return c
    }

    static func set(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}
