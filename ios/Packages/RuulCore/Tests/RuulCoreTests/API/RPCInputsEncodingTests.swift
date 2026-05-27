import Foundation
import Testing
@testable import RuulCore

/// Per doctrine §14: the params structs are the wire contract. Tests
/// here encode each Params struct and assert the JSON contains exactly
/// the `p_*` keys the dev RPCs expect, with values intact.
///
/// We round-trip the encoded data through `JSONSerialization` so the
/// assertions are order-independent (JSONEncoder does not guarantee key
/// ordering by default).
@Suite("RPCInputs encoding")
struct RPCInputsEncodingTests {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    // MARK: - create_group

    @Test("create_group encodes all p_* keys including optionals as null")
    func createGroupEncoding() throws {
        let params = RPCCreateGroupParams(name: "Casa", slug: "casa", category: "dinner", purposeDeclared: "cenar")
        let dict = try encode(params)
        #expect(dict.keys.sorted() == ["p_category", "p_name", "p_purpose_declared", "p_slug"])
        #expect(dict["p_name"] as? String == "Casa")
        #expect(dict["p_slug"] as? String == "casa")
        #expect(dict["p_category"] as? String == "dinner")
        #expect(dict["p_purpose_declared"] as? String == "cenar")
    }

    @Test("create_group encodes nil optionals as JSON null")
    func createGroupNilEncoding() throws {
        let params = RPCCreateGroupParams(name: "Casa")
        let dict = try encode(params)
        #expect(dict["p_name"] as? String == "Casa")
        // Optionals encoded by Swift's default behaviour: nil keys are omitted
        // entirely. PostgreSQL treats missing args as DEFAULTs at the RPC
        // boundary, which matches the contract for the trio of optional
        // create_group params.
        #expect(dict["p_slug"] == nil)
        #expect(dict["p_category"] == nil)
        #expect(dict["p_purpose_declared"] == nil)
    }

    // MARK: - invite_member / accept_invite / leave_group

    @Test("invite_member encodes membership_type default 'member'")
    func inviteMemberDefaults() throws {
        let groupId = UUID()
        let params = InviteMemberParams(groupId: groupId, email: "a@b.co")
        let dict = try encode(params)
        #expect(dict["p_group_id"] as? String == groupId.uuidString)
        #expect(dict["p_email"] as? String == "a@b.co")
        #expect(dict["p_membership_type"] as? String == "member")
        #expect(dict["p_phone"] == nil)
        #expect(dict["p_message"] == nil)
    }

    @Test("accept_invite encodes only p_code")
    func acceptInviteEncoding() throws {
        let params = AcceptInviteParams(code: "ABC-123")
        let dict = try encode(params)
        #expect(dict.keys.sorted() == ["p_code"])
        #expect(dict["p_code"] as? String == "ABC-123")
    }

    @Test("leave_group encodes group id + optional reason")
    func leaveGroupEncoding() throws {
        let id = UUID()
        let dict = try encode(LeaveGroupParams(groupId: id, reason: "moving out"))
        #expect(dict["p_group_id"] as? String == id.uuidString)
        #expect(dict["p_reason"] as? String == "moving out")
    }

    // MARK: - record_expense

    @Test("record_expense even split encodes nil resource as null and omits split_breakdown")
    func recordExpenseEvenSplit() throws {
        let groupId = UUID()
        let paidBy = UUID()
        let draft = ExpenseDraft(
            groupId: groupId,
            resourceId: nil,
            amount: 300,
            paidByMembershipId: paidBy,
            description: "groceries",
            split: .even
        )
        let params = RecordExpenseParams(draft: draft, clientId: "client-1")
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        #expect(dict["p_group_id"] as? String == groupId.uuidString)
        #expect(dict["p_paid_by_membership_id"] as? String == paidBy.uuidString)
        #expect(dict["p_amount"] as? NSNumber == NSNumber(value: 300))
        #expect(dict["p_unit"] as? String == "MXN")
        #expect(dict["p_description"] as? String == "groceries")
        #expect(dict["p_split_mode"] as? String == "even")
        #expect(dict["p_in_kind"] as? Bool == false)
        #expect(dict["p_client_id"] as? String == "client-1")

        // p_mandate_id must always serialise to null in Foundation scope so the
        // RPC classifies the row as self_party (per condition §16-bis #1).
        let hasMandateKey = dict.keys.contains("p_mandate_id")
        if hasMandateKey {
            #expect(dict["p_mandate_id"] is NSNull)
        }

        // p_resource_id must be present as null when nil (doctrine_shared_money).
        let hasResourceKey = dict.keys.contains("p_resource_id")
        if hasResourceKey {
            #expect(dict["p_resource_id"] is NSNull)
        }

        // even split should not send a breakdown
        if dict.keys.contains("p_split_breakdown") {
            #expect(dict["p_split_breakdown"] is NSNull)
        }
    }

