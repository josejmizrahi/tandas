import Foundation
import AVFoundation
import OSLog

/// Lightweight wrapper around `AVCaptureSession` configured for QR scanning.
/// Owners (e.g. CheckInScannerCoordinator) call `start()` then observe the
/// `state` property; SwiftUI views observe via @Observable.
@MainActor @Observable
final class QRScannerService: NSObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case denied
        case scanning
        case foundCode(String)
        case error(String)
    }

    private(set) var state: State = .idle
    let captureSession = AVCaptureSession()

    private let log = Logger(subsystem: "com.josejmizrahi.ruul", category: "qr.scanner")
    private var metadataOutput = AVCaptureMetadataOutput()
    private let scanQueue = DispatchQueue(label: "com.josejmizrahi.ruul.qr.scan")

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            await configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                await configureAndStart()
            } else {
                state = .denied
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    func stop() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        state = .idle
    }

    /// Acknowledge a scanned code and return to scanning state. Throttle from
    /// caller to avoid double-scanning the same QR.
    func acknowledgeAndResume() {
        if case .scanning = state { return }
        state = .scanning
    }

    private func configureAndStart() async {
        guard !captureSession.isRunning else {
            state = .scanning
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            state = .error("Camera unavailable")
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.metadataObjectTypes = [.qr]
            metadataOutput.setMetadataObjectsDelegate(self, queue: scanQueue)
        } else {
            state = .error("Cannot add metadata output")
            captureSession.commitConfiguration()
            return
        }

        captureSession.commitConfiguration()
        // Apple recommends starting on a background queue but AVCaptureSession
        // isn't Sendable under Swift 6 strict concurrency. Sync call is safe;
        // brief main-thread block during camera startup is acceptable.
        captureSession.startRunning()
        state = .scanning
    }
}

extension QRScannerService: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue
        else { return }
        Task { @MainActor in
            // Only update if currently scanning, to avoid clobbering a
            // foundCode while it's being processed.
            if case .scanning = state {
                state = .foundCode(payload)
            }
        }
    }
}
