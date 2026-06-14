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

    // vision-LLM posture judge: periodically judge posture from the camera(s); used
    // to alert on high-confidence bad posture and to decide if the side camera is
    // trustworthy enough to affect the score. On by default (no-op if server down).
    var llmJudge = false          // OPTIONAL extra — needs an Anthropic key; off by default
    var judgeInterval = 60.0      // seconds between LLM judgments (~once a minute)
    var judgeConfidence = 0.7     // min LLM confidence to fire an alert

    // SIMPLE SLOUCH CORE (data-driven: mpHeadAbove is the one signal that works).
    // Slouch when head-above-shoulders drops below this fraction of your calibrated
    // baseline; alert after it's held for slouchGrace seconds.
    var slouchThresh = 0.87       // ratio of baseline head-above-shoulders = slouching (FRONT: head-down)
    var sideSlouchMargin = 6.0    // degrees of forward-head beyond baseline = slouching (SIDE: forward-head)
    var headYMargin = 0.05        // absolute head drop (Vision face-Y) below baseline = slouching (catches whole-body sink)
    var slouchGrace = 8.0         // seconds of slouch before alerting
    var slouchCooldown = 45.0     // min seconds between slouch alerts
    var speakAlerts = false       // also speak the nudge aloud ("sit up straight")

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
        if let v = j["llmJudge"] as? Bool { c.llmJudge = v }
        if let v = j["judgeInterval"] as? Double { c.judgeInterval = v }
        if let v = j["judgeConfidence"] as? Double { c.judgeConfidence = v }
        if let v = j["slouchThresh"] as? Double { c.slouchThresh = v }
        if let v = j["sideSlouchMargin"] as? Double { c.sideSlouchMargin = v }
        if let v = j["headYMargin"] as? Double { c.headYMargin = v }
        if let v = j["slouchGrace"] as? Double { c.slouchGrace = v }
        if let v = j["slouchCooldown"] as? Double { c.slouchCooldown = v }
        return c
    }
}
