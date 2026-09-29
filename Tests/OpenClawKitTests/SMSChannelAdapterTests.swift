import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenClawChannels
import OpenClawCore
import OpenClawProtocol
import Testing

@Suite("SMS (Twilio) channel adapter")
struct SMSChannelAdapterTests {
    actor DiagnosticsCollector {
        var events: [RuntimeDiagnosticEvent] = []

        func append(_ event: RuntimeDiagnosticEvent) {
            self.events.append(event)
        }
    }

    static let publicURL = "https://gw.example.com/webhooks/sms"

    static func config(_ configure: (inout SMSChannelConfig) -> Void = { _ in }) -> SMSChannelConfig {
        var config = SMSChannelConfig(
            enabled: true,
            accountSid: "AC123",
            authToken: "tok-secret",
            fromNumber: "+15550001111",
            publicWebhookUrl: Self.publicURL
        )
        configure(&config)
        return config
    }

    static func signedHeaders(_ form: [String: String], url: String = Self.publicURL, token: String = "tok-secret") -> [String: String] {
        ["X-Twilio-Signature": ChannelWebhookSignature.twilioSignature(authToken: token, url: url, form: form)]
    }

    static func body(_ form: [(String, String)]) -> Data {
        ChannelHTTP.formEncoded(form)
    }

    static let mediaHex = "0123456789abcdef0123456789ABCDEF"

    @Test
    func inboundMediaURLsAreBoundToTheAccountAndMessage() {
        func check(_ raw: String) -> Bool {
            TwilioSMS.inboundMediaURL(raw, accountSid: "AC123", messageSid: "MM1") != nil
        }
        let base = "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME\(Self.mediaHex)"
        #expect(check(base))
        #expect(!check("https://api.twilio.com/2010-04-01/Accounts/ACother/Messages/MM1/Media/ME\(Self.mediaHex)"))
        #expect(!check("https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM2/Media/ME\(Self.mediaHex)"))
        #expect(!check("https://api.twilio.com/2010-04-01/Accounts.json"))
        #expect(!check("https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json"))
        #expect(!check("https://api.twilio.com:8443/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME\(Self.mediaHex)"))
        #expect(!check("https://user:pw@api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME\(Self.mediaHex)"))
        #expect(!check(base + "?x=1"))
        #expect(!check("http://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME\(Self.mediaHex)"))
        #expect(!check("https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/MEzz"))
    }

