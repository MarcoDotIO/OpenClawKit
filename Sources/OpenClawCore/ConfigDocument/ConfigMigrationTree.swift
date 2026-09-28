import Foundation
import OpenClawProtocol

// Mutable, insertion-ordered JSON tree used by the doctor-migration port.
//
// Upstream migrations mutate plain JavaScript objects in place (insertion-ordered keys, `delete`,
// shared references after `mergeMissing`). This reference-typed tree mirrors those semantics so the
// Swift port can follow the TypeScript line by line, and it carries key order through to the writer.

/// One JSON value in a mutable migration tree.
enum MigrationValue {
    case scalar(AnyCodable)
    case object(MigrationObject)
    case array(MigrationArray)

    init(_ value: AnyCodable, path: [String] = [], keyOrder: ConfigKeyOrder? = nil) {
        switch value.value {
        case .object(let object):
            self = .object(MigrationObject(object, path: path, keyOrder: keyOrder))
        case .array(let array):
            let items = array.enumerated().map { index, element in
                MigrationValue(element, path: path + [String(index)], keyOrder: keyOrder)
            }
            self = .array(MigrationArray(items))
        default:
            self = .scalar(value)
        }
    }

    static func string(_ value: String) -> MigrationValue {
        .scalar(AnyCodable(.string(value)))
    }

    static func bool(_ value: Bool) -> MigrationValue {
        .scalar(AnyCodable(.bool(value)))
    }

    static func int(_ value: Int) -> MigrationValue {
        .scalar(AnyCodable(.int(value)))
    }

    static func double(_ value: Double) -> MigrationValue {
        .scalar(AnyCodable(.double(value)))
    }

    var object: MigrationObject? {
        if case .object(let object) = self {
            return object
        }
        return nil
    }

    var array: MigrationArray? {
        if case .array(let array) = self {
            return array
        }
        return nil
    }

    var stringValue: String? {
        if case .scalar(let value) = self {
            return value.stringValue
        }
        return nil
    }

    var boolValue: Bool? {
        if case .scalar(let value) = self, case .bool(let flag) = value.value {
            return flag
        }
        return nil
    }

    /// Numeric value (integers and doubles).
    var numberValue: Double? {
        guard case .scalar(let value) = self else {
            return nil
        }
        switch value.value {
        case .int(let int):
            return Double(int)
        case .double(let double):
            return double
        default:
            return nil
        }
    }

    var isNumber: Bool {
        self.numberValue != nil
    }

    var anyCodable: AnyCodable {
        switch self {
        case .scalar(let value):
            return value
        case .object(let object):
            return object.anyCodable
        case .array(let array):
            return AnyCodable(.array(array.items.map(\.anyCodable)))
        }
    }

    func deepCopy() -> MigrationValue {
        switch self {
        case .scalar:
            return self
        case .object(let object):
            return .object(object.deepCopy())
        case .array(let array):
            return .array(MigrationArray(array.items.map { $0.deepCopy() }))
        }
    }

    /// Structural equality (ignores key order).
    func isEqual(to other: MigrationValue) -> Bool {
        self.anyCodable == other.anyCodable
    }

    func recordKeyOrder(into order: inout ConfigKeyOrder, path: [String]) {
        switch self {
        case .scalar:
            return
        case .object(let object):
            order.set(object.keys, at: path)
            for key in object.keys {
                object[key]?.recordKeyOrder(into: &order, path: path + [key])
            }
        case .array(let array):
            for (index, item) in array.items.enumerated() {
                item.recordKeyOrder(into: &order, path: path + [String(index)])
            }
        }
    }
}

/// Insertion-ordered mutable JSON object.
final class MigrationObject {
    private(set) var keys: [String] = []
    private var storage: [String: MigrationValue] = [:]

    init() {}

    init(_ object: [String: AnyCodable], path: [String] = [], keyOrder: ConfigKeyOrder? = nil) {
        let ordered = ConfigOrderHint(keyOrder?.keys(at: path) ?? []).ordered(object.keys)
        for key in ordered {
            if let value = object[key] {
                self[key] = MigrationValue(value, path: path + [key], keyOrder: keyOrder)
            }
        }
    }

    subscript(key: String) -> MigrationValue? {
        get { self.storage[key] }
        set {
            if let newValue {
                if self.storage[key] == nil {
                    self.keys.append(key)
                }
                self.storage[key] = newValue
            } else {
                self.remove(key)
            }
        }
    }

    func has(_ key: String) -> Bool {
        self.storage[key] != nil
    }

    /// JavaScript `value !== undefined` semantics: present (JSON null counts as present).
    func isSet(_ key: String) -> Bool {
        self.storage[key] != nil
    }

    @discardableResult
    func remove(_ key: String) -> MigrationValue? {
        guard let value = self.storage.removeValue(forKey: key) else {
            return nil
        }
        self.keys.removeAll { $0 == key }
        return value
    }

    var isEmpty: Bool {
        self.keys.isEmpty
    }

    var count: Int {
        self.keys.count
    }

    var entries: [(key: String, value: MigrationValue)] {
        self.keys.compactMap { key in self.storage[key].map { (key, $0) } }
    }

    func object(_ key: String) -> MigrationObject? {
        self.storage[key]?.object
    }

    func string(_ key: String) -> String? {
        self.storage[key]?.stringValue
    }

    func bool(_ key: String) -> Bool? {
        self.storage[key]?.boolValue
    }

