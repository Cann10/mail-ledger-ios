import Foundation
import SwiftData

@Model
final class Bill {
    var id: UUID
    var cardID: UUID
    var cardName: String
    var amount: Int
    var paymentDate: Date
    var createdAt: Date
    var gmailMessageID: String?
    var gmailReceivedAt: Date?
    var mailProviderRawValue: String?
    var mailAccountIdentifier: String?

    init(
        id: UUID = UUID(),
        cardID: UUID,
        cardName: String,
        amount: Int,
        paymentDate: Date,
        createdAt: Date = Date(),
        gmailMessageID: String? = nil,
        gmailReceivedAt: Date? = nil,
        mailProvider: MailProvider? = nil,
        mailAccountIdentifier: String? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.cardName = cardName
        self.amount = amount
        self.paymentDate = paymentDate
        self.createdAt = createdAt
        self.gmailMessageID = gmailMessageID
        self.gmailReceivedAt = gmailReceivedAt
        self.mailProviderRawValue = mailProvider?.rawValue
        self.mailAccountIdentifier = mailAccountIdentifier
    }

    var mailProvider: MailProvider? {
        get { mailProviderRawValue.flatMap(MailProvider.init(rawValue:)) }
        set { mailProviderRawValue = newValue?.rawValue }
    }
}