    @Test
    func mediaIsNotDownloadedForAnotherAccountOrANonMediaPath() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/Messages.json", method: "GET", json: #"{"messages":[{"body":"secret history"}]}"#)
        var policy = ChannelMessagingPolicyConfig()
        policy.allowFrom = ["*"]
        let adapter = SMSChannelAdapter(
            config: Self.config {
                $0.policy = policy
                $0.dangerouslyDisableSignatureValidation = true
            },
            environment: [:],
            transport: http
        )
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let listing = "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json"
        let forged = [("MessageSid", "MM7"), ("AccountSid", "AC123"), ("From", "+15550003333"), ("NumMedia", "1"),
                      ("MediaUrl0", listing), ("MediaContentType0", "text/plain")]
        let foreign = [("MessageSid", "MM8"), ("AccountSid", "ACother"), ("From", "+15550003333"), ("NumMedia", "1"),
                       ("MediaUrl0", "https://api.twilio.com/2010-04-01/Accounts/ACother/Messages/MM8/Media/ME\(Self.mediaHex)")]
        _ = await adapter.handleWebhook(requestURL: URL(string: Self.publicURL)!, headers: [:], body: Self.body(forged))
        _ = await adapter.handleWebhook(requestURL: URL(string: Self.publicURL)!, headers: [:], body: Self.body(foreign))
        try await waitUntil("both delivered") { await collector.messages.count == 2 }
        await adapter.stop()
        #expect(await collector.messages.allSatisfy { $0.attachments.isEmpty })
        #expect(await http.records.isEmpty)
    }

    @Test
    func signatureMatchesTwilioDocumentationVector() {
        let signature = ChannelWebhookSignature.twilioSignature(
            authToken: "12345",
            url: "https://mycompany.com/myapp.php?foo=1&bar=2",
            form: ["CallSid": "CA1234567890ABCDE", "Caller": "+12349013030", "Digits": "1234", "From": "+12349013030", "To": "+18005551212"]
        )
        #expect(signature == "0/KCTR6DLpKmkAf8muzZqo1nDgQ=")
    }

    @Test
    func webhookRejectsBadSignaturesAndMissingSid() async throws {
        let adapter = SMSChannelAdapter(config: Self.config(), environment: [:], transport: ScriptedChannelHTTP())
        try await adapter.start()
        let fields = [("From", "+15550002222"), ("To", "+15550001111"), ("Body", "hi")]
        let form = Dictionary(uniqueKeysWithValues: fields)
        let url = URL(string: Self.publicURL)!
        let unsigned = await adapter.handleWebhook(requestURL: url, headers: [:], body: Self.body(fields))
        #expect(unsigned.status == 403)
        let wrongToken = await adapter.handleWebhook(requestURL: url, headers: Self.signedHeaders(form, token: "other"), body: Self.body(fields))
        #expect(wrongToken.status == 403)
        let missingSid = await adapter.handleWebhook(requestURL: url, headers: Self.signedHeaders(form), body: Self.body(fields))
        #expect(missingSid.status == 400)
        #expect(missingSid.body == "Missing MessageSid")
        await adapter.stop()
    }

    @Test
    func webhookDeliversSignedMessageOnceWithTwiML() async throws {
        let adapter = SMSChannelAdapter(config: Self.config(), environment: [:], transport: ScriptedChannelHTTP())
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let fields = [("MessageSid", "SM1"), ("From", "+15550002222"), ("To", "+15550001111"), ("Body", "hello there"), ("NumMedia", "0")]
        let form = Dictionary(uniqueKeysWithValues: fields)
        let url = URL(string: Self.publicURL)!
        let first = await adapter.handleWebhook(requestURL: url, headers: Self.signedHeaders(form), body: Self.body(fields))
        let replay = await adapter.handleWebhook(requestURL: url, headers: Self.signedHeaders(form), body: Self.body(fields))
        try await waitUntil("delivered") { await !collector.messages.isEmpty }
        await adapter.stop()

        #expect(first.status == 200)
        #expect(first.contentType.hasPrefix("text/xml"))
        #expect(first.body == #"<?xml version="1.0" encoding="UTF-8"?><Response></Response>"#)
        #expect(replay.status == 200)
        let messages = await collector.messages
        #expect(messages.count == 1)
        #expect(messages[0].peerID == "+15550002222")
        #expect(messages[0].senderID == "+15550002222")
        #expect(messages[0].messageID == "SM1")
        #expect(messages[0].chatType == .direct)
        #expect(messages[0].text == "hello there")
    }

    @Test
    func signatureUsesRequestQueryWhenPublicURLHasNone() async throws {
        let adapter = SMSChannelAdapter(config: Self.config(), environment: [:], transport: ScriptedChannelHTTP())
        try await adapter.start()
        let fields = [("MessageSid", "SM9"), ("From", "rcs:+15550002222"), ("Body", "via rcs")]
        let form = Dictionary(uniqueKeysWithValues: fields)
        let requestURL = URL(string: "https://gw.example.com/webhooks/sms?account=main")!
        let headers = Self.signedHeaders(form, url: Self.publicURL + "?account=main")
        let response = await adapter.handleWebhook(requestURL: requestURL, headers: headers, body: Self.body(fields))
        await adapter.stop()
        #expect(response.status == 200)
        #expect(TwilioSMS.inboundSender("whatsapp:+15550002222") == nil)
        #expect(TwilioSMS.inboundSender("rcs:+15550002222") == "+15550002222")
    }

    @Test
    func deliveryStatusBecomesDiagnostic() async throws {
        let diagnostics = DiagnosticsCollector()
        let adapter = SMSChannelAdapter(
            config: Self.config { $0.dangerouslyDisableSignatureValidation = true },
            environment: [:],
            transport: ScriptedChannelHTTP(),
            diagnosticsSink: { await diagnostics.append($0) }
        )
        try await adapter.start()
        let fields = [("MessageSid", "SM5"), ("MessageStatus", "delivered"), ("To", "+15550002222")]
        let response = await adapter.handleWebhook(requestURL: URL(string: Self.publicURL)!, headers: [:], body: Self.body(fields))
        await adapter.stop()
        #expect(response.status == 200)
        let event = try #require(await diagnostics.events.first)
        #expect(event.name == "sms.delivery.status")
        #expect(event.metadata["status"] == "delivered")
        #expect(event.metadata["messageSid"] == "SM5")
    }

    @Test
    func mediaIsDownloadedOnlyForAuthorizedSenders() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/Media/ME\(Self.mediaHex)", response: HTTPResponseData(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: Data([9, 9])))
        var policy = ChannelMessagingPolicyConfig()
        policy.allowFrom = ["+1 555 000 3333"]
        let adapter = SMSChannelAdapter(
            config: Self.config {
                $0.policy = policy
                $0.dangerouslyDisableSignatureValidation = true
            },
            environment: [:],
            transport: http
        )
        let collector = ChannelEventCollector()
        await adapter.setInboundHandler { await collector.append($0) }
        try await adapter.start()
        let mediaURL = "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages/MM1/Media/ME\(Self.mediaHex)"
        let allowed = [("MessageSid", "MM1"), ("AccountSid", "AC123"), ("From", "+15550003333"), ("NumMedia", "2"), ("MediaUrl0", mediaURL),
                       ("MediaContentType0", "image/jpeg"), ("MediaUrl1", "https://evil.example.com/x.png")]
        let stranger = [("MessageSid", "MM2"), ("AccountSid", "AC123"), ("From", "+15550004444"), ("NumMedia", "1"), ("MediaUrl0", mediaURL)]
        _ = await adapter.handleWebhook(requestURL: URL(string: Self.publicURL)!, headers: [:], body: Self.body(allowed))
        _ = await adapter.handleWebhook(requestURL: URL(string: Self.publicURL)!, headers: [:], body: Self.body(stranger))
        try await waitUntil("both delivered") { await collector.messages.count == 2 }
        await adapter.stop()

        let messages = await collector.messages.sorted { ($0.messageID ?? "") < ($1.messageID ?? "") }
        #expect(messages[0].attachments.count == 1)
        #expect(messages[0].attachments.first?.mimeType == "image/jpeg")
        #expect(messages[0].text.contains("could not be included"))
        #expect(messages[1].attachments.isEmpty)
        #expect(messages[1].text.contains("not yet authorized"))
        let download = try #require(await http.requests("/Media/ME\(Self.mediaHex)").first)
        #expect(download.headers["Authorization"] == "Basic " + Data("AC123:tok-secret".utf8).base64EncodedString())
        #expect(await http.count("/x.png") == 0)
    }

    @Test
    func sendRoundTripUsesTwilioFormFieldsAndReturnsSid() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/Accounts/AC123/Messages.json", status: 201, json: #"{"sid":"SMout1","status":"queued"}"#)
        let adapter = SMSChannelAdapter(config: Self.config(), environment: [:], transport: http)
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(
            OutboundMessage(channel: .sms, peerID: "+1 (555) 000-2222", text: "**Done**: see [docs](https://docs.example.com)\n```\ncode\n```")
        )
        await adapter.stop()

        #expect(receipt.primaryPlatformMessageID == "SMout1")
        let request = try #require(await http.requests("/Accounts/AC123/Messages.json").first)
        #expect(request.url == "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json")
        #expect(request.headers["Authorization"] == "Basic " + Data("AC123:tok-secret".utf8).base64EncodedString())
        let form = ChannelHTTP.parseForm(Data(request.body.utf8))
        #expect(form["To"] == "+15550002222")
        #expect(form["From"] == "+15550001111")
        #expect(form["Body"] == "Done: see docs (https://docs.example.com)\ncode")
        #expect(form["StatusCallback"] == Self.publicURL + "#rp=ct,rt,5xx&rt=5000&rc=1")
    }

    @Test
    func longTextChunksAt1500AndMessagingServiceFallback() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/Messages.json", status: 201, json: #"{"sid":"SMa"}"#)
        let adapter = SMSChannelAdapter(
            config: Self.config {
                $0.fromNumber = nil
                $0.messagingServiceSid = "MG1"
                $0.publicWebhookUrl = nil
            },
            environment: [:],
            transport: http
        )
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .sms, peerID: "+15550002222", text: String(repeating: "a", count: 3_100)))
        await adapter.stop()
        let requests = await http.requests("/Messages.json")
        #expect(requests.count == 3)
        #expect(receipt.parts.count == 3)
        let form = ChannelHTTP.parseForm(Data(requests[0].body.utf8))
        #expect(form["MessagingServiceSid"] == "MG1")
        #expect(form["From"] == nil)
        #expect(form["StatusCallback"] == nil)
        #expect((form["Body"] ?? "").count <= 1_500)
    }

    @Test
    func mediaSendsRequireProviderAndIncludeMediaURLs() async throws {
        let http = ScriptedChannelHTTP()
        await http.on("/Messages.json", status: 201, json: #"{"sid":"MMout"}"#)
        let attachment = MediaAttachment(mimeType: "image/png", data: Data([1]))
        let bare = SMSChannelAdapter(config: Self.config(), environment: [:], transport: http)
        try await bare.start()
        await #expect(throws: ChannelSendError.self) {
            try await bare.send(OutboundMessage(channel: .sms, peerID: "+15550002222", text: "pic", attachments: [attachment]))
        }
        let adapter = SMSChannelAdapter(
            config: Self.config(),
            environment: [:],
            transport: http,
            mediaURLProvider: { _ in URL(string: "https://cdn.example.com/a.png")! }
        )
        try await adapter.start()
        let receipt = try await adapter.sendReturningReceipt(OutboundMessage(channel: .sms, peerID: "+15550002222", text: "pic", attachments: [attachment]))
        #expect(receipt.parts.first?.kind == .media)
        let form = ChannelHTTP.parseForm(Data(try #require(await http.requests("/Messages.json").last).body.utf8))
        #expect(form["MediaUrl"] == "https://cdn.example.com/a.png")
    }

    @Test
    func configDecodingEnvFallbacksAndUnconfiguredReason() throws {
        let json = #"{"channels":{"sms":{"accountSid":"ACx","authToken":{"source":"env","provider":"default","id":"TW"},"textChunkLimit":900}}}"#
        struct Root: Decodable {
            let channels: ChannelsConfig
        }
        let channels = try JSONDecoder().decode(Root.self, from: Data(json.utf8)).channels
        let sms = channels.sms
        #expect(sms.enabled)
        #expect(sms.accountSid == "ACx")
        #expect(sms.authToken == nil)
        #expect(sms.authTokenInput != nil)
        #expect(sms.textChunkLimit == 900)
        #expect(sms.effectivePolicy.dmPolicy == .pairing)
        #expect(sms.webhookPath == "/webhooks/sms")
        #expect(sms.isConfigured == false)

        let env = SMSChannelConfig(enabled: true).applyingEnvironmentFallbacks(
            ["TWILIO_ACCOUNT_SID": "ACenv", "TWILIO_AUTH_TOKEN": "t", "TWILIO_SMS_FROM": "+15550009999"]
        )
        #expect(env.isConfigured)
        #expect(env.fromNumber == "+15550009999")
        let nonDefault = SMSChannelConfig(enabled: true).applyingEnvironmentFallbacks(["TWILIO_ACCOUNT_SID": "ACenv"], accountID: "work")
        #expect(nonDefault.accountSid == nil)

        let adapter = SMSChannelAdapter(config: SMSChannelConfig(enabled: true), environment: [:])
        #expect(adapter.configurationStatus.reason == "SMS requires accountSid, authToken, and fromNumber or messagingServiceSid.")

        var roundTrip = channels
        var updated = roundTrip.sms
        updated.fromNumber = "+15550001234"
        roundTrip.sms = updated
        #expect(roundTrip.rawSection(named: "sms")?["fromNumber"]?.stringValue == "+15550001234")
        #expect(roundTrip.plaintextSecretPaths().contains("channels.sms.authToken") == false)
    }

    @Test
    func plainTextRenderingAndStatusCallbackOverrides() {
        #expect(TwilioSMS.renderPlainText("# Title\n*emphasis* and `code`") == "Title\nemphasis and code")
        #expect(
            TwilioSMS.statusCallbackURL(publicWebhookURL: "https://gw.example.com/sms#rp=all&rt=200")
                == "https://gw.example.com/sms#rp=all&rt=200&rc=1"
        )
        #expect(TwilioSMS.statusCallbackURL(publicWebhookURL: "http://localhost/sms") == nil)
        #expect(TwilioSMS.normalizePhoneNumber("sms:1 (555) 000-1111") == "+15550001111")
    }
}
