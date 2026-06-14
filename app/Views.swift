// Views.swift — the small design system (colors + status labels).

import AppKit

enum Palette {
    static let bg        = NSColor(srgbRed: 0.078, green: 0.067, blue: 0.059, alpha: 1)
    static let surface   = NSColor(srgbRed: 0.13,  green: 0.12,  blue: 0.11,  alpha: 1)
    static let textHi    = NSColor(srgbRed: 0.95,  green: 0.96,  blue: 0.95,  alpha: 1)
    static let textMuted = NSColor(srgbRed: 0.62,  green: 0.64,  blue: 0.62,  alpha: 1)
    static let track     = NSColor(srgbRed: 0.22,  green: 0.21,  blue: 0.19,  alpha: 1)
    static let good      = NSColor(srgbRed: 0.22,  green: 0.85,  blue: 0.47,  alpha: 1)
    static let warn      = NSColor(srgbRed: 1.0,   green: 0.62,  blue: 0.20,  alpha: 1)
    static let alert     = NSColor(srgbRed: 1.0,   green: 0.30,  blue: 0.28,  alpha: 1)
    static let away      = NSColor(srgbRed: 0.55,  green: 0.55,  blue: 0.55,  alpha: 1)
    static let settling  = NSColor(srgbRed: 1.0,   green: 0.84,  blue: 0.35,  alpha: 1)

    static func color(_ s: PostureLogic.Status) -> NSColor {
        switch s {
        case .away: return away
        case .settling: return settling
        case .good: return good
        case .slumping: return warn
        }
    }
    static func label(_ s: PostureLogic.Status) -> String {
        switch s {
        case .away: return "Away"
        case .settling: return "Calibrating…"
        case .good: return "Good posture"
        case .slumping: return "Slumping — sit up"
        }
    }
}
