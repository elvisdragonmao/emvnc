// emvnc fork addition: a NetworkConnection that can switch to the RA2 (RSA-AES) encrypted record layer
// after the security handshake. Before encryption is enabled it is a transparent pass-through.

#if canImport(Network)
import Foundation
import Dispatch
import Network

/// Per-direction AES-EAX state. The nonce is a 16-byte little-endian message counter starting at zero.
final class RA2Cipher {
    private let eax: AESEAX
    private var counter = [UInt8](repeating: 0, count: 16)

    init?(key: Data) {
        guard let eax = AESEAX(key: key) else { return nil }

        self.eax = eax
    }

    private func nextNonce() -> Data {
        let nonce = Data(counter)

        for i in 0..<counter.count {
            counter[i] &+= 1

            if counter[i] != 0 {
                break
            }
        }

        return nonce
    }

    /// Splits `plaintext` into RA2 records: U16 length, ciphertext, 16-byte MAC.
    func seal(_ plaintext: Data) throws -> Data {
        let maximumRecordLength = Int(UInt16.max)
        var output = Data(capacity: plaintext.count + (plaintext.count / maximumRecordLength + 1) * 18)
        var offset = plaintext.startIndex

        repeat {
            let end = min(offset + maximumRecordLength, plaintext.endIndex)
            let chunk = plaintext[offset..<end]

            var header = Data(capacity: 2)
            header.append(UInt16(chunk.count), bigEndian: true)

            guard let (ciphertext, tag) = eax.seal(Data(chunk), nonce: nextNonce(), header: header) else {
                throw VNCError.authentication(.encryptionFailed)
            }

            output.append(header)
            output.append(ciphertext)
            output.append(tag)

            offset = end
        } while offset < plaintext.endIndex

        return output
    }

    func open(header: Data, ciphertext: Data, tag: Data) throws -> Data {
        guard let plaintext = eax.open(ciphertext, nonce: nextNonce(), header: header, tag: tag) else {
            throw VNCError.authentication(.rsaAESHandshakeFailed(reason: "Message authentication failed (corrupted or tampered data)."))
        }

        return plaintext
    }
}

final class TransportConnection: NetworkConnection {
    private let base: NWConnection
    private let lock = NSLock()

    private var sendCipher: RA2Cipher?
    private var receiveCipher: RA2Cipher?

    private var plaintext = Data()
    private var plaintextOffset = 0

    init(settings: NetworkConnectionSettings) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = settings.connectionTimeout
        tcpOptions.noDelay = true

        // Detect silently dropped connections (sleep, Wi-Fi changes, VPN drops) instead of waiting forever
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.expiredDNSBehavior = .allow
        parameters.serviceClass = .interactiveVideo

        self.base = NWConnection(host: .init(settings.host),
                                 port: .init(rawValue: settings.port)!,
                                 using: parameters)
    }

    var status: NetworkConnectionStatus { base.status }
    var isReady: Bool { base.isReady }

    var isEncrypted: Bool {
        lock.withLock { sendCipher != nil }
    }

    func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
        base.setStatusUpdateHandler(statusUpdateHandler)
    }

    func cancel() {
        base.cancel()
    }

    func start(queue: DispatchQueue) {
        base.start(queue: queue)
    }

    /// Every byte read or written after this call goes through the RA2 record layer.
    func enableEncryption(sendCipher: RA2Cipher, receiveCipher: RA2Cipher) {
        lock.withLock {
            self.sendCipher = sendCipher
            self.receiveCipher = receiveCipher
            self.plaintext = Data()
            self.plaintextOffset = 0
        }
    }

    /// Used by the RA2ne ("unencrypted") variants where only the handshake is protected.
    func disableEncryption() {
        lock.withLock {
            self.sendCipher = nil
            self.receiveCipher = nil
        }
    }
}

extension TransportConnection: NetworkConnectionReading {
    func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
        guard let receiveCipher = lock.withLock({ self.receiveCipher }) else {
            return try await base.read(minimumLength: minimumLength,
                                       maximumLength: maximumLength)
        }

        let required = max(1, minimumLength)

        while availablePlaintextCount < required {
            try await receiveRecord(cipher: receiveCipher)
        }

        return lock.withLock {
            let count = min(maximumLength, plaintext.count - plaintextOffset)
            let start = plaintext.startIndex + plaintextOffset
            let chunk = plaintext.subdata(in: start..<(start + count))

            plaintextOffset += count

            if plaintextOffset == plaintext.count {
                plaintext = Data()
                plaintextOffset = 0
            }

            return chunk
        }
    }

    private var availablePlaintextCount: Int {
        lock.withLock { plaintext.count - plaintextOffset }
    }

    private func receiveRecord(cipher: RA2Cipher) async throws {
        let header = try await base.readBuffered(length: 2)
        let length = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
        let body = try await base.readBuffered(length: length + AESEAX.tagSize)

        let ciphertext = body.prefix(length)
        let tag = body.suffix(AESEAX.tagSize)

        let decrypted = try cipher.open(header: header,
                                        ciphertext: Data(ciphertext),
                                        tag: Data(tag))

        lock.withLock {
            if plaintextOffset > 0 {
                plaintext.removeFirst(plaintextOffset)
                plaintextOffset = 0
            }

            plaintext.append(decrypted)
        }
    }
}

extension TransportConnection: NetworkConnectionWriting {
    func write(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Sealing and enqueueing happen under one lock so record order on the wire matches nonce order,
            // even though the send and receive loops write concurrently.
            lock.lock()

            let payload: Data

            do {
                payload = try sendCipher?.seal(data) ?? data
            } catch {
                lock.unlock()
                continuation.resume(throwing: error)

                return
            }

            base.send(content: payload, completion: .contentProcessed({ error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }))

            lock.unlock()
        }
    }
}
#endif
