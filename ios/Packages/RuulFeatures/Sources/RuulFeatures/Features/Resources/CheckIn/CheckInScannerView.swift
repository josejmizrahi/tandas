import SwiftUI
import AVFoundation
import RuulUI
import RuulCore

public struct CheckInScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: CheckInScannerCoordinator

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
        .padding(RuulSpacing.lg)
        .overlay(scanFeedbackOverlay)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
            Spacer()
            VStack(alignment: .center, spacing: 4) {
                Text("Modo check-in")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                Text("\(coordinator.checkedCount) de \(coordinator.totalConfirmed) llegaron")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)  // spacer for symmetry
        }
        .padding(RuulSpacing.md)
        // DS v3 §13: header overlay sobre cámara — Liquid Glass real.
        .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous), material: .regular)
    }

    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous)
            .strokeBorder(Color.white.opacity(0.6), lineWidth: 3)
            .frame(width: 240, height: 240)
            .background(Color.clear)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            ForEach(coordinator.recentCheckIns, id: \.memberId) { recent in
                HStack(spacing: RuulSpacing.sm) {
                    RuulAvatar(name: recent.name, size: .small, border: .glass)
                    Text(recent.name)
                        .font(.subheadline)
                        .foregroundStyle(Color.white)
                    Spacer()
                    Text("✓ Llegó")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                }
                .padding(RuulSpacing.sm)
                // DS v3 §13: recent check-in chip overlay — Liquid Glass real.
                .ruulGlass(RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous), material: .regular)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: coordinator.recentCheckIns.map(\.memberId))
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
                color: .green,
                title: "¡Bienvenido \(name)!"
            )
        case .alreadyCheckedIn(_, let name):
            feedbackCard(
                icon: "exclamationmark.circle.fill",
                color: .orange,
                title: "\(name) ya llegó"
            )
        case .invalid:
            feedbackCard(
                icon: "xmark.circle.fill",
                color: .red,
                title: "QR inválido"
            )
        }
    }

    private func feedbackCard(icon: String, color: Color, title: String) -> some View {
        VStack(spacing: RuulSpacing.sm) {
            Image(systemName: icon)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.white, color)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.white)
        }
        .padding(RuulSpacing.xxl)
        .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: RuulRadius.extraLarge, style: .continuous))
        .transition(.scale.combined(with: .opacity))
        .animation(.smooth, value: coordinator.overlay)
    }

    // MARK: - Empty states

    private var permissionDeniedView: some View {
        VStack(spacing: RuulSpacing.lg) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .accessibilityHidden(true)
            Text("Necesitamos permiso de cámara")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.white)
            Text("Para escanear QRs y marcar llegadas.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
            RuulButton("Abrir Configuración", style: .primary, size: .large) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            RuulButton("Cerrar", style: .glass, size: .medium) { dismiss() }
            Spacer()
        }
        .padding(RuulSpacing.lg)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: RuulSpacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .accessibilityHidden(true)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
            RuulButton("Cerrar", style: .glass, size: .medium) { dismiss() }
            Spacer()
        }
        .padding(RuulSpacing.lg)
    }
}

/// Embeds the AVCaptureSession in a SwiftUI hierarchy.
private struct CameraPreviewLayer: UIViewRepresentable {
    public let session: AVCaptureSession

    public func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {}

    public final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