    @Test("record_expense custom split encodes membership_id + amount per share")
    func recordExpenseCustomSplit() throws {
        let groupId = UUID()
        let paidBy = UUID()
        let a = UUID()
        let b = UUID()
        let draft = ExpenseDraft(
            groupId: groupId,
            amount: 100,
            paidByMembershipId: paidBy,
            split: .custom(breakdown: [
                .init(membershipId: a, amount: 60),
                .init(membershipId: b, amount: 40)
            ])
        )
        let params = RecordExpenseParams(draft: draft, clientId: nil)
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        #expect(dict["p_split_mode"] as? String == "custom")
        let shares = dict["p_split_breakdown"] as? [[String: Any]]
        #expect(shares?.count == 2)
        let aShare = shares?.first(where: { ($0["membership_id"] as? String) == a.uuidString })
        let bShare = shares?.first(where: { ($0["membership_id"] as? String) == b.uuidString })
        #expect(aShare?["amount"] as? NSNumber == NSNumber(value: 60))
        #expect(bShare?["amount"] as? NSNumber == NSNumber(value: 40))
    }

    @Test("record_expense omits p_client_id when nil")
    func recordExpenseNoClientId() throws {
        let draft = ExpenseDraft(
            groupId: UUID(),
            amount: 50,
            paidByMembershipId: UUID()
        )
        let params = RecordExpenseParams(draft: draft, clientId: nil)
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if dict.keys.contains("p_client_id") {
            #expect(dict["p_client_id"] is NSNull)
        }
    }

    @Test("record_expense preserves the same p_client_id across re-encode (idempotency contract)")
    func recordExpenseClientIdStable() throws {
        let draft = ExpenseDraft(
            groupId: UUID(),
            amount: 50,
            paidByMembershipId: UUID()
        )
        let clientId = "submit-42"
        let firstParams = RecordExpenseParams(draft: draft, clientId: clientId)
        let secondParams = RecordExpenseParams(draft: draft, clientId: clientId)

        func clientIdString(_ p: RecordExpenseParams) throws -> String? {
            let data = try JSONEncoder().encode(p)
            let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return dict["p_client_id"] as? String
        }
        #expect(try clientIdString(firstParams) == clientId)
        #expect(try clientIdString(secondParams) == clientId)
    }

    // MARK: - record_settlement

    @Test("record_settlement to pool encodes paid_to_kind=pool and paid_to_id=null")
    func recordSettlementToPool() throws {
        let draft = SettlementDraft(
            groupId: UUID(),
            paidByMembershipId: UUID(),
            target: .pool,
            amount: 200
        )
        let params = RecordSettlementParams(draft: draft, clientId: nil)
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(dict["p_paid_to_kind"] as? String == "pool")
        if dict.keys.contains("p_paid_to_membership_id") {
            #expect(dict["p_paid_to_membership_id"] is NSNull)
        }
        #expect(dict["p_amount"] as? NSNumber == NSNumber(value: 200))
    }

    @Test("record_settlement to member encodes paid_to_kind=member and the recipient id")
    func recordSettlementToMember() throws {
        let recipient = UUID()
        let draft = SettlementDraft(
            groupId: UUID(),
            paidByMembershipId: UUID(),
            target: .member(membershipId: recipient),
            amount: 75
        )
        let params = RecordSettlementParams(draft: draft, clientId: "submit-99")
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        #expect(dict["p_paid_to_kind"] as? String == "member")
        #expect(dict["p_paid_to_membership_id"] as? String == recipient.uuidString)
        #expect(dict["p_client_id"] as? String == "submit-99")
    }

