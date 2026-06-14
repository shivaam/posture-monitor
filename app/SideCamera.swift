// SideCamera.swift — EXPERIMENTAL (gated on config.sideCamera). A second camera
// placed to your SIDE measures the one thing a front camera physically can't:
// forward-head / rounded shoulders (ear sitting ahead of the shoulder). Pure CV
// via the same MediaPipe /posture endpoint. Any 2nd camera works — a USB webcam
// or your iPhone as a Continuity Camera (it just shows up as a camera device).

import AppKit
import AVFoundation
import CoreImage

final class SideCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.sidecam")
    private let mp = MediaPipeClient()
    private let ciContext = CIContext()
    private var lastSent = 0.0
    private var lastSize = (w: 16.0, h: 9.0)
    private(set) var available = false
    private(set) var deviceName: String?
    private(set) var lastJPEG: Data?      // most recent frame, for the LLM placement check
    private let device: AVCaptureDevice?
    private var gotFirstReading = false

    // points + camera size (for the overlay), plus the derived forward-head angle.
    var onFrame: ((_ points: [String: (CGPoint, Double)], _ camW: Double, _ camH: Double,
                   _ forwardHeadDeg: Double?, _ present: Bool) -> Void)?

    // All non-built-in cameras (USB webcams + iPhone Continuity), in enumeration
    // order — each becomes its own side panel so we can use ALL cameras at once.
    static func sideDevices() -> [AVCaptureDevice] {
        let ds = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .continuityCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        // Continuity (iPhone) FIRST — it gives the cleaner side profile, so it drives
        // the forward-head signal; other webcams follow as extra display panels.
        return ds.devices
            .filter { $0.deviceType == .external || $0.deviceType == .continuityCamera }
            .sorted { ($0.deviceType == .continuityCamera ? 0 : 1) < ($1.deviceType == .continuityCamera ? 0 : 1) }
    }

    init(device dev: AVCaptureDevice) {
        device = dev
        super.init()
        available = true
        deviceName = dev.localizedName
    }

    func start() {
        guard let dev = device else { return }
        mp.onReading = { [weak self] r in self?.handle(r) }
        queue.async {
            self.session.beginConfiguration(); self.session.sessionPreset = .high
            if let inp = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(inp) { self.session.addInput(inp) }
            let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(out) { self.session.addOutput(out) }
            self.session.commitConfiguration(); self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSent < 0.3 { return }      // ~3 fps to the server
        lastSent = now
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSize = (Double(CVPixelBufferGetWidth(pb)), Double(CVPixelBufferGetHeight(pb)))
        let ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, 720 / max(ci.extent.width, ci.extent.height))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        if let d = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            lastJPEG = d
            mp.send(d)
        }
    }

    private func handle(_ r: MPReading) {
        if !gotFirstReading { gotFirstReading = true; plog("side: first MediaPipe reading ok=\(r.ok) shoulders=\(r.shouldersFound) pts=\(r.points.count)") }
        // Require fairly confident landmarks (0.5) — low-visibility ear/shoulder on a
        // near-frontal side view produce garbage angles that wreck the score.
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
        let dx = abs(ear.x - sh.x)            // ear ahead of shoulder (forward head)
        let dy = max(0.0001, abs(sh.y - ear.y))
        let deg = atan2(dx, dy) * 180 / .pi   // 0 = ear straight above shoulder; grows as head juts forward
        // Reject implausible angles (>45° at a desk = mis-detection / not a real
        // profile): report present but with NO usable measurement, so it doesn't
        // drag the score down on a bad frame.
        let usable: Double? = (deg >= 0 && deg <= 45) ? Double(deg) : nil
        DispatchQueue.main.async { self.onFrame?(pts, sz.w, sz.h, usable, true) }
    }
}
