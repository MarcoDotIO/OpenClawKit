import Foundation

/// Minimal RFC 5322 / MIME message parser for the IMAP watcher.
///
/// Extracts unfolded headers, the From/To/Delivered-To addresses, Subject (RFC 2047 encoded
/// words), Message-ID, the first `text/plain` body (falling back to tag-stripped `text/html`)
/// with base64/quoted-printable decoding, and attachment filenames.
public struct IMAPMailMessage: Sendable, Equatable {
    /// One mailbox address.
    public struct Address: Sendable, Equatable {
        /// Display name.
        public var name: String?
        /// `local@domain`.
        public var address: String

        /// Display text (`Name <address>` or the address).
        public var text: String {
            if let name, !name.isEmpty {
                return "\(name) <\(self.address)>"
            }
            return self.address
        }
    }

    /// Header lines in order (`name`, unfolded value).
    public var headers: [(name: String, value: String)]
    /// Plain-text body.
    public var text: String?
    /// Attachment filenames.
    public var attachmentNames: [String]

    /// Equality over headers, text and attachment names.
    /// - Parameters:
    ///   - lhs: Left value.
    ///   - rhs: Right value.
    /// - Returns: Whether both are equal.
    public static func == (lhs: IMAPMailMessage, rhs: IMAPMailMessage) -> Bool {
        lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
            && lhs.text == rhs.text && lhs.attachmentNames == rhs.attachmentNames
    }

    /// Parses a raw message.
    /// - Parameter raw: RFC 5322 bytes.
    public init(raw: Data) {
        let (headers, body) = Self.splitHeaders(raw)
        self.headers = headers
        var texts: (plain: String?, html: String?) = (nil, nil)
        var attachments: [String] = []
        Self.walk(headers: headers, body: body, texts: &texts, attachments: &attachments, depth: 0)
        self.text = texts.plain ?? texts.html.map(Self.stripHTML)
        self.attachmentNames = attachments
    }

    /// All values of a header (case-insensitive).
    /// - Parameter name: Header name.
    /// - Returns: Values in order.
    public func values(_ name: String) -> [String] {
        let lowered = name.lowercased()
        return self.headers.filter { $0.name.lowercased() == lowered }.map(\.value)
    }

    /// First value of a header.
    /// - Parameter name: Header name.
    /// - Returns: Value.
    public func value(_ name: String) -> String? {
        self.values(name).first
    }

    /// Decoded subject.
    public var subject: String? {
        self.value("Subject").map(Self.decodeEncodedWords)
    }

    /// Message-ID (with angle brackets).
    public var messageID: String? {
        self.value("Message-ID")?.trimmingCharacters(in: .whitespaces)
    }

    /// Addresses of the single From header (empty when absent).
    public var from: [Address] {
        self.values("From").flatMap(Self.parseAddressList)
    }

    /// Recipient addresses from `To` and `Delivered-To`.
    public var recipients: [String] {
        self.values("To").flatMap(Self.parseAddressList).map(\.address) + self.values("Delivered-To").flatMap(Self.parseAddressList).map(\.address)
    }

    // MARK: Parsing

