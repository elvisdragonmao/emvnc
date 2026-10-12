# RoyalVNCKit — emvnc fork

This directory is a vendored, patched copy of [RoyalVNCKit](https://github.com/royalapplications/royalvnc)
(MIT License, see `LICENSE`). Upstream was archived in October 2026, so emvnc carries its fixes here.

| | |
|---|---|
| Upstream repository | https://github.com/royalapplications/royalvnc |
| Pinned revision | `090b96eddeee183e9fec293c5cd881d302a4349d` (2026-09-21, "[ci] Skip Android build") |
| CryptoSwift | `royalapplications/CryptoSwift` pinned to `a59b4d91ebb22011656c830f874fe7152e183a57` (the revision in upstream's `Package.resolved`; upstream referenced the moving `foundationessentials` branch) |
| Full diff | [`docs/royalvnckit-fork.patch`](../../docs/royalvnckit-fork.patch) (excluding the removed C API) |

Every changed or added source file starts with or contains an `emvnc fork` comment.

## Why a fork was needed

Verified against the pinned revision before integrating:

1. **No RSA-AES.** Upstream negotiates only None (1), VNC Authentication (2), Apple Remote Desktop (30) and
   UltraVNC MS-Logon II (113). Servers that offer only RSA-AES/VeNCrypt — e.g. wayvnc/neatvnc, or TigerVNC
   configured for RSA-AES — fail with `clientCouldNotDecideOnSecurityType`. The test server for this project
   offered `[19 VeNCrypt, 129 RSA-AES-256, 5 RSA-AES]`.
2. **Tight security type selected but not implemented.** `decideSecurityType` chose type 16 when offered and
   then skipped its handshake, leaving the stream in an undefined state.
3. **Clipboard not usable by a multi-session client.** Upstream polls `NSPasteboard.general` every 0.5 s from
   every connection and writes server text straight into the pasteboard. A client with several sessions would
   upload the Mac clipboard to all of them, and there was no public API to send or receive clipboard text.
4. **Clipboard encoding.** `ClientCutText` silently sent an *empty string* for any text not representable in
   ISO 8859-1 (e.g. CJK, emoji). `ServerCutText` decoded everything as Latin-1. Extended Clipboard was a
   stub that did not consume the payload of non-caps messages (a stream desync if a server sent one).
5. **No way to restrict security types** (needed for "use VNC Password" vs. "automatic"), and the negotiated
   type and encryption state were not exposed.
6. **Mouse wheel steps collapsed** — see `mouseWheel` below.

## Changes

### Added
- `Encryption/AESEAX.swift` — AES-EAX (CTR + CMAC) on CommonCrypto, AES-128 and AES-256. Verified with the
  EAX paper vectors and PyCryptodome-generated RA2 vectors (`Tests/RoyalVNCKitTests`).
- `Encryption/RSAKeys.swift` — RA2 public-key wire format, minimal PKCS#1 DER encode/parse, RSA key generation and
  PKCS#1 v1.5 encryption/decryption via Security.framework.
- `Network/TransportConnection.swift` — replaces the bare `NWConnection` as the connection object. Pass-through
  until a security handshake enables the RA2 record layer (U16 length as associated data, 16-byte little-endian
  message counter as nonce, 16-byte MAC; writes are sealed and enqueued under one lock so record order always
  matches nonce order even though the send and receive loops write concurrently). Also enables TCP keep-alive
  (10 s idle, 5 s interval, 3 probes) so silently dropped connections are detected.
- `Protocol/SecurityTypes/RSAAES/RSAAESAuthentication.swift` — RSA-AES (5), RSA-AES-256 (129) and their
  handshake-only variants (6, 130), following the RFB spec: key exchange, randoms, SHA-1/SHA-256 session keys,
  hash verification, credential subtype 1 (username + password) or 2 (password only). The server key's
  SHA-256 fingerprint is passed to the client for trust-on-first-use verification.
- `Protocol/Messages/ExtendedClipboard.swift` — Extended Clipboard pseudo-encoding (`0xC0A1E5CE`): caps,
  request, peek, notify and provide for UTF-8 text, zlib (de)compression with a 32 MiB decompression cap.
- `SDK/Connection/VNCConnection+emvnc.swift` — public API: `VNCConnectionExtendedDelegate` (clipboard text and
  server-key verification), `sendClipboardText(_:)`, `offeredSecurityTypes`, `negotiatedSecurityType`,
  `isSessionEncrypted`, `serverKeyFingerprint`, `desktopName`, `isExtendedClipboardActive`.
- `SDK/VNCSecurityTypeInfo.swift` — names, implemented list, default preference, encryption semantics.
- `Tests/RoyalVNCKitTests` — 23 test functions (more with parameterised cases).

### Modified
- `VNCConnection.swift` — `securityTypePreference`, `extendedDelegate`, `TransportConnection`; the Extended
  Clipboard pseudo-encoding is advertised only when an extended delegate is set.
- `VNCConnection+Handshake.swift` — preference-driven security type selection (Tight removed), RSA-AES dispatch,
  descriptive error listing what the server offered.
- `VNCConnection+Receive.swift` — clipboard text goes to the extended delegate; Extended Clipboard actions.
- `ServerCutText.swift` — rewritten: always consumes the full message; standard text is decoded as UTF-8 when
  it is valid UTF-8 with non-ASCII bytes, otherwise Latin-1.
- `ClientCutText.swift` — Latin-1 when representable, otherwise UTF-8 instead of an empty string.
- `AuthenticationError.swift`, `VNCAuthenticationType.swift`, `State.swift` — new cases and state.
- `VNCFramebuffer.swift` — `ioSurface` made public (zero-copy display); a redundant forced cast removed.
- `VNCConnection+API.swift` — `mouseWheel` now sends a release after every wheel press. Upstream only sent the
  press, so the wheel "button" stayed down until the next pointer event and several wheel steps collapsed into a
  single scroll on the server (found while testing against TigerVNC with `xev`).
- `@_implementationOnly import` → `internal import` (the former warns without library evolution).

### Removed
- The C API (`SDK/CSDK`, `RoyalVNCKitC`), demo executables, bundled zlib sources (Windows only) and the `Cstb`
  dependency (non-Apple platforms only). emvnc is a macOS app and uses none of them.
- The library is built statically (upstream: dynamic with library evolution), so the app bundle needs no
  embedded framework.

## Not changed / known gaps
- **VeNCrypt (19)** — needs a TLS upgrade in the middle of an existing TCP stream, which Network.framework does not
  offer; it is not implemented. Servers that offer only VeNCrypt cannot be used. RSA-AES covers the same servers
  (TigerVNC, wayvnc) when it is enabled on them.
- **Tight security (16)**, RSA-AES "Two-step" (13, 133), SASL, MD5 and other RealVNC types are not implemented.
- Apple Remote Desktop and UltraVNC MS-Logon II use upstream's code unchanged (upstream recently replaced its
  big-number implementation with CryptoSwift's `BigUInt`); they could not be tested here — see the
  implementation report.
