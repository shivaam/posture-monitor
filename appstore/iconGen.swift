// Final icon: a clean, bold "sitting upright" figure on the teal→green gradient.
import AppKit
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 88
let bg = CGRect(x: inset, y: inset, width: S-2*inset, height: S-2*inset)
let path = NSBezierPath(roundedRect: bg, xRadius: (S-2*inset)*0.2237, yRadius: (S-2*inset)*0.2237)
NSGraphicsContext.current!.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(srgbRed:0.06,green:0.73,blue:0.71,alpha:1),
                    NSColor(srgbRed:0.13,green:0.75,blue:0.42,alpha:1)])!.draw(in: bg, angle: -55)
NSGraphicsContext.current!.restoreGraphicsState()

func dot(_ cx: CGFloat,_ cy: CGFloat,_ r: CGFloat) {
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x:cx-r,y:cy-r,width:r*2,height:r*2)).fill()
}
func bar(_ pts: [(CGFloat,CGFloat)],_ w: CGFloat) {
    let p = NSBezierPath(); p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round
    NSColor.white.setStroke()
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1)); for q in pts.dropFirst() { p.line(to: NSPoint(x:q.0,y:q.1)) }
    p.stroke()
}

let lw: CGFloat = 92
dot(430, 700, 92)                          // head
bar([(430, 600),(430, 392)], lw)           // upright back (spine)
bar([(430, 392),(672, 392)], lw)           // seat / thigh
bar([(672, 392),(672, 238)], lw)           // lower leg

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/icon-final.png"))
print("ok")