    static func splitHeaders(_ raw: Data) -> ([(name: String, value: String)], Data) {
        let bytes = [UInt8](raw)
        var index = 0
        var headerEnd = bytes.count
        var bodyStart = bytes.count
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    headerEnd = index
                    bodyStart = index + 2
                    break
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    headerEnd = index
                    bodyStart = index + 3
                    break
                }
            }
            index += 1
        }
        let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        var headers: [(name: String, value: String)] = []
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    headers.append((name, value))
                }
            }
        }
        return (headers, bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data())
    }

    private static func walk(
        headers: [(name: String, value: String)],
        body: Data,
        texts: inout (plain: String?, html: String?),
        attachments: inout [String],
        depth: Int
    ) {
        let contentType = headers.first { $0.name.lowercased() == "content-type" }?.value ?? "text/plain"
        let disposition = headers.first { $0.name.lowercased() == "content-disposition" }?.value ?? ""
        let encoding = headers.first { $0.name.lowercased() == "content-transfer-encoding" }?.value.lowercased() ?? "7bit"
        let (mediaType, parameters) = self.parseParameterized(contentType)
        let (dispositionType, dispositionParameters) = self.parseParameterized(disposition)
        if mediaType.hasPrefix("multipart/"), let boundary = parameters["boundary"], depth < 8 {
            for part in self.splitMultipart(body, boundary: boundary) {
                let (partHeaders, partBody) = self.splitHeaders(part)
                self.walk(headers: partHeaders, body: partBody, texts: &texts, attachments: &attachments, depth: depth + 1)
            }
            return
        }
        let filename = dispositionParameters["filename"] ?? parameters["name"]
        if dispositionType == "attachment" || (filename != nil && !mediaType.hasPrefix("text/")) {
            if let filename {
                attachments.append(self.decodeEncodedWords(filename))
            }
            return
        }
        let decoded = self.decodeBody(body, encoding: encoding)
        let text = self.decodeText(decoded, charset: parameters["charset"])
        if mediaType == "text/plain", texts.plain == nil {
            texts.plain = text
        } else if mediaType == "text/html", texts.html == nil {
            texts.html = text
        }
    }

    static func parseParameterized(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if character == ";", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            parameters[key] = raw
        }
        return (type, parameters)
    }

    private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let delimiter = "--" + boundary
        var parts: [Data] = []
        var current: [String]?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(delimiter) {
                if let current {
                    parts.append(Data(current.joined(separator: "\n").utf8))
                }
                current = line.hasPrefix(delimiter + "--") ? nil : []
                if line.hasPrefix(delimiter + "--") { break }
            } else if current != nil {
                current?.append(line)
            }
        }
        return parts
    }

    private static func decodeBody(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let cleaned = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            return self.decodeQuotedPrintable(String(decoding: body, as: UTF8.self), underscoreIsSpace: false)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ text: String, underscoreIsSpace: Bool) -> Data {
        var output = Data()
        let bytes = Array(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "=") {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    output.append(value)
                    index += 3
                    continue
                }
            }
            output.append(underscoreIsSpace && byte == UInt8(ascii: "_") ? 0x20 : byte)
            index += 1
        }
        return output
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "windows-1252", "cp1252":
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        default:
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Decodes RFC 2047 encoded words (`=?charset?B|Q?text?=`).
    /// - Parameter value: Header value.
    /// - Returns: Decoded text.
    public static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        var result = ""
        var cursor = value.startIndex
        var lastWasEncoded = false
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let modeRange = Range(match.range(at: 2), in: value),
                  let textRange = Range(match.range(at: 3), in: value)
            else { continue }
            let between = String(value[cursor..<range.lowerBound])
            if !(lastWasEncoded && between.allSatisfy(\.isWhitespace)) {
                result += between
            }
            let payload = String(value[textRange])
            let data = value[modeRange].uppercased() == "B"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data(payload.utf8)
                : self.decodeQuotedPrintable(payload, underscoreIsSpace: true)
            result += self.decodeText(data, charset: String(value[charsetRange]))
            cursor = range.upperBound
            lastWasEncoded = true
        }
        result += value[cursor...]
        return result
    }

    /// Parses an address list (`Name <a@b>, c@d`).
    /// - Parameter value: Header value.
    /// - Returns: Addresses.
    public static func parseAddressList(_ value: String) -> [Address] {
        var entries: [String] = []
        var current = ""
        var quoted = false
        var angle = 0
        for character in value {
            switch character {
            case "\"": quoted.toggle()
            case "<" where !quoted: angle += 1
            case ">" where !quoted: angle = max(0, angle - 1)
            default: break
            }
            if character == ",", !quoted, angle == 0 {
                entries.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        entries.append(current)
        return entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    name = String(name.dropFirst().dropLast())
                }
                guard address.contains("@") else { return nil }
                return Address(name: name.isEmpty ? nil : self.decodeEncodedWords(name), address: address)
            }
            guard trimmed.contains("@"), !trimmed.contains(" ") else { return nil }
            return Address(name: nil, address: trimmed)
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
