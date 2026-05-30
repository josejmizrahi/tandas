import Foundation

/// V3 — balance del fondo común del grupo, devuelto por
/// `group_pool_balance(p_group_id)`. Doctrina doctrine_shared_money:
/// el pool crece por contributions + settlements de multas; decrece
/// por payouts. Los expenses individuales NO tocan el pool (se
/// materializan como peer-to-peer obligations).
public struct GroupPoolBalance: Decodable, Sendable, Hashable {
    public let groupId: UUID
    public let contributionsIn: Decimal
    public let settlementsIn: Decimal
    public let payoutsOut: Decimal
    public let reversalsNet: Decimal
    public let net: Decimal
    public let unit: String

    enum CodingKeys: String, CodingKey {
        case groupId         = "group_id"
        case contributionsIn = "contributions_in"
        case settlementsIn   = "settlements_in"
        case payoutsOut      = "payouts_out"
        case reversalsNet    = "reversals_net"
        case net
        case unit
    }

    public init(
        groupId: UUID,
        contributionsIn: Decimal,
        settlementsIn: Decimal,
        payoutsOut: Decimal,
        reversalsNet: Decimal,
        net: Decimal,
        unit: String
    ) {
        self.groupId = groupId
        self.contributionsIn = contributionsIn
        self.settlementsIn = settlementsIn
        self.payoutsOut = payoutsOut
        self.reversalsNet = reversalsNet
        self.net = net
        self.unit = unit
    }
}
