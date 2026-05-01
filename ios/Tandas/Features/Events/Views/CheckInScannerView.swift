import SwiftUI
import AVFoundation

struct CheckInScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: CheckInScannerCoordinator

    var body: some View {
        ZStack {
            Color.ruulCameraBackground.ignoresSafeArea()

            switch coordinator.scanner.state {
            case .denied:
                permissionDeniedView
            case .error(let msg):
                errorView(msg)
            default:
                cameraPreview
                overlayLayer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await coordinator.start() }
        .onDisappear { coordinator.stop() }
        .onChange(of: coordinator.scanner.state) { _, newState in
            if case .foundCode(let payload) = newState {
                Task { await coordinator.handleScan(payload) }
            }
        }
    }

    // MARK: - Camera

    private var cameraPreview: some View {
        ZStack {
            CameraPreviewLayer(session: coordinator.scanner.captureSession)
                .ignoresSafeArea()
        }
    }

    // MARK: - Overlay (header + frame guide + recents)

    private var overlayLayer: some View {
        VStack {
            header
            Spacer()
            scanFrame
            Spacer()
            recentsList
        }
        .padding(RuulSpacing.s5)
        .overlay(scanFeedbackOverlay)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(alignment: .center, spacing: 4) {
                Text("Modo check-in")
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(.white)
                Text("\(coordinator.checkedCount) de \(coordinator.totalConfirmed) llegaron")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)  // spacer for symmetry
        }
        .padding(RuulSpacing.s4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous))
    }

    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: RuulRadius.lg, style: .continuous)
            .strokeBorder(Color.ruulOnImage.opacity(0.6), lineWidth: 3)
            .frame(width: 240, height: 240)
            .background(Color.clear)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            ForEach(coordinator.recentCheckIns, id: \.memberId) { recent in
                HStack(spacing: RuulSpacing.s3) {
                    RuulAvatar(name: recent.name, size: .small, border: .glass)
                    Text(recent.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(.white)
                    Spacer()
                    Text("✓ Llegó")
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulSemanticSuccess)
                }
                .padding(RuulSpacing.s3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.ruulSmooth, value: coordinator.recentCheckIns.map(\.memberId))
    }

    // MARK: - Feedback overlay (success / already / invalid)

    @ViewBuilder
    private var scanFeedbackOverlay: some View {
        switch coordinator.overlay {
        case .none:
            EmptyView()
        case .success(_, let name):
            feedbackCard(
                icon: "checkmark.circle.fill",
                color: .ruulSemanticSuccess,
                title: "¡Bienvenido \(name)!"
            )
        case .alreadyCheckedIn(_, let name):
            feedbackCard(
                icon: "exclamationmark.circle.fill",
                color: .ruulSemanticWarning,
                title: "\(name) ya llegó"
            )
        case .invalid:
            feedbackCard(
                icon: "xmark.circle.fill",
                color: .ruulSemanticError,
                title: "QR inválido"
            )
        }
    }

    private func feedbackCard(icon: String, color: Color, title: String) -> some View {
        VStack(spacing: RuulSpacing.s3) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(.white, color)
            Text(title)
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(.white)
        }
        .padding(RuulSpacing.s7)
        .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: RuulRadius.xl, style: .continuous))
        .transition(.scale.combined(with: .opacity))
        .animation(.ruulSnappy, value: coordinator.overlay)
    }

    // MARK: - Empty states

    private var permissionDeniedView: some View {
        VStack(spacing: RuulSpacing.s5) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.5))
            Text("Necesitamos permiso de cámara")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(.white)
            Text("Para escanear QRs y marcar llegadas.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            RuulButton("Abrir Configuración", style: .primary, size: .large) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            RuulButton("Cerrar", style: .glass, size: .medium) { dismiss() }
            Spacer()
        }
        .padding(RuulSpacing.s5)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: RuulSpacing.s4) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.white.opacity(0.7))
            Text(msg)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            RuulButton("Cerrar", style: .glass, size: .medium) { dismiss() }
            Spacer()
        }
        .padding(RuulSpacing.s5)
    }
}

/// Embeds the AVCaptureSession in a SwiftUI hierarchy.
private struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