    // MARK: - Reads

    @Test("group_summary encodes p_group_id only")
    func groupSummaryEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupSummaryParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    @Test("member_balance encodes both ids")
    func memberBalanceEncoding() throws {
        let g = UUID(); let m = UUID()
        let dict = try encode(MemberBalanceParams(groupId: g, membershipId: m))
        #expect(dict["p_group_id"] as? String == g.uuidString)
        #expect(dict["p_membership_id"] as? String == m.uuidString)
    }

    @Test("list_member_permissions accepts nil user id")
    func listPermissionsEncoding() throws {
        let g = UUID()
        let dict = try encode(ListMemberPermissionsParams(groupId: g, userId: nil))
        #expect(dict["p_group_id"] as? String == g.uuidString)
        if dict.keys.contains("p_user_id") {
            #expect(dict["p_user_id"] is NSNull)
        }
    }

    // MARK: - update_my_profile

    @Test("update_my_profile encodes snake_case keys")
    func updateMyProfileSnakeCase() throws {
        let input = UpdateMyProfileInput(
            pDisplayName: "Jose Mizrahi",
            pUsername: "jose_m",
            pAvatarUrl: "https://example.com/a.png",
            pBio: "Founder"
        )
        let dict = try encode(input)
        #expect(dict["p_display_name"] as? String == "Jose Mizrahi")
        #expect(dict["p_username"] as? String == "jose_m")
        #expect(dict["p_avatar_url"] as? String == "https://example.com/a.png")
        #expect(dict["p_bio"] as? String == "Founder")
    }

    @Test("update_my_profile keeps display_name only when optionals are nil")
    func updateMyProfileNilOptionals() throws {
        let input = UpdateMyProfileInput(pDisplayName: "Jose")
        let dict = try encode(input)
        #expect(dict["p_display_name"] as? String == "Jose")
        #expect(dict["p_username"] == nil)
        #expect(dict["p_avatar_url"] == nil)
        #expect(dict["p_bio"] == nil)
    }

    // MARK: - group_members

    @Test("group_members encodes p_group_id only")
    func groupMembersEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupMembersParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    @Test("group_membership_boundary encodes p_group_id only")
    func groupMembershipBoundaryEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupMembershipBoundaryParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    // MARK: - purpose

    @Test("group_purposes_active encodes p_group_id only")
    func groupPurposesActiveEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupPurposesActiveParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    @Test("set_group_purpose encodes all p_* keys")
    func setGroupPurposeEncoding() throws {
        let id = UUID()
        let input = SetGroupPurposeInput(
            pGroupId: id, pKind: "declared", pBody: "Jugar poker", pVisibility: "members"
        )
        let dict = try encode(input)
        #expect(dict.keys.sorted() == ["p_body", "p_group_id", "p_kind", "p_visibility"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
        #expect(dict["p_kind"] as? String == "declared")
        #expect(dict["p_body"] as? String == "Jugar poker")
        #expect(dict["p_visibility"] as? String == "members")
    }

    // MARK: - rules

    @Test("group_rules_active encodes p_group_id only")
    func groupRulesActiveEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupRulesActiveParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    @Test("create_text_rule encodes all p_* keys")
    func createTextRuleEncoding() throws {
        let id = UUID()
        let input = CreateTextRuleInput(
            pGroupId: id, pTitle: "Sin cel", pBody: "Apaga", pRuleType: "prohibition", pSeverity: 3
        )
        let dict = try encode(input)
        #expect(dict.keys.sorted() == ["p_body", "p_group_id", "p_rule_type", "p_severity", "p_title"])
        #expect(dict["p_severity"] as? NSNumber == NSNumber(value: 3))
    }

    @Test("archive_rule encodes p_rule_id always; reason as null when nil")
    func archiveRuleEncoding() throws {
        let id = UUID()
        let dict = try encode(ArchiveRuleInput(pRuleId: id, pReason: nil))
        #expect(dict["p_rule_id"] as? String == id.uuidString)
        _ = dict["p_reason"]

        let withReason = try encode(ArchiveRuleInput(pRuleId: id, pReason: "moving"))
        #expect(withReason["p_reason"] as? String == "moving")
    }

    // MARK: - resources

