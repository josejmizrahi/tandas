import Foundation
import XCTest
import RuulCore

/// §22.4 / mig 00251 — verifies the `ConditionNode` tree model:
///   - Codable round-trip for both wire shapes (legacy array, tree object).
///   - Decoding tolerance: array → `.and(leaves)` collapses correctly.
///   - Encoding compacts `.and(of leaves)` back to a JSON array so pre-§22.4
///     consumers (rule_versions.compiled snapshots, list_rules joins) see
///     no shape change.
///   - Tree walkers (`flatLeaves`, `allLeaves`) behave as documented.
final class ConditionNodeTests: XCTestCase {

    // MARK: - Fixtures

    private static let leafA = RuleCondition(type: .alwaysTrue, config: .empty)
    private static let leafB = RuleCondition(
        type: .responseStatusIs,
        config: .object(["status": .string("going")])
    )
    private static let leafC = RuleCondition(
        type: .checkInExists,
        config: .object(["exists": .bool(false)])
    )

    private func encode(_ node: ConditionNode) throws -> Any {
        let data = try JSONEncoder().encode(node)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func decode(_ json: String) throws -> ConditionNode {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ConditionNode.self, from: data)
    }

    // MARK: - Legacy array (pre-§22.4 wire) round-trip

    func testFlatArrayDecodesAsImplicitAnd() throws {
        let json = #"""
        [
          {"type": "alwaysTrue", "config": {}},
          {"type": "responseStatusIs", "config": {"status": "going"}}
        ]
        """#
        let node = try decode(json)
        guard case .and(let children) = node, children.count == 2 else {
            return XCTFail("expected .and with 2 leaf children, got \(node)")
        }
        XCTAssertEqual(node.flatLeaves?.count, 2, "single AND of leaves exposes flatLeaves")
        XCTAssertEqual(node.allLeaves.count, 2)
    }

    func testAndOfLeavesEncodesAsCompactArray() throws {
        // The compact form preserves pre-§22.4 jsonb on rule_versions.compiled.
        let node = ConditionNode.and([
            .leaf(Self.leafA),
            .leaf(Self.leafB),
        ])
        let any = try encode(node)
        XCTAssertTrue(any is [Any], "AND-of-leaves should serialise as JSON array, got \(type(of: any))")
        guard let arr = any as? [[String: Any]] else {
            return XCTFail("expected [[String: Any]] wire shape")
        }
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["type"] as? String, "alwaysTrue")
        XCTAssertEqual(arr[1]["type"] as? String, "responseStatusIs")
    }

    // MARK: - Tree round-trip

    func testTreeDecodesAndOrNotShapes() throws {
        // A AND (B OR NOT C)
        let json = #"""
        {
          "op": "and",
          "children": [
            {"type": "alwaysTrue", "config": {}},
            {
              "op": "or",
              "children": [
                {"type": "responseStatusIs", "config": {"status": "going"}},
                {
                  "op": "not",
                  "children": [
                    {"type": "checkInExists", "config": {"exists": false}}
                  ]
                }
              ]
            }
          ]
        }
        """#
        let node = try decode(json)
        guard case .and(let topChildren) = node, topChildren.count == 2 else {
            return XCTFail("expected top .and with 2 children, got \(node)")
        }
        // First child = leaf alwaysTrue
        if case .leaf(let l) = topChildren[0] {
            XCTAssertEqual(l.type, .alwaysTrue)
        } else {
            XCTFail("expected first child to be .leaf, got \(topChildren[0])")
        }
        // Second child = OR
        guard case .or(let orChildren) = topChildren[1], orChildren.count == 2 else {
            return XCTFail("expected .or with 2 children")
        }
        // Inside OR: leaf + NOT
        if case .leaf(let l) = orChildren[0] {
            XCTAssertEqual(l.type, .responseStatusIs)
        } else {
            XCTFail("expected OR[0] leaf")
        }
        guard case .not(let notChild) = orChildren[1] else {
            return XCTFail("expected OR[1] = NOT")
        }
        if case .leaf(let l) = notChild {
            XCTAssertEqual(l.type, .checkInExists)
        } else {
            XCTFail("expected NOT to wrap a leaf")
        }

        // `flatLeaves` returns nil for non-AND-only trees.
        XCTAssertNil(node.flatLeaves, "tree with OR/NOT must NOT expose flatLeaves")
        // `allLeaves` walks the whole tree.
        XCTAssertEqual(node.allLeaves.count, 3)
    }

    func testTreeRoundTripEncodeDecodePreservesStructure() throws {
        let tree: ConditionNode = .and([
            .leaf(Self.leafA),
            .or([
                .leaf(Self.leafB),
                .not(.leaf(Self.leafC)),
            ]),
        ])
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(ConditionNode.self, from: data)
        XCTAssertEqual(tree, decoded, "tree must round-trip through Codable")
    }

    func testFlatLeavesPreservedAcrossEncodeDecode() throws {
        // The legacy "list of conditions" use-case: callers wrap as
        // `ConditionNode(leaves:)`, encode it (compact wire), decode back,
        // and walk `flatLeaves` to recover the same list.
        let node = ConditionNode(leaves: [Self.leafA, Self.leafB, Self.leafC])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConditionNode.self, from: data)
        XCTAssertEqual(decoded.flatLeaves, [Self.leafA, Self.leafB, Self.leafC])
    }

    // MARK: - Convenience initialisers + helpers

    func testEmptyTreeIsAndWithNoChildren() {
        let n = ConditionNode.empty
        XCTAssertTrue(n.isEmpty)
        if case .and(let cs) = n {
            XCTAssertEqual(cs.count, 0)
        } else {
            XCTFail("expected .and([]) as empty")
        }
        // Vacuously true: empty AND in the engine evaluates to true.
        XCTAssertEqual(n.flatLeaves, [], "empty AND has zero leaves")
    }

    func testSingleLeafFlatLeavesReturnsOne() {
        let n = ConditionNode.leaf(Self.leafA)
        XCTAssertEqual(n.flatLeaves, [Self.leafA])
        XCTAssertEqual(n.allLeaves, [Self.leafA])
    }

    func testNotOfLeafHasNoFlatLeavesButOneAllLeaves() {
        let n = ConditionNode.not(.leaf(Self.leafB))
        XCTAssertNil(n.flatLeaves, "NOT must NOT collapse to a flat AND of leaves")
        XCTAssertEqual(n.allLeaves, [Self.leafB])
    }

    // MARK: - Error cases on decode

    func testDecodeUnknownOpThrows() {
        let json = #"{"op": "xor", "children": []}"#
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeNotWithMultipleChildrenPicksFirst() throws {
        // The server validator rejects this at publish time; the iOS
        // decoder is tolerant so stale payloads don't crash the read path.
        let json = #"""
        {"op": "not", "children": [
          {"type": "alwaysTrue", "config": {}},
          {"type": "responseStatusIs", "config": {"status": "going"}}
        ]}
        """#
        let node = try decode(json)
        if case .not(.leaf(let l)) = node {
            XCTAssertEqual(l.type, .alwaysTrue, "tolerant decoder picks first child")
        } else {
            XCTFail("expected .not(.leaf) tolerating extra children")
        }
    }

    // MARK: - GroupRule integration — tree decoded through the wire

    /// The §22.4 acceptance test mentioned in DoD: a `GroupRule` whose
    /// `conditions` JSON column is a tree must surface both the flat
    /// leaves view (back-compat for legacy consumers) AND the tree
    /// structure (preserved in `conditionsTree`).
    func testGroupRuleDecodesTreeIntoConditionsTreeAndFlatLeaves() throws {
        let groupId = UUID().uuidString
        let id      = UUID().uuidString
        let json = """
        {
          "id": "\(id)",
          "group_id": "\(groupId)",
          "slug": "test_tree_rule",
          "name": "Tree rule",
          "is_active": true,
          "trigger": {"eventType": "eventClosed", "config": {}},
          "conditions": {
            "op": "and",
            "children": [
              {"type": "alwaysTrue", "config": {}},
              {
                "op": "or",
                "children": [
                  {"type": "responseStatusIs", "config": {"status": "going"}},
                  {"type": "checkInExists",    "config": {"exists": false}}
                ]
              }
            ]
          },
          "consequences": [
            {"type": "fine", "config": {"amount": 50}}
          ],
          "exceptions": []
        }
        """
        let rule = try JSONDecoder().decode(GroupRule.self, from: Data(json.utf8))

        // Flat leaves view — every leaf surfaced for back-compat consumers.
        XCTAssertEqual(rule.conditions.count, 3)
        XCTAssertEqual(rule.conditions.map(\.type), [
            .alwaysTrue, .responseStatusIs, .checkInExists,
        ])

        // Tree preserved for §22.4-aware consumers.
        guard let tree = rule.conditionsTree else {
            return XCTFail("conditionsTree must be non-nil when wire shape is a tree")
        }
        guard case .and(let topChildren) = tree, topChildren.count == 2 else {
            return XCTFail("expected top .and with 2 children, got \(tree)")
        }
        guard case .or(let orChildren) = topChildren[1], orChildren.count == 2 else {
            return XCTFail("expected OR as second child of AND")
        }
        _ = orChildren  // structure verified
    }

    /// Pre-§22.4 rules (flat array on wire) leave `conditionsTree` nil
    /// because the flat-leaf view already carries the whole picture —
    /// the optional field stays clean for legacy reads.
    func testGroupRuleLeavesConditionsTreeNilWhenWireIsFlatArray() throws {
        let groupId = UUID().uuidString
        let id      = UUID().uuidString
        let json = """
        {
          "id": "\(id)",
          "group_id": "\(groupId)",
          "slug": "legacy_flat",
          "name": "Flat rule",
          "is_active": true,
          "trigger": {"eventType": "eventClosed", "config": {}},
          "conditions": [
            {"type": "responseStatusIs", "config": {"status": "going"}},
            {"type": "checkInExists",    "config": {"exists": false}}
          ],
          "consequences": [
            {"type": "fine", "config": {"amount": 100}}
          ],
          "exceptions": []
        }
        """
        let rule = try JSONDecoder().decode(GroupRule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.conditions.count, 2)
        XCTAssertNil(rule.conditionsTree,
                     "flat array wire → conditionsTree stays nil (back-compat)")
    }
}
