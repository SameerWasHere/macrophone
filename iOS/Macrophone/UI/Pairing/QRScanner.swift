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
            #if DEBUG
            if DebugHooks.env["MACROPHONE_FAKE_CAMERA"] == "1" {
                FakeCameraFeed().clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                Viewfinder()
            }
            #endif
            switch (hasCamera, access) {
            case _ where fakeCamera:
                EmptyView()
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
            guard !fakeCamera, hasCamera, access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("QR code scanner")
    }

    private var fakeCamera: Bool {
        #if DEBUG
        return DebugHooks.fakeCamera
        #else
        return false
        #endif
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

#if DEBUG
import CoreImage.CIFilterBuiltins

/// Store screenshots: the Mac's pairing window as the camera would see it (the simulator has no camera).
private struct FakeCameraFeed: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.15), Color(red: 0.05, green: 0.05, blue: 0.08)],
                               startPoint: .top, endPoint: .bottom)
                // The Mac's screen, slightly off-axis, a little soft.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.26), Color(red: 0.09, green: 0.10, blue: 0.15)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: g.size.width * 1.1, height: g.size.height * 0.92)
                    .blur(radius: 1.5)
                let side = min(g.size.width, g.size.height) * 0.62
                VStack(spacing: 6) {
                    Text("Pair your iPhone").font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.75))
                    if let qr = Self.qr {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: side * 0.66, height: side * 0.66)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.96)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .rotation3DEffect(.degrees(6), axis: (x: 0.3, y: -1, z: 0), perspective: 0.4)
                .blur(radius: 0.3)
                .position(x: g.size.width / 2, y: g.size.height / 2)
                RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: g.size.width * 0.3, endRadius: g.size.width * 0.8)
            }
        }
        .allowsHitTesting(false)
    }

    static let qr: UIImage? = {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data("macrophone://pair?v=1&i=5C1E0F8A-2D7B-4C11-9A63-0E2B7F9D4A10&n=MacBook%20Pro&k=tdI2yELshJ2HW4SoxXIJEiBY2QXhMP".utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }()
}
#endif

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
