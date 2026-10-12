import Foundation
import SwiftData
import Testing
@testable import EmVNCCore

@Suite("Host address parsing")
struct HostAddressTests {
    @Test(arguments: [
        ("server.local", "server.local", nil),
        ("server.local:5901", "server.local", 5901),
        ("192.168.1.20", "192.168.1.20", nil),
        ("192.168.1.20:5900", "192.168.1.20", 5900),
        ("fe80::1", "fe80::1", nil),
        ("[fe80::1]:5902", "fe80::1", 5902),
        ("[::1]", "::1", nil),
        ("  10.0.0.5  ", "10.0.0.5", nil)
    ] as [(String, String, Int?)])
    func validAddresses(input: String, host: String, port: Int?) {
        #expect(HostAddress.parse(input) == .init(host: host, port: port))
    }

    @Test(arguments: [ "", "   ", "host:", "host:0", "host:70000", "[::1", "[]:5900", "a b", "host:abc" ])
    func invalidAddresses(input: String) {
        #expect(HostAddress.parse(input) == nil)
    }

    @Test func displayBracketsIPv6WithPort() {
        #expect(HostAddress.display(host: "fe80::1", port: 5901) == "[fe80::1]:5901")
        #expect(HostAddress.display(host: "host", port: 5900) == "host")
        #expect(HostAddress.display(host: "host", port: 5901) == "host:5901")
    }
}

@Suite("Authentication methods")
struct AuthenticationMethodTests {
    @Test func methodsMapToRealSecurityTypes() {
        #expect(AuthenticationMethod.automatic.securityTypes == nil)
        #expect(AuthenticationMethod.none.securityTypes == [ 1 ])
        #expect(AuthenticationMethod.vncPassword.securityTypes == [ 2 ])
        #expect(AuthenticationMethod.appleRemoteDesktop.securityTypes == [ 30 ])
        #expect(AuthenticationMethod.ultraVNCMSLogonII.securityTypes == [ 113 ])
        #expect(AuthenticationMethod.rsaAES.securityTypes == [ 129, 5, 130, 6 ])
    }

    @Test func credentialFieldsMatchTheMethod() {
        #expect(!AuthenticationMethod.vncPassword.usesUsername)
        #expect(AuthenticationMethod.vncPassword.usesPassword)
        #expect(!AuthenticationMethod.none.usesPassword)
        #expect(AuthenticationMethod.appleRemoteDesktop.requiresUsername)
        #expect(AuthenticationMethod.rsaAES.usesUsername && !AuthenticationMethod.rsaAES.requiresUsername)
    }
}

@Suite("Connection preferences")
struct ConnectionPreferencesTests {
    @Test func roundTrip() throws {
        var preferences = ConnectionPreferences()
        preferences.scalingMode = .actualSize
        preferences.keyboardProfile = .pcStandard
        preferences.clipboardSync = false
        preferences.autoReconnect = true
        preferences.maxReconnectAttempts = 9

        let data = try JSONEncoder().encode(preferences)

        #expect(try JSONDecoder().decode(ConnectionPreferences.self, from: data) == preferences)
    }

    @Test func missingAndUnknownKeysFallBackToDefaults() throws {
        let json = Data(#"{"scalingMode":"actualSize","keyboardProfile":"somethingNew","futureOption":true}"#.utf8)
        let preferences = try JSONDecoder().decode(ConnectionPreferences.self, from: json)

        #expect(preferences.scalingMode == .actualSize)
        #expect(preferences.keyboardProfile == .mac)
        #expect(preferences.clipboardSync)
        #expect(preferences.autoScreenshot)
    }
}

@Suite("SwiftData persistence")
@MainActor
struct PersistenceTests {
    @Test func savedConnectionsSurviveAReopenedStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("test.store")
        let id: UUID

        do {
            let container = try Persistence.makeContainer(url: url)
            let context = container.mainContext
            var preferences = ConnectionPreferences()
            preferences.keyboardProfile = .pcWithMacShortcuts

            let connection = SavedConnection(name: "Office", host: "10.0.0.5", port: 5901,
                                             authenticationMethod: .vncPassword, username: "",
                                             preferences: preferences)
            connection.isFavorite = true
            connection.credentialReference = "ref"
            connection.lastConnectedAt = Date(timeIntervalSince1970: 1_000)
            connection.lastOutcome = .connected
            context.insert(connection)
            try context.save()
            id = connection.id
        }

        let reopened = try Persistence.makeContainer(url: url)
        let loaded = try #require(reopened.mainContext.connection(withID: id))

        #expect(loaded.name == "Office")
        #expect(loaded.port == 5901)
        #expect(loaded.authenticationMethod == .vncPassword)
        #expect(loaded.isFavorite)
        #expect(loaded.credentialReference == "ref")
        #expect(loaded.lastOutcome == .connected)
        #expect(loaded.lastConnectedAt == Date(timeIntervalSince1970: 1_000))
        #expect(loaded.preferences.keyboardProfile == .pcWithMacShortcuts)
    }

    @Test func schemaHasNoPasswordAttribute() {
        let names = SavedConnection.schemaMetadata.map { "\($0)".lowercased() }

        #expect(!names.contains { $0.contains("password\"") || $0.contains("name: \"password") })
        #expect(Persistence.schema.entities.flatMap(\.attributes).allSatisfy { !$0.name.lowercased().contains("password") })
    }

    @Test func sortingAndFetching() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let context = container.mainContext

        for name in [ "Charlie", "alpha", "Bravo" ] {
            context.insert(SavedConnection(name: name, host: "\(name).local"))
        }

        try context.save()

        let names = try context.fetch(FetchDescriptor<SavedConnection>(sortBy: [ SortDescriptor(\.name) ])).map(\.name)

        #expect(names.count == 3)
        #expect(Set(names) == [ "Charlie", "alpha", "Bravo" ])
    }
}
