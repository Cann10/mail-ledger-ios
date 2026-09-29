import Foundation
import Network
import Security

struct MIMETextContent: Equatable, Sendable {
    let sender: String
    let subject: String
    let plainText: String
    let htmlText: String
    /// 受信MX（Apple）が付与した `Authentication-Results` ヘッダ値。無ければ nil。
    let authenticationResults: String?
}

struct MIMEMessageParser {
    private let htmlExtractor = HTMLTextExtractor()

    func parse(rawMessage: Data) -> MIMETextContent {
        let parsed = parsePart(rawMessage)
        return MIMETextContent(
            sender: MIMEHeaderDecoder.decode(parsed.headers["from"] ?? ""),
            subject: MIMEHeaderDecoder.decode(parsed.headers["subject"] ?? ""),
            plainText: parsed.plainParts.joined(separator: "\n"),
            htmlText: parsed.htmlParts
                .map { htmlExtractor.plainText(fromHTML: $0) }
                .joined(separator: "\n"),
            authenticationResults: parsed.headers["authentication-results"]
                ?? parsed.headers["arc-authentication-results"]
        )
    }

    private struct ParsedPart {
        var headers: [String: String]
        var plainParts: [String]
        var htmlParts: [String]
    }

    private func parsePart(_ data: Data) -> ParsedPart {
        let (headerData, bodyData) = splitHeaderAndBody(data)
        let headers = parseHeaders(headerData)
        let contentType = headers["content-type"] ?? "text/plain"
        let lowercasedType = contentType.lowercased()

        if lowercasedType.hasPrefix("multipart/"),
           let boundary = parameter(named: "boundary", in: contentType) {
            return splitMultipart(bodyData, boundary: boundary).reduce(
                into: ParsedPart(headers: headers, plainParts: [], htmlParts: [])
            ) { result, partData in
                let part = parsePart(partData)
                result.plainParts.append(contentsOf: part.plainParts)
                result.htmlParts.append(contentsOf: part.htmlParts)
            }
        }

        guard lowercasedType.hasPrefix("text/plain")
                || lowercasedType.hasPrefix("text/html") else {
            return ParsedPart(headers: headers, plainParts: [], htmlParts: [])
        }
        // 添付として届いたパートは本文として解析しない（URL・添付を解析対象にしない方針）。
        if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true {
            return ParsedPart(headers: headers, plainParts: [], htmlParts: [])
        }

        let transferEncoding = headers["content-transfer-encoding"]?.lowercased() ?? "7bit"
        let decodedData = decodeBody(bodyData, transferEncoding: transferEncoding)
        let charset = parameter(named: "charset", in: contentType)
        let text = decodeText(decodedData, charset: charset)
        if lowercasedType.hasPrefix("text/html") {
            return ParsedPart(headers: headers, plainParts: [], htmlParts: [text])
        }
        return ParsedPart(headers: headers, plainParts: [text], htmlParts: [])
    }

    private func splitHeaderAndBody(_ data: Data) -> (Data, Data) {
        let separators = [Data([13, 10, 13, 10]), Data([10, 10])]
        for separator in separators {
            if let range = data.range(of: separator) {
                return (
                    data.subdata(in: data.startIndex..<range.lowerBound),
                    data.subdata(in: range.upperBound..<data.endIndex)
                )
            }
        }
        return (data, Data())
    }

    private func parseHeaders(_ data: Data) -> [String: String] {
        let source = (String(data: data, encoding: .isoLatin1) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in source.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }

        return unfolded.reduce(into: [:]) { headers, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
    }

    private func parameter(named name: String, in value: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)(?:^|;)\\s*\(escapedName)\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ) else { return nil }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, let swiftRange = Range(range, in: value) {
                return String(value[swiftRange])
            }
        }
        return nil
    }

    private func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        let source = String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return source
            .components(separatedBy: "--\(boundary)")
            .dropFirst()
            .compactMap { rawPart in
                var part = rawPart
                if part.hasPrefix("--") { return nil }
                part = part.trimmingCharacters(in: .newlines)
                guard !part.isEmpty else { return nil }
                return part.data(using: .isoLatin1)
            }
    }

    private func decodeBody(_ data: Data, transferEncoding: String) -> Data {
        if transferEncoding.contains("base64") {
            let source = String(decoding: data, as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: source) ?? Data()
        }
        if transferEncoding.contains("quoted-printable") {
            return QuotedPrintableDecoder.decode(data)
        }
        return data
    }

    private func decodeText(_ data: Data, charset: String?) -> String {
        let normalized = charset?.lowercased() ?? "utf-8"
        let encodings: [String.Encoding]
        switch normalized {
        case let value where value.contains("shift_jis") || value.contains("shift-jis") || value.contains("sjis"):
            encodings = [.shiftJIS, .utf8, .isoLatin1]
        case let value where value.contains("iso-2022-jp"):
            encodings = [.iso2022JP, .utf8, .shiftJIS, .isoLatin1]
        case let value where value.contains("euc-jp"):
            encodings = [.japaneseEUC, .utf8, .shiftJIS, .isoLatin1]
        case let value where value.contains("iso-8859-1"):
            encodings = [.isoLatin1, .utf8]
        default:
            encodings = [.utf8, .shiftJIS, .isoLatin1]
        }
        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return ""
    }
}

