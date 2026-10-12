import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passwords (SHA-1, 30 s, 6 digits — what Groww's TOTP keys use).
enum TOTP {
    static func code(secret: String, at date: Date = .now, digits: Int = 6, period: TimeInterval = 30) -> String? {
        guard let key = base32Decode(secret) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / period).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = String(binary % modulus)
        return String(repeating: "0", count: max(0, digits - value.count)) + value
    }

    static func base32Decode(_ string: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt32] = [:]
        for (index, character) in alphabet.enumerated() { lookup[character] = UInt32(index) }

        var buffer: UInt32 = 0
        var bits = 0
        var output = Data()
        for character in string.uppercased() where !"= -".contains(character) {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return output.isEmpty ? nil : output
    }
}
