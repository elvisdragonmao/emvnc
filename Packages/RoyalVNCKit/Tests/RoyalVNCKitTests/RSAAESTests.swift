import Foundation
import Testing
@testable import RoyalVNCKit

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex

    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }

    return data
}

private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Suite("AES-EAX")
struct AESEAXTests {
    // Test vectors from the EAX paper (Bellare, Rogaway, Wagner), cross-checked with PyCryptodome
    @Test(arguments: [
        ("233952DEE4D5ED5F9B9C6D6FF80FF478", "62EC67F9C3A4A407FCB2A8C49031A8B3", "6BFB914FD07EAE6B", "",
         "e037830e8389f27b025a2d6527e79d01"),
        ("91945D3F4DCBEE0BF45EF52255F095A4", "BECAF043B0A23D843194BA972C66DEBD", "FA3BFD4806EB53FA", "F7FB",
         "19dd5c4c9331049d0bdab0277408f67967e5")
    ])
    func paperVectors(key: String, nonce: String, header: String, message: String, expected: String) throws {
        let eax = try #require(AESEAX(key: hex(key)))
        let (ciphertext, tag) = try #require(eax.seal(hex(message), nonce: hex(nonce), header: hex(header)))

        #expect(toHex(ciphertext + tag) == expected)
        #expect(eax.open(ciphertext, nonce: hex(nonce), header: hex(header), tag: tag) == hex(message))
    }

    /// RA2-style inputs: 16-byte little-endian counter nonce, big-endian U16 length as the header.
    /// Expected values generated with PyCryptodome's AES.MODE_EAX.
    @Test(arguments: [
        (16, 0, "hello rfb", "10f92a33a7a6546b4f", "6aad5fc2065d90fb691ff9e2ab4b92e7"),
        (32, 0, "hello rfb", "bd3889c9cb89a556ec", "5864910bc44a740da8924c57d379a122"),
        (16, 300, "", "", "8bc4e5294cdb42f5ea0f58f24a162d7e"),
        (32, 300, "", "", "1bd79f888f40b26b9117438a3c448aab")
    ])
    func ra2Vectors(keyLength: Int, counter: Int, message: String, expectedCiphertext: String, expectedTag: String) throws {
        let eax = try #require(AESEAX(key: Data((0..<keyLength).map { UInt8($0) })))
        var nonce = Data(count: 16)
        nonce[0] = UInt8(counter & 0xff)
        nonce[1] = UInt8(counter >> 8)

        let plaintext = Data(message.utf8)
        let header = Data([ UInt8(plaintext.count >> 8), UInt8(plaintext.count & 0xff) ])
        let (ciphertext, tag) = try #require(eax.seal(plaintext, nonce: nonce, header: header))

        #expect(toHex(ciphertext) == expectedCiphertext)
        #expect(toHex(tag) == expectedTag)
    }

    @Test(arguments: [ (16, "266a24c650afa3e5e00e38967be0df7c", "f3916cab905105ffd42ac955732f215a"),
                       (32, "b42c8028ae2ff523344f42a5314b09a1", "c777aab85dcc5bd4de61dcea0f8f42f1") ])
    func multiBlockMessage(keyLength: Int, expectedTag: String, expectedCiphertextSuffix: String) throws {
        let eax = try #require(AESEAX(key: Data((0..<keyLength).map { UInt8($0) })))
        let plaintext = Data((0..<1000).map { UInt8(($0 * 7) % 256) })
        var nonce = Data(count: 16)
        nonce[0] = 1
        let header = Data([ 0x03, 0xe8 ])

        let (ciphertext, tag) = try #require(eax.seal(plaintext, nonce: nonce, header: header))

        #expect(toHex(tag) == expectedTag)
        #expect(toHex(ciphertext.suffix(16)) == expectedCiphertextSuffix)
    }

    @Test func tamperingIsDetected() throws {
        let eax = try #require(AESEAX(key: Data(repeating: 7, count: 16)))
        let nonce = Data(count: 16)
        let header = Data([ 0, 4 ])
        let (ciphertext, tag) = try #require(eax.seal(Data("data".utf8), nonce: nonce, header: header))

        var flipped = ciphertext
        flipped[0] ^= 1

        #expect(eax.open(flipped, nonce: nonce, header: header, tag: tag) == nil)
        #expect(eax.open(ciphertext, nonce: nonce, header: Data([ 0, 5 ]), tag: tag) == nil)
    }

    @Test func rejectsInvalidKeySizes() {
        #expect(AESEAX(key: Data(count: 24)) == nil)
        #expect(AESEAX(key: Data(count: 15)) == nil)
    }
}

