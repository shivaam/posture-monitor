// Config.swift — tunable defaults read from ~/.posturemonitor.json (optional).
// Defaults are the shipped behavior; the file only needs the keys you override.

import Foundation

struct Config {
    var slouchThresh = 0.90       // sensitivity: head-drop ratio below baseline that = slouching (lower = less sensitive).
                                  // Also derives the head-sink margin, so one slider drives both signals.
    var slouchGrace = 8.0         // seconds of slouch before it nudges you
    var slouchCooldown = 45.0     // min seconds between nudges
    var speakAlerts = false       // also say "sit up straight" out loud

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".posturemonitor.json")

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = j["slouchThresh"] as? Double { c.slouchThresh = v }
        if let v = j["slouchGrace"] as? Double { c.slouchGrace = v }
        if let v = j["slouchCooldown"] as? Double { c.slouchCooldown = v }
        if let v = j["speakAlerts"] as? Bool { c.speakAlerts = v }
        return c
    }
}
