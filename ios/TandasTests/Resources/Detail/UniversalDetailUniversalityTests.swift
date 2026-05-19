import Testing
import Foundation

/// Doctrinal invariant tests for the v2 Universal Resource Detail surface.
///
/// The founder approved direction: "The view does NOT branch on
/// resource.resourceType. Type metadata flows through IdentityRibbon,
/// the per-type logic lives in builders/resolvers, the view stays type-
/// agnostic." These tests grep the on-disk source files to enforce that
/// promise — a future refactor that silently re-introduces a switch on
/// resource_type inside the view body will fail this suite.
@Suite("Universal Resource Detail v2 — universality invariants")
struct UniversalDetailUniversalityTests {

    private static let repoRoot = "/Users/jj/code/tandas"
    private static let viewPath = "\(repoRoot)/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/UniversalResourceDetailView.swift"
    private static let blocksDir = "\(repoRoot)/ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/Detail/Blocks"

    @Test("UniversalResourceDetailView body does not branch on resource_type")
    func viewBodyHasNoTypeBranching() throws {
        let src = try String(contentsOfFile: Self.viewPath, encoding: .utf8)
        // Strip block + line comments so doc/spec references in headers
        // don't trip the invariant. The remaining body is what compiles.
        let code = Self.stripComments(src)
        #expect(!code.contains("resource.resourceType"),
                "UniversalResourceDetailView must not branch on resource.resourceType in code")
        #expect(!code.contains("switch source.resourceType"),
                "UniversalResourceDetailView must not switch on resource type")
    }

    @Test("Blocks/ directory has no per-type branching")
    func blocksDirectoryHasNoTypeBranching() throws {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(atPath: Self.blocksDir)
        for file in urls where file.hasSuffix(".swift") {
            let path = "\(Self.blocksDir)/\(file)"
            let src = try String(contentsOfFile: path, encoding: .utf8)
            let code = Self.stripComments(src)
            #expect(!code.contains("resource.resourceType"),
                    "\(file): Blocks/ files must not branch on resource.resourceType")
            #expect(!code.contains("switch source.resourceType"),
                    "\(file): Blocks/ files must not switch on resource type")
        }
    }

    @Test("UniversalResourceDetailView body has no sticky footer (safeAreaInset)")
    func noStickyFooter() throws {
        let src = try String(contentsOfFile: Self.viewPath, encoding: .utf8)
        let code = Self.stripComments(src)
        #expect(!code.contains("safeAreaInset"),
                "Primary action must render inline in StateHero, not as a sticky footer (doctrine §3)")
    }

    @Test("UniversalResourceDetailView body has no segmented control / TabView")
    func noTabsInView() throws {
        let src = try String(contentsOfFile: Self.viewPath, encoding: .utf8)
        let code = Self.stripComments(src)
        #expect(!code.contains("RuulSegmentedControl"),
                "No segmented control — single vertical scroll only (doctrine §0)")
        #expect(!code.contains("TabView"),
                "No TabView — single vertical scroll only (doctrine §0)")
    }

    // MARK: - Helper

    /// Removes `//` line comments and `/* */` block comments so doctrine
    /// references in doc comments don't trigger false positives. Naive
    /// implementation — fine for Swift source where strings rarely
    /// contain `//` outside of URLs (URLs use https://, not //).
    private static func stripComments(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var inBlockComment = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i) < source.endIndex
                ? source[source.index(after: i)]
                : Character(" ")
            if inBlockComment {
                if c == "*" && next == "/" {
                    inBlockComment = false
                    i = source.index(i, offsetBy: 2)
                    continue
                }
                i = source.index(after: i)
                continue
            }
            if c == "/" && next == "*" {
                inBlockComment = true
                i = source.index(i, offsetBy: 2)
                continue
            }
            if c == "/" && next == "/" {
                // Skip to end of line.
                while i < source.endIndex && source[i] != "\n" {
                    i = source.index(after: i)
                }
                continue
            }
            out.append(c)
            i = source.index(after: i)
        }
        return out
    }
}
