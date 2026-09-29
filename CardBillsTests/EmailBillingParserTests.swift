import XCTest
@testable import CardBills

final class EmailBillingParserTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        return calendar
    }()

    func testExtractsRegisteredCardAmountAndFullDate() throws {
        let parser = EmailBillingParser(calendar: calendar)
        let card = EmailCardCandidate(id: UUID(), name: "楽天カード")
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))

        let result = parser.parse(
            """
            楽天カードからのお知らせ
            ご請求予定額 38,240円
            お支払日 2026年9月27日
            """,
            cards: [card],
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.card, card)
        XCTAssertEqual(result.amount, 38_240)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 9)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 27)
    }

    func testHandlesFullwidthDigits() throws {
        let parser = EmailBillingParser(calendar: calendar)
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))

        let result = parser.parse(
            "ご請求金額 ￥１２，３４５円　お支払い日 ２０２６年９月１０日",
            cards: [],
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.amount, 12_345)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testUnknownFieldsRemainNil() {
        let result = EmailBillingParser(calendar: calendar).parse(
            "カード会社からのお知らせです。",
            cards: [EmailCardCandidate(id: UUID(), name: "登録カード")]
        )

        XCTAssertNil(result.card)
        XCTAssertNil(result.amount)
        XCTAssertNil(result.paymentDate)
    }

    func testMonthAndDayMovesToNextYearWhenClearlyPast() throws {
        let parser = EmailBillingParser(calendar: calendar)
        let referenceDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 20)))

        let result = parser.parse(
            "お支払日 1月10日",
            cards: [],
            referenceDate: referenceDate
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 10)
    }

    // MARK: - Parser精度: 複数金額 / 利用額 / 金額なし / 日付なし / 文面変化

    func testPrefersBillingAmountOverUsageAmountInSameMail() {
        let parser = EmailBillingParser(calendar: calendar)
        let result = parser.parse(
            """
            ご利用金額 120,000円
            ご請求予定額 38,240円
            お支払日 9月27日
            """,
            cards: []
        )
        XCTAssertEqual(result.amount, 38_240)
    }

    func testUsageOnlyMailReturnsNilAmountInsteadOfGuessing() {
        let parser = EmailBillingParser(calendar: calendar)
        let result = parser.parse(
            "ご利用金額 12,345円\nポイント残高 5,000円\nお支払日 9月27日",
            cards: []
        )
        XCTAssertNil(result.amount)
        XCTAssertNotNil(result.paymentDate)
    }

    func testInstallmentBreakdownDoesNotOverrideHeadlineBillingAmount() {
        let parser = EmailBillingParser(calendar: calendar)
        let result = parser.parse(
            """
            今回のお支払い金額 42,220円
            うち分割払い 10,000円
            うちリボ払い 8,000円
            """,
            cards: []
        )
        XCTAssertEqual(result.amount, 42_220)
    }

    func testYenFallbackIsRejectedWhenPrecededByUsageContext() {
        let parser = EmailBillingParser(calendar: calendar)
        let result = parser.parse(
            "ご利用可能額 ¥500,000\nお支払日 9月27日",
            cards: []
        )
        XCTAssertNil(result.amount)
    }

    func testDatelessMailKeepsAmountButLeavesPaymentDateNil() {
        let parser = EmailBillingParser(calendar: calendar)
        let result = parser.parse(
            "ご請求予定額 38,240円 ※お支払日は確定後にお知らせします",
            cards: []
        )
        XCTAssertEqual(result.amount, 38_240)
        XCTAssertNil(result.paymentDate)
    }

    func testZeroYenBillingIsExtractedAsZeroNotNil() {
        let parser = EmailBillingParser(calendar: calendar)
        let zero = parser.parse(
            "今回のご請求金額 0円（今回のお引き落としはございません）\nお支払日 9月27日",
            cards: []
        )
        let missing = parser.parse("カード会社からのお知らせです。\nお支払日 9月27日", cards: [])

        XCTAssertEqual(zero.amount, 0)
        XCTAssertNotNil(zero.paymentDate)
        XCTAssertNil(missing.amount)
    }

    func testHalfwidthAndFullwidthAmountLabelVariationsAreAccepted() {
        let parser = EmailBillingParser(calendar: calendar)
        let plain = parser.parse("ご請求額：38,240円", cards: [])
        let spaced = parser.parse("ご 請求 予定 額  38,240 円", cards: [])
        XCTAssertEqual(plain.amount, 38_240)
        // 見出し内の空白除去には未対応でも、フォールバックで金額自体は拾えること。
        XCTAssertEqual(spaced.amount, 38_240)
    }
}

