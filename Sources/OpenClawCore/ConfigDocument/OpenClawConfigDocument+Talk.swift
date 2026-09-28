import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// One provider entry under `talk.providers` / `tts.providers` (`apiKey` plus provider-owned keys).
    public struct SpeechProviderEntry: ConfigDocumentObject {
        /// Provider API key (secret).
        public var apiKey: ConfigSecretValue?
        /// Provider-owned keys (voice, model, …).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty entry.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("apiKey", \.apiKey)] }
    }

    /// `talk`: speech provider selection and realtime settings (upstream `TalkSchema`).
    public struct Talk: ConfigDocumentObject {
        /// Agent id Talk consults.
        public var agentId: String?
        /// Active speech provider id (a key in ``providers``).
        public var provider: String?
        /// Speech providers.
        public var providers: [String: SpeechProviderEntry]?
        /// Realtime voice.
        public var realtime: Realtime?
        /// Think level for consult turns.
        public var consultThinkingLevel: ThinkLevelValue?
        /// Fast mode for consult turns.
        public var consultFastMode: Bool?
        /// Speech locale.
        public var speechLocale: String?
        /// Interrupt playback when the user speaks.
        public var interruptOnSpeech: Bool?
        /// Silence timeout in milliseconds.
        public var silenceTimeoutMs: Int?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]

        /// Creates an empty Talk section.
        public init() {}

        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("agentId", \.agentId), .init("provider", \.provider), .init("providers", \.providers),
                .init("realtime", \.realtime), .init("consultThinkingLevel", \.consultThinkingLevel),
                .init("consultFastMode", \.consultFastMode), .init("speechLocale", \.speechLocale),
                .init("interruptOnSpeech", \.interruptOnSpeech), .init("silenceTimeoutMs", \.silenceTimeoutMs),
            ]
        }

        /// Upstream `superRefine` checks for the speech and realtime provider selection.
        /// - Returns: Issues (empty when valid).
        public func validationIssues() -> [ConfigDecodeIssue] {
            var issues = Self.providerSelectionIssues(provider: self.provider, providers: self.providers.map { Array($0.keys) }, path: "talk")
            if let realtime = self.realtime {
                issues += Self.providerSelectionIssues(
                    provider: realtime.provider,
                    providers: realtime.providers.map { Array($0.keys) },
                    path: "talk.realtime"
                )
            }
            return issues
        }

        static func providerSelectionIssues(provider: String?, providers: [String]?, path: String) -> [ConfigDecodeIssue] {
            let selected = (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let keys = providers ?? []
            if !selected.isEmpty, !keys.isEmpty, !keys.contains(selected) {
                return [ConfigDecodeIssue(
                    path: "\(path).provider",
                    message: "\(path).provider must match a key in \(path).providers (missing \"\(selected)\")",
                    kind: .invalidValue
                )]
            }
            if selected.isEmpty, keys.count > 1 {
                return [ConfigDecodeIssue(
                    path: "\(path).provider",
                    message: "\(path).provider is required when \(path).providers defines multiple providers",
                    kind: .invalidValue
                )]
            }
            return []
        }

        /// `talk.realtime`.
        public struct Realtime: ConfigDocumentObject {
            /// Realtime provider id.
            public var provider: String?
            /// Realtime providers.
            public var providers: [String: SpeechProviderEntry]?
            /// Realtime model.
            public var model: String?
            /// Speaker voice (legacy `voice` is migrated).
            public var speakerVoice: String?
            /// Speaker voice id.
            public var speakerVoiceId: String?
            /// Instructions.
            public var instructions: String?
            /// `realtime`, `stt-tts` or `transcription`.
            public var mode: String?
            /// `webrtc`, `provider-websocket`, `gateway-relay` or `managed-room`.
            public var transport: String?
            /// Voice-activity threshold (0...1).
            public var vadThreshold: Double?
            /// Silence duration in milliseconds.
            public var silenceDurationMs: Int?
            /// Prefix padding in milliseconds.
            public var prefixPaddingMs: Int?
            /// Reasoning effort.
            public var reasoningEffort: String?
            /// `agent-consult`, `direct-tools` or `none`.
            public var brain: String?
            /// `provider-direct` or `force-agent-consult`.
            public var consultRouting: String?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("provider", \.provider), .init("providers", \.providers), .init("model", \.model),
                    .init("speakerVoice", \.speakerVoice), .init("speakerVoiceId", \.speakerVoiceId),
                    .init("instructions", \.instructions), .init("mode", \.mode), .init("transport", \.transport),
                    .init("vadThreshold", \.vadThreshold), .init("silenceDurationMs", \.silenceDurationMs),
                    .init("prefixPaddingMs", \.prefixPaddingMs), .init("reasoningEffort", \.reasoningEffort),
                    .init("brain", \.brain), .init("consultRouting", \.consultRouting),
                ]
            }
        }
    }

    /// `tts` (top level; also `agents.entries.*.tts`, which adds `prefsPath`).
    public struct TTS: ConfigDocumentObject {
        /// `off`, `always`, `inbound` or `tagged` (legacy `enabled` is migrated).
        public var auto: String?
        /// `final` or `all`.
        public var mode: String?
        /// Provider id (legacy `edge` is migrated to `microsoft`).
        public var provider: String?
        /// Active persona id.
        public var persona: String?
        /// Personas.
        public var personas: [String: AnyCodable]?
        /// Summary model.
        public var summaryModel: String?
        /// Model-directive overrides.
        public var modelOverrides: AnyCodable?
        /// Providers.
        public var providers: [String: SpeechProviderEntry]?
        /// Maximum text length.
        public var maxTextLength: Int?
        /// Timeout in milliseconds (1000...120000).
        public var timeoutMs: Int?
        /// Agent-level preferences path (retired at the root).
        public var prefsPath: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [
                .init("auto", \.auto), .init("mode", \.mode), .init("provider", \.provider), .init("persona", \.persona),
                .init("personas", \.personas), .init("summaryModel", \.summaryModel), .init("modelOverrides", \.modelOverrides),
                .init("providers", \.providers), .init("maxTextLength", \.maxTextLength), .init("timeoutMs", \.timeoutMs),
                .init("prefsPath", \.prefsPath),
            ]
        }
    }

    /// `ui`: operator display preferences (canonical cross-client home; clients sync via `config.get`).
    public struct UI: ConfigDocumentObject {
        /// Legacy seam color (`#rrggbb`).
        public var seamColor: String?
        /// Display preferences.
        public var prefs: Prefs?
        /// Passthrough keys (the retired `assistant` until migrated).
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("seamColor", \.seamColor), .init("prefs", \.prefs)] }

        /// The user accent: `prefs.accent` wins over `seamColor`; invalid values fall through
        /// (the `theme` sentinel means "use the theme accent" and yields `nil`).
        public var accentHex: String? {
            for candidate in [self.prefs?.accent, self.seamColor] {
                if let hex = Self.normalizedAccentHex(candidate) {
                    return hex
                }
            }
            return nil
        }

        /// Strict `#rrggbb` validation (leading `#` optional) returning lowercase `#rrggbb`.
        /// - Parameter raw: Candidate color.
        /// - Returns: Canonical hex, or `nil` when invalid.
        public static func normalizedAccentHex(_ raw: String?) -> String? {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let hex = (trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed).lowercased()
            guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return "#\(hex)"
        }

        /// `ui.prefs`.
        public struct Prefs: ConfigDocumentObject {
            /// Theme: `claw`, `knot`, `dash`, `absolutely`, `tide`, `beacon`, `phosphor`, `crt`, `manuscript`,
            /// `rose`, `miami` or `custom`.
            public var theme: String?
            /// `light`, `dark` or `system`.
            public var themeMode: ThemeMode?
            /// `theme` or `#RRGGBB`.
            public var accent: String?
            /// BCP 47 locale (≤ 20 characters).
            public var locale: String?
            /// Show thinking blocks in chat.
            public var chatShowThinking: Bool?
            /// Show tool calls in chat.
            public var chatShowToolCalls: Bool?
            /// Persist commentary.
            public var chatPersistCommentary: Bool?
            /// `enter` or `modifier-enter`.
            public var chatSendShortcut: String?
            /// `steer` or `queue` (unset uses the server queue mode).
            public var chatFollowUpMode: String?
            /// Sidebar entries.
            public var sidebarEntries: [String]?
            /// Passthrough keys (presentation-only retired keys until migrated).
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates empty preferences.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("theme", \.theme), .init("themeMode", \.themeMode), .init("accent", \.accent), .init("locale", \.locale),
                    .init("chatShowThinking", \.chatShowThinking), .init("chatShowToolCalls", \.chatShowToolCalls),
                    .init("chatPersistCommentary", \.chatPersistCommentary), .init("chatSendShortcut", \.chatSendShortcut),
                    .init("chatFollowUpMode", \.chatFollowUpMode), .init("sidebarEntries", \.sidebarEntries),
                ]
            }

            /// Whether the send shortcut requires a modifier (`modifier-enter`).
            public var sendRequiresModifier: Bool {
                self.chatSendShortcut == "modifier-enter"
            }
        }

        /// `ui.prefs.themeMode` vocabulary (`system` means follow the OS appearance).
        public struct ThemeMode: ConfigOpenEnum {
            /// Raw config string.
            public let rawValue: String
            /// Creates a value from its raw string.
            public init(rawValue: String) { self.rawValue = rawValue }
            /// Light appearance.
            public static let light = Self(rawValue: "light")
            /// Dark appearance.
            public static let dark = Self(rawValue: "dark")
            /// Follow the system appearance.
            public static let system = Self(rawValue: "system")
            /// Known values.
            public static let known: [Self] = [.light, .dark, .system]
        }
    }
}
