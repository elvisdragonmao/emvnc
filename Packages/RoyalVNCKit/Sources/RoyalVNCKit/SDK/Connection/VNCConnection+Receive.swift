#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Server to Client Messages
extension VNCConnection {
	func startReceiveLoop() {
        logger.logDebug("Starting receive loop")

        receiveTask = Task(priority: taskPriority) {
			while !state.disconnectRequested,
                  connection.isReady {
				do {
					try await receive()
				} catch {
					handleBreakingError(error)
				}
			}
		}
	}
}

private extension VNCConnection {
	func receive() async throws {
		guard !state.disconnectRequested else {
			// Just ignore, since disconnect has already been requested
			return
		}

        guard connection.isReady else {
			throw VNCError.connection(.notReady)
		}

		let serverToClientMessage = try await VNCProtocol.ServerToClientMessage.receive(connection: connection)

		try await didReceive(messageType: serverToClientMessage.messageType)
	}

	func didReceive(messageType: UInt8) async throws {
		switch messageType {
			case VNCProtocol.FramebufferUpdate.messageType:
				try await handleFramebufferUpdateMessage()

			case VNCProtocol.SetColourMapEntries.messageType:
				try await handleSetColourMapEntriesMessage()

			case VNCProtocol.ServerCutText.messageType:
				try await handleServerCutTextMessage()

			case VNCProtocol.Bell.messageType:
				try await handleBellMessage()

			case VNCProtocol.EndOfContinuousUpdates.messageType:
				try await handleEndOfContinuousUpdatesMessage()

			default:
				throw VNCError.protocol(.unsupportedServerToClientMessage(messageType: messageType))
		}
	}

	func handleFramebufferUpdateMessage() async throws {
		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.framebufferUpdateReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Framebuffer Update")

		let framebufferUpdate = try await VNCProtocol.FramebufferUpdate.receive(connection: connection,
																				framebuffer: framebuffer,
																				encodings: encodings,
																				logger: logger)

		logger.logDebug("Received Framebuffer Update: \(framebufferUpdate)")

		/*
		// Write out the framebuffer for testing purposes
		try framebuffer.writeSurface()
		*/

		try await sendFramebufferUpdateRequest()
	}

	func handleSetColourMapEntriesMessage() async throws {
		guard let framebuffer = framebuffer else {
			throw VNCError.protocol(.setColourMapEntriesReceivedWithoutFramebuffer)
		}

		logger.logDebug("Receiving Colour Map Entries")

		let colourMapEntries = try await VNCProtocol.SetColourMapEntries.receive(connection: connection,
																				 logger: logger)

		logger.logDebug("Received Colour Map Entries")

		framebuffer.updateColorMap(colourMapEntries)
	}

	func handleServerCutTextMessage() async throws {
		logger.logDebug("Receiving Clipboard Text from Server")

		let serverCutText = try await VNCProtocol.ServerCutText.receive(connection: connection,
																		logger: logger)

		logger.logDebug("Received Clipboard Text from Server")

		// emvnc fork: deliver text to the extended delegate and implement the Extended Clipboard actions
		switch serverCutText.content {
			case .text(let text):
				deliverServerClipboardText(text)
			case .extended(let flags, let payload):
				try handleExtendedClipboard(flags: flags, payload: payload)
		}
	}

	func deliverServerClipboardText(_ text: String) {
		if let extendedDelegate {
			extendedDelegate.connection(self, didReceiveClipboardText: text)
		} else if settings.isClipboardRedirectionEnabled {
			clipboard.text = text
		}
	}

	func handleExtendedClipboard(flags: UInt32, payload: Data) throws {
		let message = try VNCProtocol.ExtendedClipboard.parse(flags: flags, payload: payload)

		switch message {
			case .caps(let formats, let actions, let textSize):
				state.clipboard.withLock {
					$0.serverCapabilities = .init(formats: formats,
												  actions: actions,
												  maximumTextSize: textSize ?? 0)
				}

				enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.clientCaps())
			case .notify(let formats):
				if formats.contains(.text) {
					enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.request())
				}
			case .request(let formats):
				guard formats.contains(.text) else { return }

				let text = state.clipboard.withLock { $0.localText }

				enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.provide(text: text))
			case .peek:
				let hasText = state.clipboard.withLock { $0.localText != nil }

				enqueueClientToServerMessage(VNCProtocol.ExtendedClipboard.notify(hasText: hasText))
			case .provide(let text):
				if let text {
					deliverServerClipboardText(text)
				}
		}
	}

	func handleBellMessage() async throws {
		logger.logDebug("Receiving Bell Message from Server")

		_ = try await VNCProtocol.Bell.receive(connection: connection,
											   logger: logger)

		logger.logDebug("Received Bell Message from Server")

		systemSound.play()
	}

	func handleEndOfContinuousUpdatesMessage() async throws {
		let first = !state.areContinuousUpdatesSupported

		state.areContinuousUpdatesSupported = true
		state.areContinuousUpdatesEnabled = false

		if first {
			logger.logDebug("Continuous Updates supported (server sent EndOfContinuousUpdates)")
		} else {
			logger.logDebug("Disabling Continuous Updates")
		}

		try await sendFramebufferUpdateRequest()
	}
}
