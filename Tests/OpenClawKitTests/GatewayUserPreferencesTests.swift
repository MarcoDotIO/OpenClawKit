import Foundation
import OpenClawKit
import Testing

// Port of upstream apps/shared/OpenClawKit/Tests/OpenClawKitTests/GatewayUserPreferencesTests.swift.
@Suite("Gateway user preferences")
struct GatewayUserPreferencesTests {
    @Test
    func normalizesBareAndPrefixedHex() {
        #expect(GatewayUserPreferences.normalizedAccentHex("#A1B2C3") == "#a1b2c3")
        #expect(GatewayUserPreferences.normalizedAccentHex("a1b2c3") == "#a1b2c3")
        #expect(GatewayUserPreferences.normalizedAccentHex("  #ff0000  ") == "#ff0000")
    }

    @Test(arguments: [nil, "", "#fff", "#ff0000aa", "red", "#12345g", "+abcde1", "+12345", "-12345", "#ＦＦＦＦＦＦ"] as [String?])
    func rejectsInvalidHex(value: String?) {
        #expect(GatewayUserPreferences.normalizedAccentHex(value) == nil)
    }

    @Test
    func profileAccentReadsItsEntryWithoutRejectingUnrelatedFields() throws {
        let response = Data(##"{"status":"ok","entries":{"ui.accent":"#A1B2C3","ui.theme":"dark"},"extra":true}"##.utf8)
        #expect(try GatewayUserPreferences.decodeProfileAccentHex(response) == "#a1b2c3")
    }

    @Test(arguments: [
        #"{"status":"ok"}"#,
        #"{"status":"ok","entries":null}"#,
        #"{"status":"ok","entries":[]}"#,
        #"{"status":"ok","entries":{}}"#,
        #"{"status":"ok","entries":{"ui.accent":"not-a-color"}}"#,
        #"{"status":"ok","entries":{"ui.accent":42}}"#,
        #"{"status":"ok","entries":{"ui.accent":null}}"#,
    ])
    func profileAccentRejectsMissingOrMalformedEntries(payload: String) throws {
        #expect(try GatewayUserPreferences.decodeProfileAccentHex(Data(payload.utf8)) == nil)
    }

    @Test(arguments: [
        ##"{"entries":{"ui.accent":"#123456"}}"##,
        ##"{"status":"no_durable_identity","entries":{"ui.accent":"#123456"}}"##,
        ##"{"status":"OK","entries":{"ui.accent":"#123456"}}"##,
        ##"[{"status":"ok","entries":{"ui.accent":"#123456"}}]"##,
    ])
    func onlyAnOkProfileResponseCanSupplyAnAccent(payload: String) throws {
        #expect(try GatewayUserPreferences.decodeProfileAccentHex(Data(payload.utf8)) == nil)
    }

    @Test(arguments: ["", "{"])
    func malformedJSONPreservesTheCallersErrorPath(payload: String) {
        #expect(throws: Error.self) {
            try GatewayUserPreferences.decodeProfileAccentHex(Data(payload.utf8))
        }
    }

    @Test
    func userAccentPrefersPrefsAccentOverSeamColorAndFallsThrough() throws {
        let both = try OpenClawConfigDocument.decode(Data(##"{"ui": {"seamColor": "#00ff00", "prefs": {"accent": "#FF0000"}}}"##.utf8))
        #expect(GatewayUserPreferences.gatewayUserAccentHex(ui: both.ui) == "#ff0000")
        let themeSentinel = try OpenClawConfigDocument.decode(Data(##"{"ui": {"seamColor": "#00FF00", "prefs": {"accent": "theme"}}}"##.utf8))
        #expect(GatewayUserPreferences.gatewayUserAccentHex(ui: themeSentinel.ui) == "#00ff00")
        #expect(GatewayUserPreferences.gatewayUserAccentHex(ui: nil) == nil)
        let prefs = try #require(both.ui?.prefs)
        #expect(prefs.sendRequiresModifier == false)
    }
}
