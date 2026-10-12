// emvnc fork addition: AES-EAX authenticated encryption used by the RSA-AES (RA2) security types.
// EAX = CTR encryption + OMAC (CMAC) authentication, see Bellare, Rogaway, Wagner (2004).

import Foundation
import CommonCrypto

/// AES in EAX mode with a 16-byte tag. Not thread-safe; use one instance per direction.
final class AESEAX {
    static let blockSize = kCCBlockSizeAES128
    static let tagSize = 16

    private let key: Data
    private let k1: [UInt8]
    private let k2: [UInt8]

    init?(key: Data) {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            return nil
        }

        self.key = key

        guard let l = Self.ecbEncrypt(key: key, block: [UInt8](repeating: 0, count: Self.blockSize)) else {
            return nil
        }

        let k1 = Self.double(l)
        self.k1 = k1
        self.k2 = Self.double(k1)
    }

    func seal(_ plaintext: Data, nonce: Data, header: Data) -> (ciphertext: Data, tag: Data)? {
        guard let n = omac(tweak: 0, nonce),
              let h = omac(tweak: 1, header),
              let ciphertext = ctr(plaintext, iv: n),
              let c = omac(tweak: 2, ciphertext) else {
            return nil
        }

        var tag = [UInt8](repeating: 0, count: Self.tagSize)

        for i in 0..<Self.tagSize {
            tag[i] = n[i] ^ h[i] ^ c[i]
        }

        return (ciphertext, Data(tag))
    }

    func open(_ ciphertext: Data, nonce: Data, header: Data, tag: Data) -> Data? {
        guard tag.count == Self.tagSize,
              let n = omac(tweak: 0, nonce),
              let h = omac(tweak: 1, header),
              let c = omac(tweak: 2, ciphertext) else {
            return nil
        }

        // Constant-time tag comparison
        var difference: UInt8 = 0
        let tagBytes = [UInt8](tag)

        for i in 0..<Self.tagSize {
            difference |= (n[i] ^ h[i] ^ c[i]) ^ tagBytes[i]
        }

        guard difference == 0 else {
            return nil
        }

        return ctr(ciphertext, iv: n)
    }
}

// MARK: - Primitives
extension AESEAX {
    /// OMAC^t(M) = CMAC([t]_n || M)
    func omac(tweak: UInt8, _ message: Data) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.blockSize)
        input[Self.blockSize - 1] = tweak
        input.append(contentsOf: message)

        return cmac(input)
    }

    /// CMAC (RFC 4493) computed as the last block of AES-CBC with a zero IV over the subkey-adjusted message.
    func cmac(_ message: [UInt8]) -> [UInt8]? {
        let blockSize = Self.blockSize
        var blocks = message
        let isComplete = !blocks.isEmpty && blocks.count % blockSize == 0

        if !isComplete {
            blocks.append(0x80)

            while blocks.count % blockSize != 0 {
                blocks.append(0)
            }
        }

        let lastBlockStart = blocks.count - blockSize
        let subkey = isComplete ? k1 : k2

        for i in 0..<blockSize {
            blocks[lastBlockStart + i] ^= subkey[i]
        }

        guard let output = Self.crypt(mode: kCCModeCBC,
                                      key: key,
                                      iv: [UInt8](repeating: 0, count: blockSize),
                                      input: blocks) else {
            return nil
        }

        return Array(output[(output.count - blockSize)...])
    }

    func ctr(_ input: Data, iv: [UInt8]) -> Data? {
        guard !input.isEmpty else {
            return Data()
        }

        guard let output = Self.crypt(mode: kCCModeCTR,
                                      key: key,
                                      iv: iv,
                                      input: [UInt8](input)) else {
            return nil
        }

        return Data(output)
    }

    static func double(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: block.count)
        var carry: UInt8 = 0

        for i in stride(from: block.count - 1, through: 0, by: -1) {
            result[i] = (block[i] << 1) | carry
            carry = block[i] >> 7
        }

        if carry != 0 {
            result[block.count - 1] ^= 0x87
        }

        return result
    }

    static func ecbEncrypt(key: Data, block: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: block.count)
        var moved = 0

        let status = key.withUnsafeBytes { keyBytes in
            CCCrypt(CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, key.count,
                    nil,
                    block, block.count,
                    &output, output.count,
                    &moved)
        }

        guard status == kCCSuccess, moved == block.count else {
            return nil
        }

        return output
    }

    static func crypt(mode: Int, key: Data, iv: [UInt8], input: [UInt8]) -> [UInt8]? {
        var cryptor: CCCryptorRef?

        let createStatus = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                    CCMode(mode),
                                    CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding),
                                    iv,
                                    keyBytes.baseAddress, key.count,
                                    nil, 0, 0,
                                    // CTR uses a big-endian 128-bit counter, which is what EAX specifies
                                    mode == kCCModeCTR ? CCModeOptions(kCCModeOptionCTR_BE) : 0,
                                    &cryptor)
        }

        guard createStatus == kCCSuccess, let cryptor else {
            return nil
        }

        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0

        let updateStatus = CCCryptorUpdate(cryptor,
                                           input, input.count,
                                           &output, output.count,
                                           &moved)

        guard updateStatus == kCCSuccess, moved == input.count else {
            return nil
        }

        return output
    }
}