    /// Returns the object at `key`, creating (or replacing a non-object value with) an empty object.
    func ensureObject(_ key: String) -> MigrationObject {
        if let existing = self.object(key) {
            return existing
        }
        let created = MigrationObject()
        self[key] = .object(created)
        return created
    }

    func deepCopy() -> MigrationObject {
        let copy = MigrationObject()
        for (key, value) in self.entries {
            copy[key] = value.deepCopy()
        }
        return copy
    }

    var anyCodable: AnyCodable {
        var result: [String: AnyCodable] = [:]
        for (key, value) in self.entries {
            result[key] = value.anyCodable
        }
        return AnyCodable(.object(result))
    }

    var dictionary: [String: AnyCodable] {
        self.anyCodable.dictionaryValue ?? [:]
    }
}

/// Mutable JSON array.
final class MigrationArray {
    var items: [MigrationValue]

    init(_ items: [MigrationValue] = []) {
        self.items = items
    }
}

/// Shared helpers mirroring `legacy.shared.ts`, `merge-missing.ts` and `legacy-config-record-shared.ts`.
enum MigrationSupport {
    /// Upstream `isBlockedObjectKey`.
    static func isBlockedKey(_ key: String) -> Bool {
        key == "__proto__" || key == "constructor" || key == "prototype"
    }

    /// Fill missing fields in place; nested objects merge recursively (`mergeMissing`).
    static func mergeMissing(_ target: MigrationObject, _ source: MigrationObject) {
        for (key, value) in source.entries where !self.isBlockedKey(key) {
            guard let existing = target[key] else {
                target[key] = value
                continue
            }
            if let existingObject = existing.object, let sourceObject = value.object {
                self.mergeMissing(existingObject, sourceObject)
            }
        }
    }

    /// Moves `legacyKey` to `canonicalKey` when the canonical key is unset (`moveKey`).
    static func moveKey(
        _ owner: MigrationObject?,
        _ legacyKey: String,
        _ canonicalKey: String,
        path: String,
        changes: inout [String]
    ) {
        guard let owner, owner.has(legacyKey) else {
            return
        }
        if !owner.isSet(canonicalKey) {
            owner[canonicalKey] = owner[legacyKey]
            changes.append("Moved \(path).\(legacyKey) → \(path).\(canonicalKey).")
        } else {
            changes.append("Removed \(path).\(legacyKey) (\(path).\(canonicalKey) already set).")
        }
        owner.remove(legacyKey)
    }

    /// Deletes a nested path; `*` matches every record entry (`deleteRetiredPath`).
    @discardableResult
    static func deleteRetiredPath(
        _ owner: MigrationObject?,
        _ path: ArraySlice<String>,
        removed: inout [String],
        prefix: String = ""
    ) -> Bool {
        guard let owner, let key = path.first else {
            return false
        }
        let rest = path.dropFirst()
        if key == "*" {
            var changed = false
            for (entryKey, value) in owner.entries {
                changed = self.deleteRetiredPath(value.object, rest, removed: &removed, prefix: "\(prefix)\(entryKey).") || changed
            }
            return changed
        }
        if rest.isEmpty {
            guard owner.has(key) else {
                return false
            }
            owner.remove(key)
            removed.append("\(prefix)\(key)")
            return true
        }
        return self.deleteRetiredPath(owner.object(key), rest, removed: &removed, prefix: "\(prefix)\(key).")
    }

    @discardableResult
    static func deleteRetiredPath(_ owner: MigrationObject?, _ path: [String]) -> Bool {
        var removed: [String] = []
        return self.deleteRetiredPath(owner, path[...], removed: &removed)
    }

    /// Visits `agents.entries.*` (or the legacy `agents.list[]` when entries are absent).
    static func visitAgentEntries(_ root: MigrationObject, _ visitor: (MigrationObject, String) -> Void) {
        guard let agents = root.object("agents") else {
            return
        }
        if let entries = agents.object("entries") {
            for (agentID, entry) in entries.entries where !self.isBlockedKey(agentID) {
                if let object = entry.object {
                    visitor(object, "agents.entries.\(agentID)")
                }
            }
            return
        }
        if let list = agents["list"]?.array {
            for (index, entry) in list.items.enumerated() {
                guard let object = entry.object else { continue }
                if let id = object.string("id"), self.isBlockedKey(id) { continue }
                visitor(object, "agents.list[\(index)]")
            }
        }
    }

    /// Visits `agents.defaults` and every agent entry.
    static func visitAgentConfigScopes(_ root: MigrationObject, _ visitor: (MigrationObject, String) -> Void) {
        if let defaults = root.object("agents")?.object("defaults") {
            visitor(defaults, "agents.defaults")
        }
        self.visitAgentEntries(root, visitor)
    }

    /// Visits `channels.<id>` and each `channels.<id>.accounts.<accountId>`.
    static func visitChannelEntries(_ root: MigrationObject, _ channelID: String, _ visitor: (MigrationObject, String) -> Void) {
        guard let channel = root.object("channels")?.object(channelID) else {
            return
        }
        visitor(channel, "channels.\(channelID)")
        if let accounts = channel.object("accounts") {
            for (accountID, account) in accounts.entries where !self.isBlockedKey(accountID) {
                if let object = account.object {
                    visitor(object, "channels.\(channelID).accounts.\(accountID)")
                }
            }
        }
    }

    /// Port of `normalizeAgentId` (`packages/normalization-core/src/agent-id.ts`).
    static func normalizeAgentID(_ value: String?) -> String {
        OpenClawConfigDocument.normalizeAgentID(value)
    }
}
