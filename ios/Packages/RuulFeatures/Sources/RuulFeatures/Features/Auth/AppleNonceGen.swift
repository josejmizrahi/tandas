import Foundation
import CryptoKit
import RuulCore
import RuulUI

/// Shared helper for Sign In with Apple nonce generation. The raw nonce is
/// included in the Supabase signInWithIdToken call; the SHA-256 hashed nonce
/// is what gets passed to ASAuthorizationAppleIDRequest.
public enum AppleNonceGen {
    public static func generate() -> String {
        let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        return String((0..<32).map { _ in chars.randomElement()! })
    }

    public static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
