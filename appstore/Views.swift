// Views.swift — App Store build. Shared palette for the four UI states.

import AppKit

enum Palette {
    case away, settling, good, slouching

    var color: NSColor {
        switch self {
        case .away:     return NSColor.systemGray
        case .settling: return NSColor.systemTeal
        case .good:     return NSColor.systemGreen
        case .slouching: return NSColor.systemRed
        }
    }

    var label: String {
        switch self {
        case .away:     return "No one in frame"
        case .settling: return "Calibrating — sit up tall…"
        case .good:     return "Good posture ✓"
        case .slouching: return "Slouching — sit up"
        }
    }
}
