import XCTest
@testable import CardBills

final class ICloudMailTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        return calendar
    }()

    func testHTMLOnlyIMAPMessageUsesTheCommonBillingPipeline() throws {
        let rawMessage = """
        From: 楽天カード <notice@mail.rakuten-card.co.jp>\r
        Subject: ご請求予定額のお知らせ\r
        Authentication-Results: mx.mail.icloud.com; spf=pass; dkim=pass header.d=mail.rakuten-card.co.jp; dmarc=pass\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <html><body><p>ご請求予定額 38,420円</p><p>お支払日 2026年9月27日</p></body></html>
        """.data(using: .utf8)!
        let content = MIMEMessageParser().parse(rawMessage: rawMessage)
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
        )
        let message = MailMessage(
            identifier: "777:42",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: content.sender,
            subject: content.subject,
            receivedAt: receivedAt,
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText,
            authenticationResults: content.authenticationResults
        )
        let card = PaymentCard(name: "楽天カード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.provider, .iCloud)
        XCTAssertEqual(candidate.accountIdentifier, "icloud-account")
        XCTAssertEqual(candidate.amount, 38_420)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 27)
    }

    func testMultipartPlainAndHTMLBodiesAreBothAvailable() {
        let rawMessage = """
        From: notice@mail.paypay-card.co.jp\r
        Subject: ご請求のお知らせ\r
        Content-Type: multipart/alternative; boundary="mail-boundary"\r
        \r
        --mail-boundary\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        ご請求金額 24,800円\r
        --mail-boundary\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>お支払い日 2026年9月27日</p>\r
        --mail-boundary--\r
        """.data(using: .utf8)!

        let content = MIMEMessageParser().parse(rawMessage: rawMessage)

        XCTAssertTrue(content.plainText.contains("24,800円"))
        XCTAssertTrue(content.htmlText.contains("2026年9月27日"))
    }

    func testIncompleteICloudCandidateUsesNeedsReviewWithoutInventedValues() throws {
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
        )
        let card = PaymentCard(name: "楽天カード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "777:43",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: "notice@mail.rakuten-card.co.jp",
            subject: "ご請求のお知らせ",
            receivedAt: receivedAt,
            plainTextBody: "お支払日 2026年9月27日",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testYearlessICloudDateUsesMessageReceivedAt() throws {
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
        )
        let card = PaymentCard(name: "楽天カード")
        let rule = try XCTUnwrap(CardMailRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "777:44",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: "notice@mail.rakuten-card.co.jp",
            subject: "ご請求のお知らせ",
            receivedAt: receivedAt,
            plainTextBody: "ご請求予定額 38,420円\nお支払日 1月10日",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))
        let paymentDate = try XCTUnwrap(candidate.paymentDate)

        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 10)
    }

    func testSameStatementFromAnotherMailAccountIsNotDuplicated() throws {
        // 同じ請求メールが別のメールアカウント / 別providerに届いても1請求として扱う。
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 42_220,
            paymentDate: paymentDate,
            gmailMessageID: "icloud-a:777:10",
            gmailReceivedAt: paymentDate.addingTimeInterval(-86_400),
            mailProvider: .iCloud,
            mailAccountIdentifier: "icloud-a"
        )
        let sameAccount = candidate(
            accountID: "icloud-a",
            messageID: "icloud-a:777:11",
            cardID: cardID,
            amount: 42_220,
            paymentDate: paymentDate
        )
        let otherAccount = candidate(
            accountID: "icloud-b",
            messageID: "icloud-b:888:11",
            cardID: cardID,
            amount: 42_220,
            paymentDate: paymentDate
        )
        let gmailCopy = BillingCandidate(
            messageID: "gmail-x:abc",
            provider: .gmail,
            accountIdentifier: "gmail-x",
            accountEmailAddress: "user@gmail.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: 42_220,
            paymentDate: paymentDate,
            receivedAt: paymentDate.addingTimeInterval(-60),
            existingBillID: nil
        )
        let reconciler = BillingCandidateReconciler(calendar: calendar)

        XCTAssertTrue(reconciler.reconcile(
            candidates: [sameAccount], existingBills: [existing]
        ).isEmpty)
        XCTAssertTrue(reconciler.reconcile(
            candidates: [otherAccount], existingBills: [existing]
        ).isEmpty, "別iCloudアカウントの同一請求は既存Billと重複させない")
        XCTAssertTrue(reconciler.reconcile(
            candidates: [gmailCopy], existingBills: [existing]
        ).isEmpty, "iCloud由来Billに対しGmailの同一請求は重複させない")
        XCTAssertEqual(
            reconciler.reconcile(candidates: [otherAccount, gmailCopy], existingBills: []).count,
            1,
            "Gmail/iCloudの同一請求メールは1件に統合する"
        )
    }

    func testLaterICloudFinalNoticeUpdatesExistingBillForSameAccount() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 40_000,
            paymentDate: paymentDate,
            gmailMessageID: "icloud-a:777:10",
            gmailReceivedAt: receivedAt.addingTimeInterval(-86_400),
            mailProvider: .iCloud,
            mailAccountIdentifier: "icloud-a"
        )
        let finalCandidate = BillingCandidate(
            messageID: "icloud-a:777:12",
            provider: .iCloud,
            accountIdentifier: "icloud-a",
            accountEmailAddress: "user@icloud.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: 42_220,
            paymentDate: paymentDate,
            receivedAt: receivedAt,
            existingBillID: nil
        )

        let result = BillingCandidateReconciler(calendar: calendar).reconcile(
            candidates: [finalCandidate],
            existingBills: [existing]
        )

        XCTAssertEqual(result.first?.existingBillID, existing.id)
        XCTAssertEqual(result.first?.amount, 42_220)
    }

    func testIMAPResponseMetadataAndLiteralParsing() throws {
        let header = "From: notice@mail.rakuten-card.co.jp\r\nSubject: test\r\n\r\n"
        let response = Data(
            "* 4 FETCH (UID 42 UIDVALIDITY 777 INTERNALDATE \"02-Sep-2026 09:15:00 +0900\" RFC822.SIZE 900 {\(header.utf8.count)}\r\n\(header))\r\nA0004 OK FETCH completed\r\n".utf8
        )

        XCTAssertEqual(IMAPResponseParser.uidValidity(from: response), 777)
        XCTAssertEqual(IMAPResponseParser.messageSize(from: response), 900)
        XCTAssertNotNil(IMAPResponseParser.internalDate(from: response))
        XCTAssertEqual(
            String(data: try XCTUnwrap(IMAPResponseParser.firstLiteral(from: response)), encoding: .utf8),
            header
        )
        XCTAssertEqual(
            IMAPResponseParser.searchUIDs(from: Data("* SEARCH 10 11 42\r\nA0003 OK\r\n".utf8)),
            [10, 11, 42]
        )

        let embeddedCompletion = Data(
            "* 4 FETCH (BODY[] {14}\r\nA0004 OK fake)\r\nA0004 OK FETCH completed\r\n".utf8
        )
        XCTAssertTrue(IMAPResponseParser.hasTaggedCompletion(
            embeddedCompletion,
            tag: "A0004"
        ))
        XCTAssertFalse(IMAPResponseParser.hasTaggedCompletion(
            Data("* 4 FETCH (BODY[] {14}\r\nA0004 OK fake".utf8),
            tag: "A0004"
        ))
    }

    // MARK: - フィッシング / なりすまし対策（iCloud 経路）

    private func rakutenRule() throws -> CardMailSearchRule {
        try XCTUnwrap(GmailCardRuleRegistry().rule(for: "楽天カード"))
    }

    private func icloudMessage(
        raw: String,
        identifier: String = "999:1"
    ) throws -> MailMessage {
        let content = MIMEMessageParser().parse(rawMessage: Data(raw.utf8))
        return MailMessage(
            identifier: identifier,
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: content.sender,
            subject: content.subject,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText,
            authenticationResults: content.authenticationResults
        )
    }

    /// 認証結果ヘッダが取得できない場合は limitedTrust（候補化するが自動確定させない）。
    func testICloudMessageWithoutAuthHeaderBecomesLimitedTrust() throws {
        let raw = """
        From: 楽天カード <notice@mail.rakuten-card.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        今回のご請求金額 42,220円\r
        口座振替日 2026年11月27日\r
        """
        let message = try icloudMessage(raw: raw)
        XCTAssertNil(message.authenticationResults)

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: try rakutenRule()
        ), "認証ヘッダ無しでも公式ドメインなら候補化する")
        XCTAssertEqual(candidate.amount, 42_220)
        XCTAssertEqual(candidate.trustLevel, .limited)
        XCTAssertEqual(candidate.extractionState, .needsReview, "limited は抽出が揃っても needsReview")
        XCTAssertEqual(candidate.senderVerificationNotice, "送信元の認証情報を確認できませんでした")
    }

    /// 認証ヘッダが無くても、送信元ドメインが allowlist 外なら弾く。
    func testICloudSpoofedSenderRejectedEvenWithoutAuthHeader() throws {
        let raw = """
        From: 楽天カード <billing@rakuten-card.co.jp.attacker.example>\r
        Subject: 【重要】ご請求金額確定のお知らせ\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        今回のご請求金額 42,220円\r
        口座振替日 2026年11月27日\r
        """
        let message = try icloudMessage(raw: raw)
        XCTAssertNil(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: try rakutenRule()
        ))
    }

    /// iCloud でも Authentication-Results ヘッダを取り込み、SPF/DKIM/DMARC 失敗を弾く。
    func testICloudAuthenticationResultsFailureIsRejected() throws {
        let raw = """
        From: 楽天カード <notice@mail.rakuten-card.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Authentication-Results: mx.mail.icloud.com; spf=fail smtp.mailfrom=evil.example; dkim=fail; dmarc=fail\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        今回のご請求金額 42,220円\r
        口座振替日 2026年11月27日\r
        """
        let message = try icloudMessage(raw: raw)
        XCTAssertNotNil(message.authenticationResults)
        XCTAssertNil(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: try rakutenRule()
        ), "認証失敗メールは候補化しない")
    }

    /// iCloud で DMARC=pass の正規メールはこれまで通り候補化される（誤拒否しない）。
    func testICloudAuthenticationResultsPassAllowsCandidate() throws {
        let raw = """
        From: 楽天カード <notice@mail.rakuten-card.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Authentication-Results: mx.mail.icloud.com; spf=pass; dkim=pass header.d=mail.rakuten-card.co.jp; dmarc=pass\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        今回のご請求金額 42,220円\r
        口座振替日 2026年11月27日\r
        """
        let message = try icloudMessage(raw: raw)
        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: try rakutenRule()
        ))
        XCTAssertEqual(candidate.amount, 42_220)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 27)
        XCTAssertEqual(candidate.trustLevel, .trusted, "認証が読めれば iCloud でも trusted")
        XCTAssertEqual(candidate.extractionState, .complete)
    }

    private func candidate(
        accountID: String,
        messageID: String,
        cardID: UUID,
        amount: Int,
        paymentDate: Date
    ) -> BillingCandidate {
        BillingCandidate(
            messageID: messageID,
            provider: .iCloud,
            accountIdentifier: accountID,
            accountEmailAddress: "user@icloud.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: amount,
            paymentDate: paymentDate,
            receivedAt: paymentDate.addingTimeInterval(-60),
            existingBillID: nil
        )
    }
}
