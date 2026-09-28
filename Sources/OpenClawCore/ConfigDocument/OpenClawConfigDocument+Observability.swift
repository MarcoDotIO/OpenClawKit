import Foundation
import OpenClawProtocol

extension OpenClawConfigDocument {
    /// `logging` (gateway behavior; metadata for control-plane UIs).
    public struct Logging: ConfigDocumentObject {
        /// `silent`, `fatal`, `error`, `warn`, `info`, `debug` or `trace`.
        public var level: String?
        /// Console level (same vocabulary).
        public var consoleLevel: String?
        /// Log file path.
        public var file: String?
        /// Log file size cap.
        public var maxFileBytes: Int?
        /// `pretty` or `json` (legacy `compact` is migrated to `pretty`).
        public var consoleStyle: String?
        /// Extra redaction patterns.
        public var redactPatterns: [String]?
        /// Audit logging (`enabled`, `executionIdentity`, `messages`).
        public var audit: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("level", \.level), .init("consoleLevel", \.consoleLevel), .init("file", \.file),
             .init("maxFileBytes", \.maxFileBytes), .init("consoleStyle", \.consoleStyle),
             .init("redactPatterns", \.redactPatterns), .init("audit", \.audit)]
        }
    }

    /// `diagnostics` (OpenTelemetry export is gateway behavior; metadata here).
    public struct Diagnostics: ConfigDocumentObject {
        /// Enables diagnostics.
        public var enabled: Bool?
        /// Diagnostic flags.
        public var flags: [String]?
        /// OpenTelemetry export.
        public var otel: OTel?
        /// Cache trace (`enabled` only).
        public var cacheTrace: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("enabled", \.enabled), .init("flags", \.flags), .init("otel", \.otel), .init("cacheTrace", \.cacheTrace)]
        }

        /// `diagnostics.otel`.
        public struct OTel: ConfigDocumentObject {
            /// Enables export.
            public var enabled: Bool?
            /// OTLP/HTTP endpoint.
            public var endpoint: String?
            /// Traces endpoint.
            public var tracesEndpoint: String?
            /// Metrics endpoint.
            public var metricsEndpoint: String?
            /// Logs endpoint.
            public var logsEndpoint: String?
            /// Only `http/protobuf` (gRPC was removed).
            public var `protocol`: String?
            /// Export headers.
            public var headers: [String: String]?
            /// Service name.
            public var serviceName: String?
            /// Metric name prefix (≤ 128 characters).
            public var metricNamePrefix: String?
            /// Export traces.
            public var traces: Bool?
            /// Export metrics.
            public var metrics: Bool?
            /// Export logs.
            public var logs: Bool?
            /// `otlp`, `stdout` or `both`.
            public var logsExporter: String?
            /// Sample rate (0...1).
            public var sampleRate: Double?
            /// Flush interval in milliseconds.
            public var flushIntervalMs: Int?
            /// Capture message content.
            public var captureContent: Bool?
            /// Passthrough keys.
            public var additionalProperties: [String: AnyCodable] = [:]
            /// Creates an empty section.
            public init() {}
            /// Typed fields.
            public static var configFields: [ConfigField<Self>] {
                [
                    .init("enabled", \.enabled), .init("endpoint", \.endpoint), .init("tracesEndpoint", \.tracesEndpoint),
                    .init("metricsEndpoint", \.metricsEndpoint), .init("logsEndpoint", \.logsEndpoint), .init("protocol", \.protocol),
                    .init("headers", \.headers), .init("serviceName", \.serviceName), .init("metricNamePrefix", \.metricNamePrefix),
                    .init("traces", \.traces), .init("metrics", \.metrics), .init("logs", \.logs), .init("logsExporter", \.logsExporter),
                    .init("sampleRate", \.sampleRate), .init("flushIntervalMs", \.flushIntervalMs),
                    .init("captureContent", \.captureContent),
                ]
            }
        }
    }

    /// `update`: self-update channel.
    public struct Update: ConfigDocumentObject {
        /// `stable`, `extended-stable`, `beta` or `dev`.
        public var channel: String?
        /// Check for updates on start (disabling it also stops anonymous update pings).
        public var checkOnStart: Bool?
        /// Automatic updates (`enabled`, default `false`).
        public var auto: AnyCodable?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] {
            [.init("channel", \.channel), .init("checkOnStart", \.checkOnStart), .init("auto", \.auto)]
        }
    }

    /// `telemetry`: anonymous telemetry consent (always off when `DO_NOT_TRACK=1`).
    public struct Telemetry: ConfigDocumentObject {
        /// Enables telemetry (default `false`).
        public var enabled: Bool?
        /// ISO timestamp of consent.
        public var consentedAt: String?
        /// Passthrough keys.
        public var additionalProperties: [String: AnyCodable] = [:]
        /// Creates an empty section.
        public init() {}
        /// Typed fields.
        public static var configFields: [ConfigField<Self>] { [.init("enabled", \.enabled), .init("consentedAt", \.consentedAt)] }

        /// Effective telemetry state: `DO_NOT_TRACK=1` always disables it.
        /// - Parameter environment: Process environment.
        /// - Returns: Whether telemetry may be sent.
        public func isEffectivelyEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
            if environment["DO_NOT_TRACK"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return false
            }
            return self.enabled == true
        }
    }
}
