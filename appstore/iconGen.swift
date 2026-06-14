// Draws the PostureMonitor app icon → /tmp/icon_1024.png
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-rect (macOS squircle-ish) gradient background.
let inset: CGFloat = 92
let bg = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let radius: CGFloat = (S - 2*inset) * 0.2237
let bgPath = NSBezierPath(roundedRect: bg, xRadius: radius, yRadius: radius)
bgPath.addClip()
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.06, green: 0.73, blue: 0.71, alpha: 1),   // teal
    NSColor(srgbRed: 0.13, green: 0.75, blue: 0.42, alpha: 1)])! // green
grad.draw(in: bg, angle: -55)

// Seated-upright figure in white (head + vertical spine + thigh), bold rounded strokes.
NSColor.white.setStroke()
NSColor.white.setFill()

let cx: CGFloat = 470
// head
let headR: CGFloat = 78
NSBezierPath(ovalIn: CGRect(x: cx - headR, y: 712 - headR, width: headR*2, height: headR*2)).fill()

func stroke(_ pts: [(CGFloat, CGFloat)], width: CGFloat) {
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    p.stroke()
}

// spine (upright) then thigh forward — the "sitting tall" L.
stroke([(cx, 612), (cx, 430), (690, 430)], width: 64)
// lower leg down from the knee.
stroke([(690, 430), (690, 300)], width: 64)

// faint chair back behind the spine, to read as "seated".
NSColor(white: 1, alpha: 0.30).setStroke()
stroke([(cx - 120, 770), (cx - 120, 360)], width: 30)
stroke([(cx - 130, 372), (760, 372)], width: 30)

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/icon_1024.png"))
print("wrote /tmp/icon_1024.png")
