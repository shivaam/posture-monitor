// Config.swift — tunable defaults read from ~/.posturemonitor.json (optional).
// Defaults are the shipped behavior; the file only needs the keys you override.

import Foundation

struct Config {
    var slouchThresh = 0.90       // sensitivity: head-drop ratio below baseline that = slouching (lower = less sensitive).
                                  // Also derives the head-sink margin, so one slider drives both signals.
    var slouchGrace = 8.0         // seconds of slouch before it nudges you
    var slouchCooldown = 45.0     // min seconds between nudges
    var speakAlerts = false       // also say "sit up straight" out loud

    // Background / periodic mode + alert styles. Menu-driven, persisted in UserDefaults
    // (so toggling from the menu sticks), with these as the first-run defaults.
    var monitorMode = "continuous"   // "continuous" (camera always on) | "periodic" (wake every N min)
    var sampleIntervalMin = 5.0      // periodic: minutes between checks
    var sampleSeconds = 4.0          // periodic: how long the camera stays on per check (incl. warm-up)
    var periodicNeedsTwo = true      // periodic: nudge only after 2 slouchy checks in a row
    var alertSound = true            // 🔊 play a sound
    var alertFlash = false           // ⚡ flash the screen
    var alertBanner = false          // 💬 floating on-screen banner
    var showDockIcon = true          // true = normal app (Dock icon + window); uncheck in menu to run in background

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".posturemonitor.json")

    static func set(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    static func load() -> Config {
        var c = Config()
        if let data = try? Data(contentsOf: url),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = j["slouchThresh"] as? Double { c.slouchThresh = v }
            if let v = j["slouchGrace"] as? Double { c.slouchGrace = v }
            if let v = j["slouchCooldown"] as? Double { c.slouchCooldown = v }
            if let v = j["speakAlerts"] as? Bool { c.speakAlerts = v }
        }
        // UserDefaults overrides for the menu-driven options (take precedence over JSON).
        let d = UserDefaults.standard
        if d.object(forKey: "slouchThresh") != nil { c.slouchThresh = d.double(forKey: "slouchThresh") }
        if d.object(forKey: "slouchGrace") != nil { c.slouchGrace = d.double(forKey: "slouchGrace") }
        if d.object(forKey: "monitorMode") != nil { c.monitorMode = d.string(forKey: "monitorMode") ?? c.monitorMode }
        if d.object(forKey: "sampleIntervalMin") != nil { c.sampleIntervalMin = d.double(forKey: "sampleIntervalMin") }
        if d.object(forKey: "periodicNeedsTwo") != nil { c.periodicNeedsTwo = d.bool(forKey: "periodicNeedsTwo") }
        if d.object(forKey: "alertSound") != nil { c.alertSound = d.bool(forKey: "alertSound") }
        if d.object(forKey: "alertFlash") != nil { c.alertFlash = d.bool(forKey: "alertFlash") }
        if d.object(forKey: "alertBanner") != nil { c.alertBanner = d.bool(forKey: "alertBanner") }
        if d.object(forKey: "showDockIcon") != nil { c.showDockIcon = d.bool(forKey: "showDockIcon") }
        return c
    }
}
