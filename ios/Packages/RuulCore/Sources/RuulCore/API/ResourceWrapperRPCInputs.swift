import Foundation

/// V3 D.24 P2B-1.x — iOS bindings for the 4 atomic subtype wrappers
/// (P2A) that match the data iOS currently collects in `CreateResourceView`:
/// fund, space, asset, right. `event` and `slot` require time pickers
/// the form doesn't render yet, so they keep using the legacy envelope-
/// only path (`create_group_resource`).
///
/// Each wrapper sets `ruul.resource_create_intent` via GUC inside the
/// SECURITY DEFINER function chain, so calls from these inputs land in
/// the P2B-1 audit table with the wrapper name as intent_marker.

public struct CreateFundResourceParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pName: String
    public let pFundKind: String              // 'pool' | 'protected' | 'shared_pool'
    public let pCurrency: String?
    public let pDescription: String?
    public let pIsSharedPool: Bool?
    public let pIsInKind: Bool?
    public let pThresholdTarget: Decimal?
    public let pVisibility: String?
    public let pMetadata: [String: RPCJSONValue]?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId         = "p_group_id"
        case pName            = "p_name"
        case pFundKind        = "p_fund_kind"
        case pCurrency        = "p_currency"
        case pDescription     = "p_description"
        case pIsSharedPool    = "p_is_shared_pool"
        case pIsInKind        = "p_is_in_kind"
        case pThresholdTarget = "p_threshold_target"
        case pVisibility      = "p_visibility"
        case pMetadata        = "p_metadata"
        case pClientId        = "p_client_id"
    }

    public init(
        groupId: UUID,
        name: String,
        fundKind: String = "pool",
        currency: String? = nil,
        description: String? = nil,
        isSharedPool: Bool? = nil,
        isInKind: Bool? = nil,
        thresholdTarget: Decimal? = nil,
        visibility: String? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        clientId: String? = nil
    ) {
        self.pGroupId = groupId
        self.pName = name
        self.pFundKind = fundKind
        self.pCurrency = currency
        self.pDescription = description
        self.pIsSharedPool = isSharedPool
        self.pIsInKind = isInKind
        self.pThresholdTarget = thresholdTarget
        self.pVisibility = visibility
        self.pMetadata = metadata
        self.pClientId = clientId
    }
}

public struct CreateSpaceResourceParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pName: String
    public let pAddress: String?
    public let pDescription: String?
    public let pCapacity: Int?
    public let pRules: String?
    public let pVisibility: String?
    public let pMetadata: [String: RPCJSONValue]?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId      = "p_group_id"
        case pName         = "p_name"
        case pAddress      = "p_address"
        case pDescription  = "p_description"
        case pCapacity     = "p_capacity"
        case pRules        = "p_rules"
        case pVisibility   = "p_visibility"
        case pMetadata     = "p_metadata"
        case pClientId     = "p_client_id"
    }

    public init(
        groupId: UUID,
        name: String,
        address: String? = nil,
        description: String? = nil,
        capacity: Int? = nil,
        rules: String? = nil,
        visibility: String? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        clientId: String? = nil
    ) {
        self.pGroupId = groupId
        self.pName = name
        self.pAddress = address
        self.pDescription = description
        self.pCapacity = capacity
        self.pRules = rules
        self.pVisibility = visibility
        self.pMetadata = metadata
        self.pClientId = clientId
    }
}

public struct CreateAssetResourceParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pName: String
    /// Nullable in DB; iOS sends nil today (no asset_kind picker).
    public let pAssetKind: String?
    public let pDescription: String?
    public let pSerialNumber: String?
    public let pCurrentValue: Decimal?
    public let pCurrentValueUnit: String?
    public let pCondition: String?  // 'good'|'used'|'damaged'|'repaired'|'retired' or nil
    public let pCustodianMembershipId: UUID?
    public let pOwnerMembershipId: UUID?
    public let pOwnershipKind: String?
    public let pVisibility: String?
    public let pMetadata: [String: RPCJSONValue]?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId                = "p_group_id"
        case pName                   = "p_name"
        case pAssetKind              = "p_asset_kind"
        case pDescription            = "p_description"
        case pSerialNumber           = "p_serial_number"
        case pCurrentValue           = "p_current_value"
        case pCurrentValueUnit       = "p_current_value_unit"
        case pCondition              = "p_condition"
        case pCustodianMembershipId  = "p_custodian_membership_id"
        case pOwnerMembershipId      = "p_owner_membership_id"
        case pOwnershipKind          = "p_ownership_kind"
        case pVisibility             = "p_visibility"
        case pMetadata               = "p_metadata"
        case pClientId               = "p_client_id"
    }

    public init(
        groupId: UUID,
        name: String,
        assetKind: String? = nil,
        description: String? = nil,
        serialNumber: String? = nil,
        currentValue: Decimal? = nil,
        currentValueUnit: String? = nil,
        condition: String? = nil,
        custodianMembershipId: UUID? = nil,
        ownerMembershipId: UUID? = nil,
        ownershipKind: String? = nil,
        visibility: String? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        clientId: String? = nil
    ) {
        self.pGroupId = groupId
        self.pName = name
        self.pAssetKind = assetKind
        self.pDescription = description
        self.pSerialNumber = serialNumber
        self.pCurrentValue = currentValue
        self.pCurrentValueUnit = currentValueUnit
        self.pCondition = condition
        self.pCustodianMembershipId = custodianMembershipId
        self.pOwnerMembershipId = ownerMembershipId
        self.pOwnershipKind = ownershipKind
        self.pVisibility = visibility
        self.pMetadata = metadata
        self.pClientId = clientId
    }
}

public struct CreateRightResourceParams: Encodable, Sendable {
    public let pGroupId: UUID
    public let pName: String
    public let pRightKind: String                // 'access'|'membership'|'seat'|'benefit'|'other'
    public let pHolderMembershipId: UUID?        // NULLable in DB
    public let pDescription: String?
    public let pExpiresAt: Date?
    public let pTransferable: Bool?
    public let pConditions: String?
    public let pVisibility: String?
    public let pMetadata: [String: RPCJSONValue]?
    public let pClientId: String?

    enum CodingKeys: String, CodingKey {
        case pGroupId            = "p_group_id"
        case pName               = "p_name"
        case pRightKind          = "p_right_kind"
        case pHolderMembershipId = "p_holder_membership_id"
        case pDescription        = "p_description"
        case pExpiresAt          = "p_expires_at"
        case pTransferable       = "p_transferable"
        case pConditions         = "p_conditions"
        case pVisibility         = "p_visibility"
        case pMetadata           = "p_metadata"
        case pClientId           = "p_client_id"
    }

    public init(
        groupId: UUID,
        name: String,
        rightKind: String = "access",
        holderMembershipId: UUID? = nil,
        description: String? = nil,
        expiresAt: Date? = nil,
        transferable: Bool? = nil,
        conditions: String? = nil,
        visibility: String? = nil,
        metadata: [String: RPCJSONValue]? = nil,
        clientId: String? = nil
    ) {
        self.pGroupId = groupId
        self.pName = name
        self.pRightKind = rightKind
        self.pHolderMembershipId = holderMembershipId
        self.pDescription = description
        self.pExpiresAt = expiresAt
        self.pTransferable = transferable
        self.pConditions = conditions
        self.pVisibility = visibility
        self.pMetadata = metadata
        self.pClientId = clientId
    }
}
