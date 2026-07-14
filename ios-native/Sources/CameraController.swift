import AVFoundation
import UIKit

// Live rear-camera session. The viewfinder shows the session through
// CameraPreview; freezing a frame grabs the most recent video buffer
// (instant, no shutter latency — matching how real Visual Intelligence
// freezes what you see).
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var denied = false
    @Published var running = false

    private let queue = DispatchQueue(label: "shidoku.camera")
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var configured = false
    private static let ciContext = CIContext()

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self = self else { return }
            DispatchQueue.main.async { self.denied = !ok }
            guard ok else { return }
            self.queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.running = true }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) {
            // portrait-locked app: keep buffers upright
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = pb
        bufferLock.unlock()
    }

    // The most recent live frame as a UIImage (nil until the first frame lands).
    func grabFrame() -> UIImage? {
        bufferLock.lock()
        let pb = latestBuffer
        bufferLock.unlock()
        guard let pixelBuffer = pb else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = CameraController.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
