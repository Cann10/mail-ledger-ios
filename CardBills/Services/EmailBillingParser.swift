import Foundation

struct EmailCardCandidate: Equatable, Sendable {
    let id: UUID
    let name: String
}

struct ParsedEmailBilling: Equatable, Sendable {
    let card: EmailCardCandidate?
    let amount: Int?
    let paymentDate: Date?
}

struct BillingEmailPatternSet: Sendable {
    let amountPatterns: [String]
    let datePatterns: [String]

    static let empty = BillingEmailPatternSet(amountPatterns: [], datePatterns: [])
}

/// 貼り付けられたメール本文だけを同期的に解析する、外部依存のないParser。
/// 本文は保持せず、抽出結果だけを返す。値型のみで構成し並列タスクから安全に呼べる。
struct EmailBillingParser: Sendable {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func parse(
        _ source: String,
        cards: [EmailCardCandidate],
        referenceDate: Date = Date(),
        preferredPatterns: BillingEmailPatternSet = .empty
    ) -> ParsedEmailBilling {
        let text = normalize(source)

        return ParsedEmailBilling(
            card: extractCard(from: text, cards: cards),
            amount: extractAmount(
                from: text,
                preferredPatterns: preferredPatterns.amountPatterns
            ),
            paymentDate: extractDate(
                from: text,
                referenceDate: referenceDate,
                preferredPatterns: preferredPatterns.datePatterns
            )
        )
    }

    private func extractCard(
        from text: String,
        cards: [EmailCardCandidate]
    ) -> EmailCardCandidate? {
        let searchable = searchNormalized(text)

        return cards
            .sorted { $0.name.count > $1.name.count }
            .first { searchable.contains(searchNormalized($0.name)) }
    }

    private func extractAmount(
        from text: String,
        preferredPatterns: [String]
    ) -> Int? {
        // 明示的な「総額 / 合計」ラベルは会社別見出し（予定額を含む）より先に評価する。
        // 予定額と確定合計が同一メールにある場合に確定合計を採るための最優先段。
        let explicitTotalPattern =
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求金額合計|ご請求合計金額|合計ご請求金額|お支払い金額合計|お支払い合計金額|合計お支払い金額|ご利用代金合計|ご請求総額|お支払い総額|今回のご請求総額|今回のお支払い総額)[^0-9¥￥]{0,40}[¥￥]?\s*([0-9][0-9,]*)\s*円"#

