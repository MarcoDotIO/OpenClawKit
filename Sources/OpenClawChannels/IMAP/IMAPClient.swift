import Foundation
import OpenClawCore

/// Byte transport for the IMAP client (TLS socket on Apple platforms; inject a fake in tests).
public protocol IMAPTransport: Sendable {
    /// Opens the connection.
    func open() async throws
    /// Writes bytes.
    /// - Parameter data: Bytes.
    func write(_ data: Data) async throws
    /// Reads the next chunk (empty at end of stream).
    /// - Returns: Bytes.
    func read() async throws -> Data
    /// Closes the connection.
    func close() async
}

/// IMAP protocol error.
public enum IMAPError: Error, LocalizedError, Sendable, Equatable {
    /// The server answered `NO`/`BAD`.
    case commandFailed(command: String, status: String, text: String)
    /// Authentication failed.
    case authenticationFailed(String)
    /// The connection closed.
    case connectionClosed
    /// The server did not answer in time.
    case timeout(String)
    /// Unexpected server data.
    case protocolViolation(String)

    /// Error description.
    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, text): "IMAP \(command) failed (\(status)): \(text)"
        case .authenticationFailed(let text): "IMAP authentication failed: \(text)"
        case .connectionClosed: "IMAP connection closed"
        case .timeout(let what): "IMAP timed out waiting for \(what)"
        case .protocolViolation(let text): "IMAP protocol error: \(text)"
        }
    }
}

/// Parsed IMAP data item.
public indirect enum IMAPToken: Sendable, Equatable {
    /// Atom (including bracketed sections such as `BODY[]`).
    case atom(String)
    /// Quoted string.
    case string(String)
    /// Literal bytes.
    case literal(Data)
    /// Parenthesized list.
    case list([IMAPToken])
    /// `NIL`.
    case null

    /// Text value of an atom or string.
    public var text: String? {
        switch self {
        case .atom(let value), .string(let value): value
        case .literal(let data): String(decoding: data, as: UTF8.self)
        default: nil
        }
    }
}

/// One message returned by `UID FETCH`.
public struct IMAPFetchedMessage: Sendable, Equatable {
    /// UID.
    public var uid: UInt32
    /// INTERNALDATE.
    public var internalDate: Date?
    /// RFC822.SIZE.
    public var size: Int?
    /// Raw source (possibly capped).
    public var source: Data?
}

