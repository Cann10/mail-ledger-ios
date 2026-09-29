import Foundation
import SwiftData

@Model
final class PaymentCard {
    var id: UUID
    var name: String
    var paymentDay: Int?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        paymentDay: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.paymentDay = paymentDay
        self.createdAt = createdAt
    }
}

