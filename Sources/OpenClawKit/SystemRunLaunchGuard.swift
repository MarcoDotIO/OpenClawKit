#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Identity of an approved `system.run` executable, captured when the approval is granted.
///
/// ``realPath`` is the POSIX `realpath(3)` of the executable. ``sha256`` is recorded when this user
/// can modify the executable (the file or its directory is writable), so a later swap of the file
/// contents is caught even though the path still matches.
public struct OpenClawSystemRunExecutableBinding: Codable, Sendable, Equatable {
    /// Resolved real path (symlinks and `/private/tmp`-style aliases resolved).
    public let realPath: String
    /// Lowercase SHA-256 hex of the executable, for writable executables.
    public let sha256: String?

    /// Creates a binding.
    /// - Parameters:
    ///   - realPath: Resolved real path.
    ///   - sha256: Content hash for writable executables.
    public init(realPath: String, sha256: String?) {
        self.realPath = realPath
        self.sha256 = sha256
    }
}

/// Re-checks an approved `system.run` immediately before the process is spawned (macOS exec hosts).
///
/// Between approval and launch the approval policy or the executable can change. Right before
/// spawning, a host calls ``verifyBeforeLaunch(params:executablePath:binding:stateDirectoryURL:)``,
/// which reads the delayed-approval policy snapshot from the gateway-forwarded plan, re-reads the
/// persisted exec policy, re-resolves the executable's real path and, for writable executables,
/// re-hashes it. Any mismatch is a `SYSTEM_RUN_DENIED` node error; the host must not launch and must
/// not re-present the request.
public enum OpenClawSystemRunLaunchGuard {
    /// Environment keys a launch-directory `.env` must never inject (upstream: Homebrew's curl/git
    /// overrides let a checkout redirect package-manager downloads).
    public static let blockedLaunchEnvironmentKeys: Set<String> = ["HOMEBREW_CURL_PATH", "HOMEBREW_GIT_PATH"]

    /// Captures the binding for an executable at approval time.
    /// - Parameter executablePath: Absolute executable path.
    /// - Returns: The binding.
    /// - Throws: ``OpenClawNodeError`` (`SYSTEM_RUN_DENIED`) when the path cannot be resolved or read.
    public static func bind(executablePath: String) throws -> OpenClawSystemRunExecutableBinding {
        guard let realPath = self.realPath(executablePath) else {
            throw self.denied("executable could not be resolved")
        }
        guard self.isWritableByCurrentUser(realPath) else {
            return OpenClawSystemRunExecutableBinding(realPath: realPath, sha256: nil)
        }
        guard let digest = self.sha256Hex(ofFileAt: realPath) else {
            throw self.denied("executable could not be read")
        }
        return OpenClawSystemRunExecutableBinding(realPath: realPath, sha256: digest)
    }

    /// Verifies a `system.run` right before launch, failing closed like upstream.
    ///
    /// A malformed ``OpenClawSystemRunParams/systemRunPlan`` is `INVALID_REQUEST`, and a run that
    /// carries delayed approval (``OpenClawSystemRunParams/carriesDelayedApproval``) without a
    /// prepared ``OpenClawSystemRunApprovalPlan/policySnapshot`` is `INVALID_REQUEST` ("delayed
    /// approval requires a prepared policy snapshot"). Otherwise the snapshot is compared with the
    /// persisted policy and the executable binding is re-checked.
    /// - Parameters:
    ///   - params: The decoded `system.run` params.
    ///   - executablePath: Executable path about to be spawned.
    ///   - binding: Binding captured at approval time, or `nil` when the approval did not bind one.
    ///   - stateDirectoryURL: State directory of the exec-approvals store.
    /// - Returns: `nil` when the launch may proceed, otherwise the node error to return.
    public static func verifyBeforeLaunch(
        params: OpenClawSystemRunParams,
        executablePath: String,
        binding: OpenClawSystemRunExecutableBinding?,
        stateDirectoryURL: URL?) -> OpenClawNodeError?
    {
        let plan: OpenClawSystemRunApprovalPlan?
        do {
            plan = try params.approvalPlan()
        } catch let error as OpenClawNodeError {
            return error
        } catch {
            return OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: systemRunPlan invalid")
        }
        var snapshot: OpenClawSystemRunApprovalPolicySnapshot?
        if params.carriesDelayedApproval {
            guard let planSnapshot = plan?.policySnapshot else {
                return OpenClawNodeError(
                    code: .invalidRequest,
                    message: "INVALID_REQUEST: delayed approval requires a prepared policy snapshot")
            }
            snapshot = planSnapshot
        }
        return self.verifyBeforeLaunch(
            executablePath: executablePath,
            binding: binding,
            policySnapshot: snapshot,
            agentId: params.agentId,
            stateDirectoryURL: stateDirectoryURL)
    }

