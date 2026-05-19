import Foundation

/// The seven canonical visual shapes a `CapabilityBlock` can take.
/// Limited on purpose: any new capability MUST fit one of these or
/// trigger a doctrine review before adding an eighth.
///
/// Renderer mapping (see `CapabilityBlockView`):
///   summaryFacts — 1-3 key/value rows + verb (Rotation, Recurrence, Eligibility, …)
///   avatarQueue  — horizontal avatar strip with order semantics (RSVP, Rotation queue, Custody chain)
///   mediaStrip   — thumbnails (Evidence, Asset photos)
///   balance      — large currency number + delta (Fund balance, Wallet balance)
///   progress     — X-of-Y bar (Vote tally, Check-in, Quota)
///   timelineMini — 2-3 dated events (Appeals, Agreements lifecycle)
///   emptyPrompt  — slim one-line CTA when the capability is enabled but empty
public enum BlockLayoutKind: String, Sendable, Hashable, CaseIterable {
    case summaryFacts
    case avatarQueue
    case mediaStrip
    case balance
    case progress
    case timelineMini
    case emptyPrompt
}
