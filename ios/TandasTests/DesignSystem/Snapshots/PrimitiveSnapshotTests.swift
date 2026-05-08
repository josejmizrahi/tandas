import SnapshotTesting
import SwiftUI
import XCTest
import RuulUI
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
    private let badgeSize = CGSize(width: 220, height: 56)
    private let cardSize = CGSize(width: 360, height: 120)
    private let moneySize = CGSize(width: 220, height: 80)
    private let pillSize = CGSize(width: 80, height: 64)
    private let chipSize = CGSize(width: 220, height: 56)

    // MARK: - RuulButton

    func test_RuulButton_primary_light() {
        let view = RuulButton("Confirmar", style: .primary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .light)
    }

    func test_RuulButton_primary_dark() {
        let view = RuulButton("Confirmar", style: .primary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .dark)
    }

    func test_RuulButton_secondary_light() {
        let view = RuulButton("Cancelar", style: .secondary, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .light)
    }

    func test_RuulButton_destructive_dark() {
        let view = RuulButton("Eliminar", style: .destructive, fillsWidth: true) {}
        assertImage(view, size: buttonSize, scheme: .dark)
    }

    // MARK: - RuulBadge

    func test_RuulBadge_neutral_light() {
        let view = RuulBadge("Pendiente")
        assertImage(view, size: badgeSize, scheme: .light)
    }

    func test_RuulBadge_neutral_dark() {
        let view = RuulBadge("Pendiente")
        assertImage(view, size: badgeSize, scheme: .dark)
    }

    // MARK: - RuulMoneyView

    func test_RuulMoneyView_neutral_light() {
        let view = RuulMoneyView(amount: 1234.50, currency: "MXN", size: .medium)
        assertImage(view, size: moneySize, scheme: .light)
    }

    func test_RuulMoneyView_negative_dark() {
        let view = RuulMoneyView(
            amount: -89.00,
            currency: "MXN",
            size: .large,
            showSign: true,
            color: .negative
        )
        assertImage(view, size: moneySize, scheme: .dark)
    }

    // MARK: - RuulPillButton

    func test_RuulPillButton_light() {
        let view = RuulPillButton(symbol: "plus") {}
        assertImage(view, size: pillSize, scheme: .light)
    }

    func test_RuulPillButton_dark() {
        let view = RuulPillButton(symbol: "plus") {}
        assertImage(view, size: pillSize, scheme: .dark)
    }

    // MARK: - RuulChip

    func test_RuulChip_selectableActive_light() {
        let view = RuulChip(
            "Activo",
            systemImage: "checkmark.circle.fill",
            style: .selectable(isSelected: true)
        ) {}
        assertImage(view, size: chipSize, scheme: .light)
    }

    func test_RuulChip_suggestion_dark() {
        let view = RuulChip("Sugerencia", style: .suggestion) {}
        assertImage(view, size: chipSize, scheme: .dark)
    }

    // MARK: - Helpers

    private func assertImage<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme,
        filePath: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let host = DSSnapshot.host(view, size: size, scheme: scheme)
        assertSnapshot(
            of: host,
            as: .image(precision: 0.99, perceptualPrecision: 0.98, size: size),
            named: scheme == .dark ? "dark" : "light",
            file: filePath,
            testName: testName,
            line: line
        )
    }
}
