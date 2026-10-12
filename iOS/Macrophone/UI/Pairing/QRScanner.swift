import AVFoundation
import SwiftUI
import UIKit

/// The camera, looking for a Macrophone QR code. Camera access is asked for only here.
struct QRScanner: View {
    var onFound: (String) -> Void
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Ink.sunk)
            switch (hasCamera, access) {
            case (false, _):
                message("No camera here", "Use a code instead, or open the pairing link on this iPhone.")
            case (true, .authorized):
                CameraPreview(onFound: onFound)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                Viewfinder()
            case (true, .notDetermined):
                ProgressView().tint(Ink.ink)
            default:
                VStack(spacing: 12) {
                    message("Camera is off for Macrophone", "Allow it in Settings to scan, or use a code instead.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, tint: Light.cyan))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Ink.line))
        .task {
            guard hasCamera, access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("QR code scanner")
    }

    private func message(_ title: String, _ body: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.tertiary)
            Text(title).font(.headline).foregroundStyle(Ink.ink)
            Text(body).font(.subheadline).foregroundStyle(Ink.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }
}

/// Four soft corners over the camera.
private struct Viewfinder: View {
    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) * 0.62
            let r = CGRect(x: (g.size.width - side) / 2, y: (g.size.height - side) / 2, width: side, height: side)
            Path { p in
                let l: CGFloat = 26
                for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                    p.move(to: CGPoint(x: x + dx * l, y: y))
                    p.addLine(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x, y: y + dy * l))
                }
            }
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: Light.cyan.opacity(0.6), radius: 6)
        }
        .allowsHitTesting(false)
    }
}

private struct CameraPreview: UIViewRepresentable {
    var onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        context.coordinator.attach(to: v)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { context.coordinator.onFound = onFound }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: (String) -> Void
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "macrophone.camera")
        private var delivered = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func attach(to view: PreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            let session = self.session
            sessionQueue.async { [weak self] in
                guard let self, let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
                session.beginConfiguration()
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = [.qr]
                }
                session.commitConfiguration()
                session.startRunning()
            }
        }

        func stop() {
            let session = self.session
            sessionQueue.async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered,
                  let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
                  code.lowercased().hasPrefix("macrophone://") else { return }
            delivered = true
            onFound(code)
            // Allow another scan if this one doesn't work out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.delivered = false }
        }
    }
}
