import Foundation

struct GmailProfile: Sendable {
    let emailAddress: String
}

struct HTMLTextExtractor {
    func parserBody(
        plainParts: [String],
        htmlParts: [String],
        snippet: String
    ) -> String {
        let textParts = plainParts + htmlParts.map { plainText(fromHTML: $0) }
        let nonEmptyParts = textParts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return nonEmptyParts.isEmpty ? snippet : nonEmptyParts.joined(separator: "\n")
    }

    func plainText(fromHTML html: String) -> String {
        var result = html
        result = result.replacingOccurrences(
            of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        // 表は文字距離ではなく行/列構造でラベルと値を対応付け、「ラベル：値」に正規化して先頭へ置く。
        let tableLines = tableNormalizedLines(result)
        result = result.replacingOccurrences(
            of: #"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>|</td>|</th>|</table>|</thead>|</tbody>"#,
            with: "\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        for (entity, replacement) in Self.htmlEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // 正規化済みの「ラベル：値」行を先頭に置くと、firstMatch を使うParserが確実にそれを拾う。
        return tableLines + result
    }

    private static let htmlEntities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"
    ]

    // MARK: - 構造的な HTML テーブル正規化

    private static let tableBillLabels = [
        "ご請求金額", "ご請求額", "請求金額", "請求額", "お支払い金額", "お支払金額",
        "ご請求予定額", "お支払い予定額", "ご請求金額合計", "お支払い金額合計",
        "ご請求総額", "お支払い総額", "今回のご請求金額", "今回のお支払い金額",
        "ご請求確定金額", "口座振替金額"
    ]
    private static let tableLabelExclusions = [
        "前回", "前月", "翌月", "リボ", "分割", "キャッシング", "ボーナス", "次回",
        "利用可能", "ご利用可能", "利用枠", "ポイント", "残高", "獲得", "累計"
    ]
    private static let tableDateLabels = [
        "お支払い日", "お支払日", "口座振替日", "口座引き落とし日", "引き落とし日", "支払日", "お引落日"
    ]

    /// `<table>` を行/列で解析し、「ラベル：値」形式の正規化行（複数）を返す。表が無ければ空文字。
    private func tableNormalizedLines(_ html: String) -> String {
        var lines: [String] = []
        for tableInner in Self.capturedGroups(#"(?is)<table[^>]*>(.*?)</table>"#, in: html) {
            let rows = Self.tableRows(tableInner)

            // 横方向: 同一行内で「ラベルセル」→ 右隣以降で最初の「金額/日付を含む非除外セル」を対応。
            for cells in rows {
                for (index, cell) in cells.enumerated() {
                    if Self.isTableBillLabel(cell) {
                        for value in cells[(index + 1)...] where !Self.tableCellHasExclusion(value) {
                            if Self.tableCellHasAmount(value) {
                                lines.append("\(cell)：\(value)")
                                break
                            }
                        }
                    }
                    if Self.isTableDateLabel(cell) {
                        for value in cells[(index + 1)...] where Self.tableCellHasDate(value) {
                            lines.append("\(cell)：\(value)")
                            break
                        }
                    }
                }
            }

            // 縦方向: 見出し行 i と値行 i+1 を列インデックスで対応（間に件数列等があっても列位置で紐付く）。
            for i in rows.indices.dropLast() {
                let head = rows[i]
                let value = rows[i + 1]
                guard head.count >= 2, head.count == value.count else { continue }
                for k in head.indices {
                    if Self.isTableBillLabel(head[k]),
                       !Self.tableCellHasExclusion(value[k]),
                       Self.tableCellHasAmount(value[k]) {
                        lines.append("\(head[k])：\(value[k])")
                    }
                    if Self.isTableDateLabel(head[k]), Self.tableCellHasDate(value[k]) {
                        lines.append("\(head[k])：\(value[k])")
                    }
                }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func tableRows(_ tableInner: String) -> [[String]] {
        let unified = tableInner.replacingOccurrences(
            of: #"(?i)</tr\s*>"#, with: "\u{0001}", options: .regularExpression
        )
        return unified.components(separatedBy: "\u{0001}").compactMap { rowHTML in
            let cells = capturedGroups(#"(?is)<t[dh][^>]*>(.*?)</t[dh]\s*>"#, in: rowHTML)
                .map(tableCellText)
            return cells.isEmpty ? nil : cells
        }
    }

    private static func tableCellText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression
        )
        for (entity, replacement) in htmlEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTableBillLabel(_ cell: String) -> Bool {
        tableBillLabels.contains { cell.contains($0) }
            && !tableLabelExclusions.contains { cell.contains($0) }
    }

    private static func isTableDateLabel(_ cell: String) -> Bool {
        tableDateLabels.contains { cell.contains($0) }
            && !["次回", "翌月", "来月"].contains { cell.contains($0) }
    }

    private static func tableCellHasExclusion(_ cell: String) -> Bool {
        (tableLabelExclusions + ["利用", "手数料", "繰越"]).contains { cell.contains($0) }
    }

    private static func tableCellHasAmount(_ cell: String) -> Bool {
        cell.range(of: #"[¥￥]\s*[0-9]|[0-9][0-9,]*\s*円"#, options: .regularExpression) != nil
    }

    private static func tableCellHasDate(_ cell: String) -> Bool {
        cell.range(
            of: #"20[0-9]{2}\s*[年/\.\-]\s*[0-9]{1,2}\s*[月/\.\-]\s*[0-9]{1,2}|[0-9]{1,2}\s*月\s*[0-9]{1,2}\s*日?|(?<![0-9])[0-9]{1,2}\s*[/\-]\s*[0-9]{1,2}(?![0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func capturedGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { return nil }
                return ns.substring(with: match.range(at: 1))
            }
    }
}

typealias GmailMessageBodyTextExtractor = HTMLTextExtractor

struct GmailAPIClient: Sendable {
    private struct ProfileResponse: Decodable {
        let emailAddress: String
    }

    private struct MessageListResponse: Decodable {
        struct MessageReference: Decodable {
            let id: String
        }

        let messages: [MessageReference]?
    }

    private struct MessageResource: Decodable {
        struct Payload: Decodable {
            struct Header: Decodable {
                let name: String
                let value: String
            }

            struct Body: Decodable {
                let data: String?
                let attachmentID: String?

                enum CodingKeys: String, CodingKey {
                    case data
                    case attachmentID = "attachmentId"
                }
            }

            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Payload]?
        }

        let id: String
        let internalDate: String?
        let snippet: String?
        let payload: Payload?
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

    private struct MessagePartSource {
        let data: String?
    }

    private let networkSession: URLSession

    init(networkSession: URLSession = GoogleNetworkSession.shared) {
        self.networkSession = networkSession
    }

    func fetchProfile(accessToken: String) async throws -> GmailProfile {
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile") else {
            throw GmailIntegrationError.api(statusCode: 0, message: "アカウント情報URLを作成できませんでした。")
        }

        let data = try await authorizedGET(url: url, accessToken: accessToken)
        guard let response = try? JSONDecoder().decode(ProfileResponse.self, from: data),
              !response.emailAddress.isEmpty else {
            throw GmailIntegrationError.api(statusCode: 0, message: "Gmailアカウントを確認できませんでした。")
        }
        return GmailProfile(emailAddress: response.emailAddress)
    }

    func listMessageIDs(
        query: String,
        maxResults: Int = 10,
        accessToken: String
    ) async throws -> [String] {
        var components = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages"
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "labelIds", value: "INBOX"),
            URLQueryItem(name: "includeSpamTrash", value: "false"),
            URLQueryItem(name: "maxResults", value: String(min(max(maxResults, 1), 25)))
        ]
        guard let url = components?.url else {
            throw GmailIntegrationError.api(statusCode: 0, message: "検索URLを作成できませんでした。")
        }

        let data = try await authorizedGET(url: url, accessToken: accessToken)
        guard let response = try? JSONDecoder().decode(MessageListResponse.self, from: data) else {
            throw GmailIntegrationError.api(statusCode: 0, message: "検索結果を読み取れませんでした。")
        }
        return response.messages?.map(\.id) ?? []
    }

    func fetchMessage(
        id: String,
        accountIdentifier: String,
        accessToken: String
    ) async throws -> MailMessage {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var components = URLComponents(
            string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(encodedID)"
        )
        components?.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let url = components?.url else {
            throw GmailIntegrationError.invalidMessage
        }

        let data = try await authorizedGET(url: url, accessToken: accessToken)
        guard let resource = try? JSONDecoder().decode(MessageResource.self, from: data),
              let payload = resource.payload else {
            throw GmailIntegrationError.invalidMessage
        }
        guard let receivedAt = resource.internalDate
            .flatMap({ TimeInterval($0) })
            .map({ Date(timeIntervalSince1970: $0 / 1_000) }) else {
            throw GmailIntegrationError.invalidMessage
        }

        let headers = payload.headers ?? []
        let from = header(named: "From", in: headers)
        let subject = header(named: "Subject", in: headers)
        // 受信MX（Google）が先頭に付与する Authentication-Results を信頼して使う。
        let authResults = firstHeader(
            anyOf: ["Authentication-Results", "ARC-Authentication-Results"],
            in: headers
        )
        let plainParts = decodedParts(in: payload, matching: "text/plain")
        let htmlParts = decodedParts(in: payload, matching: "text/html")
        let textExtractor = GmailMessageBodyTextExtractor()
        var plainTextBody = plainParts.joined(separator: "\n")
        let htmlConvertedBody = htmlParts
            .map { textExtractor.plainText(fromHTML: $0) }
            .joined(separator: "\n")
        if plainTextBody.isEmpty && htmlConvertedBody.isEmpty {
            plainTextBody = resource.snippet ?? ""
        }

        return MailMessage(
            identifier: resource.id,
            accountIdentifier: accountIdentifier,
            provider: .gmail,
            sender: from,
            subject: subject,
            receivedAt: receivedAt,
            plainTextBody: plainTextBody,
            htmlConvertedBody: htmlConvertedBody,
            authenticationResults: authResults
        )
    }

    private func authorizedGET(url: URL, accessToken: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkSession.data(for: request)
        } catch let urlError as URLError {
            // 一時的な通信失敗。既存データには触れず、後で安全に再試行する。
            throw GmailIntegrationError.network(urlError.code)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailIntegrationError.api(statusCode: 0, message: "応答を確認できませんでした。")
        }
        if httpResponse.statusCode == 401 {
            throw GmailIntegrationError.apiUnauthorized
        }
        if httpResponse.statusCode == 429 || httpResponse.statusCode == 403 {
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            let message = envelope?.error.message ?? ""
            if httpResponse.statusCode == 429
                || message.localizedCaseInsensitiveContains("rate")
                || message.localizedCaseInsensitiveContains("quota")
                || message.localizedCaseInsensitiveContains("userRateLimitExceeded") {
                let retryAfter = (httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap { TimeInterval($0) }
                throw GmailIntegrationError.rateLimited(retryAfterSeconds: retryAfter)
            }
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw GmailIntegrationError.api(
                statusCode: httpResponse.statusCode,
                message: envelope?.error.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }
        return data
    }

    private func header(
        named name: String,
        in headers: [MessageResource.Payload.Header]
    ) -> String {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    private func firstHeader(
        anyOf names: [String],
        in headers: [MessageResource.Payload.Header]
    ) -> String? {
        for name in names {
            if let value = headers.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            })?.value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func decodedParts(
        in payload: MessageResource.Payload,
        matching mimeType: String
    ) -> [String] {
        // 添付として届いた本文（attachmentId 経由）は取得しない。インライン本文のみ解析する。
        partSources(in: payload, matching: mimeType).compactMap { source in
            source.data.flatMap(decodeBase64URLText)
        }
    }

    private func partSources(
        in payload: MessageResource.Payload,
        matching mimeType: String
    ) -> [MessagePartSource] {
        var results: [MessagePartSource] = []

        if payload.mimeType?.lowercased().hasPrefix(mimeType) == true {
            results.append(MessagePartSource(data: payload.body?.data))
        }

        for part in payload.parts ?? [] {
            results.append(contentsOf: partSources(in: part, matching: mimeType))
        }

        return results
    }

    private func decodeBase64URLText(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .shiftJIS)
            ?? String(data: data, encoding: .isoLatin1)
    }

}
