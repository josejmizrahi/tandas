import SwiftUI
import RuulUI
import RuulCore

/// Floating nav row pinned to the top of the resource detail. Three
/// glass-pill buttons:
///
///   - Close       — dismisses the detail (context.onDismiss or env dismiss)
///   - Share       — presenter.onPresentShareSheet (hidden when no presenter)
///   - More menu   — Editar (event-only) + Activar capability
///
/// Designed to overlay the cover hero on event-shaped detail surfaces.
/// The buttons stay tappable above the scroll content via a ZStack
/// composition at the `UniversalResourceDetailView` level.
public struct DetailTopNavView: View {
    @Environment(\.dismiss) private var envDismiss
    @Environment(\.eventDetailPresenter) private var presenter: EventDetailPresenter?

    public let context: ResourceDetailContext

    public init(context: ResourceDetailContext) {
        self.context = context
    }

    public var body: some View {
        HStack(spacing: RuulSpacing.xs) {
            navCircleButton(icon: "xmark", label: "Cerrar") {
                if let onDismiss = context.onDismiss {
                    onDismiss()
                } else {
                    envDismiss()
                }
            }
            Spacer()
            if presenter != nil {
                navCircleButton(icon: "square.and.arrow.up", label: "Compartir") {
                    presenter?.onPresentShareSheet()
                }
            }
            moreMenu
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.top, statusBarTopPadding)
    }

    // MARK: - More menu

    private var moreMenu: some View {
        Menu {
            if presenter != nil && context.resource.resourceType == .event {
                Button("Editar", systemImage: "pencil") {
                    presenter?.onPresentEditEvent()
                }
            }
            // "Agregar función" only when the surrounding shell actually
            // wires a handler (non-events). For events the function set
            // is hard-seeded by migrations 00109/00110 — surfacing a
            // no-op menu item would just confuse the user.
            //
            // Beta 1 W2-C1: button label was "Activar capability" which
            // leaked the internal model term. "Función" is the canonical
            // user-facing translation per the UX dictionary.
            if !context.usesEventHero {
                Button("Agregar función", systemImage: "plus.circle") {
                    context.onPresentEnableCapability()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.clear)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: 36, height: 36)
                    .ruulGlass(Circle(), material: .regular)
                    .ruulElevation(.sm)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Más acciones")
    }

    // MARK: - Circle button

    private func navCircleButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                // Tap target ≥44pt (HIG). Apple's `glassEffect` with
                // `interactive: true` was observed to swallow taps inside
                // the circle on iOS 26.x — keep the visual circle at 36pt
                // and the actual hit area at 44pt via `contentShape`.
                Circle()
                    .fill(.clear)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ruulTextPrimary)
                    .frame(width: 36, height: 36)
                    .ruulGlass(Circle(), material: .regular)
                    .ruulElevation(.sm)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.ruulPress)
        .accessibilityLabel(label)
    }

    // MARK: - Status bar inset

    /// Approximate top safe-area inset. Used so the nav row clears the
    /// dynamic island / notch without resorting to `.ignoresSafeArea`
    /// (which would also push the row up under the system clock).
    private var statusBarTopPadding: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 50
    }
}
