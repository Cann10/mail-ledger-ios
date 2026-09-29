import Foundation

enum CardCompanyParserKind: String, Sendable {
    case rakuten
    case smbc
    case payPay
    case jcb
    case aeon
    case epos
    case dcard
    /// 定型的な日本語カード明細メール（「今回のご請求金額 …円」「お支払い日 …」）向けの共通パーサ。
    /// 複数カード会社で文面が実質同一のため1つに集約する。
    case standardStatement
}

protocol CardCompanyBillingParsing {
    var patterns: BillingEmailPatternSet { get }
}

// 金額パターンは「具体的な見出し」を先に、汎用ラベルを後に置く。
// commonParserは配列順に評価し、最初に一致したパターンの値を採用する。
// これにより「前回請求額」「ご利用金額」等より先に「今回の請求/支払い金額」を拾う。

struct RakutenCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のご請求金額|ご請求予定金額|カードご請求金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)ご請求金額[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:口座振替日|お引き落とし日|引き落とし日|お支払い日|お支払日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct SMBCCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のお支払い金額|今回のご請求金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:お支払い金額|お支払金額|ご請求金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:お支払い予定日|お支払い日|お支払日|口座振替日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct PayPayCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今月のご請求金額|ご請求予定金額|請求予定金額|今月のお支払い金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)ご請求金額[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:引き落とし予定日|引き落とし日|お支払い日|お支払日|口座振替日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct JCBCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            // 具体的な見出しを最優先（「前回」「翌月以降」の予定額を拾わない）。
            #"(?:今回のお支払い金額|お支払い金額合計|今回のご請求金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:お支払い金額|お支払金額|ご請求金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:お支払い日|お支払日|口座振替日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct AeonCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のご請求金額|ご請求確定金額|口座振替金額|ご請求金額合計|お支払い金額合計)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求金額|お支払い金額|お支払金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:口座振替日|お支払い日|お支払日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct EposCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のご請求金額|今回のお支払い金額|ご請求確定金額|お支払い予定金額|ご請求金額合計)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求金額|お支払い金額|お支払金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:口座振替日|お支払い日|お支払日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct DCardBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のご請求金額|ご請求確定金額|お支払い金額合計|ご請求金額合計)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求金額|お支払い金額|お支払金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:お支払い日|お支払日|口座振替日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

/// ビューカード / American Express / ダイナースクラブ / セブンカード・プラス / TS CUBICカード など、
/// 「今回のご請求金額 …円」「お支払い日 …」形式の定型明細メールで共有する共通パーサ。
struct StandardStatementBillingParser: CardCompanyBillingParsing {
    let patterns = BillingEmailPatternSet(
        amountPatterns: [
            #"(?:今回のご請求金額|今回のお支払い金額|ご請求確定金額|ご請求金額合計|お支払い金額合計)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#,
            #"(?<!前回)(?<!前回の)(?<!前月)(?<!前月の)(?<!翌月以降の)(?<!リボ)(?<!リボ払い)(?<!リボ払い当月)(?<!分割)(?<!分割払い)(?<!キャッシング)(?<!ボーナス)(?<!ボーナス払い)(?<!次回)(?<!次回の)(?:ご請求金額|ご請求額|お支払い金額|お支払金額)[^0-9¥￥]{0,24}[¥￥]?\s*([0-9][0-9,]*)\s*円"#
        ],
        datePatterns: [
            #"(?<!次回)(?<!次回の)(?<!翌月)(?<!翌月の)(?<!来月)(?<!来月の)(?:お支払い日|お支払日|口座振替日|口座引き落とし日|引き落とし日)[^0-9]{0,24}(?:(20[0-9]{2})\s*[年/\.\-]\s*)?([0-9]{1,2})\s*[月/\.\-]\s*([0-9]{1,2})\s*日?"#
        ]
    )
}

struct CardCompanyBillingParser: Sendable {
    private let commonParser: EmailBillingParser

    init(commonParser: EmailBillingParser = EmailBillingParser()) {
        self.commonParser = commonParser
    }

    func parse(
        _ source: String,
        card: EmailCardCandidate,
        kind: CardCompanyParserKind,
        referenceDate: Date = Date()
    ) -> ParsedEmailBilling {
        let specialized: any CardCompanyBillingParsing
        switch kind {
        case .rakuten:
            specialized = RakutenCardBillingParser()
        case .smbc:
            specialized = SMBCCardBillingParser()
        case .payPay:
            specialized = PayPayCardBillingParser()
        case .jcb:
            specialized = JCBCardBillingParser()
        case .aeon:
            specialized = AeonCardBillingParser()
        case .epos:
            specialized = EposCardBillingParser()
        case .dcard:
            specialized = DCardBillingParser()
        case .standardStatement:
            specialized = StandardStatementBillingParser()
        }

        let parsed = commonParser.parse(
            source,
            cards: [card],
            referenceDate: referenceDate,
            preferredPatterns: specialized.patterns
        )

        // The card is fixed only after Gmail sender-domain validation for its rule.
        return ParsedEmailBilling(
            card: card,
            amount: parsed.amount,
            paymentDate: parsed.paymentDate
        )
    }
}

