#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// emvnc fork: rewritten. Upstream decoded standard messages as Latin-1 only and did not consume the payload
// of extended (negative length) messages, which would desynchronise the stream if a server sent one.
extension VNCProtocol {
    struct ServerCutText: VNCReceivableMessage {
        static let messageType: UInt8 = 3

        /// Upper bound for a standard ServerCutText payload; larger messages are treated as protocol errors.
        static let maximumLength = 64 * 1024 * 1024

        enum Content {
            case text(String)
            case extended(flags: UInt32, payload: Data)
        }

        let messageType: UInt8
        let content: Content
    }
}

extension VNCProtocol.ServerCutText {
    static func receive(connection: NetworkConnectionReading,
                        logger: VNCLogger) async throws -> Self {
        try await connection.readPadding(length: 3)

        let length = Int(try await connection.readInt32())

        if length >= 0 {
            guard length <= maximumLength else {
                throw VNCError.protocol(.invalidData)
            }

            let bytes = try await connection.readBuffered(length: length)

            return .init(messageType: messageType,
                         content: .text(decodeStandardText(bytes)))
        }

        let extendedLength = -length

        guard extendedLength >= 4, extendedLength <= maximumLength else {
            throw VNCError.protocol(.invalidData)
        }

        let flags = try await connection.readUInt32()
        let payload = try await connection.readBuffered(length: extendedLength - 4)

        logger.logDebug("Received extended ServerCutText (flags: \(String(flags, radix: 16)))")

        return .init(messageType: messageType,
                     content: .extended(flags: flags, payload: payload))
    }

    /// The RFB spec mandates ISO 8859-1, but several servers send UTF-8. Bytes that form valid UTF-8 with
    /// non-ASCII content are decoded as UTF-8; everything else as Latin-1. Text is cut at the first NUL.
    static func decodeStandardText(_ bytes: Data) -> String {
        var bytes = bytes

        if let nul = bytes.firstIndex(of: 0) {
            bytes = bytes[..<nul]
        }

        if bytes.contains(where: { $0 >= 0x80 }),
           let utf8 = String(data: bytes, encoding: .utf8) {
            return utf8
        }

        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}
