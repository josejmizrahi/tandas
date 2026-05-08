import SnapshotTesting
import SwiftUI
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

/// Shared helpers for DS primitive snapshot tests. Locks the rendered surface
/// to a fixed size + traits so snapshots are deterministic across machines.
///
/// Per DS v3 §17.2 — captura visual baseline para detectar regressions en los
/// componentes core. Cada primitive se snapshotea en Light + Dark.
enum DSSnapshot {
    /// Render a SwiftUI view inside a UIHostingController locked to `size`,
    /// with the given color scheme applied via overrideUserInterfaceStyle so
    /// the asserted image is independent of the host simulator's appearance.
    @MainActor
    static func host<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme
    ) -> UIViewController {
        let container = view
            .frame(width: size.width, height: size.height, alignment: .center)
            .background(Color.ruulBackground)
        let host = UIHostingController(rootView: AnyView(container))
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        return host
    }
}