@Suite("RA2 record layer")
struct RA2CipherTests {
    @Test func firstRecordMatchesTheReferenceEncoding() throws {
        let sender = try #require(RA2Cipher(key: Data((0..<16).map { UInt8($0) })))
        let record = try sender.seal(Data("hello rfb".utf8))

        #expect(toHex(record) == "0009" + "10f92a33a7a6546b4f" + "6aad5fc2065d90fb691ff9e2ab4b92e7")
    }

    @Test func recordsRoundTripWithAdvancingNonces() throws {
        let key = Data((0..<32).map { UInt8($0 * 3) })
        let sender = try #require(RA2Cipher(key: key))
        let receiver = try #require(RA2Cipher(key: key))

        for message in [ "first", "second", "", "third message" ] {
            let record = try sender.seal(Data(message.utf8))
            let length = Int(record[0]) << 8 | Int(record[1])
            let opened = try receiver.open(header: record.prefix(2),
                                           ciphertext: record.dropFirst(2).prefix(length),
                                           tag: record.suffix(16))

            #expect(String(decoding: opened, as: UTF8.self) == message)
        }
    }

    @Test func outOfOrderRecordsFailAuthentication() throws {
        let key = Data(repeating: 1, count: 16)
        let sender = try #require(RA2Cipher(key: key))
        let receiver = try #require(RA2Cipher(key: key))

        _ = try sender.seal(Data("skipped".utf8))
        let second = try sender.seal(Data("second".utf8))

        #expect(throws: VNCError.self) {
            _ = try receiver.open(header: second.prefix(2), ciphertext: second.dropFirst(2).dropLast(16), tag: second.suffix(16))
        }
    }

    @Test func largeWritesAreSplitIntoRecords() throws {
        let sender = try #require(RA2Cipher(key: Data(repeating: 2, count: 16)))
        let payload = Data(repeating: 0xab, count: 70_000)
        let sealed = try sender.seal(payload)

        // 65535 + 4465 bytes of payload, each record adding 2 bytes of header and 16 bytes of MAC
        #expect(sealed.count == 70_000 + 2 * 18)
        #expect(sealed.prefix(2) == Data([ 0xff, 0xff ]))
    }
}

@Suite("RSA keys")
struct RSAKeyTests {
    @Test func derRoundTrip() throws {
        let modulus: [UInt8] = [ 0xc3 ] + Array(repeating: 0x11, count: 255)
        let exponent: [UInt8] = [ 0x01, 0x00, 0x01 ]
        let key = RA2PublicKey(bitLength: 2048, modulus: modulus, exponent: exponent)
        let parsed = try #require(DER.parseRSAPublicKey(key.pkcs1DER))

        #expect(parsed.modulus == modulus)
        #expect(parsed.exponent == exponent)
    }

    @Test func wireFormatPadsBothNumbers() {
        let key = RA2PublicKey(bitLength: 1024, modulus: Array(repeating: 0xff, count: 128), exponent: [ 1, 0, 1 ])
        let wire = key.wireRepresentation

        #expect(wire.count == 4 + 128 * 2)
        #expect(wire.prefix(4) == Data([ 0, 0, 4, 0 ]))
        #expect(wire.suffix(3) == Data([ 1, 0, 1 ]))
        #expect(wire[4 + 128] == 0)
    }

    @Test func generatedKeyEncryptsAndDecrypts() throws {
        let pair = try RA2ClientKeyPair.generate(bitLength: 2048)
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        #expect(pair.publicKey.modulus.count == 256)
        #expect(pair.publicKey.wireRepresentation.count == 4 + 512)

        let encrypted = try pair.publicKey.encrypt(random)

        #expect(encrypted.count == 256)
        #expect(try pair.decrypt(encrypted) == random)
    }
}

@Suite("Extended Clipboard")
struct ExtendedClipboardTests {
    typealias Clipboard = VNCProtocol.ExtendedClipboard

    @Test func textUsesCRLFAndATerminatingNul() {
        let encoded = Clipboard.encodeText("a\nb\r\nc")

        #expect(encoded == Data("a\r\nb\r\nc".utf8) + Data([ 0 ]))
        #expect(Clipboard.decodeText(encoded) == "a\nb\nc")
    }

    @Test func provideRoundTripsUnicode() throws {
        let text = "剪貼簿 ✓\n第二行 🚀"
        let message = Clipboard.provide(text: text)

        #expect(message.flags == Clipboard.Action.provide.rawValue | Clipboard.Format.text.rawValue)

        guard case .provide(let decoded) = try Clipboard.parse(flags: message.flags, payload: message.payload) else {
            Issue.record("Expected provide")
            return
        }

        #expect(decoded == text)
    }

