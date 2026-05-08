import Foundation
import RuulCore

/// **Deprecated.** Use `RuulCore.Resource` directly. This typealias
/// preserves source compatibility for callers that haven't migrated.
/// Removed in a follow-up cleanup once all references are gone.
@available(*, deprecated, renamed: "Resource", message: "Use RuulCore.Resource directly")
public typealias ResourceProtocol = Resource
