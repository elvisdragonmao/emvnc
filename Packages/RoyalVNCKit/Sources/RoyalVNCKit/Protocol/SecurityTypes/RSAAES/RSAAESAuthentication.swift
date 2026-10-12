// emvnc fork addition: RSA-AES / RSA-AES-256 security types (RealVNC "RA2", also implemented by TigerVNC,
// neatvnc/wayvnc and others). Spec: https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#rsa-aes-security-type

import Foundation
import CryptoKit
import Security

extension VNCConnection {
    func performRSAAESAuthentication(securityType: VNCProtocol.SecurityType) async throws {
        let uses256 = securityType == .rsaAES256 || securityType == .rsaAES256Unencrypted
        let keepsEncryption = securityType == .rsaAES || securityType == .rsaAES256

        // 1. Server public key
        let serverKeyBits = Int(try await connection.readUInt32())

        guard (RA2PublicKey.minimumBitLength...RA2PublicKey.maximumBitLength).contains(serverKeyBits) else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Unsupported server key length (\(serverKeyBits) bits)."))
        }

        let serverKeyBytes = (serverKeyBits + 7) / 8
        let serverModulus = try await connection.readBuffered(length: serverKeyBytes)
        let serverExponent = try await connection.readBuffered(length: serverKeyBytes)

        let serverKey = RA2PublicKey(bitLength: serverKeyBits,
                                     modulus: [UInt8](serverModulus),
                                     exponent: [UInt8](serverExponent))

        var serverKeyWire = Data(capacity: 4 + serverKeyBytes * 2)
        serverKeyWire.append(UInt32(serverKeyBits), bigEndian: true)
        serverKeyWire.append(serverModulus)
        serverKeyWire.append(serverExponent)

        try await verifyServerIdentity(serverKeyWire)

        // 2. Client public key
        let clientKeyPair = try RA2ClientKeyPair.generate()
        let clientKeyWire = clientKeyPair.publicKey.wireRepresentation

        try await connection.write(data: clientKeyWire)

        // 3. Server random, encrypted with our public key
        let encryptedServerRandomLength = Int(try await connection.readUInt16())

        guard encryptedServerRandomLength == clientKeyPair.publicKey.byteLength else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Unexpected server random length."))
        }

        let encryptedServerRandom = try await connection.readBuffered(length: encryptedServerRandomLength)
        let serverRandom = try clientKeyPair.decrypt(encryptedServerRandom)

        // 4. Client random, encrypted with the server's public key (same size as the server's random)
        let randomLength = serverRandom.count

        guard randomLength == 16 || randomLength == 32 else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Unexpected server random size."))
        }

        var clientRandomBytes = [UInt8](repeating: 0, count: randomLength)

        guard SecRandomCopyBytes(kSecRandomDefault, randomLength, &clientRandomBytes) == errSecSuccess else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Failed to generate random bytes."))
        }

        let clientRandom = Data(clientRandomBytes)
        let encryptedClientRandom = try serverKey.encrypt(clientRandom)

        var clientRandomMessage = Data(capacity: 2 + encryptedClientRandom.count)
        clientRandomMessage.append(UInt16(encryptedClientRandom.count), bigEndian: true)
        clientRandomMessage.append(encryptedClientRandom)

        try await connection.write(data: clientRandomMessage)

        // 5. Session keys; everything from here on is AES-EAX framed
        let hash: (Data) -> Data = uses256
            ? { Data(SHA256.hash(data: $0)) }
            : { Data(Insecure.SHA1.hash(data: $0)) }

        let keyLength = uses256 ? 32 : 16
        let clientSessionKey = hash(serverRandom + clientRandom).prefix(keyLength)
        let serverSessionKey = hash(clientRandom + serverRandom).prefix(keyLength)

        guard let sendCipher = RA2Cipher(key: Data(clientSessionKey)),
              let receiveCipher = RA2Cipher(key: Data(serverSessionKey)) else {
            throw VNCError.authentication(.encryptionFailed)
        }

        connection.enableEncryption(sendCipher: sendCipher,
                                    receiveCipher: receiveCipher)

        // 6. Hash exchange binds both public keys to the session
        let expectedServerHash = hash(serverKeyWire + clientKeyWire)
        let receivedServerHash = try await connection.readBuffered(length: expectedServerHash.count)

        guard receivedServerHash == expectedServerHash else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Server hash mismatch."))
        }

        try await connection.write(data: hash(clientKeyWire + serverKeyWire))

        // 7. Subtype: 1 = username + password, 2 = password only
        let subtype = try await connection.readUInt8()

        let username: String
        let password: String

        switch subtype {
            case 1:
                let credential = try await askDelegateForUsernamePasswordCredential(authenticationType: .rsaAESUsernamePassword)
                username = credential.username
                password = credential.password
            case 2:
                let credential = try await askDelegateForPasswordCredential(authenticationType: .rsaAESPassword)
                username = ""
                password = credential.password
            default:
                throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Unknown credential subtype \(subtype)."))
        }

        let usernameData = Data(username.utf8)
        let passwordData = Data(password.utf8)

        guard usernameData.count <= 255, passwordData.count <= 255 else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Username or password is longer than 255 bytes."))
        }

        var credentials = Data(capacity: 2 + usernameData.count + passwordData.count)
        credentials.append(UInt8(usernameData.count))
        credentials.append(usernameData)
        credentials.append(UInt8(passwordData.count))
        credentials.append(passwordData)

        try await connection.write(data: credentials)

        credentials.resetBytes(in: 0..<credentials.count)

        if !keepsEncryption {
            connection.disableEncryption()
        }
    }

    private func verifyServerIdentity(_ serverKeyWire: Data) async throws {
        let fingerprint = SHA256.hash(data: serverKeyWire)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")

        state.serverKeyFingerprint = fingerprint

        guard let extendedDelegate else {
            return
        }

        let trusted = await withCheckedContinuation { continuation in
            extendedDelegate.connection(self,
                                        shouldTrustServerKeyWithFingerprint: fingerprint) { trusted in
                continuation.resume(returning: trusted)
            }
        }

        guard trusted else {
            throw VNCError.authentication(.serverIdentityRejected)
        }
    }
}