    @Test func clientMessageUsesNegativeLength() {
        let message = Clipboard.notify(hasText: true)
        let data = message.data

        #expect(data[0] == 6)
        #expect(data.subdata(in: 4..<8) == Data([ 0xff, 0xff, 0xff, 0xfc ]))
        #expect(data.subdata(in: 8..<12) == Data([ 0x08, 0x00, 0x00, 0x01 ]))
    }

    @Test func capsAreParsedPerFormat() throws {
        let flags = Clipboard.Action.caps.rawValue | Clipboard.Action.provide.rawValue | Clipboard.Action.notify.rawValue
            | Clipboard.Format.text.rawValue | Clipboard.Format.rtf.rawValue
        var sizes = Data()
        sizes.append(UInt32(20 * 1024 * 1024), bigEndian: true)
        sizes.append(UInt32(0), bigEndian: true)

        guard case .caps(let formats, let actions, let textSize) = try Clipboard.parse(flags: flags, payload: sizes) else {
            Issue.record("Expected caps")
            return
        }

        #expect(formats.contains(.text))
        #expect(actions.contains(.provide))
        #expect(textSize == 20 * 1024 * 1024)
    }

    @Test func requestPeekAndNotify() throws {
        guard case .request(let formats) = try Clipboard.parse(flags: Clipboard.Action.request.rawValue | 1, payload: Data()) else {
            Issue.record("Expected request")
            return
        }

        #expect(formats.contains(.text))

        guard case .peek = try Clipboard.parse(flags: Clipboard.Action.peek.rawValue, payload: Data()) else {
            Issue.record("Expected peek")
            return
        }
    }

    @Test func corruptProvidePayloadIsAnError() {
        #expect(throws: (any Error).self) {
            _ = try Clipboard.parse(flags: Clipboard.Action.provide.rawValue | 1, payload: Data([ 1, 2, 3 ]))
        }
    }

    @Test func standardCutTextDecoding() {
        #expect(VNCProtocol.ServerCutText.decodeStandardText(Data([ 0x63, 0x61, 0x66, 0xe9 ])) == "café")
        #expect(VNCProtocol.ServerCutText.decodeStandardText(Data("café ✓".utf8)) == "café ✓")
        #expect(VNCProtocol.ServerCutText.decodeStandardText(Data("abc".utf8) + Data([ 0, 0x41 ])) == "abc")
    }
}

@Suite("Security type negotiation")
struct SecurityTypeTests {
    @Test func defaultPreferenceOnlyContainsImplementedTypes() {
        #expect(VNCSecurityTypeInfo.defaultPreference.allSatisfy(VNCSecurityTypeInfo.implemented.contains))
        #expect(!VNCSecurityTypeInfo.implemented.contains(16)) // Tight is not implemented
        #expect(!VNCSecurityTypeInfo.implemented.contains(19)) // VeNCrypt is not implemented
    }

    @Test func onlyFullRSAAESEncryptsTheSession() {
        #expect(VNCSecurityTypeInfo.encryptsSession(5))
        #expect(VNCSecurityTypeInfo.encryptsSession(129))
        #expect(!VNCSecurityTypeInfo.encryptsSession(6))
        #expect(!VNCSecurityTypeInfo.encryptsSession(2))
        #expect(!VNCSecurityTypeInfo.encryptsSession(30))
    }

    @Test func names() {
        #expect(VNCSecurityTypeInfo.name(of: 19) == "VeNCrypt")
        #expect(VNCSecurityTypeInfo.name(of: 30) == "Apple Remote Desktop")
        #expect(VNCSecurityTypeInfo.name(of: 250) == "Type 250")
    }
}

@Suite("Pointer input")
struct PointerInputTests {
    @Test func everyWheelStepIsAPressAndARelease() {
        let settings = VNCConnection.Settings(isDebugLoggingEnabled: false, hostname: "localhost", port: 5900,
                                              isShared: true, isScalingEnabled: false, useDisplayLink: false,
                                              inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
                                              isClipboardRedirectionEnabled: false, colorDepth: .depth24Bit,
                                              frameEncodings: [VNCFrameEncodingType]())
        let connection = VNCConnection(settings: settings)

        connection.mouseWheel(.up, x: 10, y: 10, steps: 3)

        var masks: [UInt8] = []

        while let message = connection.clientToServerMessageQueue.dequeue() {
            if let event = message as? VNCProtocol.PointerEvent {
                masks.append(event.buttonMask)
            }
        }

        // Button 4 (bit 3) down, then up, for each step
        #expect(masks == [ 8, 0, 8, 0, 8, 0 ])
    }
}
