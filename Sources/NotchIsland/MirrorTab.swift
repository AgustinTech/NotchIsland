import AVFoundation
import AppKit
import SwiftUI

/// Cámara del Mac a modo de espejo. Solo se enciende mientras esta pestaña está abierta.
final class CameraModel: ObservableObject {
    @Published var denied = false
    let session = AVCaptureSession()

    private var configured = false
    /// Solo se lee y escribe en `queue`, junto con el estado de la sesión.
    private var wantsRunning = false
    private let queue = DispatchQueue(label: "notchisland.camera")

    func start() {
        queue.async { self.wantsRunning = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.run() } else { self.denied = true }
                }
            }
        default:
            denied = true
        }
    }

    private func run() {
        denied = false
        queue.async {
            guard self.wantsRunning else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .medium
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if self.session.inputs.isEmpty { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        private let previewLayer = AVCaptureVideoPreviewLayer()

        func attach(_ session: AVCaptureSession) {
            wantsLayer = true
            layer = CALayer()
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            // Efecto espejo: la conexión solo existe cuando la cámara ya está activa.
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}

struct MirrorTab: View {
    @StateObject private var camera = CameraModel()
    let expanded: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if camera.denied {
                VStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 22))
                    Text("Permite la cámara en Ajustes del Sistema → Privacidad y seguridad")
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.horizontal, 24)
            } else {
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .onAppear {
            if expanded { camera.start() }
        }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded { camera.start() } else { camera.stop() }
        }
        .onDisappear { camera.stop() }
    }
}
