// emvnc fork addition: RSA helpers for the RSA-AES (RA2) security types, backed by Security.framework.

import Foundation
import Security

/// An RSA public key in the RA2 wire format: U32 key length in bits, modulus, public exponent
/// (both big-endian and padded to ceil(bits / 8) bytes).
struct RA2PublicKey {
    let bitLength: Int
    let modulus: [UInt8]
    let exponent: [UInt8]

    static let minimumBitLength = 1024
    static let maximumBitLength = 8192

    var byteLength: Int { (bitLength + 7) / 8 }

    /// The serialized key, used both on the wire and as input to the session hashes.
    var wireRepresentation: Data {
        var data = Data(capacity: 4 + byteLength * 2)
        data.append(UInt32(bitLength), bigEndian: true)
        data.append(contentsOf: Self.leftPad(modulus, to: byteLength))
        data.append(contentsOf: Self.leftPad(exponent, to: byteLength))

        return data
    }

    /// PKCS#1 RSAPublicKey DER, the format `SecKeyCreateWithData` expects for RSA public keys.
    var pkcs1DER: Data {
        DER.sequence(DER.integer(modulus) + DER.integer(exponent))
    }

    static func leftPad(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        let trimmed = Array(bytes.drop(while: { $0 == 0 }))

        guard trimmed.count < length else {
            return Array(trimmed.suffix(length))
        }

        return [UInt8](repeating: 0, count: length - trimmed.count) + trimmed
    }
}

struct RA2ClientKeyPair {
    let privateKey: SecKey
    let publicKey: RA2PublicKey

    static func generate(bitLength: Int = 2048) throws -> Self {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bitLength,
            kSecAttrIsPermanent: false
        ]

        var error: Unmanaged<CFError>?

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let secPublicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(secPublicKey, &error) as Data?,
              let (modulus, exponent) = DER.parseRSAPublicKey(der) else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Failed to generate the client RSA key."))
        }

        let publicKey = RA2PublicKey(bitLength: bitLength,
                                     modulus: modulus,
                                     exponent: exponent)

        return .init(privateKey: privateKey,
                     publicKey: publicKey)
    }

    func decrypt(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?

        guard let plaintext = SecKeyCreateDecryptedData(privateKey,
                                                        .rsaEncryptionPKCS1,
                                                        data as CFData,
                                                        &error) as Data? else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Failed to decrypt the server random."))
        }

        return plaintext
    }
}

extension RA2PublicKey {
    func encrypt(_ data: Data) throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: bitLength
        ]

        var error: Unmanaged<CFError>?

        guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &error),
              let ciphertext = SecKeyCreateEncryptedData(key,
                                                         .rsaEncryptionPKCS1,
                                                         data as CFData,
                                                         &error) as Data? else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Failed to encrypt with the server's RSA key."))
        }

        return Data(Self.leftPad([UInt8](ciphertext), to: byteLength))
    }
}

// MARK: - Minimal DER
enum DER {
    static func length(_ length: Int) -> [UInt8] {
        guard length >= 0x80 else {
            return [ UInt8(length) ]
        }

        var bytes = [UInt8]()
        var value = length

        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }

        return [ 0x80 | UInt8(bytes.count) ] + bytes
    }

    static func integer(_ bigEndianBytes: [UInt8]) -> [UInt8] {
        var value = Array(bigEndianBytes.drop(while: { $0 == 0 }))

        if value.isEmpty {
            value = [ 0 ]
        }

        if value[0] & 0x80 != 0 {
            value.insert(0, at: 0)
        }

        return [ 0x02 ] + length(value.count) + value
    }

    static func sequence(_ contents: [UInt8]) -> Data {
        Data([ 0x30 ] + length(contents.count) + contents)
    }

    /// Parses a PKCS#1 RSAPublicKey: SEQUENCE { modulus INTEGER, publicExponent INTEGER }.
    static func parseRSAPublicKey(_ der: Data) -> (modulus: [UInt8], exponent: [UInt8])? {
        var reader = Reader(bytes: [UInt8](der))

        guard reader.readTag() == 0x30,
              reader.readLength() != nil,
              reader.readTag() == 0x02,
              let modulusLength = reader.readLength(),
              let modulus = reader.read(modulusLength),
              reader.readTag() == 0x02,
              let exponentLength = reader.readLength(),
              let exponent = reader.read(exponentLength) else {
            return nil
        }

        return (Array(modulus.drop(while: { $0 == 0 })),
                Array(exponent.drop(while: { $0 == 0 })))
    }

    struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func readTag() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }

            return bytes[index]
        }

        mutating func readLength() -> Int? {
            guard let first = readTag() else { return nil }

            guard first & 0x80 != 0 else {
                return Int(first)
            }

            let count = Int(first & 0x7f)

            guard count > 0, count <= 4, let lengthBytes = read(count) else {
                return nil
            }

            return lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        }

        mutating func read(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }

            return bytes[index..<(index + count)]
        }
    }
}
