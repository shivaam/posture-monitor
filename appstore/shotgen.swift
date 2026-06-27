// shotgen.swift — turn a window screenshot into an App Store screenshot:
// (1) pixelate any faces (privacy), (2) frame the window on a 2560x1600 gradient
// canvas with a caption.  Usage: shotgen <in.png> <out.png> "Caption text"
import AppKit
import Vision
import CoreImage

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: shotgen in.png out.png [caption]\n".data(using:.utf8)!); exit(2) }
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let caption = args.count >= 4 ? args[3] : ""

guard let src = NSImage(contentsOf: inURL), let cg0 = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(inURL.path)\n".data(using:.utf8)!); exit(1)
}

// --- 1. pixelate faces ---
let ciCtx = CIContext()
var ci = CIImage(cgImage: cg0)
let h = CGFloat(cg0.height), w = CGFloat(cg0.width)
let handler = VNImageRequestHandler(cgImage: cg0, options: [:])
let req = VNDetectFaceRectanglesRequest()
try? handler.perform([req])
for face in (req.results ?? []) {
    // Vision rect is normalized, origin bottom-left. Expand a little for full coverage.
    let bb = face.boundingBox
    var r = CGRect(x: bb.minX*w, y: bb.minY*h, width: bb.width*w, height: bb.height*h)
    r = r.insetBy(dx: -r.width*0.18, dy: -r.height*0.22)
    let scale = max(12, max(r.width, r.height)/10)
    let pix = ci.cropped(to: r)
        .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: r.midX, y: r.midY)])
        .cropped(to: r)
    ci = pix.composited(over: ci)
}
guard let shotCG = ciCtx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { exit(1) }
let shot = NSImage(cgImage: shotCG, size: NSSize(width: w, height: h))

// --- 2. frame on a 2560x1600 canvas ---
let W: CGFloat = 2560, H: CGFloat = 1600
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let grad = NSGradient(colors: [NSColor(srgbRed: 0.08, green: 0.66, blue: 0.62, alpha: 1),
                               NSColor(srgbRed: 0.10, green: 0.72, blue: 0.45, alpha: 1)])!
grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

// caption near top
if !caption.isEmpty {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 96, weight: .bold),
        .foregroundColor: NSColor.white, .paragraphStyle: p]
    let s = NSAttributedString(string: caption, attributes: attrs)
    let tr = NSRect(x: 120, y: H - 280, width: W - 240, height: 200)
    s.draw(in: tr)
}

// window image: scale to fit, centered in lower area, rounded + shadow
let maxW = W * 0.78, maxH = H * 0.62
let ar = w / h
var dw = maxW, dh = dw / ar
if dh > maxH { dh = maxH; dw = dh * ar }
let dx = (W - dw)/2, dy = (H - dh)/2 - 60
let rect = NSRect(x: dx, y: dy, width: dw, height: dh)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.35).cgColor)
let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
NSColor.white.setFill(); path.fill()   // backing so shadow reads
ctx.restoreGState()
NSGraphicsContext.current!.saveGraphicsState()
path.setClip()
shot.draw(in: rect)
NSGraphicsContext.current!.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