enum MIMEHeaderDecoder {
    static func decode(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var result = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let payloadRange = Range(match.range(at: 3), in: value) else { continue }
            let charset = String(value[charsetRange])
            let encoding = String(value[encodingRange]).lowercased()
            let payload = String(value[payloadRange])
            let data: Data?
            if encoding == "b" {
                data = Data(base64Encoded: payload)
            } else {
                data = QuotedPrintableDecoder.decode(
                    Data(payload.replacingOccurrences(of: "_", with: " ").utf8)
                )
            }
            guard let data else { continue }
            let decoded = decode(data, charset: charset)
            result.replaceSubrange(fullRange, with: decoded)
        }
        return result
    }

    private static func decode(_ data: Data, charset: String) -> String {
        let normalized = charset.lowercased()
        let encodings: [String.Encoding]
        if normalized.contains("iso-2022-jp") {
            encodings = [.iso2022JP, .utf8, .shiftJIS]
        } else if normalized.contains("shift") || normalized.contains("sjis") {
            encodings = [.shiftJIS, .utf8]
        } else {
            encodings = [.utf8, .isoLatin1]
        }
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return ""
    }
}

enum QuotedPrintableDecoder {
    static func decode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hex(bytes[index + 1]),
                   let low = hex(bytes[index + 2]) {
                    result.append(high * 16 + low)
                    index += 3
                    continue
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return Data(result)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

struct IMAPResponseParser {
    static func hasTaggedCompletion(_ response: Data, tag: String) -> Bool {
        var cursor = response.startIndex
        while cursor < response.endIndex {
            guard let lineEnding = response.range(
                of: Data([13, 10]),
                in: cursor..<response.endIndex
            ) else { return false }
            let lineData = response.subdata(in: cursor..<lineEnding.lowerBound)
            let line = String(data: lineData, encoding: .isoLatin1) ?? ""
            if line.hasPrefix("\(tag) OK")
                || line.hasPrefix("\(tag) NO")
                || line.hasPrefix("\(tag) BAD") {
                return true
            }

            cursor = lineEnding.upperBound
            if let literalLength = trailingLiteralLength(in: line) {
                guard cursor + literalLength <= response.endIndex else { return false }
                cursor += literalLength
            }
        }
        return false
    }

    static func searchUIDs(from response: Data) -> [UInt64] {
        let source = String(data: response, encoding: .isoLatin1) ?? ""
        guard let line = source
            .components(separatedBy: "\r\n")
            .first(where: { $0.uppercased().hasPrefix("* SEARCH") }) else { return [] }
        return line
            .dropFirst("* SEARCH".count)
            .split(separator: " ")
            .compactMap { UInt64($0) }
    }

    static func uidValidity(from response: Data) -> UInt64? {
        firstCapture(#"(?i)UIDVALIDITY\s+(\d+)"#, in: response).flatMap(UInt64.init)
    }

    static func internalDate(from response: Data) -> Date? {
        guard let value = firstCapture(#"(?i)INTERNALDATE\s+\"([^\"]+)\""#, in: response) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }

    static func messageSize(from response: Data) -> Int? {
        firstCapture(#"(?i)RFC822\.SIZE\s+(\d+)"#, in: response).flatMap(Int.init)
    }

    static func firstLiteral(from response: Data) -> Data? {
        let source = String(data: response, encoding: .isoLatin1) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"\{(\d+)\}\r\n"#),
              let match = regex.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
              ),
              let lengthRange = Range(match.range(at: 1), in: source),
              let length = Int(source[lengthRange]) else { return nil }
        let start = match.range(at: 0).location + match.range(at: 0).length
        guard start >= 0, length >= 0, start + length <= response.count else { return nil }
        return response.subdata(in: start..<(start + length))
    }

    private static func firstCapture(_ pattern: String, in response: Data) -> String? {
        let source = String(data: response, encoding: .isoLatin1) ?? ""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func trailingLiteralLength(in line: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\{(\d+)\+?\}$"#),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[range])
    }
}

private enum IMAPCommandError: Error {
    case rejected(String)
    case invalidResponse
}

private final class IMAPTLSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.example.mailledger.imap.connection")

    init(host: String, port: UInt16) {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )
        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            connection.stateUpdateHandler = { state in
                guard !completed else { return }
                switch state {
                case .ready:
                    completed = true
                    continuation.resume()
                case .failed, .cancelled:
                    completed = true
                    continuation.resume(throwing: ICloudMailError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ value: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: Data(value.utf8),
                completion: .contentProcessed { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ICloudMailError.connectionFailed)
                    }
                }
            )
        }
    }

    func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ICloudMailError.connectionFailed)
                } else {
                    continuation.resume(throwing: ICloudMailError.invalidServerResponse)
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class IMAPSession: @unchecked Sendable {
    private let connection: IMAPTLSConnection
    private var tagNumber = 0

    init(host: String, port: UInt16) {
        connection = IMAPTLSConnection(host: host, port: port)
    }

    func connect() async throws {
        try await connection.connect()
        let greeting = try await receiveUntil { data in
            data.range(of: Data([13, 10])) != nil
        }
        let source = (String(data: greeting, encoding: .isoLatin1) ?? "").uppercased()
        guard source.hasPrefix("* OK") || source.hasPrefix("* PREAUTH") else {
            throw ICloudMailError.invalidServerResponse
        }
    }

    func login(emailAddress: String, appSpecificPassword: String) async throws {
        let localPart = emailAddress.split(separator: "@", maxSplits: 1).first.map(String.init)
        let usernames = [localPart, emailAddress]
            .compactMap { $0 }
            .reduce(into: [String]()) { result, username in
                if !result.contains(username) { result.append(username) }
            }

        for username in usernames {
            do {
                _ = try await execute(
                    "LOGIN \(quoted(username)) \(quoted(appSpecificPassword))"
                )
                return
            } catch IMAPCommandError.rejected(_) {
                continue
            }
        }
        throw ICloudMailError.authenticationFailed
    }

    func execute(_ command: String) async throws -> Data {
        tagNumber += 1
        let tag = String(format: "A%04d", tagNumber)
        try await connection.send("\(tag) \(command)\r\n")
        let response = try await receiveUntil { data in
            IMAPResponseParser.hasTaggedCompletion(data, tag: tag)
        }
        let source = String(data: response, encoding: .isoLatin1) ?? ""
        if source.range(of: "(?m)^\(tag) OK", options: .regularExpression) != nil {
            return response
        }
        if let line = source
            .components(separatedBy: "\r\n")
            .first(where: { $0.hasPrefix("\(tag) ") }) {
            throw IMAPCommandError.rejected(line)
        }
        throw IMAPCommandError.invalidResponse
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveUntil(_ completed: (Data) -> Bool) async throws -> Data {
        var response = Data()
        while response.count < 4 * 1024 * 1024 {
            response.append(try await connection.receiveChunk())
            if completed(response) { return response }
        }
        throw ICloudMailError.messageTooLarge
    }

    private func quoted(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return "\"\(sanitized)\""
    }
}

struct ICloudIMAPClient: Sendable {
    static let host = "imap.mail.me.com"
    static let port: UInt16 = 993
    static let maximumMessageSize = 1_500_000

    func verifyCredentials(emailAddress: String, appSpecificPassword: String) async throws {
        let session = IMAPSession(host: Self.host, port: Self.port)
        do {
            try await session.connect()
            try await session.login(
                emailAddress: emailAddress,
                appSpecificPassword: appSpecificPassword
            )
            _ = try await session.execute("SELECT INBOX")
            _ = try? await session.execute("LOGOUT")
            session.cancel()
        } catch {
            session.cancel()
            throw map(error)
        }
    }

    func fetchMessages(
        credential: ICloudMailCredential,
        rules: [CardMailSearchRule],
        excludingMessageIDs: Set<String> = [],
        lookbackDays: Int? = nil,
        now: Date = Date()
    ) async throws -> [MailMessage] {
        let session = IMAPSession(host: Self.host, port: Self.port)
        do {
            try await session.connect()
            try await session.login(
                emailAddress: credential.account.emailAddress,
                appSpecificPassword: credential.appSpecificPassword
            )
            let selectResponse = try await session.execute("SELECT INBOX")
            guard let uidValidity = IMAPResponseParser.uidValidity(from: selectResponse) else {
                throw ICloudMailError.invalidServerResponse
            }

            var seenUIDs: Set<UInt64> = []
            var messages: [MailMessage] = []
            for rule in rules {
                // 差分更新: 呼び出し側が期間を渡した場合はそれを優先し、初回はrule既定（120日）。
                let effectiveLookbackDays = min(
                    max(lookbackDays ?? rule.lookbackDays, 1),
                    CardMailSearchRule.maximumLookbackDays
                )
                let sinceDate = Calendar(identifier: .gregorian).date(
                    byAdding: .day,
                    value: -effectiveLookbackDays,
                    to: now
                ) ?? now
                let senderCriteria = rule.senderDomains.map {
                    "FROM \(quotedSearch($0))"
                }
                let search = "UID SEARCH SINCE \(imapDate(sinceDate)) \(orExpression(senderCriteria))"
                let searchResponse = try await session.execute(search)
                let uids = IMAPResponseParser.searchUIDs(from: searchResponse)
                    .filter { seenUIDs.insert($0).inserted }
                    .suffix(rule.maxResults)
                    .reversed()

                for uid in uids {
                    let scopedMessageID = "\(credential.account.id):\(uidValidity):\(uid)"
                    guard !excludingMessageIDs.contains(scopedMessageID) else { continue }
                    let metadata = try await session.execute(
                        "UID FETCH \(uid) (UID INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING AUTHENTICATION-RESULTS ARC-AUTHENTICATION-RESULTS)])"
                    )
                    guard let receivedAt = IMAPResponseParser.internalDate(from: metadata),
                          let messageSize = IMAPResponseParser.messageSize(from: metadata),
                          messageSize <= Self.maximumMessageSize,
                          let headerData = IMAPResponseParser.firstLiteral(from: metadata) else {
                        continue
                    }
                    let headerContent = MIMEMessageParser().parse(rawMessage: headerData)
                    guard rule.matches(sender: headerContent.sender) else { continue }

                    let fullResponse = try await session.execute("UID FETCH \(uid) (BODY.PEEK[])")
                    guard let rawMessage = IMAPResponseParser.firstLiteral(from: fullResponse) else {
                        continue
                    }
                    let content = MIMEMessageParser().parse(rawMessage: rawMessage)
                    // 受信MXが付けた Authentication-Results はメタデータ取得分を優先し、
                    // 無ければ全文側から拾う（後段の MailSecurityGate で SPF/DKIM/DMARC を検証）。
                    let authResults = headerContent.authenticationResults
                        ?? content.authenticationResults
                    messages.append(MailMessage(
                        identifier: "\(uidValidity):\(uid)",
                        accountIdentifier: credential.account.id,
                        provider: .iCloud,
                        sender: content.sender.isEmpty ? headerContent.sender : content.sender,
                        subject: content.subject.isEmpty ? headerContent.subject : content.subject,
                        receivedAt: receivedAt,
                        plainTextBody: content.plainText,
                        htmlConvertedBody: content.htmlText,
                        authenticationResults: authResults
                    ))
                }
            }

            _ = try? await session.execute("LOGOUT")
            session.cancel()
            return messages.sorted { $0.receivedAt > $1.receivedAt }
        } catch {
            session.cancel()
            throw map(error)
        }
    }

    private func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    private func orExpression(_ criteria: [String]) -> String {
        guard let first = criteria.first else { return "ALL" }
        guard criteria.count > 1 else { return first }
        return "OR \(first) \(orExpression(Array(criteria.dropFirst())))"
    }

    private func quotedSearch(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func map(_ error: Error) -> Error {
        if let error = error as? ICloudMailError { return error }
        if let commandError = error as? IMAPCommandError {
            switch commandError {
            case .rejected(let response):
                return ICloudMailError.serverRejected(response)
            case .invalidResponse:
                return ICloudMailError.invalidServerResponse
            }
        }
        return ICloudMailError.connectionFailed
    }
}
