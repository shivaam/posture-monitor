// Config.swift — App Store build. Settings live in UserDefaults, NOT a home-dir
// JSON file: the App Store sandbox blocks reading arbitrary files in ~. The
// in-app slider is the primary control; these are just the persisted values.

import Foundation

struct Config {
    var slouchThresh = 0.90       // sensitivity: lower = less sensitive. Also derives the head-sink margin.
    var slouchGrace = 8.0         // seconds of slouch before it nudges you
    var slouchCooldown = 45.0     // min seconds between nudges
    var speakAlerts = false       // also say "sit up straight" out loud

    static func load() -> Config {
        var c = Config()
        let d = UserDefaults.standard
        if d.object(forKey: "slouchThresh") != nil { c.slouchThresh = d.double(forKey: "slouchThresh") }
        if d.object(forKey: "slouchGrace") != nil { c.slouchGrace = d.double(forKey: "slouchGrace") }
        if d.object(forKey: "slouchCooldown") != nil { c.slouchCooldown = d.double(forKey: "slouchCooldown") }
        if d.object(forKey: "speakAlerts") != nil { c.speakAlerts = d.bool(forKey: "speakAlerts") }
        return c
    }

    static func set(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}
