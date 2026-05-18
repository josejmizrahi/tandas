import Foundation
import XCTest
import RuulCore

/// §22.4 / mig 00251 — verifies the composer-side `ShapeNode` tree
/// model and `RuleDraft` mutations that drive the Avanzado mode UI:
///   - Codable encode/decode for both wire shapes (leaf object,
///     `{op,children}` tree object).
///   - `replacing` / `removing` keep the tree well-formed.
///   - `RuleDraft.enterAdvancedMode` lifts the flat list into a
///     `.and([leaves])` tree; `exitAdvancedMode` flattens it back.
///   - `wrapSiblingsAsOR` and `wrapAsNOT` produce the `A AND (B OR C)`
///     and `NOT D` shapes the composer needs to author.
final class ShapeNodeTests: XCTestCase {

    // MARK: - Fixtures

    private func leafA() -> ShapeInstance {
        ShapeInstance(shapeId: "alwaysTrue", config: .object([:]))
    }
    private func leafB() -> ShapeInstance {
        ShapeInstance(shapeId: "responseStatusIs", config: .object(["status": .string("going")]))
    }
    private func leafC() -> ShapeInstance {
        ShapeInstance(shapeId: "checkInExists", config: .object(["exists": .bool(false)]))
    }

    private func decode(_ json: String) throws -> ShapeNode {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ShapeNode.self, from: data)
    }

    // MARK: - Codable

    func testLeafEncodesAsBareShapeInstance() throws {
        let node = ShapeNode.leaf(leafB())
        let data = try JSONEncoder().encode(node)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any] else {
            return XCTFail("expected JSON object, got \(type(of: any))")
        }
        XCTAssertEqual(dict["shape_id"] as? String, "responseStatusIs")
        XCTAssertNil(dict["op"], "leaf must NOT carry the tree op key")
    }

    func testTreeEncodesAsOpChildrenObject() throws {
        let tree: ShapeNode = .and(id: UUID(), children: [
            .leaf(leafA()),
            .or(id: UUID(), children: [.leaf(leafB()), .leaf(leafC())])
        ])
        let data = try JSONEncoder().encode(tree)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any] else {
            return XCTFail("expected JSON object")
        }
        XCTAssertEqual(dict["op"] as? String, "and")
        guard let children = dict["children"] as? [Any] else {
            return XCTFail("expected children array")
        }
        XCTAssertEqual(children.count, 2)
    }

    func testTreeRoundTripPreservesStructure() throws {
        let tree: ShapeNode = .and(id: UUID(), children: [
            .leaf(leafA()),
            .or(id: UUID(), children: [
                .leaf(leafB()),
                .not(id: UUID(), child: .leaf(leafC()))
            ])
        ])
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(ShapeNode.self, from: data)
        // Op-node ids are client-only — only the leaf ids round-trip.
        XCTAssertEqual(decoded.allLeaves.map(\.shapeId),
                       tree.allLeaves.map(\.shapeId))
        // Structure check: top is AND with 2 children; second child is OR
        // with leaf + NOT(leaf).
        guard case .and(_, let topCs) = decoded, topCs.count == 2 else {
            return XCTFail("expected top AND with 2 children")
        }
        guard case .or(_, let orCs) = topCs[1], orCs.count == 2 else {
            return XCTFail("expected OR as second child")
        }
        guard case .not(_, let notChild) = orCs[1] else {
            return XCTFail("expected NOT inside OR")
        }
        if case .leaf(let i) = notChild {
            XCTAssertEqual(i.shapeId, "checkInExists")
        } else {
            XCTFail("expected NOT-wrapped leaf")
        }
    }

    func testDecodeUnknownOpThrows() {
        let json = #"{"op": "xor", "children": []}"#
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: - isFlatAnd / allLeaves

    func testIsFlatAndDetectsLegacyShape() {
        let flat = ShapeNode.and([leafA(), leafB(), leafC()])
        XCTAssertTrue(flat.isFlatAnd, "AND of pure leaves is flat")

        let nested: ShapeNode = .and(id: UUID(), children: [
            .leaf(leafA()),
            .or(id: UUID(), children: [.leaf(leafB()), .leaf(leafC())])
        ])
        XCTAssertFalse(nested.isFlatAnd, "AND with an OR child is NOT flat")

        let notRoot: ShapeNode = .not(id: UUID(), child: .leaf(leafA()))
        XCTAssertFalse(notRoot.isFlatAnd, "NOT at root is not a flat AND")
    }

    func testAllLeavesPreOrder() {
        let tree: ShapeNode = .and(id: UUID(), children: [
            .leaf(leafA()),
            .or(id: UUID(), children: [
                .leaf(leafB()),
                .not(id: UUID(), child: .leaf(leafC()))
            ])
        ])
        XCTAssertEqual(tree.allLeaves.map(\.shapeId),
                       ["alwaysTrue", "responseStatusIs", "checkInExists"])
    }

    // MARK: - replacing / removing

    func testReplacingSwapsLeafInPlace() {
        let originalLeaf = leafA()
        let tree: ShapeNode = .and(id: UUID(), children: [.leaf(originalLeaf), .leaf(leafB())])
        let replacement = ShapeNode.not(id: UUID(), child: .leaf(originalLeaf))
        guard let updated = tree.replacing(id: originalLeaf.id, with: replacement) else {
            return XCTFail("expected replacement to succeed")
        }
        guard case .and(_, let cs) = updated, case .not(_, .leaf(let l)) = cs[0] else {
            return XCTFail("expected first child to become NOT(leaf)")
        }
        XCTAssertEqual(l.shapeId, "alwaysTrue")
    }

    func testRemovingCollapsesSingleChildContainer() {
        // Removing one of two OR siblings collapses the OR into the
        // surviving sibling (single-child AND/OR is meaningless).
        let a = leafA()
        let b = leafB()
        let orId = UUID()
        let andId = UUID()
        let tree: ShapeNode = .and(id: andId, children: [
            .or(id: orId, children: [.leaf(a), .leaf(b)])
        ])
        guard let updated = tree.removing(id: a.id) else {
            return XCTFail("expected removal to succeed")
        }
        // Auto-collapse cascades: OR collapses to its single surviving
        // leaf, then AND collapses (also single child) to that leaf.
        // The tree minimization keeps the sentence renderer + server
        // validator happy. (Pre-collapse behavior preserved the AND
        // wrapping; updated to match current collapseRemoval doctrine.)
        guard case .leaf(let l) = updated else {
            return XCTFail("expected fully-collapsed surviving leaf, got \(updated)")
        }
        XCTAssertEqual(l.shapeId, "responseStatusIs")
    }

    // MARK: - RuleDraft Avanzado mutations

    func testEnterAdvancedModeLiftsConditionsIntoFlatAnd() {
        var draft = RuleDraft(
            name: "Test",
            scope: .group,
            conditions: [leafA(), leafB()]
        )
        XCTAssertNil(draft.conditionsTree)
        draft.enterAdvancedMode()
        guard let tree = draft.conditionsTree else {
            return XCTFail("entering advanced mode must set conditionsTree")
        }
        XCTAssertTrue(tree.isFlatAnd, "entry tree must be flat AND(leaves)")
        XCTAssertEqual(tree.allLeaves.map(\.shapeId), ["alwaysTrue", "responseStatusIs"])
    }

    func testExitAdvancedModeFlattensTreeBackToList() {
        var draft = RuleDraft(name: "T", scope: .group, conditions: [leafA()])
        draft.enterAdvancedMode()
        draft.exitAdvancedMode()
        XCTAssertNil(draft.conditionsTree)
        XCTAssertEqual(draft.conditions.map(\.shapeId), ["alwaysTrue"])
    }

    func testWrapSiblingsAsORBuildsAandThenOr() {
        // Goal: end up with A AND (B OR C).
        let a = leafA()
        let b = leafB()
        let c = leafC()
        var draft = RuleDraft(name: "T", scope: .group, conditions: [a, b, c])
        draft.enterAdvancedMode()

        // Wrap B + C as OR (B is the head; "next sibling" is C).
        draft.wrapSiblingsAsOR(headId: b.id)

        guard let tree = draft.conditionsTree else {
            return XCTFail("tree expected after wrap")
        }
        guard case .and(_, let cs) = tree, cs.count == 2 else {
            return XCTFail("expected AND with 2 children, got \(tree)")
        }
        guard case .leaf(let firstLeaf) = cs[0] else {
            return XCTFail("expected first child to remain a leaf")
        }
        XCTAssertEqual(firstLeaf.shapeId, "alwaysTrue")
        guard case .or(_, let orCs) = cs[1], orCs.count == 2 else {
            return XCTFail("expected second child to be OR with 2 children")
        }
        XCTAssertEqual(orCs.compactMap { if case .leaf(let l) = $0 { return l.shapeId } else { return nil } },
                       ["responseStatusIs", "checkInExists"])
    }

    func testWrapAsNOTNegatesALeafInPlace() {
        let a = leafA()
        var draft = RuleDraft(name: "T", scope: .group, conditions: [a, leafB()])
        draft.enterAdvancedMode()
        draft.wrapAsNOT(id: a.id)
        guard let tree = draft.conditionsTree, case .and(_, let cs) = tree, cs.count == 2 else {
            return XCTFail("expected AND with 2 children")
        }
        guard case .not(_, .leaf(let inner)) = cs[0] else {
            return XCTFail("expected first child to become NOT(leaf)")
        }
        XCTAssertEqual(inner.shapeId, "alwaysTrue")
    }

    func testUnwrapGroupingFlattensORBackUp() {
        // Build A AND (B OR C), then unwrap the OR → A AND B AND C.
        let a = leafA(); let b = leafB(); let c = leafC()
        var draft = RuleDraft(name: "T", scope: .group, conditions: [a, b, c])
        draft.enterAdvancedMode()
        draft.wrapSiblingsAsOR(headId: b.id)
        guard case .and(_, let cs) = draft.conditionsTree, let orNode = cs.first(where: {
            if case .or = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected OR child to exist after wrap")
        }
        draft.unwrap(nodeId: orNode.id)
        guard case .and(_, let after) = draft.conditionsTree else {
            return XCTFail("expected AND after unwrap")
        }
        XCTAssertEqual(after.count, 3, "OR's children moved up to top-level AND")
        XCTAssertEqual(after.compactMap { if case .leaf(let l) = $0 { return l.shapeId } else { return nil } },
                       ["alwaysTrue", "responseStatusIs", "checkInExists"])
    }

    func testRemoveConditionStaysInSyncWithTree() {
        let a = leafA(); let b = leafB(); let c = leafC()
        var draft = RuleDraft(name: "T", scope: .group, conditions: [a, b, c])
        draft.enterAdvancedMode()
        draft.removeCondition(id: b.id)
        // Flat list lost B.
        XCTAssertEqual(draft.conditions.map(\.shapeId), ["alwaysTrue", "checkInExists"])
        // Tree lost B too.
        guard let tree = draft.conditionsTree else {
            return XCTFail("tree expected")
        }
        XCTAssertEqual(tree.allLeaves.map(\.shapeId), ["alwaysTrue", "checkInExists"])
    }

    func testAddConditionInAvanzadoAppendsAtRoot() {
        var draft = RuleDraft(name: "T", scope: .group, conditions: [leafA()])
        draft.enterAdvancedMode()
        draft.addCondition("checkInExists", config: .object(["exists": .bool(false)]))
        // Flat view gained the new leaf.
        XCTAssertEqual(draft.conditions.map(\.shapeId), ["alwaysTrue", "checkInExists"])
        // Tree's root AND gained the leaf too.
        guard case .and(_, let cs) = draft.conditionsTree, cs.count == 2 else {
            return XCTFail("expected root AND with 2 children after add")
        }
        guard case .leaf(let added) = cs[1] else {
            return XCTFail("expected second child to be the new leaf")
        }
        XCTAssertEqual(added.shapeId, "checkInExists")
    }
}
