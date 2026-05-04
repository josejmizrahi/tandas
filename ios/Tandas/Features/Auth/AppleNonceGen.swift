import Foundation
import CryptoKit

/// Shared helper for Sign In with Apple nonce generation. The raw nonce is
/// included in the Supabase signInWithIdToken call; the SHA-256 hashed nonce
/// is what gets passed to ASAuthorizationAppleIDRequest.
enum AppleNonceGen {
    static func generate() -> String {
        let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        return String((0..<32).map { _ in chars.randomElement()! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
