import Foundation

/// How a check-in was registered. Maps to
/// `event_attendance.check_in_method` text column.
enum CheckInMethod: String, Codable, Sendable, Hashable {
    case selfMethod = "self"      // guest tapped "Ya llegué" themselves
    case qrScan     = "qr_scan"   // host scanned guest's QR
    case hostMarked = "host_marked" // host toggled the row manually

    var displayName: String {
        switch self {
        case .selfMethod: return "Self"
        case .qrScan:     return "QR"
        case .hostMarked: return "Host"
        }
    }
}
