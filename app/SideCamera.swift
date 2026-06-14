// SideCamera.swift — OPTIONAL second camera placed to your SIDE. It measures the
// one thing a front camera can't: forward-head (the ear sitting ahead of the
// shoulder). Same MediaPipe /posture endpoint, its own session.

import AppKit
import AVFoundation
import CoreImage

// All cameras the user could pick — built-in, USB webcams, iPhone (Continuity).
func availableCameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified).devices
}

final class SideCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.side")
    private let mp = MediaPipeClient()
    private let ciContext = CIContext()
    private var lastSent = 0.0
    private var lastSize = (w: 16.0, h: 9.0)
    private let device: AVCaptureDevice

    // points + camera size (for the overlay) + the derived forward-head angle.
    var onFrame: ((_ points: [String: (CGPoint, Double)], _ camW: Double, _ camH: Double,
                   _ forwardHeadDeg: Double?, _ present: Bool) -> Void)?

    init(device: AVCaptureDevice) { self.device = device; super.init() }

    func start() {
        mp.onReading = { [weak self] r in self?.handle(r) }
        queue.async {
            self.session.beginConfiguration(); self.session.sessionPreset = .high
            if let inp = try? AVCaptureDeviceInput(device: self.device), self.session.canAddInput(inp) { self.session.addInput(inp) }
            let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(out) { self.session.addOutput(out) }
            self.session.commitConfiguration(); self.session.startRunning()
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSent < 0.3 { return }       // ~3 fps to the server
        lastSent = now
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSize = (Double(CVPixelBufferGetWidth(pb)), Double(CVPixelBufferGetHeight(pb)))
        let ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, 480 / max(ci.extent.width, ci.extent.height))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        if let d = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            mp.send(d)
        }
    }

    private func handle(_ r: MPReading) {
        func vp(_ k: String) -> (CGPoint, Double)? { let v = r.points[k]; return (v != nil && v!.1 > 0.5) ? v! : nil }
        // Use whichever side faces the camera (higher-visibility ear+shoulder pair).
        let pairs = [("leftEar", "leftShoulder"), ("rightEar", "rightShoulder")]
            .compactMap { (e, s) -> (CGPoint, CGPoint, Double)? in
                guard let ev = vp(e), let sv = vp(s) else { return nil }
                return (ev.0, sv.0, min(ev.1, sv.1))
            }
        let pts = r.points, sz = lastSize
        guard let best = pairs.max(by: { $0.2 < $1.2 }) else {
            DispatchQueue.main.async { self.onFrame?(pts, sz.w, sz.h, nil, false) }; return
        }
        let (ear, sh, _) = best
        let dx = abs(ear.x - sh.x)            // ear ahead of shoulder = forward head
        let dy = max(0.0001, abs(sh.y - ear.y))
        let deg = atan2(dx, dy) * 180 / .pi
        let usable: Double? = (deg >= 0 && deg <= 45) ? Double(deg) : nil   // reject implausible
        DispatchQueue.main.async { self.onFrame?(pts, sz.w, sz.h, usable, true) }
    }
}
