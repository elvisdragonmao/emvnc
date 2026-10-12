// emvnc fork addition: Extended Clipboard pseudo-encoding (UTF-8 clipboard text).
// Spec: https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#extended-clipboard-pseudo-encoding

import Foundation

internal import Z

extension VNCProtocol {
    enum ExtendedClipboard {
        struct Format: OptionSet {
            let rawValue: UInt32

            static let text = Self(rawValue: 1 << 0)
            static let rtf = Self(rawValue: 1 << 1)
            static let html = Self(rawValue: 1 << 2)
            static let dib = Self(rawValue: 1 << 3)
            static let files = Self(rawValue: 1 << 4)

            static let mask: UInt32 = 0x0000_ffff
        }

        struct Action: OptionSet {
            let rawValue: UInt32

            static let caps = Self(rawValue: 1 << 24)
            static let request = Self(rawValue: 1 << 25)
            static let peek = Self(rawValue: 1 << 26)
            static let notify = Self(rawValue: 1 << 27)
            static let provide = Self(rawValue: 1 << 28)

            static let mask: UInt32 = 0xff00_0000
        }

        /// Largest clipboard text the client accepts unsolicited, and the cap for decompressed payloads.
        static let maximumTextSize = 10 * 1024 * 1024
        static let maximumDecompressedSize = 32 * 1024 * 1024

        /// An extended ClientCutText message (negative length).
        struct ClientMessage: VNCSendableMessage {
            let messageType: UInt8 = 6
            let flags: UInt32
            let payload: Data

            var data: Data {
                var data = Data(capacity: 12 + payload.count)
                data.append(messageType)
                data.appendPadding(length: 3)
                data.append(Int32(-(4 + payload.count)), bigEndian: true)
                data.append(flags, bigEndian: true)
                data.append(payload)

                return data
            }

            func send(connection: NetworkConnectionWriting) async throws {
                try await connection.write(data: data)
            }
        }

        enum Incoming {
            case caps(formats: Format, actions: Action, textSize: Int?)
            case request(formats: Format)
            case peek
            case notify(formats: Format)
            case provide(text: String?)
        }

        // MARK: Outgoing
        static func clientCaps() -> ClientMessage {
            let formats: Format = [ .text ]
            let actions: Action = [ .caps, .request, .peek, .notify, .provide ]

            var sizes = Data()
            sizes.append(UInt32(maximumTextSize), bigEndian: true)

            return .init(flags: formats.rawValue | actions.rawValue,
                         payload: sizes)
        }

        static func notify(hasText: Bool) -> ClientMessage {
            let formats: Format = hasText ? [ .text ] : []

            return .init(flags: Action.notify.rawValue | formats.rawValue,
                         payload: .init())
        }

        static func request() -> ClientMessage {
            .init(flags: Action.request.rawValue | Format.text.rawValue,
                  payload: .init())
        }

        static func provide(text: String?) -> ClientMessage {
            guard let text else {
                return .init(flags: Action.provide.rawValue,
                             payload: deflate(Data()) ?? .init())
            }

            let textData = encodeText(text)

            var plain = Data(capacity: 4 + textData.count)
            plain.append(UInt32(textData.count), bigEndian: true)
            plain.append(textData)

            return .init(flags: Action.provide.rawValue | Format.text.rawValue,
                         payload: deflate(plain) ?? .init())
        }

        /// UTF-8 with CRLF line endings and a terminating NUL, as the spec requires.
        static func encodeText(_ text: String) -> Data {
            let normalized = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")

            var data = Data(normalized.utf8)
            data.append(0)

            return data
        }

        static func decodeText(_ data: Data) -> String {
            var bytes = data

            if let nul = bytes.firstIndex(of: 0) {
                bytes = bytes[..<nul]
            }

            let text = String(decoding: bytes, as: UTF8.self)

            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }

        static func encodedTextSize(_ text: String) -> Int {
            encodeText(text).count
        }

        // MARK: Incoming
        static func parse(flags: UInt32, payload: Data) throws -> Incoming {
            let formats = Format(rawValue: flags & Format.mask)
            let actions = Action(rawValue: flags & Action.mask)

            if actions.contains(.caps) {
                // One U32 maximum size per format bit that is set, in bit order
                var textSize: Int?
                var offset = payload.startIndex

                for bit in 0..<16 {
                    let format = Format(rawValue: 1 << UInt32(bit))

                    guard formats.contains(format) else { continue }
                    guard offset + 4 <= payload.endIndex else { break }

                    let size = payload[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }

                    if format == .text {
                        textSize = size
                    }

                    offset += 4
                }

                return .caps(formats: formats, actions: actions, textSize: textSize)
            }

            if actions.contains(.request) {
                return .request(formats: formats)
            }

            if actions.contains(.peek) {
                return .peek
            }

            if actions.contains(.notify) {
                return .notify(formats: formats)
            }

            if actions.contains(.provide) {
                guard formats.contains(.text) else {
                    return .provide(text: nil)
                }

                guard let plain = inflate(payload) else {
                    throw VNCError.protocol(.zlibDecompress(underlyingError: nil))
                }

                // Pairs of U32 size + data for each format, in bit order. Text is bit 0, so it comes first.
                guard plain.count >= 4 else {
                    throw VNCError.protocol(.invalidData)
                }

                let start = plain.startIndex
                let size = plain[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }

                guard plain.count >= 4 + size else {
                    throw VNCError.protocol(.invalidData)
                }

                return .provide(text: decodeText(plain[(start + 4)..<(start + 4 + size)]))
            }

            throw VNCError.protocol(.unexpectedExtendedServerCutTextAction(action: actions.rawValue))
        }

        // MARK: zlib
        static func deflate(_ data: Data) -> Data? {
            var destinationLength = compressBound(uLong(data.count))
            var destination = [UInt8](repeating: 0, count: Int(destinationLength))

            let status = data.withUnsafeBytes { source in
                compress2(&destination,
                          &destinationLength,
                          source.bindMemory(to: Bytef.self).baseAddress,
                          uLong(data.count),
                          Z_DEFAULT_COMPRESSION)
            }

            guard status == Z_OK else {
                return nil
            }

            return Data(destination.prefix(Int(destinationLength)))
        }

        static func inflate(_ data: Data) -> Data? {
            var stream = z_stream()

            guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                return nil
            }

            defer { inflateEnd(&stream) }

            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var input = [UInt8](data)
            var status = Z_OK

            input.withUnsafeMutableBufferPointer { inputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = uInt(inputBuffer.count)

                repeat {
                    chunk.withUnsafeMutableBufferPointer { chunkBuffer in
                        stream.next_out = chunkBuffer.baseAddress
                        stream.avail_out = uInt(chunkBuffer.count)

                        status = Z.inflate(&stream, Z_NO_FLUSH)

                        let produced = chunkBuffer.count - Int(stream.avail_out)
                        output.append(chunkBuffer.baseAddress!, count: produced)
                    }
                } while status == Z_OK && output.count <= maximumDecompressedSize && (stream.avail_in > 0 || stream.avail_out == 0)
            }

            guard status == Z_STREAM_END || (status == Z_OK && stream.avail_in == 0),
                  output.count <= maximumDecompressedSize else {
                return nil
            }

            return output
        }
    }
}
