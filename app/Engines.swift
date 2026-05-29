// Engines.swift — posture logic + the two engines (Apple Vision in-app, and the
// MediaPipe Python server over HTTP) for PostureMonitor v2.

import AppKit
import AVFoundation
import Vision
import CoreImage

// MARK: - Readings

struct VisionReading {
    var faceFound = false
    var headY = 0.0       // face-box center height in frame (drops on slump)
    var faceSize = 0.0    // face-box height (grows when you lean in)
    var roll = 0.0        // head roll in degrees (usually ~0 from Vision)
    var frameW = 0.0      // camera pixel size (for overlay aspect mapping)
    var frameH = 0.0
}

struct MPReading {
    var ok = false
    var shouldersFound = false
    var headAbove: Double?       // (shoulderMidY - noseY)/shoulderWidth
    var tiltDeg: Double?
    var width: Double?
    // full named landmarks for the overlay: name -> (point 0..1 top-left, visibility)
    var points: [String: (CGPoint, Double)] = [:]
}

// MARK: - Drift detector (unchanged logic, ported from the prototype)

final class PostureLogic {
    enum Status { case away, settling, good, slumping, leaning, tooClose }

    var sensitivity = 0.85
    var tiltThresh = 9.0
    var proximityMargin = 0.18
    var grace = 15.0
    var cooldown = 45.0

    private let smoothN = 15, stableN = 45
    private let stableStd = 0.020
    private var headS: [Double] = [], tiltS: [Double] = [], widthS: [Double] = [], stable: [Double] = []
    private var baseHead: Double?
    private var baseTilt = 0.0, baseWidth = 0.0
    private var badSince: Double?
    private var lastAlert = -1e9
    private var goodFrames = 0, totalFrames = 0

    struct Result { let status: Status; let ratio: Double; let fire: Bool; let tooClose: Bool; let score: Double }

    var calibrated: Bool { baseHead != nil }

    func recalibrate() { baseHead = nil; stable.removeAll(); goodFrames = 0; totalFrames = 0; badSince = nil }

    private func push(_ a: inout [Double], _ v: Double, _ cap: Int) { a.append(v); if a.count > cap { a.removeFirst() } }
    private func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    private func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    private func std(_ a: [Double]) -> Double {
        if a.count < 2 { return 0 }
        let m = mean(a); return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
    }
    private func scorePct() -> Double { totalFrames > 0 ? 100 * Double(goodFrames) / Double(totalFrames) : 100 }

    func update(now: Double, present: Bool, head: Double?, tilt: Double?, width: Double?) -> Result {
        if !present || head == nil {
            headS.removeAll(); tiltS.removeAll(); widthS.removeAll(); stable.removeAll(); badSince = nil
            return Result(status: .away, ratio: 1, fire: false, tooClose: false, score: scorePct())
        }
        push(&headS, head!, smoothN); push(&tiltS, tilt ?? 0, smoothN)
        push(&widthS, width ?? 0, smoothN); push(&stable, head!, stableN)
        let curHead = mean(headS), curTilt = mean(tiltS), curWidth = mean(widthS)

        if baseHead == nil {
            if stable.count >= stableN && std(stable) < stableStd {
                baseHead = median(stable); baseTilt = curTilt; baseWidth = curWidth
                return Result(status: .good, ratio: 1, fire: false, tooClose: false, score: scorePct())
            }
            return Result(status: .settling, ratio: 1, fire: false, tooClose: false, score: scorePct())
        }
        let ratio = curHead / baseHead!
        let headBad = ratio < sensitivity
        let leanBad = abs(curTilt - baseTilt) > tiltThresh
        let tooClose = baseWidth > 0 && curWidth > baseWidth * (1 + proximityMargin)
        let bad = headBad || leanBad || tooClose
        totalFrames += 1; if !bad { goodFrames += 1 }
        var status: Status = .good
        if tooClose { status = .tooClose } else if headBad { status = .slumping } else if leanBad { status = .leaning }
        var fire = false
        if bad {
            if badSince == nil { badSince = now }
            if now - badSince! >= grace && now - lastAlert >= cooldown { lastAlert = now; fire = true }
        } else { badSince = nil }
        return Result(status: status, ratio: ratio, fire: fire, tooClose: tooClose, score: scorePct())
    }
}

// MARK: - Vision engine (camera + face, every frame; forwards JPEGs to MediaPipe)

final class VisionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.cam")
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let ciContext = CIContext()
    private var lastProc = 0.0
    private var lastJPEG = 0.0

    var onVision: ((VisionReading) -> Void)?       // ~8 fps, main thread
    var onFrameJPEG: ((Data) -> Void)?             // ~2 fps, for MediaPipe
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
        // Forward a downsized JPEG to MediaPipe as fast as it keeps up (~5 fps;
        // requests drop while one is in flight) for smoother live pointers.
        if now - lastJPEG > 0.18, let data = jpeg(from: sampleBuffer, maxDim: 320) {
            lastJPEG = now
            DispatchQueue.main.async { self.onFrameJPEG?(data) }
        }
        // Vision face at ~8 fps.
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
            r.roll = (face.roll.map { Double(truncating: $0) } ?? 0) * 180 / .pi
        }
        DispatchQueue.main.async { self.onVision?(r) }
    }

    private func jpeg(from sb: CMSampleBuffer, maxDim: CGFloat) -> Data? {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        let scale = min(1, maxDim / max(ci.extent.width, ci.extent.height))
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }
}

// MARK: - MediaPipe client (POST frames to the Python /posture endpoint)

final class MediaPipeClient {
    var onReading: ((MPReading) -> Void)?
    private var inFlight = false
    private let endpoint = URL(string: "http://localhost:8000/posture")!
    private let token: String?

    init() {
        // Optional bearer token via POSTURE_TOKEN env var; the bundled server
        // runs without auth, so this is usually nil.
        token = ProcessInfo.processInfo.environment["POSTURE_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send(_ jpeg: Data) {
        guard !inFlight else { return }      // drop frames while one is in flight
        inFlight = true
        let boundary = "B\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let t = token, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
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
        r.tiltDeg = obj["shoulder_tilt_deg"] as? Double
        r.width = obj["shoulder_width"] as? Double
        if let lms = obj["landmarks"] as? [String: [Double]] {
            for (k, a) in lms where a.count >= 3 {
                r.points[k] = (CGPoint(x: a[0], y: a[1]), a[2])   // (point top-left, visibility)
            }
        }
        return r
    }
}
