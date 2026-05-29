// Config.swift — feature flags + tunable defaults read from
// ~/.posturemonitor.json. Defaults below are EXACTLY today's behavior, so the
// stable app is unchanged when no config file exists. Experimental/"for fun"
// features must default to false here and be gated on their flag, so they can
// never break the working app. tune.py can write sensitivity/tilt/proximity
// here to close the self-tuning loop without recompiling.

import Foundation

struct Config {
    // stable behavior (defaults match the shipped app)
    var autoRecord = true
    var sensitivity = 0.85
    var tiltThresh = 9.0
    var proximityMargin = 0.18

    // experimental — OFF by default; gate new "for fun" features on these
    var sideCamera = false
    var experimental = false

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".posturemonitor.json")

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = j["autoRecord"] as? Bool { c.autoRecord = v }
        if let v = j["sensitivity"] as? Double { c.sensitivity = v }
        if let v = j["tiltThresh"] as? Double { c.tiltThresh = v }
        if let v = j["proximityMargin"] as? Double { c.proximityMargin = v }
        if let v = j["sideCamera"] as? Bool { c.sideCamera = v }
        if let v = j["experimental"] as? Bool { c.experimental = v }
        return c
    }
}
