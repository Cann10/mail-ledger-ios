import Foundation
import SwiftData

enum DemoDataSeeder {
    static func seed(into context: ModelContext, referenceDate: Date = Date()) throws {
        let calendar = Calendar.current
        let firstCard = PaymentCard(name: "三井住友カード", paymentDay: 10)
        let secondCard = PaymentCard(name: "楽天カード", paymentDay: 27)
        context.insert(firstCard)
        context.insert(secondCard)

        let firstDate = upcomingDate(day: 10, referenceDate: referenceDate, calendar: calendar)
        let secondDate = upcomingDate(day: 27, referenceDate: referenceDate, calendar: calendar)

        context.insert(Bill(
            cardID: firstCard.id,
            cardName: firstCard.name,
            amount: 21_200,
            paymentDate: firstDate
        ))
        context.insert(Bill(
            cardID: secondCard.id,
            cardName: secondCard.name,
            amount: 42_220,
            paymentDate: secondDate
        ))

        try context.save()
    }

    private static func upcomingDate(
        day: Int,
        referenceDate: Date,
        calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        let currentYear = calendar.component(.year, from: today)
        let currentMonth = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)

        if day >= currentDay,
           let date = validDate(year: currentYear, month: currentMonth, day: day, calendar: calendar) {
            return date
        }

        let nextMonth = calendar.date(byAdding: .month, value: 1, to: today) ?? today
        return validDate(
            year: calendar.component(.year, from: nextMonth),
            month: calendar.component(.month, from: nextMonth),
            day: day,
            calendar: calendar
        ) ?? nextMonth
    }

    private static func validDate(
        year: Int,
        month: Int,
        day: Int,
        calendar: Calendar
    ) -> Date? {
        let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        guard let firstOfMonth,
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return nil
        }

        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: min(day, range.count)
        ))
    }
}

