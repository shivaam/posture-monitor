// Views.swift — design system + the clean visuals (score ring, posture avatar,
// camera thumbnail). Nothing is drawn onto the raw camera feed, so there's no
// mirror/crop alignment to get wrong.

import AppKit
import AVFoundation

// MARK: - Design system

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
        case .slumping, .leaning: return warn
        case .tooClose: return alert
        }
    }
    static func label(_ s: PostureLogic.Status) -> String {
        switch s {
        case .away: return "Away"
        case .settling: return "Calibrating…"
        case .good: return "Good posture"
        case .slumping: return "Slumping — sit up"
        case .leaning: return "Leaning — level out"
        case .tooClose: return "Too close — ease back"
        }
    }
}

// MARK: - Score ring

final class RingView: NSView {
    var fraction: CGFloat = 1 { didSet { needsDisplay = true } }   // 0..1
    var color: NSColor = Palette.settling { didSet { needsDisplay = true } }
    var value: Int = 100 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let lw: CGFloat = 12
        let rect = bounds.insetBy(dx: lw, dy: lw)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let bg = NSBezierPath()
        bg.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bg.lineWidth = lw; Palette.track.setStroke(); bg.stroke()

        let start: CGFloat = 90
        let fg = NSBezierPath()
        fg.appendArc(withCenter: center, radius: radius,
                     startAngle: start, endAngle: start - 360 * max(0, min(1, fraction)),
                     clockwise: true)
        fg.lineWidth = lw; fg.lineCapStyle = .round; color.setStroke(); fg.stroke()

        let num = "\(value)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 0.7, weight: .bold),
            .foregroundColor: color]
        let size = num.size(withAttributes: attrs)
        num.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }
}

// MARK: - Posture avatar (stylized head + shoulders, drawn from the metrics)

final class AvatarView: NSView {
    var headDrop: CGFloat = 0 { didSet { needsDisplay = true } }    // 0 tall .. 1 slumped
    var tiltDeg: CGFloat = 0 { didSet { needsDisplay = true } }
    var shoulderRound: CGFloat = 0 { didSet { needsDisplay = true } } // 0 flat .. 1 rounded
    var color: NSColor = Palette.settling { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        let cx = w / 2
        let lineW = max(5, w * 0.035)
        let col = active ? color : Palette.away
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.translateBy(x: cx, y: h / 2)
        ctx.rotate(by: -tiltDeg * .pi / 180 * 0.6)        // gentle, clamped feel
        ctx.translateBy(x: -cx, y: -h / 2)

        let headR = w * 0.13
        let shoulderHalf = w * 0.30
        let drop = headDrop * h * 0.12
        let shoulderY = h * 0.30 + headDrop * h * 0.04    // shoulders rise a touch on slump
        let headCenterY = h * 0.66 - drop

        let body = NSBezierPath()
        // shoulder arc (dips lower in the middle; rounds up with slump)
        let leftSh = CGPoint(x: cx - shoulderHalf, y: shoulderY)
        let rightSh = CGPoint(x: cx + shoulderHalf, y: shoulderY)
        let dipY = shoulderY - headR * 0.2 - shoulderRound * headR * 0.6
        body.move(to: leftSh)
        body.curve(to: rightSh,
                   controlPoint1: CGPoint(x: cx - shoulderHalf * 0.4, y: dipY),
                   controlPoint2: CGPoint(x: cx + shoulderHalf * 0.4, y: dipY))
        // neck
        body.move(to: CGPoint(x: cx, y: shoulderY - headR * 0.1))
        body.line(to: CGPoint(x: cx, y: headCenterY - headR))
        body.lineWidth = lineW; body.lineCapStyle = .round; body.lineJoinStyle = .round
        col.setStroke(); body.stroke()

        // head
        let head = NSBezierPath(ovalIn: CGRect(x: cx - headR, y: headCenterY - headR,
                                               width: headR * 2, height: headR * 2))
        head.lineWidth = lineW; col.setStroke(); head.stroke()

        ctx.restoreGState()
    }
}

// MARK: - Camera thumbnail (shown only during calibration)

final class PreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = 8
        layer?.addSublayer(preview)
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds }
}
