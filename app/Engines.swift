// Engines.swift — posture logic + the two engines (Apple Vision in-app, and the
// MediaPipe Python server over HTTP) for PostureMonitor v2.

import AppKit
import AVFoundation
import Vision
import CoreImage

// The PostureMonitor server runs on its OWN port (not :8000) so it never collides
// with the StretchLab launchd server. Override with the POSTURE_SERVER env var.
let postureServerBase: String = ProcessInfo.processInfo.environment["POSTURE_SERVER"]
    ?? "http://127.0.0.1:8077"

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
    private(set) var baseHead: Double?
    private(set) var baseTilt = 0.0
    private(set) var baseWidth = 0.0
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
    private var lastJPEGTime = 0.0
    private(set) var lastJPEG: Data?      // most recent front frame, for the LLM setup diagnosis
    let recorder = ClipRecorder()

    var onVision: ((VisionReading) -> Void)?       // ~8 fps, main thread
    var onFrameJPEG: ((Data) -> Void)?             // ~2 fps, for MediaPipe
    var onCameraDenied: (() -> Void)?

    var isRecording: Bool { recorder.isRecording }
    func startRecording() { recorder.start() }
    func stopRecording(_ done: @escaping (URL?) -> Void) { recorder.stop(done) }

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
        recorder.append(sampleBuffer)      // every frame when recording (camera queue)
        let now = ProcessInfo.processInfo.systemUptime
        // Forward a downsized JPEG to MediaPipe as fast as it keeps up (~5 fps;
        // requests drop while one is in flight) for smoother live pointers.
        if now - lastJPEGTime > 0.18, let data = jpeg(from: sampleBuffer, maxDim: 720) {
            lastJPEGTime = now
            lastJPEG = data
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
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - MediaPipe client (POST frames to the Python /posture endpoint)

final class MediaPipeClient {
    var onReading: ((MPReading) -> Void)?
    private var inFlight = false
    private let endpoint = URL(string: "\(postureServerBase)/posture")!
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

// MARK: - Placement client (ask the vision LLM if a camera is positioned well)

struct PlacementResult { var ok = false; var position = ""; var guidance = "" }

/// Two-camera setup diagnosis from the vision LLM (reasons across both views).
struct SetupAssessment {
    var frontOK = false, sideOK = false, hasSide = false
    var posture = "", problem = "", fix = "", explanation = ""
}

/// Lightweight periodic posture judgment (posture + confidence + is-side-usable).
struct JudgeResult {
    var posture = "unknown"
    var confidence = 0.0
    var sideUsable = false
    var note = ""
    var bad: Bool { ["slumping", "leaning", "forward_head", "too_close", "rounded_shoulders"].contains(posture) }
}

/// POSTs frames to the server, which asks a vision LLM about camera placement /
/// the whole setup (no hand-coded geometry — the LLM reasons about the images).
final class PlacementClient {
    private let endpoint = URL(string: "\(postureServerBase)/check_placement")!
    private let assessEndpoint = URL(string: "\(postureServerBase)/assess_setup")!
    private let judgeEndpoint = URL(string: "\(postureServerBase)/judge")!
    private var inFlight = false
    private var assessInFlight = false
    private var judgeInFlight = false

    /// Periodic posture judgment from the vision LLM (front + optional side).
    func judge(front: Data, side: Data?, completion: @escaping (JudgeResult?) -> Void) {
        guard !judgeInFlight else { completion(nil); return }
        judgeInFlight = true
        let boundary = "B\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: judgeEndpoint); req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        appendFile(&body, boundary: boundary, name: "front", front)
        if let side { appendFile(&body, boundary: boundary, name: "side", side) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { self.judgeInFlight = false }
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let posture = o["posture"] as? String else { DispatchQueue.main.async { completion(nil) }; return }
            var j = JudgeResult()
            j.posture = posture
            j.confidence = o["confidence"] as? Double ?? 0
            j.sideUsable = o["side_usable"] as? Bool ?? false
            j.note = o["note"] as? String ?? ""
            DispatchQueue.main.async { completion(j) }
        }.resume()
    }

    /// Multipart helper: append one file part to `body`.
    private func appendFile(_ body: inout Data, boundary: String, name: String, _ jpeg: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n".data(using: .utf8)!)
    }

    /// Send front (+ optional side) frames; the LLM diagnoses the whole setup.
    func assess(front: Data, side: Data?, completion: @escaping (SetupAssessment?) -> Void) {
        guard !assessInFlight else { completion(nil); return }
        assessInFlight = true
        let boundary = "B\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: assessEndpoint); req.httpMethod = "POST"; req.timeoutInterval = 40
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        appendFile(&body, boundary: boundary, name: "front", front)
        if let side { appendFile(&body, boundary: boundary, name: "side", side) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { self.assessInFlight = false }
            var a = SetupAssessment()
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                a.frontOK = o["front_ok"] as? Bool ?? false
                a.sideOK = o["side_ok"] as? Bool ?? false
                a.hasSide = o["has_side"] as? Bool ?? (side != nil)
                a.posture = o["posture"] as? String ?? ""
                a.problem = o["problem"] as? String ?? ""
                a.fix = o["fix"] as? String ?? ""
                a.explanation = o["explanation"] as? String ?? ""
            }
            DispatchQueue.main.async { completion(a.explanation.isEmpty ? nil : a) }
        }.resume()
    }

    func check(_ jpeg: Data, view: String = "side", completion: @escaping (PlacementResult?) -> Void) {
        guard !inFlight else { completion(nil); return }
        inFlight = true
        let boundary = "B\(Int(Date().timeIntervalSince1970 * 1000))"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30      // vision LLM latency
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"view\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(view)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"f.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { self.inFlight = false }
            var res = PlacementResult()
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                res.ok = obj["ok"] as? Bool ?? false
                res.position = obj["position"] as? String ?? ""
                res.guidance = obj["guidance"] as? String ?? ""
            }
            DispatchQueue.main.async { completion(res.guidance.isEmpty ? nil : res) }
        }.resume()
    }
}

