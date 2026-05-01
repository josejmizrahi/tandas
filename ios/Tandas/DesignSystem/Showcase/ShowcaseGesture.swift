#if DEBUG
import SwiftUI
import UIKit

/// Listens for the device shake gesture and presents the showcase as a
/// full-screen cover. Apply `.ruulShowcaseShakeListener()` at the app root
/// (only in DEBUG builds).
public extension View {
    func ruulShowcaseShakeListener() -> some View {
        modifier(ShowcaseShakeListener())
    }
}

private struct ShowcaseShakeListener: ViewModifier {
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .background(ShakeDetector(onShake: { presented = true }))
            .fullScreenCover(isPresented: $presented) {
                ShowcaseRootView()
                    .overlay(alignment: .topTrailing) {
                        Button { presented = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                        }
                        .padding()
                    }
            }
    }
}

/// UIKit bridge — installs an event listener on the window to catch shakes.
private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

private final class ShakeViewController: UIViewController {
    var onShake: () -> Void

    init(onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake() }
    }
}
#endif
