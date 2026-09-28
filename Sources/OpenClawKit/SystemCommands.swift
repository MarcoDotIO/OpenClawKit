import Foundation
import OpenClawProtocol

public enum OpenClawSystemCommand: String, Codable, Sendable {
    case run = "system.run"
    case which = "system.which"
    case notify = "system.notify"
    case execApprovalsGet = "system.execApprovals.get"
    case execApprovalsSet = "system.execApprovals.set"
}

/// Host filesystem node commands.
///
/// `fs.listDir` is admin-only on the gateway (direct `node.invoke` and pairing approval both need
/// `operator.admin`); only desktop hosts should advertise it.
public enum OpenClawFileSystemCommand: String, Codable, Sendable {
    /// `fs.listDir`: list the child directories of one absolute host path (see ``FsListDirResult``).
    case listDir = "fs.listDir"
}

/// Wire names of node commands that exist upstream without a dedicated Swift enum
/// (`src/infra/node-commands.ts`, `src/gateway/node-command-policy.ts`).
///
/// Apple hosts that implement one of these declare the constant in `GatewayConnectOptions.commands`.
public enum OpenClawNodeCommandName {
    /// `system.run.prepare`: build an approval plan before `system.run`. Hosts that do not advertise
    /// it still receive approved `system.run` calls carrying `approved`/`approvalDecision`, because the
    /// gateway synthesizes a local plan.
    public static let systemRunPrepare = "system.run.prepare"
    /// `terminal.upload`: stage an uploaded file for a workspace terminal (admin-only).
    public static let terminalUpload = "terminal.upload"
    /// `browser.proxy`: browser proxy requests (admin-only).
    public static let browserProxy = "browser.proxy"
    /// `browser.proxy.upload.v1`: browser proxy uploads (admin-only).
    public static let browserProxyUpload = "browser.proxy.upload.v1"
    /// `mcp.tools.call.v1`: call an MCP tool hosted by the node.
    public static let mcpToolsCall = "mcp.tools.call.v1"
    /// `device.apps`: list installed apps (macOS and Android defaults).
    public static let deviceApps = "device.apps"
    /// `device.permissions`: report OS permission state (Android default).
    public static let devicePermissions = "device.permissions"
    /// `device.health`: report device health (Android default).
    public static let deviceHealth = "device.health"
    /// `desktop.stream`: stream the desktop (desktop default).
    public static let desktopStream = "desktop.stream"
}

public enum OpenClawNotificationPriority: String, Codable, Sendable {
    case passive
    case active
    case timeSensitive
}

public enum OpenClawNotificationDelivery: String, Codable, Sendable {
    case system
    case overlay
    case auto
}

/// Params for `system.run` (upstream `src/node-host/invoke-types.ts` `SystemRunParams`).
public struct OpenClawSystemRunParams: Codable, Sendable, Equatable {
    /// Argument vector; the first element is the executable.
    public var command: [String]
    /// Original shell text of the command, when known.
    public var rawCommand: String?
    /// Approval plan prepared by `system.run.prepare` or synthesized by the gateway.
    public var systemRunPlan: AnyCodable?
    /// Working directory.
    public var cwd: String?
    /// Extra environment variables.
    public var env: [String: String]?
    /// Timeout in milliseconds; see ``effectiveTimeoutMs(defaultTimeoutSec:)``.
    public var timeoutMs: Int?
    /// Whether the command needs screen-recording permission.
    public var needsScreenRecording: Bool?
    /// Agent that requested the run.
    public var agentId: String?
    /// Session that requested the run.
    public var sessionKey: String?
    /// `true` when an operator already approved this run (no prior `system.run.prepare` needed).
    public var approved: Bool?
    /// Approval decision (`allow-once`, `allow-always`, …) when ``approved`` is set.
    public var approvalDecision: String?
    /// Where the approval came from.
    public var approvalSource: String?
    /// Agent run the command belongs to; echoed on exec lifecycle events.
    public var runId: String?
    /// Suppresses the exit notification for this run.
    public var suppressNotifyOnExit: Bool?

    /// Creates `system.run` params.
    public init(
        command: [String],
        rawCommand: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeoutMs: Int? = nil,
        needsScreenRecording: Bool? = nil,
        agentId: String? = nil,
        sessionKey: String? = nil,
        approved: Bool? = nil,
        approvalDecision: String? = nil,
        runId: String? = nil,
        systemRunPlan: AnyCodable? = nil,
        approvalSource: String? = nil,
        suppressNotifyOnExit: Bool? = nil)
    {
        self.command = command
        self.rawCommand = rawCommand
        self.systemRunPlan = systemRunPlan
        self.cwd = cwd
        self.env = env
        self.timeoutMs = timeoutMs
        self.needsScreenRecording = needsScreenRecording
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.approved = approved
        self.approvalDecision = approvalDecision
        self.approvalSource = approvalSource
        self.runId = runId
        self.suppressNotifyOnExit = suppressNotifyOnExit
    }

    /// Timeout to apply: the explicit positive ``timeoutMs`` or, when absent, the host default (the
    /// `tools.exec.timeoutSec` mirror). Returns `nil` only when neither is set.
    public func effectiveTimeoutMs(defaultTimeoutSec: Int?) -> Int? {
        if let timeoutMs, timeoutMs > 0 {
            return timeoutMs
        }
        guard let defaultTimeoutSec, defaultTimeoutSec > 0 else { return nil }
        let (product, overflow) = defaultTimeoutSec.multipliedReportingOverflow(by: 1000)
        return overflow ? Int.max : product
    }
}

/// Captured process result returned by `system.run` (upstream `RunResult`).
public struct OpenClawSystemRunResult: Codable, Sendable, Equatable {
    /// Process exit code, when the process exited.
    public var exitCode: Int?
    /// Whether the run hit its timeout.
    public var timedOut: Bool
    /// Whether the run hit its no-output timeout.
    public var noOutputTimedOut: Bool?
    /// Whether the run succeeded.
    public var success: Bool
    /// Captured standard output.
    public var stdout: String
    /// Captured standard error.
    public var stderr: String
    /// Error message when the run failed to start or was denied.
    public var error: String?
    /// Whether output was truncated.
    public var truncated: Bool

    /// Creates a run result.
    public init(
        exitCode: Int? = nil,
        timedOut: Bool = false,
        noOutputTimedOut: Bool? = nil,
        success: Bool,
        stdout: String = "",
        stderr: String = "",
        error: String? = nil,
        truncated: Bool = false)
    {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.noOutputTimedOut = noOutputTimedOut
        self.success = success
        self.stdout = stdout
        self.stderr = stderr
        self.error = error
        self.truncated = truncated
    }
}

public struct OpenClawSystemWhichParams: Codable, Sendable, Equatable {
    public var bins: [String]

    public init(bins: [String]) {
        self.bins = bins
    }
}

public struct OpenClawSystemNotifyParams: Codable, Sendable, Equatable {
    public var title: String
    public var body: String
    public var sound: String?
    public var priority: OpenClawNotificationPriority?
    public var delivery: OpenClawNotificationDelivery?

    public init(
        title: String,
        body: String,
        sound: String? = nil,
        priority: OpenClawNotificationPriority? = nil,
        delivery: OpenClawNotificationDelivery? = nil)
    {
        self.title = title
        self.body = body
        self.sound = sound
        self.priority = priority
        self.delivery = delivery
    }
}
