import Foundation
import Supabase

/// Implementación live de `RuulRPCClient` contra el backend MVP 2.0.
/// Escrituras vía `client.rpc(...)`; lecturas de lista vía RPC cuando existe
/// o `client.from(...)` (PostgREST read-only por RLS). Todo error pasa por
/// `RPCErrorMapper`.
public struct SupabaseRuulRPCClient: RuulRPCClient {
    private let client: SupabaseClient

    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Helpers

    private func call<Result: Decodable>(_ fn: String, params: some Encodable & Sendable) async throws -> Result {
        do {
            return try await client.rpc(fn, params: params).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func call<Result: Decodable>(_ fn: String) async throws -> Result {
        do {
            return try await client.rpc(fn).execute().value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    private func callVoid(_ fn: String, params: some Encodable & Sendable) async throws {
        do {
            _ = try await client.rpc(fn, params: params).execute()
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - Identity

    public func ensurePersonActor() async throws -> CurrentActor {
        try await call("ensure_person_actor")
    }

    public func updateMyProfile(fullName: String?, preferredName: String?, avatarUrl: String?) async throws -> CurrentActor {
        struct Params: Encodable, Sendable {
            let pFullName: String?
            let pPreferredName: String?
            let pAvatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case pFullName = "p_full_name"
                case pPreferredName = "p_preferred_name"
                case pAvatarUrl = "p_avatar_url"
            }
        }
        return try await call("update_my_profile", params: Params(
            pFullName: fullName, pPreferredName: preferredName, pAvatarUrl: avatarUrl
        ))
    }

    public func updateMyProfileMetadata(_ metadata: JSONValue) async throws -> CurrentActor {
        struct Params: Encodable, Sendable {
            let pMetadata: JSONValue
            enum CodingKeys: String, CodingKey { case pMetadata = "p_metadata" }
        }
        return try await call("update_my_profile", params: Params(pMetadata: metadata))
    }

    public func personalSettingsSummary() async throws -> PersonalSettings {
        try await call("personal_settings_summary")
    }

    public func contextSettingsSummary(contextId: UUID) async throws -> ContextSettings {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pContextActorId = "p_context_actor_id" }
        }
        return try await call("context_settings_summary", params: Params(pContextActorId: contextId))
    }

    public func updateContext(_ input: UpdateContextInput) async throws -> ContextSettings {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDisplayName: String?
            let pDescription: String?
            let pVisibility: String?
            let pImageUrl: String?
            let pDecisionsConfig: JSONValue?
            let pMoneyConfig: JSONValue?
            let pReservationsConfig: JSONValue?
            let pInvitationsConfig: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pVisibility = "p_visibility"
                case pImageUrl = "p_image_url"
                case pDecisionsConfig = "p_decisions_config"
                case pMoneyConfig = "p_money_config"
                case pReservationsConfig = "p_reservations_config"
                case pInvitationsConfig = "p_invitations_config"
            }
        }
        return try await call("update_context", params: Params(
            pContextActorId: input.contextId,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pVisibility: input.visibility,
            pImageUrl: input.imageUrl,
            pDecisionsConfig: input.decisionsConfig,
            pMoneyConfig: input.moneyConfig,
            pReservationsConfig: input.reservationsConfig,
            pInvitationsConfig: input.invitationsConfig
        ))
    }

    public func resourceSettingsSummary(resourceId: UUID) async throws -> ResourceSettings {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_settings_summary", params: Params(pResourceId: resourceId))
    }

    // MARK: - Actor capabilities (R.2S.1)

    public func actorCapabilities(actorId: UUID) async throws -> ActorCapabilities {
        struct Params: Encodable, Sendable {
            let pActorId: UUID
            enum CodingKeys: String, CodingKey { case pActorId = "p_actor_id" }
        }
        return try await call("actor_capabilities", params: Params(pActorId: actorId))
    }

    public func actorCapabilitiesCatalog() async throws -> ActorCapabilitiesCatalog {
        try await call("actor_capabilities_catalog")
    }

    public func actorCan(actorId: UUID, capability: String) async throws -> Bool {
        struct Params: Encodable, Sendable {
            let pActorId: UUID
            let pCapability: String
            enum CodingKeys: String, CodingKey {
                case pActorId = "p_actor_id"
                case pCapability = "p_capability"
            }
        }
        return try await call("actor_can", params: Params(pActorId: actorId, pCapability: capability))
    }

    // MARK: - Contexts

    public func contextCandidates() async throws -> ContextCandidates {
        try await call("context_candidates")
    }

    public func contextSummary(contextId: UUID) async throws -> ContextSummary {
        try await call("context_summary", params: ContextIdParams(contextId: contextId))
    }

    public func contextDetailDescriptor(contextId: UUID) async throws -> ContextDetailDescriptor {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pContextActorId = "p_context_actor_id" }
        }
        return try await call("context_detail_descriptor", params: Params(pContextActorId: contextId))
    }

    public func myWorld() async throws -> MyWorld {
        try await call("my_world")
    }

    public func createContext(_ input: CreateContextInput) async throws -> CreatedContext {
        struct Params: Encodable, Sendable {
            let pDisplayName: String
            let pActorKind: String
            let pActorSubtype: String
            let pVisibility: String
            enum CodingKeys: String, CodingKey {
                case pDisplayName = "p_display_name"
                case pActorKind = "p_actor_kind"
                case pActorSubtype = "p_actor_subtype"
                case pVisibility = "p_visibility"
            }
        }
        return try await call("create_context", params: Params(
            pDisplayName: input.displayName,
            pActorKind: input.actorKind.rawValue,
            pActorSubtype: input.actorSubtype,
            pVisibility: input.visibility
        ))
    }

    // MARK: - Context hierarchy (R.2U)

    public func contextChildren(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try await call("context_children", params: ContextIdParams(contextId: contextId))
    }

    public func contextParents(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try await call("context_parents", params: ContextIdParams(contextId: contextId))
    }

    public func contextTree(rootContextId: UUID) async throws -> ContextTreeNode {
        struct Params: Encodable, Sendable {
            let pRootContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pRootContextActorId = "p_root_context_actor_id" }
        }
        return try await call("context_tree", params: Params(pRootContextActorId: rootContextId))
    }

    public func contextAncestors(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try await call("context_ancestors", params: ContextIdParams(contextId: contextId))
    }

    public func contextDescendants(contextId: UUID) async throws -> [ContextHierarchyNode] {
        try await call("context_descendants", params: ContextIdParams(contextId: contextId))
    }

    public func createChildContext(_ input: CreateChildContextInput) async throws -> CreatedChildContext {
        struct Params: Encodable, Sendable {
            let pParentContextActorId: UUID
            let pDisplayName: String
            let pActorKind: String
            let pActorSubtype: String
            let pVisibility: String
            enum CodingKeys: String, CodingKey {
                case pParentContextActorId = "p_parent_context_actor_id"
                case pDisplayName = "p_display_name"
                case pActorKind = "p_actor_kind"
                case pActorSubtype = "p_actor_subtype"
                case pVisibility = "p_visibility"
            }
        }
        return try await call("create_child_context", params: Params(
            pParentContextActorId: input.parentContextActorId,
            pDisplayName: input.displayName,
            pActorKind: input.actorKind.rawValue,
            pActorSubtype: input.actorSubtype,
            pVisibility: input.visibility
        ))
    }

    public func linkChildContext(parentId: UUID, childId: UUID) async throws -> LinkChildContextResult {
        struct Params: Encodable, Sendable {
            let pParentContextActorId: UUID
            let pChildContextActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pParentContextActorId = "p_parent_context_actor_id"
                case pChildContextActorId = "p_child_context_actor_id"
            }
        }
        return try await call("link_child_context", params: Params(
            pParentContextActorId: parentId,
            pChildContextActorId: childId
        ))
    }

    public func unlinkChildContext(parentId: UUID, childId: UUID) async throws -> UnlinkChildContextResult {
        struct Params: Encodable, Sendable {
            let pParentContextActorId: UUID
            let pChildContextActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pParentContextActorId = "p_parent_context_actor_id"
                case pChildContextActorId = "p_child_context_actor_id"
            }
        }
        return try await call("unlink_child_context", params: Params(
            pParentContextActorId: parentId,
            pChildContextActorId: childId
        ))
    }

    // MARK: - Invites & membership

    public func createInvite(contextId: UUID, maxUses: Int?, expiresAt: Date?) async throws -> InviteCreated {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMaxUses: Int?
            let pExpiresAt: Date?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMaxUses = "p_max_uses"
                case pExpiresAt = "p_expires_at"
            }
        }
        return try await call("create_invite", params: Params(
            pContextActorId: contextId, pMaxUses: maxUses, pExpiresAt: expiresAt
        ))
    }

    public func revokeInvite(inviteId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pInviteId: UUID
            enum CodingKeys: String, CodingKey { case pInviteId = "p_invite_id" }
        }
        try await callVoid("revoke_invite", params: Params(pInviteId: inviteId))
    }

    public func joinByInviteCode(_ code: String) async throws -> JoinResult {
        struct Params: Encodable, Sendable {
            let pCode: String
            enum CodingKeys: String, CodingKey { case pCode = "p_code" }
        }
        return try await call("join_by_invite_code", params: Params(pCode: code))
    }

    public func inviteMember(contextId: UUID, memberActorId: UUID, membershipType: String) async throws -> InviteMemberResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pMembershipType: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pMembershipType = "p_membership_type"
            }
        }
        return try await call("invite_member", params: Params(
            pContextActorId: contextId,
            pMemberActorId: memberActorId,
            pMembershipType: membershipType
        ))
    }

    public func createPlaceholderPerson(
        contextId: UUID,
        displayName: String,
        phone: String?,
        email: String?,
        membershipType: String
    ) async throws -> PlaceholderPersonResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDisplayName: String
            let pPhone: String?
            let pEmail: String?
            let pMembershipType: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDisplayName = "p_display_name"
                case pPhone = "p_phone"
                case pEmail = "p_email"
                case pMembershipType = "p_membership_type"
            }
        }
        return try await call("create_placeholder_person", params: Params(
            pContextActorId: contextId,
            pDisplayName: displayName,
            pPhone: phone,
            pEmail: email,
            pMembershipType: membershipType
        ))
    }

    public func findPlaceholderMatchesForMe() async throws -> PlaceholderMatchesResult {
        struct Empty: Encodable, Sendable {}
        return try await call("find_placeholder_matches_for_me", params: Empty())
    }

    public func claimPlaceholderActor(placeholderActorId: UUID) async throws -> ClaimPlaceholderResult {
        struct Params: Encodable, Sendable {
            let pPlaceholderActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pPlaceholderActorId = "p_placeholder_actor_id"
            }
        }
        return try await call("claim_placeholder_actor", params: Params(
            pPlaceholderActorId: placeholderActorId
        ))
    }

    public func acceptInvitation(contextId: UUID) async throws -> AcceptInvitationResult {
        try await call("accept_invitation", params: ContextIdParams(contextId: contextId))
    }

    public func listMyPendingInvitations(actorId: UUID) async throws -> [PendingInvitation] {
        do {
            // `actor_memberships` tiene 3 FKs a `actors` (context/member/invited_by),
            // PostgREST requiere el nombre del constraint para desambigüar.
            return try await client
                .from("actor_memberships")
                .select("id,context_actor_id,created_at,context:actors!actor_memberships_context_actor_id_fkey(display_name,actor_kind,actor_subtype)")
                .eq("member_actor_id", value: actorId.uuidString)
                .eq("membership_status", value: "invited")
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func removeMember(contextId: UUID, memberActorId: UUID, reason: String?) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pReason = "p_reason"
            }
        }
        try await callVoid("remove_member", params: Params(
            pContextActorId: contextId, pMemberActorId: memberActorId, pReason: reason
        ))
    }

    public func leaveContext(contextId: UUID) async throws {
        try await callVoid("leave_context", params: ContextIdParams(contextId: contextId))
    }

    public func assignRole(contextId: UUID, memberActorId: UUID, roleKey: String) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pRoleKey: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pRoleKey = "p_role_key"
            }
        }
        try await callVoid("assign_role", params: Params(
            pContextActorId: contextId, pMemberActorId: memberActorId, pRoleKey: roleKey
        ))
    }

    // MARK: - Documents

    public func registerDocument(_ input: RegisterDocumentInput) async throws -> DocumentRegistered {
        struct Params: Encodable, Sendable {
            let pTitle: String
            let pContextActorId: UUID?
            let pDocumentType: String
            let pStoragePath: String?
            let pMimeType: String?
            let pFileSizeBytes: Int64?
            let pResourceId: UUID?
            let pEventId: UUID?
            let pMetadata: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pTitle = "p_title"
                case pContextActorId = "p_context_actor_id"
                case pDocumentType = "p_document_type"
                case pStoragePath = "p_storage_path"
                case pMimeType = "p_mime_type"
                case pFileSizeBytes = "p_file_size_bytes"
                case pResourceId = "p_resource_id"
                case pEventId = "p_event_id"
                case pMetadata = "p_metadata"
            }
        }
        return try await call("register_document", params: Params(
            pTitle: input.title,
            pContextActorId: input.contextActorId,
            pDocumentType: input.documentType.rawValue,
            pStoragePath: input.storagePath,
            pMimeType: input.mimeType,
            pFileSizeBytes: input.fileSizeBytes,
            pResourceId: input.resourceId,
            pEventId: input.eventId,
            pMetadata: input.metadata
        ))
    }

    public func listResourceDocuments(resourceId: UUID) async throws -> [Document] {
        do {
            return try await client
                .from("documents")
                .select()
                .eq("resource_id", value: resourceId.uuidString)
                .is("archived_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listContextDocuments(contextId: UUID, includeArchived: Bool) async throws -> [Document] {
        struct Params: Encodable {
            let pContextActorId: UUID
            let pIncludeArchived: Bool
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pIncludeArchived = "p_include_archived"
            }
        }
        return try await call("list_context_documents", params: Params(
            pContextActorId: contextId,
            pIncludeArchived: includeArchived
        ))
    }

    public func archiveDocument(documentId: UUID) async throws {
        struct Params: Encodable {
            let pDocumentId: UUID
            enum CodingKeys: String, CodingKey { case pDocumentId = "p_document_id" }
        }
        try await callVoid("archive_document", params: Params(pDocumentId: documentId))
    }

    public func uploadDocumentFile(path: String, data: Data, contentType: String) async throws {
        do {
            _ = try await client.storage
                .from(SupabaseRuulRPCClient.documentsBucket)
                .upload(path, data: data, options: FileOptions(contentType: contentType, upsert: false))
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func documentSignedURL(path: String, expiresIn: Int) async throws -> URL {
        do {
            return try await client.storage
                .from(SupabaseRuulRPCClient.documentsBucket)
                .createSignedURL(path: path, expiresIn: expiresIn)
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    /// Nombre del bucket de Storage donde residen los binarios de documentos.
    /// Debe existir en el proyecto con policies que permitan upload/select al
    /// `authenticated` role (ver migration `..._documents_storage_bucket.sql`).
    static let documentsBucket = "documents"

    // MARK: - Resources & rights

    public func resourceTypeCatalog() async throws -> ResourceTypeCatalog {
        try await call("resource_type_catalog")
    }

    public func listResourceClasses() async throws -> [ResourceClass] {
        try await call("list_resource_classes")
    }

    public func listResourceSubtypes(classKey: String?) async throws -> [ResourceSubtype] {
        struct Params: Encodable, Sendable {
            let pClassKey: String?
            enum CodingKeys: String, CodingKey { case pClassKey = "p_class_key" }
        }
        return try await call("list_resource_subtypes", params: Params(pClassKey: classKey))
    }

    public func resourceAvailableActions(resourceId: UUID, actorId: UUID) async throws -> [AvailableAction] {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pActorId = "p_actor_id"
            }
        }
        return try await call("resource_available_actions", params: Params(
            pResourceId: resourceId, pActorId: actorId
        ))
    }

    public func createResource(_ input: CreateResourceInput) async throws -> Resource {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pResourceType: String
            let pDisplayName: String
            let pDescription: String?
            let pEstimatedValue: Double?
            let pCurrency: String?
            let pClientId: String?
            let pLocationText: String?
            let pSubtypeKey: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pResourceType = "p_resource_type"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pEstimatedValue = "p_estimated_value"
                case pCurrency = "p_currency"
                case pClientId = "p_client_id"
                case pLocationText = "p_location_text"
                case pSubtypeKey = "p_subtype_key"
            }
        }
        let created: ResourceCreated = try await call("create_resource", params: Params(
            pContextActorId: input.contextId,
            pResourceType: input.resourceType,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pEstimatedValue: input.estimatedValue,
            pCurrency: input.currency,
            pClientId: input.clientId,
            pLocationText: input.locationText,
            pSubtypeKey: input.subtypeKey
        ))
        return created.resource
    }

    public func listContextResources(contextId: UUID) async throws -> [ContextResource] {
        try await call("list_context_resources", params: ContextIdParams(contextId: contextId))
    }

    public func resourceDetail(resourceId: UUID) async throws -> ResourceDetail {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_detail", params: Params(pResourceId: resourceId))
    }

    public func resourceDetailDescriptor(resourceId: UUID) async throws -> ResourceDetailDescriptor {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_detail_descriptor", params: Params(pResourceId: resourceId))
    }

    public func listResourceActions(resourceId: UUID) async throws -> [ResourceDescriptorAction] {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("list_resource_actions", params: Params(pResourceId: resourceId))
    }

    public func executeResourceAction(
        resourceId: UUID,
        actionKey: String,
        payload: JSONValue,
        clientId: UUID?
    ) async throws -> ExecuteResourceActionResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pActionKey: String
            let pPayload: JSONValue
            let pClientId: UUID?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pActionKey = "p_action_key"
                case pPayload = "p_payload"
                case pClientId = "p_client_id"
            }
        }
        return try await call("execute_resource_action", params: Params(
            pResourceId: resourceId,
            pActionKey: actionKey,
            pPayload: payload,
            pClientId: clientId
        ))
    }

    public func grantRight(_ input: GrantRightInput) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pHolderActorId: UUID
            let pRightKind: String
            let pPercent: Double?
            let pScope: String?
            let pStartsAt: Date?
            let pEndsAt: Date?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pHolderActorId = "p_holder_actor_id"
                case pRightKind = "p_right_kind"
                case pPercent = "p_percent"
                case pScope = "p_scope"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
            }
        }
        struct Result: Decodable {
            let rightId: UUID
            enum CodingKeys: String, CodingKey { case rightId = "right_id" }
        }
        let result: Result = try await call("grant_right", params: Params(
            pResourceId: input.resourceId,
            pHolderActorId: input.holderActorId,
            pRightKind: input.rightKind.rawValue,
            pPercent: input.percent,
            pScope: input.scope,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt
        ))
        return result.rightId
    }

    public func revokeRight(rightId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pRightId: UUID
            enum CodingKeys: String, CodingKey { case pRightId = "p_right_id" }
        }
        try await callVoid("revoke_right", params: Params(pRightId: rightId))
    }

    public func updateResource(_ input: UpdateResourceInput) async throws -> Resource {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pDisplayName: String?
            let pDescription: String?
            let pEstimatedValue: Double?
            let pCurrency: String?
            let pMetadata: JSONValue?
            let pLocationText: String?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pDisplayName = "p_display_name"
                case pDescription = "p_description"
                case pEstimatedValue = "p_estimated_value"
                case pCurrency = "p_currency"
                case pMetadata = "p_metadata"
                case pLocationText = "p_location_text"
            }
        }
        struct Updated: Decodable {
            let resource: Resource
        }
        let result: Updated = try await call("update_resource", params: Params(
            pResourceId: input.resourceId,
            pDisplayName: input.displayName,
            pDescription: input.description,
            pEstimatedValue: input.estimatedValue,
            pCurrency: input.currency,
            pMetadata: input.metadata,
            pLocationText: input.locationText
        ))
        return result.resource
    }

    public func transferResourceOwnership(resourceId: UUID, toActorId: UUID, reason: String?) async throws -> TransferOwnershipResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pToActorId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pToActorId = "p_to_actor_id"
                case pReason = "p_reason"
            }
        }
        return try await call("transfer_resource_ownership", params: Params(
            pResourceId: resourceId, pToActorId: toActorId, pReason: reason
        ))
    }

    public func archiveResource(resourceId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        try await callVoid("archive_resource", params: Params(pResourceId: resourceId))
    }

    // MARK: - Events

    public func createCalendarEvent(_ input: CreateEventInput) async throws -> CalendarEvent {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pTitle: String
            let pEventType: String
            let pStartsAt: Date
            let pEndsAt: Date?
            let pDescription: String?
            let pLocationText: String?
            let pRecurrenceRule: String?
            let pHostActorId: UUID?
            let pInviteAllMembers: Bool
            let pClientId: String?
            let pIsVirtual: Bool
            let pRecurrenceCount: Int?
            let pRecurrenceUntil: Date?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pTitle = "p_title"
                case pEventType = "p_event_type"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
                case pDescription = "p_description"
                case pLocationText = "p_location_text"
                case pRecurrenceRule = "p_recurrence_rule"
                case pHostActorId = "p_host_actor_id"
                case pInviteAllMembers = "p_invite_all_members"
                case pClientId = "p_client_id"
                case pIsVirtual = "p_is_virtual"
                case pRecurrenceCount = "p_recurrence_count"
                case pRecurrenceUntil = "p_recurrence_until"
            }
        }
        let created: EventCreated = try await call("create_calendar_event", params: Params(
            pContextActorId: input.contextId,
            pTitle: input.title,
            pEventType: input.eventType.rawValue,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt,
            pDescription: input.description,
            pLocationText: input.locationText,
            pRecurrenceRule: input.recurrenceRule,
            pHostActorId: input.hostActorId,
            pInviteAllMembers: input.inviteAllMembers,
            pClientId: input.clientId,
            pIsVirtual: input.isVirtual,
            pRecurrenceCount: input.recurrenceCount,
            pRecurrenceUntil: input.recurrenceUntil
        ))
        return created.event
    }

    public func updateCalendarEvent(_ input: UpdateEventInput) async throws -> CalendarEvent {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pTitle: String?
            let pDescription: String?
            let pStartsAt: Date?
            let pEndsAt: Date?
            let pLocationText: String?
            let pIsVirtual: Bool?
            let pRecurrenceRule: String?
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
                case pLocationText = "p_location_text"
                case pIsVirtual = "p_is_virtual"
                case pRecurrenceRule = "p_recurrence_rule"
            }
        }
        struct UpdateResult: Decodable, Sendable {
            let event: CalendarEvent
        }
        let result: UpdateResult = try await call("update_calendar_event", params: Params(
            pEventId: input.eventId,
            pTitle: input.title,
            pDescription: input.description,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt,
            pLocationText: input.locationText,
            pIsVirtual: input.isVirtual,
            pRecurrenceRule: input.recurrenceRule
        ))
        return result.event
    }

    public func listEvents(contextId: UUID) async throws -> [CalendarEvent] {
        do {
            return try await client
                .from("calendar_events")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("starts_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func getEvent(eventId: UUID) async throws -> CalendarEvent {
        do {
            let rows: [CalendarEvent] = try await client
                .from("calendar_events")
                .select()
                .eq("id", value: eventId.uuidString)
                .limit(1)
                .execute()
                .value
            guard let event = rows.first else {
                throw RuulError.unexpected(message: "Evento no encontrado")
            }
            return event
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listEventParticipants(eventId: UUID) async throws -> [EventParticipant] {
        do {
            return try await client
                .from("event_participants")
                .select()
                .eq("event_id", value: eventId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func eventDetail(eventId: UUID) async throws -> EventDetail {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("event_detail", params: Params(pEventId: eventId))
    }

    public func rsvpEvent(eventId: UUID, status: RSVPStatus) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pStatus: String
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pStatus = "p_status"
            }
        }
        try await callVoid("rsvp_event", params: Params(pEventId: eventId, pStatus: status.rawValue))
    }

    public func checkInParticipant(eventId: UUID, participantActorId: UUID?) async throws -> CheckInResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pParticipantActorId: UUID?
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pParticipantActorId = "p_participant_actor_id"
            }
        }
        return try await call("check_in_participant", params: Params(
            pEventId: eventId, pParticipantActorId: participantActorId
        ))
    }

    public func cancelParticipation(eventId: UUID) async throws -> CancelParticipationResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("cancel_participation", params: Params(pEventId: eventId))
    }

    public func closeEvent(eventId: UUID) async throws -> CloseEventResult {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("close_event", params: Params(pEventId: eventId))
    }

    public func addEventParticipants(eventId: UUID, actorIds: [UUID]) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorIds: [UUID]
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorIds = "p_actor_ids"
            }
        }
        try await callVoid("add_event_participants", params: Params(pEventId: eventId, pActorIds: actorIds))
    }

    public func removeEventParticipants(eventId: UUID, actorIds: [UUID]) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorIds: [UUID]
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorIds = "p_actor_ids"
            }
        }
        try await callVoid("remove_event_participants", params: Params(pEventId: eventId, pActorIds: actorIds))
    }

    public func setEventParticipantPlusCount(eventId: UUID, actorId: UUID, count: Int) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorId: UUID
            let pCount: Int
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorId = "p_actor_id"
                case pCount = "p_count"
            }
        }
        try await callVoid("set_event_participant_plus_count", params: Params(pEventId: eventId, pActorId: actorId, pCount: count))
    }

    public func addEventGuest(eventId: UUID, displayName: String, countShare: Int, linkedActorId: UUID?, source: String) async throws -> EventGuestAdded {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pDisplayName: String
            let pCountShare: Int
            let pLinkedActorId: UUID?
            let pSource: String
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pDisplayName = "p_display_name"
                case pCountShare = "p_count_share"
                case pLinkedActorId = "p_linked_actor_id"
                case pSource = "p_source"
            }
        }
        return try await call("add_event_guest", params: Params(
            pEventId: eventId, pDisplayName: displayName,
            pCountShare: countShare, pLinkedActorId: linkedActorId, pSource: source
        ))
    }

    public func removeEventGuest(guestId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pGuestId: UUID
            enum CodingKeys: String, CodingKey { case pGuestId = "p_guest_id" }
        }
        try await callVoid("remove_event_guest", params: Params(pGuestId: guestId))
    }

    public func listEventGuests(eventId: UUID) async throws -> [EventGuest] {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("list_event_guests", params: Params(pEventId: eventId))
    }

    public func hostConfirmParticipant(eventId: UUID, actorId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorId = "p_actor_id"
            }
        }
        try await callVoid("host_confirm_participant", params: Params(pEventId: eventId, pActorId: actorId))
    }

    // MARK: - F.EVENT.8 host rotation

    public func previewNextHost(eventId: UUID) async throws -> NextHostPreview {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
        }
        return try await call("preview_next_host", params: Params(pEventId: eventId))
    }

    public func setNextHost(eventId: UUID, actorId: UUID) async throws -> NextHostPreview {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorId = "p_actor_id"
            }
        }
        return try await call("set_next_host", params: Params(pEventId: eventId, pActorId: actorId))
    }

    public func setHostRotationOrder(eventId: UUID, actorIds: [UUID]?) async throws {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pActorIds: [UUID]?
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pActorIds = "p_actor_ids"
            }
        }
        try await callVoid("set_host_rotation_order", params: Params(pEventId: eventId, pActorIds: actorIds))
    }

    // MARK: - Rules

    public func createRule(_ input: CreateRuleInput) async throws -> Rule {
        // R.2S.5: siempre pasamos los 10 args. Si targetScope es nil,
        // mandamos 'context' y filter `{}` (= comportamiento legacy).
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pTitle: String
            let pTriggerEventType: String?
            let pConditionTree: JSONValue?
            let pConsequences: JSONValue?
            let pTargetScope: String
            let pTargetFilter: JSONValue
            let pBody: String?
            let pRuleType: String
            let pSeverity: Int
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pTitle = "p_title"
                case pTriggerEventType = "p_trigger_event_type"
                case pConditionTree = "p_condition_tree"
                case pConsequences = "p_consequences"
                case pTargetScope = "p_target_scope"
                case pTargetFilter = "p_target_filter"
                case pBody = "p_body"
                case pRuleType = "p_rule_type"
                case pSeverity = "p_severity"
            }
        }
        let created: RuleCreated = try await call("create_rule", params: Params(
            pContextActorId: input.contextId,
            pTitle: input.title,
            pTriggerEventType: input.triggerEventType,
            pConditionTree: input.conditionTree,
            pConsequences: input.consequences,
            pTargetScope: input.targetScope ?? "context",
            pTargetFilter: input.targetFilter ?? .object([:]),
            pBody: input.body,
            pRuleType: input.ruleType,
            pSeverity: input.severity
        ))
        return created.rule
    }

    public func updateRule(_ input: UpdateRuleInput) async throws -> Rule {
        struct Params: Encodable, Sendable {
            let pRuleId: UUID
            let pTitle: String?
            let pBody: String?
            let pTriggerEventType: String?
            let pConditionTree: JSONValue?
            let pConsequences: JSONValue?
            let pTargetScope: String?
            let pTargetFilter: JSONValue?
            let pSeverity: Int?
            let pStatus: String?
            enum CodingKeys: String, CodingKey {
                case pRuleId = "p_rule_id"
                case pTitle = "p_title"
                case pBody = "p_body"
                case pTriggerEventType = "p_trigger_event_type"
                case pConditionTree = "p_condition_tree"
                case pConsequences = "p_consequences"
                case pTargetScope = "p_target_scope"
                case pTargetFilter = "p_target_filter"
                case pSeverity = "p_severity"
                case pStatus = "p_status"
            }
        }
        struct UpdateResult: Decodable, Sendable {
            let rule: Rule
        }
        let result: UpdateResult = try await call("update_rule", params: Params(
            pRuleId: input.ruleId,
            pTitle: input.title,
            pBody: input.body,
            pTriggerEventType: input.triggerEventType,
            pConditionTree: input.conditionTree,
            pConsequences: input.consequences,
            pTargetScope: input.targetScope,
            pTargetFilter: input.targetFilter,
            pSeverity: input.severity,
            pStatus: input.status
        ))
        return result.rule
    }

    public func listRules(contextId: UUID) async throws -> [Rule] {
        do {
            return try await client
                .from("rules")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func archiveRule(ruleId: UUID, reason: String?) async throws -> RuleArchivedResult {
        struct Params: Encodable, Sendable {
            let pRuleId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pRuleId = "p_rule_id"
                case pReason = "p_reason"
            }
        }
        return try await call("archive_rule", params: Params(
            pRuleId: ruleId,
            pReason: reason
        ))
    }


    // MARK: - Reservations

    public func requestReservation(_ input: RequestReservationInput) async throws -> ReservationRequestResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pContextActorId: UUID
            let pStartsAt: Date
            let pEndsAt: Date
            let pReservedForActorId: UUID?
            let pClientId: String?
            let pSourceEventId: UUID?
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pContextActorId = "p_context_actor_id"
                case pStartsAt = "p_starts_at"
                case pEndsAt = "p_ends_at"
                case pReservedForActorId = "p_reserved_for_actor_id"
                case pClientId = "p_client_id"
                case pSourceEventId = "p_source_event_id"
            }
        }
        return try await call("request_resource_reservation", params: Params(
            pResourceId: input.resourceId,
            pContextActorId: input.contextId,
            pStartsAt: input.startsAt,
            pEndsAt: input.endsAt,
            pReservedForActorId: input.reservedForActorId,
            pClientId: input.clientId,
            pSourceEventId: input.sourceEventId
        ))
    }

    public func listReservations(resourceId: UUID) async throws -> [Reservation] {
        do {
            return try await client
                .from("resource_reservations")
                .select()
                .eq("resource_id", value: resourceId.uuidString)
                .order("starts_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listContextReservations(contextId: UUID) async throws -> [Reservation] {
        do {
            return try await client
                .from("resource_reservations")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("starts_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listReservationsByEvent(eventId: UUID) async throws -> [Reservation] {
        do {
            return try await client
                .from("resource_reservations")
                .select()
                .eq("source_event_id", value: eventId.uuidString)
                .order("starts_at", ascending: true)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listConflicts(resourceId: UUID) async throws -> [ReservationConflict] {
        do {
            return try await client
                .from("reservation_conflicts")
                .select()
                .eq("resource_id", value: resourceId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func detectReservationConflicts(resourceId: UUID) async throws -> [ReservationConflict] {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("detect_reservation_conflicts", params: Params(pResourceId: resourceId))
    }

    public func reservationDetail(reservationId: UUID) async throws -> ReservationDetail {
        try await call("reservation_detail", params: ReservationIdParams(reservationId: reservationId))
    }

    public func approveReservation(reservationId: UUID) async throws {
        try await callVoid("approve_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func confirmReservation(reservationId: UUID) async throws {
        try await callVoid("confirm_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func cancelReservation(reservationId: UUID) async throws {
        try await callVoid("cancel_reservation", params: ReservationIdParams(reservationId: reservationId))
    }

    public func resolveReservationConflict(conflictId: UUID, winnerReservationId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            let pWinnerReservationId: UUID
            enum CodingKeys: String, CodingKey {
                case pConflictId = "p_conflict_id"
                case pWinnerReservationId = "p_winner_reservation_id"
            }
        }
        try await callVoid("resolve_reservation_conflict", params: Params(
            pConflictId: conflictId, pWinnerReservationId: winnerReservationId
        ))
    }

    public func resolveReservationConflictWith(
        conflictId: UUID,
        resolutionModel: ResolutionModel,
        winnerReservationId: UUID?,
        metadata: JSONValue?
    ) async throws -> ResolveConflictResult {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            let pResolutionModel: String
            let pWinnerReservationId: UUID?
            let pMetadata: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pConflictId = "p_conflict_id"
                case pResolutionModel = "p_resolution_model"
                case pWinnerReservationId = "p_winner_reservation_id"
                case pMetadata = "p_metadata"
            }
        }
        return try await call("resolve_reservation_conflict", params: Params(
            pConflictId: conflictId,
            pResolutionModel: resolutionModel.rawValue,
            pWinnerReservationId: winnerReservationId,
            pMetadata: metadata
        ))
    }

    // MARK: - R.5B Resource Conflicts (R.5B.5a wire)

    public func listResourceConflicts(resourceId: UUID, includeResolved: Bool) async throws -> ResourceConflictList {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            let pIncludeResolved: Bool
            enum CodingKeys: String, CodingKey {
                case pResourceId = "p_resource_id"
                case pIncludeResolved = "p_include_resolved"
            }
        }
        return try await call("list_resource_conflicts", params: Params(
            pResourceId: resourceId, pIncludeResolved: includeResolved
        ))
    }

    public func listContextConflicts(contextActorId: UUID, includeResolved: Bool) async throws -> ContextConflictList {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pIncludeResolved: Bool
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pIncludeResolved = "p_include_resolved"
            }
        }
        return try await call("list_context_conflicts", params: Params(
            pContextActorId: contextActorId, pIncludeResolved: includeResolved
        ))
    }

    public func resolveResourceConflict(
        conflictId: UUID,
        kind: ResolveResourceConflictKind,
        winnerActorId: UUID?,
        payload: JSONValue
    ) async throws -> ResolveResourceConflictResult {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            let pResolutionKind: String
            let pWinnerActorId: UUID?
            let pResolutionPayload: JSONValue
            enum CodingKeys: String, CodingKey {
                case pConflictId = "p_conflict_id"
                case pResolutionKind = "p_resolution_kind"
                case pWinnerActorId = "p_winner_actor_id"
                case pResolutionPayload = "p_resolution_payload"
            }
        }
        return try await call("resolve_resource_conflict", params: Params(
            pConflictId: conflictId,
            pResolutionKind: kind.rawValue,
            pWinnerActorId: winnerActorId,
            pResolutionPayload: payload
        ))
    }

    public func detectResourceConflicts(resourceId: UUID) async throws -> DetectResourceConflictsResult {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("detect_resource_conflicts", params: Params(pResourceId: resourceId))
    }

    public func detectContextConflicts(contextActorId: UUID) async throws -> DetectContextConflictsResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pContextActorId = "p_context_actor_id" }
        }
        return try await call("detect_context_conflicts", params: Params(pContextActorId: contextActorId))
    }

    // MARK: - Decisions

    public func createDecision(_ input: CreateDecisionInput) async throws -> Decision {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDecisionType: String
            let pTitle: String
            let pDescription: String?
            let pClosesAt: Date?
            let pPayload: JSONValue?
            let pClientId: String?
            let pVotingModel: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDecisionType = "p_decision_type"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pClosesAt = "p_closes_at"
                case pPayload = "p_payload"
                case pClientId = "p_client_id"
                case pVotingModel = "p_voting_model"
            }
        }
        let created: DecisionCreated = try await call("create_decision", params: Params(
            pContextActorId: input.contextId,
            pDecisionType: input.decisionType.rawValue,
            pTitle: input.title,
            pDescription: input.description,
            pClosesAt: input.closesAt,
            pPayload: input.payload,
            pClientId: input.clientId,
            pVotingModel: input.votingModel?.rawValue
        ))
        return created.decision
    }

    public func updateDecision(_ input: UpdateDecisionInput) async throws -> Decision {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pTitle: String?
            let pDescription: String?
            let pClosesAt: Date?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pClosesAt = "p_closes_at"
            }
        }
        struct UpdateResult: Decodable, Sendable {
            let decision: Decision
        }
        let result: UpdateResult = try await call("update_decision", params: Params(
            pDecisionId: input.decisionId,
            pTitle: input.title,
            pDescription: input.description,
            pClosesAt: input.closesAt
        ))
        return result.decision
    }

    public func listDecisions(contextId: UUID) async throws -> [Decision] {
        do {
            return try await client
                .from("decisions")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listDecisionVotes(decisionId: UUID) async throws -> [DecisionVote] {
        do {
            return try await client
                .from("decision_votes")
                .select()
                .eq("decision_id", value: decisionId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func voteDecision(decisionId: UUID, vote: VoteChoice, option: String?) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pVote: String
            let pOption: String?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pVote = "p_vote"
                case pOption = "p_option"
            }
        }
        return try await call("vote_decision", params: Params(
            pDecisionId: decisionId, pVote: vote.rawValue, pOption: option
        ))
    }

    public func closeDecision(decisionId: UUID) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("close_decision", params: Params(pDecisionId: decisionId))
    }

    public func executeDecision(decisionId: UUID, result: JSONValue?) async throws {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pResult: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pResult = "p_result"
            }
        }
        try await callVoid("execute_decision", params: Params(pDecisionId: decisionId, pResult: result))
    }

    public func decisionDetail(decisionId: UUID) async throws -> DecisionDetail {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("decision_detail", params: Params(pDecisionId: decisionId))
    }

    public func listDecisionOptions(decisionId: UUID) async throws -> [DecisionOption] {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("list_decision_options", params: Params(pDecisionId: decisionId))
    }

    public func voteForOption(decisionId: UUID, optionId: UUID) async throws -> VoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pOptionId: UUID
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pOptionId = "p_option_id"
            }
        }
        return try await call("vote_for_option", params: Params(pDecisionId: decisionId, pOptionId: optionId))
    }

    public func unvoteOption(decisionId: UUID, optionId: UUID) async throws -> UnvoteResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pOptionId: UUID
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pOptionId = "p_option_id"
            }
        }
        return try await call("unvote_option", params: Params(pDecisionId: decisionId, pOptionId: optionId))
    }

    public func createDecisionOption(_ input: CreateDecisionOptionInput) async throws -> DecisionOption {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            let pOptionKey: String
            let pTitle: String
            let pDescription: String?
            let pPayload: JSONValue?
            let pSortOrder: Int?
            enum CodingKeys: String, CodingKey {
                case pDecisionId = "p_decision_id"
                case pOptionKey = "p_option_key"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pPayload = "p_payload"
                case pSortOrder = "p_sort_order"
            }
        }
        struct Response: Decodable {
            let option: DecisionOption
        }
        let response: Response = try await call("create_decision_option", params: Params(
            pDecisionId: input.decisionId,
            pOptionKey: input.optionKey,
            pTitle: input.title,
            pDescription: input.description,
            pPayload: input.payload,
            pSortOrder: input.sortOrder
        ))
        return response.option
    }

    // MARK: - Money

    public func recordExpense(_ input: RecordExpenseInput) async throws -> ExpenseResult {
        struct WireSplit: Encodable, Sendable {
            let actorId: UUID
            let amount: Double
            enum CodingKeys: String, CodingKey {
                case actorId = "actor_id"
                case amount
            }
        }
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pDescription: String
            let pSplitWith: [UUID]?
            let pExcludedActorIds: [UUID]?
            let pSplitMethod: String
            let pSplits: [WireSplit]?
            let pEventId: UUID?
            let pPaidByActorId: UUID?
            let pClientId: String?
            let pSourceEventId: UUID?
            let pSplitBasis: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pDescription = "p_description"
                case pSplitWith = "p_split_with"
                case pExcludedActorIds = "p_excluded_actor_ids"
                case pSplitMethod = "p_split_method"
                case pSplits = "p_splits"
                case pEventId = "p_event_id"
                case pPaidByActorId = "p_paid_by_actor_id"
                case pClientId = "p_client_id"
                case pSourceEventId = "p_source_event_id"
                case pSplitBasis = "p_split_basis"
            }
        }
        return try await call("record_expense", params: Params(
            pContextActorId: input.contextId,
            pAmount: input.amount,
            pCurrency: input.currency,
            pDescription: input.description,
            pSplitWith: input.splitWith,
            pExcludedActorIds: input.excludedActorIds,
            pSplitMethod: input.splitMethod,
            pSplits: input.splits?.map { WireSplit(actorId: $0.actorId, amount: $0.amount) },
            pEventId: input.eventId,
            pPaidByActorId: input.paidByActorId,
            pClientId: input.clientId,
            pSourceEventId: input.sourceEventId,
            pSplitBasis: input.splitBasis
        ))
    }

    public func previewEventSplit(eventId: UUID, amount: Double, currency: String) async throws -> EventSplitPreview {
        struct Params: Encodable, Sendable {
            let pEventId: UUID
            let pAmount: Double
            let pCurrency: String
            enum CodingKeys: String, CodingKey {
                case pEventId = "p_event_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
            }
        }
        return try await call("preview_event_split", params: Params(
            pEventId: eventId,
            pAmount: amount,
            pCurrency: currency
        ))
    }

    public func recordFine(contextId: UUID, debtorActorId: UUID, amount: Double, currency: String, reason: String?) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDebtorActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDebtorActorId = "p_debtor_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pReason = "p_reason"
            }
        }
        struct Result: Decodable {
            let obligationId: UUID
            enum CodingKeys: String, CodingKey { case obligationId = "obligation_id" }
        }
        let result: Result = try await call("record_fine", params: Params(
            pContextActorId: contextId,
            pDebtorActorId: debtorActorId,
            pAmount: amount,
            pCurrency: currency,
            pReason: reason
        ))
        return result.obligationId
    }

    public func recordGameResult(_ input: RecordGameResultInput) async throws -> GameResultRecorded {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pEventId: UUID?
            let pGameName: String
            let pWinnerActorId: UUID
            let pLoserActorId: UUID
            let pAmount: Double
            let pCurrency: String
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pEventId = "p_event_id"
                case pGameName = "p_game_name"
                case pWinnerActorId = "p_winner_actor_id"
                case pLoserActorId = "p_loser_actor_id"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pClientId = "p_client_id"
            }
        }
        return try await call("record_game_result", params: Params(
            pContextActorId: input.contextId,
            pEventId: input.eventId,
            pGameName: input.gameName,
            pWinnerActorId: input.winnerActorId,
            pLoserActorId: input.loserActorId,
            pAmount: input.amount,
            pCurrency: input.currency,
            pClientId: input.clientId
        ))
    }

    public func listObligations(contextId: UUID) async throws -> [Obligation] {
        do {
            return try await client
                .from("obligations")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    // MARK: - R.2R Obligations universales

    public func createActionObligation(_ input: CreateActionObligationInput) async throws -> ActionObligationCreated {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDebtorActorId: UUID
            let pTitle: String
            let pKind: String
            let pDescription: String?
            let pDueAt: Date?
            let pCreditorActorId: UUID?
            let pSourceEventId: UUID?
            let pSourceReservationId: UUID?
            let pSourceDecisionId: UUID?
            let pMetadata: JSONValue?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDebtorActorId = "p_debtor_actor_id"
                case pTitle = "p_title"
                case pKind = "p_kind"
                case pDescription = "p_description"
                case pDueAt = "p_due_at"
                case pCreditorActorId = "p_creditor_actor_id"
                case pSourceEventId = "p_source_event_id"
                case pSourceReservationId = "p_source_reservation_id"
                case pSourceDecisionId = "p_source_decision_id"
                case pMetadata = "p_metadata"
                case pClientId = "p_client_id"
            }
        }
        return try await call("create_action_obligation", params: Params(
            pContextActorId: input.contextId,
            pDebtorActorId: input.debtorActorId,
            pTitle: input.title,
            pKind: input.kind,
            pDescription: input.description,
            pDueAt: input.dueAt,
            pCreditorActorId: input.creditorActorId,
            pSourceEventId: input.sourceEventId,
            pSourceReservationId: input.sourceReservationId,
            pSourceDecisionId: input.sourceDecisionId,
            pMetadata: input.metadata,
            pClientId: input.clientId
        ))
    }

    public func completeObligation(obligationId: UUID, completionNotes: String?, completionMetadata: JSONValue?) async throws -> ObligationCompletedResult {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            let pCompletionNotes: String?
            let pCompletionMetadata: JSONValue?
            enum CodingKeys: String, CodingKey {
                case pObligationId = "p_obligation_id"
                case pCompletionNotes = "p_completion_notes"
                case pCompletionMetadata = "p_completion_metadata"
            }
        }
        return try await call("complete_obligation", params: Params(
            pObligationId: obligationId,
            pCompletionNotes: completionNotes,
            pCompletionMetadata: completionMetadata
        ))
    }

    public func obligationDetail(obligationId: UUID) async throws -> ObligationDetail {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            enum CodingKeys: String, CodingKey { case pObligationId = "p_obligation_id" }
        }
        return try await call("obligation_detail", params: Params(pObligationId: obligationId))
    }

    public func forgiveObligation(obligationId: UUID, reason: String?) async throws -> ObligationForgivenResult {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pObligationId = "p_obligation_id"
                case pReason = "p_reason"
            }
        }
        return try await call("forgive_obligation", params: Params(
            pObligationId: obligationId,
            pReason: reason
        ))
    }

    public func updateObligation(_ input: UpdateObligationInput) async throws -> Obligation {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            let pTitle: String?
            let pDescription: String?
            let pDueAt: Date?
            let pAmount: Double?
            let pCurrency: String?
            enum CodingKeys: String, CodingKey {
                case pObligationId = "p_obligation_id"
                case pTitle = "p_title"
                case pDescription = "p_description"
                case pDueAt = "p_due_at"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
            }
        }
        struct UpdateResult: Decodable, Sendable {
            let obligation: Obligation
        }
        let result: UpdateResult = try await call("update_obligation", params: Params(
            pObligationId: input.obligationId,
            pTitle: input.title,
            pDescription: input.description,
            pDueAt: input.dueAt,
            pAmount: input.amount,
            pCurrency: input.currency
        ))
        return result.obligation
    }

    // MARK: - Pools (R.8)

    public func createPool(_ input: CreatePoolInput) async throws -> PoolCreated {
        struct Params: Encodable, Sendable {
            let pParentContextActorId: UUID
            let pDisplayName: String
            let pPolicyKey: String
            let pPolicyConfig: JSONValue?
            let pCurrency: String?
            let pTargetAmount: Double?
            let pDescription: String?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pParentContextActorId = "p_parent_context_actor_id"
                case pDisplayName = "p_display_name"
                case pPolicyKey = "p_policy_key"
                case pPolicyConfig = "p_policy_config"
                case pCurrency = "p_currency"
                case pTargetAmount = "p_target_amount"
                case pDescription = "p_description"
                case pClientId = "p_client_id"
            }
        }
        return try await call("create_pool", params: Params(
            pParentContextActorId: input.contextId,
            pDisplayName: input.displayName,
            pPolicyKey: input.policyKey,
            pPolicyConfig: input.policyConfig,
            pCurrency: input.currency,
            pTargetAmount: input.targetAmount,
            pDescription: input.description,
            pClientId: input.clientId
        ))
    }

    public func contributeToPool(_ input: ContributeToPoolInput) async throws -> PoolContributionResult {
        struct Params: Encodable, Sendable {
            let pPoolAccountId: UUID
            let pBasisKind: String
            let pAmount: Double
            let pCurrency: String?
            let pAssetResourceId: UUID?
            let pValuationMethod: String?
            let pValuationNotes: String?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pPoolAccountId = "p_pool_account_id"
                case pBasisKind = "p_basis_kind"
                case pAmount = "p_amount"
                case pCurrency = "p_currency"
                case pAssetResourceId = "p_asset_resource_id"
                case pValuationMethod = "p_valuation_method"
                case pValuationNotes = "p_valuation_notes"
                case pClientId = "p_client_id"
            }
        }
        return try await call("contribute_to_pool", params: Params(
            pPoolAccountId: input.poolAccountId,
            pBasisKind: input.basisKind,
            pAmount: input.amount,
            pCurrency: input.currency,
            pAssetResourceId: input.assetResourceId,
            pValuationMethod: input.valuationMethod,
            pValuationNotes: input.valuationNotes,
            pClientId: input.clientId
        ))
    }

    public func listContextPools(contextId: UUID) async throws -> [PoolAccount] {
        struct Params: Encodable, Sendable {
            let pParentContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pParentContextActorId = "p_parent_context_actor_id" }
        }
        return try await call("list_context_pools", params: Params(pParentContextActorId: contextId))
    }

    public func poolAccountDetail(poolAccountId: UUID) async throws -> PoolAccountDetail {
        try await call("pool_account_detail", params: PoolAccountIdParams(poolAccountId: poolAccountId))
    }

    public func previewPoolResolution(poolAccountId: UUID) async throws -> PoolResolutionPreview {
        try await call("preview_pool_resolution", params: PoolAccountIdParams(poolAccountId: poolAccountId))
    }

    public func resolvePool(poolAccountId: UUID, resolution: JSONValue?, clientId: String?) async throws -> PoolResolutionResult {
        struct Params: Encodable, Sendable {
            let pPoolAccountId: UUID
            let pResolution: JSONValue?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pPoolAccountId = "p_pool_account_id"
                case pResolution = "p_resolution"
                case pClientId = "p_client_id"
            }
        }
        return try await call("resolve_pool", params: Params(
            pPoolAccountId: poolAccountId,
            pResolution: resolution,
            pClientId: clientId
        ))
    }

    // MARK: - Settlement

    public func generateSettlementBatch(contextId: UUID, currency: String) async throws -> SettlementBatchResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pCurrency: String
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pCurrency = "p_currency"
            }
        }
        return try await call("generate_settlement_batch", params: Params(
            pContextActorId: contextId, pCurrency: currency
        ))
    }

    public func listSettlementBatches(contextId: UUID) async throws -> [SettlementBatch] {
        do {
            return try await client
                .from("settlement_batches")
                .select()
                .eq("context_actor_id", value: contextId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func listSettlementItems(batchId: UUID) async throws -> [SettlementItem] {
        do {
            return try await client
                .from("settlement_items")
                .select()
                .eq("settlement_batch_id", value: batchId.uuidString)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func markSettlementPaid(itemId: UUID) async throws -> MarkPaidResult {
        struct Params: Encodable, Sendable {
            let pSettlementItemId: UUID
            enum CodingKeys: String, CodingKey { case pSettlementItemId = "p_settlement_item_id" }
        }
        return try await call("mark_settlement_paid", params: Params(pSettlementItemId: itemId))
    }

    public func confirmSettlementPaid(itemId: UUID) async throws -> MarkPaidResult {
        struct Params: Encodable, Sendable {
            let pSettlementItemId: UUID
            enum CodingKeys: String, CodingKey { case pSettlementItemId = "p_settlement_item_id" }
        }
        return try await call("confirm_settlement_paid", params: Params(pSettlementItemId: itemId))
    }

    public func rejectSettlementPaid(itemId: UUID, reason: String?) async throws {
        struct Params: Encodable, Sendable {
            let pSettlementItemId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pSettlementItemId = "p_settlement_item_id"
                case pReason = "p_reason"
            }
        }
        try await callVoid("reject_settlement_paid", params: Params(pSettlementItemId: itemId, pReason: reason))
    }

    public func appealSettlementPaid(itemId: UUID, reason: String?) async throws {
        struct Params: Encodable, Sendable {
            let pSettlementItemId: UUID
            let pReason: String?
            enum CodingKeys: String, CodingKey {
                case pSettlementItemId = "p_settlement_item_id"
                case pReason = "p_reason"
            }
        }
        try await callVoid("appeal_settlement_paid", params: Params(pSettlementItemId: itemId, pReason: reason))
    }

    // MARK: - Explanation engine (R.2S.10)

    public func whyCanViewResource(actorId: UUID, resourceId: UUID) async throws -> WhyCanViewResource {
        try await call("why_can_view_resource", params: ActorResourceParams(actorId: actorId, resourceId: resourceId))
    }

    public func whyCanReserve(actorId: UUID, resourceId: UUID) async throws -> WhyCanReserve {
        try await call("why_can_reserve", params: ActorResourceParams(actorId: actorId, resourceId: resourceId))
    }

    public func whyDecisionResult(decisionId: UUID) async throws -> WhyDecisionResult {
        struct Params: Encodable, Sendable {
            let pDecisionId: UUID
            enum CodingKeys: String, CodingKey { case pDecisionId = "p_decision_id" }
        }
        return try await call("why_decision_result", params: Params(pDecisionId: decisionId))
    }

    public func whyReservationWon(conflictId: UUID) async throws -> WhyReservationWon {
        struct Params: Encodable, Sendable {
            let pConflictId: UUID
            enum CodingKeys: String, CodingKey { case pConflictId = "p_conflict_id" }
        }
        return try await call("why_reservation_won", params: Params(pConflictId: conflictId))
    }

    public func whyObligationExists(obligationId: UUID) async throws -> WhyObligationExists {
        struct Params: Encodable, Sendable {
            let pObligationId: UUID
            enum CodingKeys: String, CodingKey { case pObligationId = "p_obligation_id" }
        }
        return try await call("why_obligation_exists", params: Params(pObligationId: obligationId))
    }

    // MARK: - Activity

    public func listActivity(
        contextId: UUID,
        limit: Int,
        before: Date?,
        includeDescendants: Bool
    ) async throws -> [ActivityEvent] {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pLimit: Int
            let pBefore: Date?
            let pIncludeDescendants: Bool
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pLimit = "p_limit"
                case pBefore = "p_before"
                case pIncludeDescendants = "p_include_descendants"
            }
        }
        let page: ActivityPage = try await call("list_activity", params: Params(
            pContextActorId: contextId,
            pLimit: limit,
            pBefore: before,
            pIncludeDescendants: includeDescendants
        ))
        return page.activity
    }

    // MARK: - Similarity & duplicates (R.2V)

    public func contextSimilarity(contextId: UUID) async throws -> [ContextSimilarityCandidate] {
        try await call("context_similarity", params: ContextIdParams(contextId: contextId))
    }

    public func resourceSimilarity(resourceId: UUID) async throws -> [ResourceSimilarityCandidate] {
        struct Params: Encodable, Sendable {
            let pResourceId: UUID
            enum CodingKeys: String, CodingKey { case pResourceId = "p_resource_id" }
        }
        return try await call("resource_similarity", params: Params(pResourceId: resourceId))
    }

    public func duplicateCandidates(minScore: Double?, maxPairs: Int?) async throws -> DuplicateCandidates {
        struct Params: Encodable, Sendable {
            let pMinScore: Double?
            let pMaxPairs: Int?
            enum CodingKeys: String, CodingKey {
                case pMinScore = "p_min_score"
                case pMaxPairs = "p_max_pairs"
            }
        }
        return try await call("duplicate_candidates", params: Params(pMinScore: minScore, pMaxPairs: maxPairs))
    }

    public func mergeCandidates() async throws -> DuplicateCandidates {
        try await call("merge_candidates")
    }

    public func relationshipSuggestions(actorId: UUID?) async throws -> [RelationshipSuggestion] {
        struct Params: Encodable, Sendable {
            let pActorId: UUID?
            enum CodingKeys: String, CodingKey { case pActorId = "p_actor_id" }
        }
        return try await call("relationship_suggestions", params: Params(pActorId: actorId))
    }

    public func mergeContexts(sourceId: UUID, targetId: UUID) async throws -> MergeContextResult {
        struct Params: Encodable, Sendable {
            let pSourceContextId: UUID
            let pTargetContextId: UUID
            enum CodingKeys: String, CodingKey {
                case pSourceContextId = "p_source_context_id"
                case pTargetContextId = "p_target_context_id"
            }
        }
        return try await call("merge_contexts", params: Params(
            pSourceContextId: sourceId, pTargetContextId: targetId
        ))
    }

    public func unmergeContext(sourceId: UUID) async throws -> UnmergeContextResult {
        struct Params: Encodable, Sendable {
            let pSourceContextId: UUID
            enum CodingKeys: String, CodingKey { case pSourceContextId = "p_source_context_id" }
        }
        return try await call("unmerge_context", params: Params(pSourceContextId: sourceId))
    }

    public func contextCreationCandidates(displayName: String) async throws -> [ContextCreationCandidate] {
        struct Params: Encodable, Sendable {
            let pDisplayName: String
            enum CodingKeys: String, CodingKey { case pDisplayName = "p_display_name" }
        }
        return try await call("context_creation_candidates", params: Params(pDisplayName: displayName))
    }

    public func resourceCreationCandidates(displayName: String, contextId: UUID) async throws -> [ResourceCreationCandidate] {
        struct Params: Encodable, Sendable {
            let pDisplayName: String
            let pContextId: UUID
            enum CodingKeys: String, CodingKey {
                case pDisplayName = "p_display_name"
                case pContextId = "p_context_id"
            }
        }
        return try await call("resource_creation_candidates", params: Params(
            pDisplayName: displayName, pContextId: contextId
        ))
    }

    public func dismissSuggestion(subjectA: UUID, subjectB: UUID, suggestionType: SuggestionType) async throws -> DismissSuggestionResult {
        struct Params: Encodable, Sendable {
            let pSubjectA: UUID
            let pSubjectB: UUID
            let pSuggestionType: String
            enum CodingKeys: String, CodingKey {
                case pSubjectA = "p_subject_a"
                case pSubjectB = "p_subject_b"
                case pSuggestionType = "p_suggestion_type"
            }
        }
        return try await call("dismiss_suggestion", params: Params(
            pSubjectA: subjectA, pSubjectB: subjectB, pSuggestionType: suggestionType.rawValue
        ))
    }

    // MARK: - Subscriptions & Trust (R.3A)

    public func subscribe(
        targetType: SubscriptionTargetType,
        targetId: UUID,
        subscriptionType: SubscriptionType,
        notes: String?
    ) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pTargetType: String
            let pTargetId: UUID
            let pSubscriptionType: String
            let pNotes: String?
            enum CodingKeys: String, CodingKey {
                case pTargetType        = "p_target_type"
                case pTargetId          = "p_target_id"
                case pSubscriptionType  = "p_subscription_type"
                case pNotes             = "p_notes"
            }
        }
        return try await call("subscribe", params: Params(
            pTargetType: targetType.rawValue,
            pTargetId: targetId,
            pSubscriptionType: subscriptionType.rawValue,
            pNotes: notes
        ))
    }

    public func unsubscribe(subscriptionId: UUID) async throws -> Bool {
        struct Params: Encodable, Sendable {
            let pSubscriptionId: UUID
            enum CodingKeys: String, CodingKey { case pSubscriptionId = "p_subscription_id" }
        }
        return try await call("unsubscribe", params: Params(pSubscriptionId: subscriptionId))
    }

    public func markAsStakeholder(targetType: SubscriptionTargetType, targetId: UUID) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pTargetType: String
            let pTargetId: UUID
            enum CodingKeys: String, CodingKey {
                case pTargetType = "p_target_type"
                case pTargetId   = "p_target_id"
            }
        }
        return try await call("mark_as_stakeholder", params: Params(
            pTargetType: targetType.rawValue, pTargetId: targetId
        ))
    }

    public func listMySubscriptions() async throws -> SubscriptionList {
        try await call("list_my_subscriptions")
    }

    public func activityFeed(actorId: UUID?, limit: Int) async throws -> ActivityFeed {
        struct Params: Encodable, Sendable {
            let pActorId: UUID?
            let pLimit: Int
            enum CodingKeys: String, CodingKey {
                case pActorId = "p_actor_id"
                case pLimit   = "p_limit"
            }
        }
        return try await call("activity_feed", params: Params(pActorId: actorId, pLimit: limit))
    }

    public func addTrust(targetActorId: UUID, trustLevel: Int, trustType: TrustType, notes: String?) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let pTargetActorId: UUID
            let pTrustLevel: Int
            let pTrustType: String
            let pNotes: String?
            enum CodingKeys: String, CodingKey {
                case pTargetActorId = "p_target_actor_id"
                case pTrustLevel    = "p_trust_level"
                case pTrustType     = "p_trust_type"
                case pNotes         = "p_notes"
            }
        }
        return try await call("add_trust", params: Params(
            pTargetActorId: targetActorId,
            pTrustLevel: trustLevel,
            pTrustType: trustType.rawValue,
            pNotes: notes
        ))
    }

    public func removeTrust(trustEdgeId: UUID) async throws -> Bool {
        struct Params: Encodable, Sendable {
            let pTrustEdgeId: UUID
            enum CodingKeys: String, CodingKey { case pTrustEdgeId = "p_trust_edge_id" }
        }
        return try await call("remove_trust", params: Params(pTrustEdgeId: trustEdgeId))
    }

    public func listTrustNetwork(actorId: UUID?) async throws -> TrustNetwork {
        struct Params: Encodable, Sendable {
            let pActorId: UUID?
            enum CodingKeys: String, CodingKey { case pActorId = "p_actor_id" }
        }
        return try await call("list_trust_network", params: Params(pActorId: actorId))
    }

    // MARK: - Navigation shell (F.NAV.0)

    public func attentionInbox() async throws -> [AttentionItem] {
        struct Empty: Encodable, Sendable {}
        return try await call("attention_inbox", params: Empty())
    }

    public func dismissAttentionItem(itemId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pAttentionItemId: UUID
            enum CodingKeys: String, CodingKey { case pAttentionItemId = "p_attention_item_id" }
        }
        try await callVoid("dismiss_attention_item", params: Params(pAttentionItemId: itemId))
    }

    public func markContextFavorite(contextActorId: UUID, isFavorite: Bool) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pIsFavorite: Bool
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pIsFavorite = "p_is_favorite"
            }
        }
        try await callVoid("mark_context_favorite", params: Params(pContextActorId: contextActorId, pIsFavorite: isFavorite))
    }

    public func markContextVisited(contextActorId: UUID) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            enum CodingKeys: String, CodingKey { case pContextActorId = "p_context_actor_id" }
        }
        try await callVoid("mark_context_visited", params: Params(pContextActorId: contextActorId))
    }

    public func listContextFavorites() async throws -> [ContextPreference] {
        struct Empty: Encodable, Sendable {}
        return try await call("list_context_favorites", params: Empty())
    }

    public func listRecentContexts(limit: Int) async throws -> [ContextPreference] {
        struct Params: Encodable, Sendable {
            let pLimit: Int
            enum CodingKeys: String, CodingKey { case pLimit = "p_limit" }
        }
        return try await call("list_recent_contexts", params: Params(pLimit: limit))
    }

    // MARK: - Governance (R.5 + R.7)

    public func memberAvailableActions(
        contextId: UUID,
        memberActorId: UUID,
        actorId: UUID
    ) async throws -> [AvailableAction] {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pMemberActorId: UUID
            let pActorId: UUID
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pMemberActorId = "p_member_actor_id"
                case pActorId = "p_actor_id"
            }
        }
        return try await call("member_available_actions", params: Params(
            pContextActorId: contextId,
            pMemberActorId: memberActorId,
            pActorId: actorId
        ))
    }

    public func requestGovernanceAction(_ input: RequestGovernanceActionInput) async throws -> RequestGovernanceActionResult {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pActionKey: String
            let pTargetType: String?
            let pTargetId: UUID?
            let pPayload: JSONValue
            let pTitle: String?
            let pClosesAt: Date?
            let pClientId: String?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pActionKey = "p_action_key"
                case pTargetType = "p_target_type"
                case pTargetId = "p_target_id"
                case pPayload = "p_payload"
                case pTitle = "p_title"
                case pClosesAt = "p_closes_at"
                case pClientId = "p_client_id"
            }
        }
        return try await call("request_governance_action", params: Params(
            pContextActorId: input.contextActorId,
            pActionKey: input.actionKey,
            pTargetType: input.targetType,
            pTargetId: input.targetId,
            pPayload: input.payload,
            pTitle: input.title,
            pClosesAt: input.closesAt,
            pClientId: input.clientId
        ))
    }

    public func listGovernancePolicies(contextActorId: UUID) async throws -> [GovernancePolicy] {
        try await call("list_governance_policies", params: ContextIdParams(contextId: contextActorId))
    }

    public func setGovernancePolicy(contextActorId: UUID, policyKey: String, policyValue: JSONValue) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pPolicyKey: String
            let pPolicyValue: JSONValue
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pPolicyKey = "p_policy_key"
                case pPolicyValue = "p_policy_value"
            }
        }
        try await callVoid("create_governance_policy", params: Params(
            pContextActorId: contextActorId,
            pPolicyKey: policyKey,
            pPolicyValue: policyValue
        ))
    }

    public func listVoteDelegations(contextActorId: UUID) async throws -> [VoteDelegation] {
        do {
            return try await client
                .from("vote_delegations")
                .select()
                .eq("context_actor_id", value: contextActorId.uuidString)
                .is("revoked_at", value: nil)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            throw RPCErrorMapper.map(error)
        }
    }

    public func delegateVote(contextActorId: UUID, delegateActorId: UUID, endsAt: Date?) async throws {
        struct Params: Encodable, Sendable {
            let pContextActorId: UUID
            let pDelegateActorId: UUID
            let pEndsAt: Date?
            enum CodingKeys: String, CodingKey {
                case pContextActorId = "p_context_actor_id"
                case pDelegateActorId = "p_delegate_actor_id"
                case pEndsAt = "p_ends_at"
            }
        }
        try await callVoid("delegate_vote", params: Params(
            pContextActorId: contextActorId,
            pDelegateActorId: delegateActorId,
            pEndsAt: endsAt
        ))
    }

    public func revokeVoteDelegation(contextActorId: UUID) async throws {
        try await callVoid("revoke_vote_delegation", params: ContextIdParams(contextId: contextActorId))
    }
}

// MARK: - Params compartidos

private struct ContextIdParams: Encodable, Sendable {
    let contextId: UUID
    enum CodingKeys: String, CodingKey { case contextId = "p_context_actor_id" }
}

private struct ActorResourceParams: Encodable, Sendable {
    let actorId: UUID
    let resourceId: UUID
    enum CodingKeys: String, CodingKey {
        case actorId = "p_actor_id"
        case resourceId = "p_resource_id"
    }
}

private struct ReservationIdParams: Encodable, Sendable {
    let reservationId: UUID
    enum CodingKeys: String, CodingKey { case reservationId = "p_reservation_id" }
}

private struct PoolAccountIdParams: Encodable, Sendable {
    let poolAccountId: UUID
    enum CodingKeys: String, CodingKey { case poolAccountId = "p_pool_account_id" }
}