    /// Verifies an approved run right before launch with an explicit snapshot. Prefer
    /// ``verifyBeforeLaunch(params:executablePath:binding:stateDirectoryURL:)``, which reads the
    /// snapshot from the forwarded plan and fails closed when a delayed approval lacks one; this
    /// overload skips the policy re-check when `policySnapshot` is `nil`.
    /// - Parameters:
    ///   - executablePath: Executable path about to be spawned.
    ///   - binding: Binding captured at approval time, or `nil` when the approval did not bind one.
    ///   - policySnapshot: Policy the approval was granted under (``OpenClawSystemRunApprovalPlan/policySnapshot``).
    ///   - agentId: Agent whose policy applies.
    ///   - stateDirectoryURL: State directory of the exec-approvals store (required with `policySnapshot`).
    /// - Returns: `nil` when the launch may proceed, otherwise a `SYSTEM_RUN_DENIED` error.
    public static func verifyBeforeLaunch(
        executablePath: String,
        binding: OpenClawSystemRunExecutableBinding?,
        policySnapshot: OpenClawSystemRunApprovalPolicySnapshot? = nil,
        agentId: String? = nil,
        stateDirectoryURL: URL? = nil) -> OpenClawNodeError?
    {
        if let policySnapshot {
            guard let stateDirectoryURL else {
                return self.denied("exec approvals unavailable before execution")
            }
            let current: OpenClawSystemRunApprovalPolicySnapshot
            do {
                let record = try ExecApprovalsSQLiteStore.read(stateDirectoryURL: stateDirectoryURL)
                current = OpenClawSystemRunApprovalPolicySnapshot(document: record?.document, agentId: agentId)
            } catch {
                return self.denied("exec approvals unavailable before execution")
            }
            guard policySnapshot.isCurrent(current) else {
                return self.denied("exec approvals changed before execution")
            }
        }
        guard let binding else { return nil }
        guard let realPath = self.realPath(executablePath), realPath == binding.realPath else {
            return self.denied("approved executable path changed before execution")
        }
        if let expected = binding.sha256 {
            guard self.sha256Hex(ofFileAt: realPath) == expected else {
                return self.denied("approved executable changed before execution")
            }
        } else if self.isWritableByCurrentUser(realPath) {
            // Became writable after approval: its contents can no longer be vouched for.
            return self.denied("approved executable became writable before execution")
        }
        return nil
    }

    /// Drops ``blockedLaunchEnvironmentKeys`` from an environment assembled for the child process.
    /// - Parameter environment: Candidate environment.
    /// - Returns: The sanitized environment.
    public static func sanitizedLaunchEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !self.blockedLaunchEnvironmentKeys.contains($0.key) }
    }

    static func realPath(_ path: String) -> String? {
        guard !path.isEmpty, !path.utf8.contains(0), let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isWritableByCurrentUser(_ realPath: String) -> Bool {
        if access(realPath, W_OK) == 0 { return true }
        let directory = (realPath as NSString).deletingLastPathComponent
        return !directory.isEmpty && access(directory, W_OK) == 0
    }

    static func sha256Hex(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (or empty data) at end of file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func denied(_ reason: String) -> OpenClawNodeError {
        OpenClawNodeError(code: .systemRunDenied, message: "SYSTEM_RUN_DENIED: \(reason)")
    }
}
#endif