        let labeledPatterns = [explicitTotalPattern] + preferredPatterns + [
            // 「前回／前月／翌月以降」の（の付き含む）金額に加え、「リボ／分割／キャッシング／ボーナス／次回」の
            // 部分金額も今回の総請求ではないため除外する。
            // 金額は末尾に「円」を必須とし、「〜のお知らせ」等の直後にある日付数字（例: 11月10日）を拾わない。
            // 素の「請求金額」「請求額」は「前回ご請求金額」の末尾に一致してしまうため除外し、
            // 「ご/お/引」始まりの見出しに絞る。素の「請求額」しか無いメールはフォールバックで拾う。
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求予定額|ご請求金額|ご請求額|お支払い予定額|お支払い金額|お支払金額|引落予定額|引き落とし予定額)[^0-9¥￥]{0,40}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            // ご/お が付かない素の「請求金額」「請求額」等。ご請求金額の尾部一致を (?<!ご)(?<!お) で回避し、
            // 「(ご)利用」直後も除外して利用額を拾わない。
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?<!ご)(?<!お)(?<!ご利用)(?<!利用)(?:請求金額|請求額|請求予定額|支払金額|支払い金額)[^0-9¥￥]{0,40}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?:今回のお支払い|今回のお支払)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ]

        // 請求/支払の見出しに紐づく金額はそのまま採用する。「0円」も有効な確定値として返し、
        // 「金額を取得できなかった（nil）」状態と区別する。
        for pattern in labeledPatterns {
            if let value = firstCapture(in: text, pattern: pattern, group: 1),
               let amount = Int(value.replacingOccurrences(of: ",", with: "")),
               amount >= 0 {
                return amount
            }
        }

        // ラベルなしのフォールバック。請求額でない金額（利用額・ポイント・残高・手数料など）を
        // 直前の文言で除外し、該当がなければ nil（＝要確認）を返す。0円などを勝手に入れない。
        let fallbackPatterns = [
            #"[¥￥]\s*([0-9][0-9,]*)"#,
            #"([1-9][0-9,]{2,})\s*円"#
        ]

        for pattern in fallbackPatterns {
            if let amount = firstUnexcludedAmount(
                in: text,
                pattern: pattern,
                excluding: Self.nonBillingAmountContextTokens
            ) {
                return amount
            }
        }

        return nil
    }

    private static let nonBillingAmountContextTokens = [
        "利用", "ご利用", "ポイント", "残高", "手数料", "繰越", "獲得",
        "累計", "前回", "前月", "上限", "利用可能", "利用枠",
        "キャッシング", "リボ", "分割", "ボーナス"
    ]

    private func firstUnexcludedAmount(
        in text: String,
        pattern: String,
        excluding tokens: [String],
        contextLength: Int = 16
    ) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: fullRange) {
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: text) else { continue }
            let precedingStart = text.index(
                groupRange.lowerBound,
                offsetBy: -contextLength,
                limitedBy: text.startIndex
            ) ?? text.startIndex
            let preceding = text[precedingStart..<groupRange.lowerBound]
            if tokens.contains(where: { preceding.contains($0) }) { continue }
            if let amount = Int(
                text[groupRange].replacingOccurrences(of: ",", with: "")
            ), amount > 0 {
                return amount
            }
        }
        return nil
    }

    private func extractDate(
        from text: String,
        referenceDate: Date,
        preferredPatterns: [String]
    ) -> Date? {
        let labeledPatterns = preferredPatterns + [
            // 「今回の」支払日ラベルを最優先（今回/次回が併記されても今回分を選ぶ）。
            #"(?:今回のお支払い日|今回のお支払日|当月のお支払い日|当月お支払い日|今回の口座振替日|今回の引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#,
            // 次回／翌月／来月の支払日ラベルは弾く。
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:お支払い日|お支払日|支払日|お引落日|引落日|引き落とし日|口座振替日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]

        for pattern in labeledPatterns {
            if let captures = captures(in: text, pattern: pattern),
               let date = makeDate(
                yearText: capture(captures, at: 1),
                monthText: capture(captures, at: 2),
                dayText: capture(captures, at: 3),
                referenceDate: referenceDate
               ) {
                return date
            }
        }

        let fullDatePattern = #"(20[0-9]{2})\s*[年/\.\-]\s*([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        if let captures = captures(in: text, pattern: fullDatePattern),
           let date = makeDate(
            yearText: capture(captures, at: 1),
            monthText: capture(captures, at: 2),
            dayText: capture(captures, at: 3),
            referenceDate: referenceDate
           ) {
            return date
        }

        // 年なしの「月日」。ラベルが無いので、長い数字列（電話番号・会員番号等）への
        // 埋没を前後の数字境界で防ぎつつ、区切りは「月」「/」「-」を許容する（例: 11-10）。
        let monthDayPattern = #"(?<![0-9])([0-9]{1,2})\s*(?:月|/|-)\s*([0-9]{1,2})\s*日?(?![0-9])"#
        if let captures = captures(in: text, pattern: monthDayPattern),
           let date = makeDate(
            yearText: nil,
            monthText: capture(captures, at: 1),
            dayText: capture(captures, at: 2),
            referenceDate: referenceDate
           ) {
            return date
        }

        return nil
    }

    private func makeDate(
        yearText: String?,
        monthText: String?,
        dayText: String?,
        referenceDate: Date
    ) -> Date? {
        guard let monthText,
              let dayText,
              let month = Int(monthText),
              let day = Int(dayText),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        let explicitYear = yearText.flatMap(Int.init)
        let referenceYear = calendar.component(.year, from: referenceDate)
        var components = DateComponents(
            calendar: calendar,
            year: explicitYear ?? referenceYear,
            month: month,
            day: day
        )

        guard var date = calendar.date(from: components),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            return nil
        }

        if explicitYear == nil,
           let staleLimit = calendar.date(byAdding: .day, value: -45, to: referenceDate),
           date < staleLimit {
            components.year = referenceYear + 1
            guard let nextYearDate = calendar.date(from: components) else { return nil }
            date = nextYearDate
        }

        return calendar.startOfDay(for: date)
    }

    private func normalize(_ source: String) -> String {
        var result = ""
        let fullwidthDigits = Array("０１２３４５６７８９")

        for character in source {
            if let index = fullwidthDigits.firstIndex(of: character) {
                result.append(String(index))
            } else {
                switch character {
                case "，": result.append(",")
                case "／": result.append("/")
                case "．": result.append(".")
                case "－": result.append("-")
                case "￥": result.append("¥")
                default: result.append(character)
                }
            }
        }

        return result
    }

    private func searchNormalized(_ source: String) -> String {
        normalize(source)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private func firstCapture(in text: String, pattern: String, group: Int) -> String? {
        guard let values = captures(in: text, pattern: pattern) else { return nil }
        return capture(values, at: group)
    }

    private func capture(_ values: [String?], at index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func captures(in text: String, pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }

        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }
}