    @Test("group_resources_active encodes p_group_id only")
    func groupResourcesActiveEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupResourcesActiveParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
    }

    @Test("create_group_resource encodes all p_* keys")
    func createGroupResourceEncoding() throws {
        let gid = UUID()
        let input = CreateGroupResourceInput(
            pGroupId: gid,
            pResourceType: "fund",
            pName: "Fondo",
            pDescription: "Bote",
            pVisibility: "members",
            pOwnershipKind: "group",
            pOwnerMembershipId: nil,
            pCustodianMembershipId: nil
        )
        let dict = try encode(input)
        #expect(dict["p_group_id"] as? String == gid.uuidString)
        #expect(dict["p_resource_type"] as? String == "fund")
        #expect(dict["p_name"] as? String == "Fondo")
        #expect(dict["p_description"] as? String == "Bote")
        #expect(dict["p_visibility"] as? String == "members")
        #expect(dict["p_ownership_kind"] as? String == "group")
    }

    @Test("archive_group_resource encodes p_resource_id")
    func archiveGroupResourceEncoding() throws {
        let id = UUID()
        let dict = try encode(ArchiveGroupResourceInput(pResourceId: id, pReason: "moved"))
        #expect(dict["p_resource_id"] as? String == id.uuidString)
        #expect(dict["p_reason"] as? String == "moved")
    }

    @Test("group_foundation_status encodes p_group_id only")
    func groupFoundationStatusEncoding() throws {
        let id = UUID()
        let dict = try encode(GroupFoundationStatusParams(groupId: id))
        #expect(dict.keys.sorted() == ["p_group_id"])
        #expect(dict["p_group_id"] as? String == id.uuidString)
    }

    // MARK: - member_reputation_events (Primitiva 12)

    @Test("member_reputation_events emits p_group_id, p_subject_membership_id, p_limit")
    func memberReputationEventsEncoding() throws {
        let gid = UUID(); let mid = UUID()
        let dict = try encode(MemberReputationEventsParams(groupId: gid, subjectMembershipId: mid, limit: 25))
        #expect(dict.keys.sorted() == ["p_group_id", "p_limit", "p_subject_membership_id"])
        #expect(dict["p_group_id"] as? String == gid.uuidString)
        #expect(dict["p_subject_membership_id"] as? String == mid.uuidString)
        #expect((dict["p_limit"] as? Int) == 25)
    }

    // MARK: - issue_sanction (Primitiva 11)

    @Test("issue_sanction emits all p_* keys, optionals as explicit JSON null")
    func issueSanctionMonetaryEncoding() throws {
        let gid = UUID(); let mid = UUID()
        let input = IssueSanctionInput(
            pGroupId: gid,
            pTargetMembershipId: mid,
            pSanctionKind: "monetary",
            pReason: "Faltó al fondo",
            pAmount: 250,
            pUnit: "MXN",
            pClientId: "abc"
        )
        let dict = try encode(input)
        #expect(dict["p_group_id"] as? String == gid.uuidString)
        #expect(dict["p_target_membership_id"] as? String == mid.uuidString)
        #expect(dict["p_sanction_kind"] as? String == "monetary")
        #expect(dict["p_reason"] as? String == "Faltó al fondo")
        #expect(dict["p_unit"] as? String == "MXN")
        #expect(dict["p_client_id"] as? String == "abc")
        // Optionals not set should still be present as JSON null.
        #expect(dict.keys.contains("p_ends_at"))
        #expect(dict.keys.contains("p_rule_version_id"))
        #expect(dict.keys.contains("p_source_event_id"))
        #expect(dict["p_ends_at"] is NSNull)
        #expect(dict["p_rule_version_id"] is NSNull)
    }

    @Test("issue_sanction with nil amount emits null amount key explicitly")
    func issueSanctionWarningEncoding() throws {
        let input = IssueSanctionInput(
            pGroupId: UUID(),
            pTargetMembershipId: UUID(),
            pSanctionKind: "warning",
            pReason: "Llegó tarde"
        )
        let dict = try encode(input)
        #expect(dict["p_sanction_kind"] as? String == "warning")
        #expect(dict["p_amount"] is NSNull)
        #expect(dict["p_unit"] is NSNull)
    }
}