// MARK: - Clip recorder (low-bitrate camera clips for training + offline analysis)

final class ClipRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private(set) var isRecording = false
    private(set) var lastURL: URL?
    private var eventsURL: URL?
    private var evT0 = 0.0

    private let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/PostureMonitor")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func start() {
        guard !isRecording else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "clip_\(f.string(from: Date()))"
        lastURL = dir.appendingPathComponent(base + ".mp4")
        eventsURL = dir.appendingPathComponent(base + ".events.jsonl")
        try? FileManager.default.removeItem(at: eventsURL!)
        evT0 = ProcessInfo.processInfo.systemUptime
        writer = nil; input = nil; started = false
        isRecording = true
        event(["type": "start"])
    }

    /// Append a timestamped event (calibration baseline, periodic samples) to the
    /// clip's sidecar JSONL — so the clip is self-describing for training/analysis.
    func event(_ payload: [String: Any]) {
        guard isRecording, let url = eventsURL else { return }
        var p = payload
        p["t"] = ((ProcessInfo.processInfo.systemUptime - evT0) * 100).rounded() / 100   // secs since rec start
        guard let data = try? JSONSerialization.data(withJSONObject: p),
              let line = String(data: data, encoding: .utf8)?.appending("\n"),
              let bytes = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(bytes); try? fh.close() }
        else { try? bytes.write(to: url) }
    }

    /// Called every camera frame (on the camera queue). Lazily builds the writer
    /// from the first frame's dimensions; encodes at a low bitrate (small files).
    func append(_ sb: CMSampleBuffer) {
        guard isRecording, let url = lastURL else { return }
        if writer == nil {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            try? FileManager.default.removeItem(at: url)
            guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 700_000]]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            if wr.canAdd(inp) { wr.add(inp) }
            wr.startWriting()
            writer = wr; input = inp
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started { writer?.startSession(atSourceTime: pts); started = true }
        if input?.isReadyForMoreMediaData == true { input?.append(sb) }
    }

    func stop(_ done: @escaping (URL?) -> Void) {
        guard isRecording else { DispatchQueue.main.async { done(nil) }; return }
        event(["type": "stop"])
        isRecording = false
        let url = lastURL
        input?.markAsFinished()
        writer?.finishWriting { [weak self] in
            self?.writer = nil; self?.input = nil; self?.started = false
            DispatchQueue.main.async { done(url) }
        }
    }
}
