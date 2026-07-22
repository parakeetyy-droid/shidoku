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

    // Live pinch-to-zoom (real Visual Intelligence supports it). The active
    // device is held so a pinch can drive its videoZoomFactor; the current
    // factor is the pinch baseline that carries between gestures and across
    // captures within the session (it resets only on relaunch, when a fresh
    // process reconfigures the device at 1.0). Only the LIVE viewfinder zooms —
    // the frozen photo does not, and grabFrame captures the zoomed frame for
    // free (data-output buffers already reflect videoZoomFactor).
    private var device: AVCaptureDevice?
    private let zoomLock = NSLock()
    private var _zoom: CGFloat = 1.0
    private static let maxZoomCap: CGFloat = 6.0
    var currentZoom: CGFloat {
        zoomLock.lock(); defer { zoomLock.unlock() }; return _zoom
    }

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
        // A VIDEO preset, NOT .photo. .photo drives the sensor in a high-res
        // still mode whose live pipeline (the preview layer AND the data output)
        // runs at a low, variable frame rate — the cause of the sluggish
        // viewfinder on device. 1080p is far more than grabFrame needs (it is
        // downscaled to 1100 px) and streams a smooth 30 fps.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        var camera: AVCaptureDevice?
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            camera = device
            self.device = device
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
        // Pin a steady 30 fps floor: cameras otherwise stretch frame duration in
        // dim light for exposure, and nothing here guaranteed a floor. Done
        // after commit, so the preset's format is the active one being locked.
        if let camera = camera { lockFrameRate(camera, fps: 30) }
    }

    // Lock the live frame rate to a steady value (both bounds = fps), guarded to
    // a format that actually offers it. Device-level, so it survives the preset.
    private func lockFrameRate(_ device: AVCaptureDevice, fps: Double) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // leave the format's default frame rate if the device won't lock
        }
    }

    // Ramp the live zoom toward `target`, clamped to 1.0…min(6, format max). All
    // configuration happens on the camera queue under lockForConfiguration;
    // ramp(toVideoZoomFactor:rate:) eases the change so a continuous pinch reads
    // as smooth motion, not a jump. `rate` is in log2(zoom) per second — 16 is
    // fast enough to track the fingers while staying eased. The committed factor
    // is stored as the next pinch's baseline.
    func setZoom(to target: CGFloat, rate: Float = 16) {
        queue.async {
            guard let device = self.device else { return }
            let maxZ = min(CameraController.maxZoomCap, device.activeFormat.videoMaxZoomFactor)
            let clamped = max(1.0, min(target, maxZ))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: clamped, withRate: rate)
                device.unlockForConfiguration()
                self.zoomLock.lock(); self._zoom = clamped; self.zoomLock.unlock()
            } catch {
                // if the device won't lock, keep the current zoom
            }
        }
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
