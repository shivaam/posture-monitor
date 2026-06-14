// Engines.swift — Apple Vision (in-app face position) + a small MediaPipe pose
// server (shoulders/ears) that the app talks to over localhost.

import AppKit
import AVFoundation
import Vision
import CoreImage

// The local MediaPipe pose server. Override with the POSTURE_SERVER env var.
let postureServerBase: String = ProcessInfo.processInfo.environment["POSTURE_SERVER"]
    ?? "http://127.0.0.1:8077"

// MARK: - Readings

struct VisionReading {
    var faceFound = false
    var headY = 0.0       // face-box center height in frame (drops when you slump down)
    var faceSize = 0.0    // face-box height (grows when you lean in)
    var frameW = 0.0      // camera pixel size (for overlay aspect mapping)
    var frameH = 0.0
}

struct MPReading {
    var ok = false
    var shouldersFound = false
    var headAbove: Double?       // (shoulderMidY - noseY)/shoulderWidth — head height above shoulders
    var points: [String: (CGPoint, Double)] = [:]   // named landmarks for the skeleton overlay
}

// MARK: - Calibration / presence detector

final class PostureLogic {
    enum Status { case away, settling, good, slumping }

    private let smoothN = 15, stableN = 45
    private let stableStd = 0.020
    private var headS: [Double] = [], stable: [Double] = []
    private(set) var baseHead: Double?

    var calibrated: Bool { baseHead != nil }
    func recalibrate() { baseHead = nil; stable.removeAll() }

    private func push(_ a: inout [Double], _ v: Double, _ cap: Int) { a.append(v); if a.count > cap { a.removeFirst() } }
    private func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    private func std(_ a: [Double]) -> Double {
        if a.count < 2 { return 0 }
        let m = mean(a); return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
    }

    /// Drives presence + auto-calibration. Returns the coarse status; the slouch
    /// decision itself lives in AppModel (head-above-shoulders + absolute head-Y).
    func update(present: Bool, head: Double?) -> Status {
        if !present || head == nil {
            headS.removeAll(); stable.removeAll()
            return .away
        }
        push(&headS, head!, smoothN); push(&stable, head!, stableN)
        if baseHead == nil {
            if stable.count >= stableN && std(stable) < stableStd {
                baseHead = median(stable)
                return .good
            }
            return .settling
        }
        return .good
    }
}

// MARK: - Vision engine (camera + face every frame; forwards JPEGs to MediaPipe)

final class VisionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.cam")
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let ciContext = CIContext()
    private var lastProc = 0.0
    private var lastJPEGTime = 0.0

    var onVision: ((VisionReading) -> Void)?       // ~8 fps, main thread
    var onFrameJPEG: ((Data) -> Void)?             // ~5 fps, for MediaPipe
    var onCameraDenied: (() -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { DispatchQueue.main.async { self.onCameraDenied?() }; return }
            self.queue.async { self.configure(); self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        // Forward a downsized JPEG to MediaPipe (~5 fps; requests drop while one is in flight).
        if now - lastJPEGTime > 0.18, let data = jpeg(from: sampleBuffer, maxDim: 720) {
            lastJPEGTime = now
            DispatchQueue.main.async { self.onFrameJPEG?(data) }
        }
        // Apple Vision face at ~8 fps.
        if now - lastProc < 0.12 { return }
        lastProc = now
        var r = VisionReading()
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            r.frameW = Double(CVPixelBufferGetWidth(pb)); r.frameH = Double(CVPixelBufferGetHeight(pb))
        }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        try? handler.perform([faceRequest])
        if let face = faceRequest.results?.first as? VNFaceObservation {
            r.faceFound = true
            r.headY = Double(face.boundingBox.midY)
            r.faceSize = Double(face.boundingBox.height)
        }
        DispatchQueue.main.async { self.onVision?(r) }
    }

    private func jpeg(from sb: CMSampleBuffer, maxDim: CGFloat) -> Data? {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, maxDim / max(ci.extent.width, ci.extent.height))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - MediaPipe client (POST frames to the local /posture endpoint)

final class MediaPipeClient {
    var onReading: ((MPReading) -> Void)?
    private var inFlight = false
    private let endpoint = URL(string: "\(postureServerBase)/posture")!

    func send(_ jpeg: Data) {
        guard !inFlight else { return }      // drop frames while one is in flight
        inFlight = true
        let boundary = "B\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"f.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { self.inFlight = false }
            let reading = MediaPipeClient.parse(data)
            DispatchQueue.main.async { self.onReading?(reading) }
        }.resume()
    }

    private static func parse(_ data: Data?) -> MPReading {
        var r = MPReading()
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["person_detected"] as? Bool == true else { return r }
        r.ok = true
        r.shouldersFound = obj["shoulders_found"] as? Bool ?? false
        r.headAbove = obj["head_above"] as? Double
        if let lms = obj["landmarks"] as? [String: [Double]] {
            for (k, a) in lms where a.count >= 3 {
                r.points[k] = (CGPoint(x: a[0], y: a[1]), a[2])   // (point top-left, visibility)
            }
        }
        return r
    }
}
