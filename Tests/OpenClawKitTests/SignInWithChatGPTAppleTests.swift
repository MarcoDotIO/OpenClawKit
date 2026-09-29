import Foundation
import Testing
@testable import OpenClawChatUI
@testable import OpenClawCore
@testable import OpenClawKit

private actor SIWCMemoryStore: CredentialStore {
    private var values: [String: String] = [:]

    func saveSecret(_ value: String, for key: String) async throws {
        self.values[key] = value
    }

    func loadSecret(for key: String) async throws -> String? {
        self.values[key]
    }

    func deleteSecret(for key: String) async throws {
        self.values[key] = nil
    }
}

@Suite("Sign in with ChatGPT on Apple platforms")
struct SignInWithChatGPTAppleTests {
    @Test("File credential stores write 0600 files in 0700 directories without temp leftovers")
    func privateCredentialFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclawkit-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state", isDirectory: true)
        let fileURL = directory.appendingPathComponent("credentials.json")
        let store = FileCredentialStore(fileURL: fileURL)
        try await store.saveSecret("refresh-token", for: "openclaw.siwc.credential.x")
        try await store.saveSecret("refresh-token-2", for: "openclaw.siwc.credential.x")

        let fileMode = try #require(FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o600)
        let directoryMode = try #require(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["credentials.json"])
        #expect(try await store.loadSecret(for: "openclaw.siwc.credential.x") == "refresh-token-2")
    }

    @Test("A device identity yields a stable RFC 9278 host identifier")
    func deviceIdentityHostIdentifier() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let identity = DeviceIdentity(deviceId: "device", publicKey: key.base64EncodedString(), privateKey: "", createdAtMs: 0)
        let identifier = try #require(SignInWithChatGPTHostIdentifier(deviceIdentity: identity))
        #expect(identifier == SignInWithChatGPTHostIdentifier.jwkThumbprint(ed25519PublicKey: key))
        #expect(identifier.rawValue.hasPrefix("urn:ietf:params:oauth:jwk-thumbprint:sha-256:"))
        #expect(!identifier.rawValue.contains("device"))
        let broken = DeviceIdentity(deviceId: "device", publicKey: "bm90LWEta2V5", privateKey: "", createdAtMs: 0)
        #expect(SignInWithChatGPTHostIdentifier(deviceIdentity: broken) == nil)
    }

    #if os(iOS) || os(macOS) || os(visionOS)
    @MainActor
    @Test("The SwiftUI model routes usage limits to the usage-limit sheet")
    func modelRoutesErrors() async throws {
        let session = SignInWithChatGPTSession(
            configuration: SignInWithChatGPTClientConfiguration(agentName: "TestAgent"),
            credentialStore: SIWCMemoryStore()
        )
        let model = SignInWithChatGPTModel(session: session) { SignInWithChatGPTExternalBrowser { _ in false } }
        await model.reload()
        #expect(model.accounts.isEmpty)
        #expect(model.activeAccount == nil)
        #expect(!model.isUsingChatGPTPlan)

        model.handle(ChatGPTPlanError(kind: .usageLimitReached, statusCode: 429))
        #expect(model.planError?.isUsageLimit == true)
        #expect(model.errorMessage == nil)

        model.handle(ChatGPTPlanError(kind: .usageUnavailable, statusCode: 503))
        #expect(model.errorMessage?.contains("temporarily unavailable") == true)

        model.handle(SignInWithChatGPTError.notSignedIn)
        #expect(model.errorMessage == SignInWithChatGPTError.notSignedIn.localizedDescription)

        await model.signIn()
        #expect(model.errorMessage?.contains("Could not open the browser") == true)
        #expect(!model.isSigningIn)
        #expect(!model.showsPlanWelcome)

        #expect(SignInWithChatGPTButton.Label.continueWithChatGPT.title == "Continue with ChatGPT")
        #expect(SignInWithChatGPTButton.Label.signInWithChatGPT.title == "Sign in with ChatGPT")
        #expect(ChatGPTPlanLinks.manageUsage.absoluteString == "https://chatgpt.com/settings/usage")
        _ = SignInWithChatGPTButton(style: .white) {}.body
        _ = ChatGPTPlanWelcomeView {}.body
        _ = ChatGPTPlanUsageIndicator().body
        _ = ChatGPTPlanUsageLimitView(layout: .compact, onBuyAppCredits: {}).body
    }
    #endif
}
