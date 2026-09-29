import Foundation

// Hand-written port of upstream OpenClaw 2026.9.6
// apps/shared/OpenClawKit/Sources/OpenClawProtocol/WizardHelpers.swift, adapted to the enum-backed
// `AnyCodable` (upstream casts `value as? T`, which always fails against `AnySendableValue`).
// Keep the public API identical to upstream so ported wizard UIs compile unchanged.

/// One selectable option of a `wizard.*` select step.
public struct WizardOption: Sendable {
    /// Value sent back when the option is chosen.
    public let value: AnyCodable?
    /// Display label.
    public let label: String
    /// Optional secondary hint.
    public let hint: String?

    /// Creates a wizard option.
    /// - Parameters:
    ///   - value: Value sent back when the option is chosen.
    ///   - label: Display label.
    ///   - hint: Optional secondary hint.
    public init(value: AnyCodable?, label: String, hint: String?) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

/// Device-code sign-in details attached to a wizard step.
public struct WizardDeviceCodePresentation: Sendable {
    /// Code the user enters on the verification page.
    public let code: String
    /// Minutes until the code expires (only values in `1...1440` are kept).
    public let expiresInMinutes: Int?
    /// Optional instructions shown next to the code.
    public let message: String?

    /// Creates a device-code presentation.
    /// - Parameters:
    ///   - code: Code the user enters.
    ///   - expiresInMinutes: Minutes until the code expires.
    ///   - message: Optional instructions.
    public init(code: String, expiresInMinutes: Int?, message: String?) {
        self.code = code
        self.expiresInMinutes = expiresInMinutes
        self.message = message
    }
}

/// Parses a wizard step's `deviceCode` object.
/// - Parameter raw: `WizardStep.devicecode`.
/// - Returns: The presentation, or `nil` when no non-empty `code` is present.
public func parseWizardDeviceCode(_ raw: [String: AnyCodable]?) -> WizardDeviceCodePresentation? {
    guard let code = raw?["code"]?.stringValue, !code.isEmpty else { return nil }
    let allowedMinutes = 1...1440
    let expiresInMinutes = raw?["expiresInMinutes"]?.intValue.flatMap { allowedMinutes.contains($0) ? $0 : nil }
    return WizardDeviceCodePresentation(
        code: code,
        expiresInMinutes: expiresInMinutes,
        message: raw?["message"]?.stringValue
    )
}

/// Parses a wizard step's `options` array.
/// - Parameter raw: `WizardStep.options`.
/// - Returns: Options in wire order (empty when absent).
public func parseWizardOptions(_ raw: [[String: AnyCodable]]?) -> [WizardOption] {
    guard let raw else { return [] }
    return raw.map { entry in
        WizardOption(
            value: entry["value"],
            label: entry["label"]?.stringValue ?? "",
            hint: entry["hint"]?.stringValue
        )
    }
}

/// Normalizes a wizard status value (`running`, `done`, `cancelled`, `error`, ...).
/// - Parameter value: Raw status value.
/// - Returns: Trimmed, lowercased status, or `nil` when the value is not a string.
public func wizardStatusString(_ value: AnyCodable?) -> String? {
    value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// Returns a wizard step's type (`note`, `select`, `text`, `confirm`, `progress`, ...).
/// - Parameter step: Wizard step.
/// - Returns: Step type, or an empty string when absent.
public func wizardStepType(_ step: WizardStep) -> String {
    step.type.stringValue ?? ""
}

/// Returns who executes a wizard step.
///
/// `"gateway"` marks a step the Gateway runs itself (download/install progress). Those steps carry no
/// answer, so clients must poll for the next frame instead of waiting for input that will never come.
/// - Parameter step: Wizard step.
/// - Returns: Executor, or an empty string when absent.
public func wizardStepExecutor(_ step: WizardStep) -> String {
    step.executor?.stringValue ?? ""
}

/// Renders a scalar `AnyCodable` as a string (`""` for null, objects and arrays).
/// - Parameter value: Value to render.
/// - Returns: String form of the scalar.
public func anyCodableString(_ value: AnyCodable?) -> String {
    switch value?.value {
    case .string(let string):
        string
    case .int(let int):
        String(int)
    case .double(let double):
        String(double)
    case .bool(let bool):
        bool ? "true" : "false"
    default:
        ""
    }
}

/// Interprets an `AnyCodable` as a Boolean: numbers are `true` when non-zero and strings when
/// `true`, `1` or `yes` (case-insensitive).
/// - Parameter value: Value to interpret.
/// - Returns: Boolean interpretation (`false` for null, objects and arrays).
public func anyCodableBool(_ value: AnyCodable?) -> Bool {
    switch value?.value {
    case .bool(let bool):
        return bool
    case .int(let int):
        return int != 0
    case .double(let double):
        return double != 0
    case .string(let string):
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "true" || trimmed == "1" || trimmed == "yes"
    default:
        return false
    }
}

/// Returns the elements of an array value (`[]` for anything else).
/// - Parameter value: Value to read.
/// - Returns: Array elements.
public func anyCodableArray(_ value: AnyCodable?) -> [AnyCodable] {
    value?.arrayValue ?? []
}

/// Compares two wizard values, treating strings and numbers with the same text as equal.
/// - Parameters:
///   - lhs: First value.
///   - rhs: Second value.
/// - Returns: `true` when both values are equal scalars (or a string equals a number's text).
public func anyCodableEqual(_ lhs: AnyCodable?, _ rhs: AnyCodable?) -> Bool {
    switch (lhs?.value, rhs?.value) {
    case let (.string(l), .string(r)):
        l == r
    case let (.int(l), .int(r)):
        l == r
    case let (.double(l), .double(r)):
        l == r
    case let (.bool(l), .bool(r)):
        l == r
    case let (.string(l), .int(r)):
        l == String(r)
    case let (.int(l), .string(r)):
        String(l) == r
    case let (.string(l), .double(r)):
        l == String(r)
    case let (.double(l), .string(r)):
        String(l) == r
    default:
        false
    }
}