/// Minimal IMAP4rev1 client used by ``IMAPMailboxWatcher`` (LOGIN, CAPABILITY, EXAMINE,
/// UID FETCH, IDLE, LOGOUT) with literal-aware response parsing.
public actor IMAPClient {
    private let transport: any IMAPTransport
    private var buffer = Data()
    private var closed = false
    private var readError: Error?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var tagCounter = 0

    /// Capabilities announced by the server.
    public private(set) var capabilities: Set<String> = []

    /// Creates a client.
    /// - Parameter transport: Byte transport.
    public init(transport: any IMAPTransport) {
        self.transport = transport
    }

    /// Opens the connection and reads the greeting.
    /// - Parameter timeout: Greeting timeout in seconds.
    public func connect(timeout: TimeInterval = 30) async throws {
        try await self.transport.open()
        self.readerTask = Task { [weak self, transport] in
            while !Task.isCancelled {
                do {
                    let chunk = try await transport.read()
                    guard let self else { return }
                    if chunk.isEmpty {
                        await self.markClosed(error: nil)
                        return
                    }
                    await self.append(chunk)
                } catch {
                    await self?.markClosed(error: error)
                    return
                }
            }
        }
        let greeting = try await self.readResponse(timeout: timeout)
        let text = Self.lineText(greeting)
        guard text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") else {
            throw IMAPError.protocolViolation("unexpected greeting: \(text.prefix(120))")
        }
        self.captureCapabilities(from: text)
    }

    /// Runs `CAPABILITY`.
    public func refreshCapabilities() async throws {
        let responses = try await self.command("CAPABILITY")
        for response in responses {
            self.captureCapabilities(from: Self.lineText(response))
        }
    }

    /// Runs `LOGIN` with quoted credentials.
    /// - Parameters:
    ///   - user: User.
    ///   - password: Password.
    public func login(user: String, password: String) async throws {
        guard !user.contains(where: \.isNewline), !password.contains(where: \.isNewline) else {
            throw IMAPError.authenticationFailed("credentials must not contain line breaks")
        }
        do {
            let responses = try await self.command("LOGIN \(Self.quote(user)) \(Self.quote(password))", redacted: "LOGIN")
            for response in responses {
                self.captureCapabilities(from: Self.lineText(response))
            }
        } catch IMAPError.commandFailed(_, _, let text) {
            throw IMAPError.authenticationFailed(text)
        }
    }

    /// Opens a mailbox read-only (`EXAMINE`).
    /// - Parameter mailbox: Mailbox name.
    /// - Returns: UIDVALIDITY and UIDNEXT.
    public func examine(_ mailbox: String) async throws -> (uidValidity: UInt32, uidNext: UInt32?) {
        let responses = try await self.command("EXAMINE \(Self.quote(mailbox))")
        var uidValidity: UInt32?
        var uidNext: UInt32?
        for response in responses {
            let text = Self.lineText(response)
            if let value = Self.firstMatch("\\[UIDVALIDITY (\\d+)\\]", in: text) {
                uidValidity = UInt32(value)
            }
            if let value = Self.firstMatch("\\[UIDNEXT (\\d+)\\]", in: text) {
                uidNext = UInt32(value)
            }
        }
        guard let uidValidity else {
            throw IMAPError.protocolViolation("EXAMINE returned no UIDVALIDITY")
        }
        return (uidValidity, uidNext)
    }

    /// Fetches messages with UID above `after` (`UID FETCH after+1:* (UID INTERNALDATE RFC822.SIZE BODY.PEEK[]<0.max>)`).
    /// - Parameters:
    ///   - after: Last seen UID.
    ///   - maxBytes: Source byte cap.
    /// - Returns: Messages with UID greater than `after`, ascending.
    public func fetch(after: UInt32, maxBytes: Int) async throws -> [IMAPFetchedMessage] {
        let responses = try await self.command("UID FETCH \(after &+ 1):* (UID INTERNALDATE RFC822.SIZE BODY.PEEK[]<0.\(maxBytes)>)")
        var messages: [IMAPFetchedMessage] = []
        for response in responses {
            let tokens = Self.tokenize(response)
            guard tokens.count >= 4, tokens[0] == .atom("*"), tokens[2].text?.uppercased() == "FETCH", case .list(let items) = tokens[3] else {
                continue
            }
            var message = IMAPFetchedMessage(uid: 0)
            var index = 0
            while index + 1 < items.count {
                let key = items[index].text?.uppercased() ?? ""
                let value = items[index + 1]
                switch key {
                case "UID": message.uid = value.text.flatMap { UInt32($0) } ?? 0
                case "INTERNALDATE": message.internalDate = value.text.flatMap(Self.parseInternalDate)
                case "RFC822.SIZE": message.size = value.text.flatMap { Int($0) }
                default:
                    if key.hasPrefix("BODY[") {
                        if case .literal(let data) = value {
                            message.source = data
                        } else if let text = value.text {
                            message.source = Data(text.utf8)
                        }
                    }
                }
                index += 2
            }
            if message.uid > after {
                messages.append(message)
            }
        }
        return messages.sorted { $0.uid < $1.uid }
    }

    /// Runs `IDLE` until an `EXISTS` update arrives or the timeout elapses, then `DONE`.
    /// - Parameter timeout: Seconds to idle.
    /// - Returns: `true` when the mailbox changed.
    public func idle(timeout: TimeInterval) async throws -> Bool {
        let tag = self.nextTag()
        try await self.transport.write(Data("\(tag) IDLE\r\n".utf8))
        var sawExists = false
        while true {
            let response = try await self.readResponse(timeout: 30)
            let text = Self.lineText(response)
            if text.hasPrefix("+") { break }
            if text.hasPrefix(tag + " ") {
                throw IMAPError.commandFailed(command: "IDLE", status: "NO", text: text)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !sawExists {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let response = try await self.readResponseIfAvailable(timeout: remaining) else { break }
            if Self.lineText(response).range(of: "^\\* \\d+ EXISTS", options: [.regularExpression, .caseInsensitive]) != nil {
                sawExists = true
            }
        }
        try await self.transport.write(Data("DONE\r\n".utf8))
        while true {
            let response = try await self.readResponse(timeout: 30)
            let text = Self.lineText(response)
            if text.hasPrefix(tag + " ") {
                break
            }
            if text.range(of: "^\\* \\d+ EXISTS", options: [.regularExpression, .caseInsensitive]) != nil {
                sawExists = true
            }
        }
        return sawExists
    }

    /// Sends `LOGOUT` (best effort) and closes the transport.
    public func logout() async {
        if !self.closed {
            _ = try? await self.command("LOGOUT", timeout: 5)
        }
        await self.close()
    }

    /// Closes the transport.
    public func close() async {
        self.readerTask?.cancel()
        await self.transport.close()
        self.markClosed(error: nil)
    }

    // MARK: Commands

    /// Runs one tagged command and returns its untagged responses.
    /// - Parameters:
    ///   - command: Command text (without tag).
    ///   - redacted: Name used in errors.
    ///   - timeout: Response timeout.
    /// - Returns: Untagged responses (raw logical lines including literals).
    @discardableResult
    public func command(_ command: String, redacted: String? = nil, timeout: TimeInterval = 120) async throws -> [Data] {
        let tag = self.nextTag()
        try await self.transport.write(Data("\(tag) \(command)\r\n".utf8))
        var untagged: [Data] = []
        while true {
            let response = try await self.readResponse(timeout: timeout)
            let text = Self.lineText(response)
            if text.hasPrefix(tag + " ") {
                let rest = text.dropFirst(tag.count + 1)
                let status = rest.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
                guard status == "OK" else {
                    let name = redacted ?? String(command.split(separator: " ").first ?? "")
                    let detail = String(rest.dropFirst(status.count)).trimmingCharacters(in: .whitespaces)
                    throw IMAPError.commandFailed(command: name, status: status, text: detail)
                }
                return untagged
            }
            untagged.append(response)
        }
    }

    private func nextTag() -> String {
        self.tagCounter += 1
        return "A\(self.tagCounter)"
    }

    private func captureCapabilities(from text: String) {
        guard let range = text.range(of: "CAPABILITY ", options: .caseInsensitive) else { return }
        var list = String(text[range.upperBound...])
        if let close = list.firstIndex(of: "]") {
            list = String(list[..<close])
        }
        self.capabilities = Set(list.split(separator: " ").map { $0.uppercased() })
    }

    // MARK: Reading

    private func append(_ chunk: Data) {
        self.buffer.append(chunk)
        self.wakeAll()
    }

    private func markClosed(error: Error?) {
        guard !self.closed else { return }
        self.closed = true
        self.readError = error
        self.wakeAll()
    }

    private func wakeAll() {
        let pending = self.waiters
        self.waiters.removeAll()
        for waiter in pending.values {
            waiter.resume()
        }
    }

    private func waitForData(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            await self?.expireWaiter(id)
        }
        await withCheckedContinuation { continuation in
            self.waiters[id] = continuation
        }
        timer.cancel()
        return true
    }

    private func expireWaiter(_ id: UUID) {
        self.waiters.removeValue(forKey: id)?.resume()
    }

    private func readResponse(timeout: TimeInterval) async throws -> Data {
        guard let response = try await self.readResponseIfAvailable(timeout: timeout) else {
            throw IMAPError.timeout("server response")
        }
        return response
    }

    private func readResponseIfAvailable(timeout: TimeInterval) async throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let response = self.extractResponse() {
                return response
            }
            if self.closed {
                if let readError {
                    throw readError
                }
                throw IMAPError.connectionClosed
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            _ = await self.waitForData(timeout: remaining)
        }
    }

    /// Extracts one logical response (a line plus any literals it announces) from the buffer.
    private func extractResponse() -> Data? {
        let bytes = [UInt8](self.buffer)
        var index = 0
        while true {
            guard let lineEnd = Self.findCRLF(bytes, from: index) else { return nil }
            let lineBytes = bytes[index..<lineEnd]
            if let literalLength = Self.trailingLiteralLength(lineBytes) {
                let literalStart = lineEnd + 2
                guard bytes.count >= literalStart + literalLength else { return nil }
                index = literalStart + literalLength
                continue
            }
            let responseEnd = lineEnd + 2
            let response = Data(bytes[0..<responseEnd])
            self.buffer = Data(bytes[responseEnd...])
            return response
        }
    }

    static func findCRLF(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A {
                return index
            }
            index += 1
        }
        return nil
    }

    static func trailingLiteralLength(_ line: ArraySlice<UInt8>) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = String(decoding: line[(open + 1)..<(line.endIndex - 1)], as: UTF8.self)
        if digits.hasSuffix("+") {
            digits.removeLast()
        }
        return Int(digits)
    }

    // MARK: Parsing helpers

    /// First line of a response as text.
    static func lineText(_ response: Data) -> String {
        let bytes = [UInt8](response)
        let end = self.findCRLF(bytes, from: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    /// Tokenizes a logical response (atoms, quoted strings, literals, lists).
    static func tokenize(_ response: Data) -> [IMAPToken] {
        let bytes = [UInt8](response)
        var index = 0
        return self.parseTokens(bytes, &index, closing: nil)
    }

    private static func parseTokens(_ bytes: [UInt8], _ index: inout Int, closing: UInt8?) -> [IMAPToken] {
        var tokens: [IMAPToken] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x20, 0x0D, 0x0A:
                index += 1
            case UInt8(ascii: "("):
                index += 1
                tokens.append(.list(self.parseTokens(bytes, &index, closing: UInt8(ascii: ")"))))
            case UInt8(ascii: ")"):
                index += 1
                if closing != nil { return tokens }
            case UInt8(ascii: "\""):
                index += 1
                var value = [UInt8]()
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count {
                        index += 1
                    }
                    value.append(bytes[index])
                    index += 1
                }
                index += 1
                tokens.append(.string(String(decoding: value, as: UTF8.self)))
            case UInt8(ascii: "{"):
                guard let close = bytes[index...].firstIndex(of: UInt8(ascii: "}")) else {
                    index = bytes.count
                    break
                }
                let digits = String(decoding: bytes[(index + 1)..<close], as: UTF8.self).replacingOccurrences(of: "+", with: "")
                let length = Int(digits) ?? 0
                let start = min(bytes.count, close + 3)
                let end = min(bytes.count, start + length)
                tokens.append(.literal(Data(bytes[start..<end])))
                index = end
            default:
                var value = [UInt8]()
                var depth = 0
                while index < bytes.count {
                    let current = bytes[index]
                    if depth == 0, current == 0x20 || current == UInt8(ascii: "(") || current == UInt8(ascii: ")") || current == 0x0D || current == 0x0A {
                        break
                    }
                    if current == UInt8(ascii: "[") { depth += 1 }
                    if current == UInt8(ascii: "]") { depth = max(0, depth - 1) }
                    value.append(current)
                    index += 1
                }
                let text = String(decoding: value, as: UTF8.self)
                tokens.append(text.uppercased() == "NIL" ? .null : .atom(text))
            }
        }
        return tokens
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    static func parseInternalDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }
}
