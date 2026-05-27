import Foundation
import Testing
@testable import RuulCore

/// Per doctrine §14: the mapper IS the iOS contract for backend errors.
/// Every canonical raise text the dev RPCs emit must round-trip to a
/// recognised `CanonicalBackendError` case — anything else regresses to
/// `.unknown(message:)`, which the test suite flags so we notice when a
/// migration changes the raise wording.
@Suite("RPCErrorMapper")
struct RPCErrorMapperTests {

    @Test("must be authenticated")
    func auth() {
        #expect(RPCErrorMapper.parse("must be authenticated") == .mustBeAuthenticated)
    }

    @Test("caller is not an active member of group <uuid>")
    func notActiveMember() {
        let id = UUID()
        let parsed = RPCErrorMapper.parse("caller is not an active member of group \(id.uuidString.lowercased())")
        if case .callerNotActiveMember(let groupId) = parsed {
            #expect(groupId == id)
        } else {
            Issue.record("expected .callerNotActiveMember, got \(parsed)")
        }
    }

    @Test("caller lacks permission <key> in group <uuid>")
    func lacksPermission() {
        let id = UUID()
        let parsed = RPCErrorMapper.parse("caller lacks permission money.expense.create in group \(id.uuidString.lowercased())")
        if case .lacksPermission(let key, let groupId) = parsed {
            #expect(key == "money.expense.create")
            #expect(groupId == id)
        } else {
            Issue.record("expected .lacksPermission, got \(parsed)")
        }
    }

    @Test("amount must be positive")
    func amountPositive() {
        #expect(RPCErrorMapper.parse("amount must be positive") == .amountMustBePositive)
    }

    @Test("amount required")
    func amountRequired() {
        #expect(RPCErrorMapper.parse("amount required") == .amountRequired)
    }

    @Test("custom split sum does not match amount")
    func splitMismatch() {
        let parsed = RPCErrorMapper.parse("custom split sum 90 does not match amount 100")
        if case .customSplitMismatch(let sum, let expected) = parsed {
            #expect(sum == 90)
            #expect(expected == 100)
        } else {
            Issue.record("expected .customSplitMismatch, got \(parsed)")
        }
    }

    @Test("invalid paid_to_kind")
    func paidToKind() {
        #expect(RPCErrorMapper.parse("invalid paid_to_kind") == .invalidPaidToKind)
    }

    @Test("resource <uuid> not in group <uuid>")
    func resourceNotInGroup() {
        let r = UUID(); let g = UUID()
        let parsed = RPCErrorMapper.parse("resource \(r.uuidString.lowercased()) not in group \(g.uuidString.lowercased())")
        if case .resourceNotInGroup(let rid, let gid) = parsed {
            #expect(rid == r)
            #expect(gid == g)
        } else {
            Issue.record("expected .resourceNotInGroup, got \(parsed)")
        }
    }

    @Test("cross-tenant violation")
    func crossTenant() {
        #expect(RPCErrorMapper.parse("cross-tenant violation") == .crossTenantViolation)
    }

    @Test("invite raises")
    func inviteRaises() {
        #expect(RPCErrorMapper.parse("invite requires email or phone") == .inviteRequiresEmailOrPhone)
        #expect(RPCErrorMapper.parse("invite not found or already used") == .inviteNotFoundOrUsed)
        #expect(RPCErrorMapper.parse("invite expired") == .inviteExpired)
        #expect(RPCErrorMapper.parse("invite token mismatch") == .inviteTokenMismatch)
    }

    @Test("mandate does not authorize this action: <reason>")
    func mandateDeny() {
        let parsed = RPCErrorMapper.parse("mandate does not authorize this action: scope=money only")
        if case .mandateDoesNotAuthorize(let reason) = parsed {
            #expect(reason == "scope=money only")
        } else {
            Issue.record("expected .mandateDoesNotAuthorize, got \(parsed)")
        }
    }

    @Test("rule evaluation depth exceeds max")
    func ruleDepth() {
        let id = UUID()
        let parsed = RPCErrorMapper.parse("rule evaluation depth for event \(id.uuidString.lowercased()) exceeds max")
        if case .ruleEvaluationDepthExceeded(let eventId, let max) = parsed {
            #expect(eventId == id)
            #expect(max == 5)
        } else {
            Issue.record("expected .ruleEvaluationDepthExceeded, got \(parsed)")
        }
    }

    @Test("profile raises")
    func profileRaises() {
        #expect(RPCErrorMapper.parse("display_name required") == .displayNameRequired)
        #expect(RPCErrorMapper.parse("username already taken") == .usernameAlreadyTaken)
    }

    @Test("purpose raises")
    func purposeRaises() {
        #expect(RPCErrorMapper.parse("invalid purpose kind") == .invalidPurposeKind)
        #expect(RPCErrorMapper.parse("invalid purpose visibility") == .invalidPurposeVisibility)
        #expect(RPCErrorMapper.parse("purpose body required") == .purposeBodyRequired)
    }

    @Test("rules raises")
    func rulesRaises() {
        #expect(RPCErrorMapper.parse("rule title required") == .ruleTitleRequired)
        #expect(RPCErrorMapper.parse("rule body required") == .ruleBodyRequired)
        #expect(RPCErrorMapper.parse("invalid rule type") == .invalidRuleType)
        #expect(RPCErrorMapper.parse("invalid rule severity") == .invalidRuleSeverity)
        #expect(RPCErrorMapper.parse("rule not found") == .ruleNotFound)
    }

    @Test("resources raises")
    func resourcesRaises() {
        #expect(RPCErrorMapper.parse("invalid resource type") == .invalidResourceType)
        #expect(RPCErrorMapper.parse("resource name required") == .resourceNameRequired)
        #expect(RPCErrorMapper.parse("invalid resource visibility") == .invalidResourceVisibility)
        #expect(RPCErrorMapper.parse("invalid ownership kind") == .invalidOwnershipKind)
        #expect(RPCErrorMapper.parse("resource not found") == .resourceNotFound)
        let parsed = RPCErrorMapper.parse("owner membership not in group \(UUID().uuidString.lowercased())")
        if case .ownerMembershipNotInGroup = parsed {} else { Issue.record("expected ownerMembershipNotInGroup") }
        let parsed2 = RPCErrorMapper.parse("custodian membership not in group \(UUID().uuidString.lowercased())")
        if case .custodianMembershipNotInGroup = parsed2 {} else { Issue.record("expected custodianMembershipNotInGroup") }
    }

    @Test("sanctions raises")
    func sanctionsRaises() {
        #expect(RPCErrorMapper.parse("monetary sanction requires positive amount + unit") == .monetarySanctionRequiresAmountUnit)
    }

    @Test("decision rules raises")
    func decisionRulesRaises() {
        #expect(RPCErrorMapper.parse("invalid decision style") == .invalidDecisionStyle)
        #expect(RPCErrorMapper.parse("quorum_min must be >= 1") == .quorumMinTooSmall)
    }

    @Test("unknown raises fall through to .unknown(message:)")
    func unknownRaise() {
        let raw = "Database connection lost"
        if case .unknown(let message) = RPCErrorMapper.parse(raw) {
            #expect(message == raw)
        } else {
            Issue.record("expected .unknown, got \(RPCErrorMapper.parse(raw))")
        }
    }
}
