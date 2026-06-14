// Engines.swift — App Store / Vision-only build.
// Apple Vision face position ONLY. No MediaPipe, no local server, no network —
// all of which the App Store sandbox forbids. The trade-off: we detect the
// "whole body sinks" slouch (head drops in frame), but not forward-head.

import AppKit
import AVFoundation
import Vision

// MARK: - Reading

struct VisionReading {
    var faceFound = false
    var headY = 0.0          // face-box center height in frame (drops when you slump down)
    var faceSize = 0.0       // face-box height (grows when you lean in)
    var faceRect = CGRect.zero   // normalized Vision rect (origin bottom-left) for the overlay
    var frameW = 0.0
    var frameH = 0.0
}

// MARK: - Calibration / presence detector

final class PostureLogic {
    enum Status { case away, settling, good }

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

    /// Presence + auto-calibration. Captures the upright baseline once your head
    /// holds still. The slouch decision itself lives in AppModel.
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

// MARK: - Cameras

func availableCameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified).devices
}

// MARK: - Vision engine (camera + face every frame; nothing leaves the process)

final class VisionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "posture.cam")
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var lastProc = 0.0

    var onVision: ((VisionReading) -> Void)?
    var onCameraDenied: (() -> Void)?
    var preferredDevice: AVCaptureDevice?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { DispatchQueue.main.async { self.onCameraDenied?() }; return }
            self.queue.async { self.configure(); self.session.startRunning() }
        }
    }

    func switchTo(_ dev: AVCaptureDevice) {
        queue.async {
            self.preferredDevice = dev
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            if let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        let dev = preferredDevice
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let dev, let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
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
        if now - lastProc < 0.12 { return }     // ~8 fps
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
            r.faceRect = face.boundingBox
        }
        DispatchQueue.main.async { self.onVision?(r) }
    }
}
