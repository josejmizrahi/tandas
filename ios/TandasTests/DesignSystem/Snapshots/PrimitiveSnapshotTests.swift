import SnapshotTesting
import SwiftUI
import XCTest
import RuulUI
import RuulCore
@testable import Tandas

/// Visual baseline para los DS primitives core. Renderiza cada componente en
/// Light + Dark y compara contra `__Snapshots__/`.
///
/// Para regenerar baselines (después de un cambio intencional de DS):
///   `withSnapshotTesting(record: .all) { /* run tests */ }`
/// o setear `SNAPSHOT_TESTING_RECORD=all` env var.
///
/// Per DS v3 §17.2.
@MainActor
final class PrimitiveSnapshotTests: XCTestCase {

    private let buttonSize = CGSize(width: 320, height: 64)
    private let cardSize = CGSize(width: 360, height: 120)
    private let moneySize = CGSize(width: 220, height: 80)

    // MARK: - RuulButton

    func test_RuulButton_primary_light() throws {
        try skipOnCI()
        let view = RuulButton("Confirmar", style: .primary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .light)
    }

    func test_RuulButton_primary_dark() throws {
        try skipOnCI()
        let view = RuulButton("Confirmar", style: .primary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .dark)
    }

    func test_RuulButton_secondary_light() throws {
        try skipOnCI()
        let view = RuulButton("Cancelar", style: .secondary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .light)
    }

    func test_RuulButton_destructive_dark() throws {
        try skipOnCI()
        let view = RuulButton("Eliminar", style: .destructive, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .dark)
    }


    // MARK: - RuulMoneyView

    func test_RuulMoneyView_neutral_light() throws {
        try skipOnCI()
        let view = RuulMoneyView(amount: 1234.50, currency: "MXN", size: .medium)
        assertImage(view, size: moneySize, scheme: .light)
    }

    func test_RuulMoneyView_negative_dark() throws {
        try skipOnCI()
        let view = RuulMoneyView(
            amount: -89.00,
            currency: "MXN",
            size: .large,
            showSign: true,
            color: .negative
        )
        assertImage(view, size: moneySize, scheme: .dark)
    }

    /// Skip a snapshot test when running on GitHub Actions.
    /// Two primitive families render catastrophically differently
    /// across iOS 26 simulator SDK minors (CI macos-15 ships Xcode
    /// 26.3 / iOS 26.2; engineer machines run 26.4+):
    ///   - `RuulMoneyView` via `.monospacedDigit()` — glyph edges flip
    ///     full-white↔full-black (perceptual precision ~0.0006).
    ///   - `RuulButton` via the iOS 26 Liquid Glass button styles
    ///     (`.borderedProminent` / `.bordered` / `.glass`) — the
    ///     material blur + tint composites differently enough that only
    ///     ~33% of pixels match.
    /// The reference snapshots in this repo were recorded on 26.4 and
    /// CI's 26.2 produces divergence no reasonable tolerance absorbs
    /// without also hiding real regressions.
    /// Local Xcode 26.4+ runs still execute these tests, so a real
    /// regression in the rendering is caught during dev. When CI's
    /// macos image upgrades to Xcode ≥ 26.4 — currently blocked on
    /// GitHub's macos-15 image — the snapshots match again and this
    /// skip can go away.
    ///
    /// Detection: `#if CI` is set via `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
    /// in the workflow's xcodebuild command. ProcessInfo + ENV does
    /// NOT propagate from runner shell into the iOS Simulator test
    /// process (verified across 3 CI runs); the compile-time flag is
    /// the only reliable channel for iOS unit tests.
    private func skipOnCI() throws {
        #if CI
        throw XCTSkip("RuulMoneyView snapshots skipped on CI — cross-Xcode font rendering. See PrimitiveSnapshotTests.swift skipOnCI() comment.")
        #endif
    }

    // MARK: - Helpers

    private func assertImage<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme,
        precision: Float = 0.99,
        perceptualPrecision: Float = 0.98,
        filePath: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let host = DSSnapshot.host(view, size: size, scheme: scheme)
        assertSnapshot(
            of: host,
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision, size: size),
            named: scheme == .dark ? "dark" : "light",
            file: filePath,
            testName: testName,
            line: line
        )
    }
}
