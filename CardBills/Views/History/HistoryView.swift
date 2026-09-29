import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Bill.paymentDate, order: .reverse) private var bills: [Bill]

    @State private var selectedMonth: Date = HistoryView.monthStart(for: Date())
    @State private var editingBill: Bill?
    @State private var showsMonthPicker = false

    // MARK: 集計

    private static func monthStart(for date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private var selectedMonthBills: [Bill] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: selectedMonth) else { return [] }
        return bills
            .filter { $0.paymentDate >= interval.start && $0.paymentDate < interval.end }
            .sorted { $0.paymentDate > $1.paymentDate }
    }

    private var selectedMonthTotal: Int {
        selectedMonthBills.reduce(0) { $0 + $1.amount }
    }

    private var lowerBound: Date {
        guard let earliest = bills.map(\.paymentDate).min() else {
            return HistoryView.monthStart(for: Date())
        }
        return HistoryView.monthStart(for: earliest)
    }

    private var upperBound: Date {
        let currentMonth = HistoryView.monthStart(for: Date())
        guard let latest = bills.map(\.paymentDate).max() else { return currentMonth }
        let latestMonth = HistoryView.monthStart(for: latest)
        return latestMonth > currentMonth ? latestMonth : currentMonth
    }

    private var canGoEarlier: Bool { selectedMonth > lowerBound }
    private var canGoLater: Bool { selectedMonth < upperBound }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: selectedMonth) else { return }
        // Reduce Motion 時は月移動のスライドを止める（DESIGN.md §7）。
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            selectedMonth = HistoryView.monthStart(for: next)
        }
    }

    // MARK: 本体

    var body: some View {
        NavigationStack {
            Group {
                if bills.isEmpty {
                    EmptyStateView(
                        icon: "clock",
                        title: "履歴はまだありません",
                        message: "登録した請求が月ごとに表示されます。"
                    )
                } else {
                    VStack(spacing: 0) {
                        monthBar
                        Divider()
                        monthContent
                    }
                }
            }
            .background(AppTheme.groupedBackground)
            .navigationTitle("履歴")
            .sheet(item: $editingBill) { bill in
                BillEditorView(bill: bill)
            }
            .sheet(isPresented: $showsMonthPicker) {
                MonthPickerSheet(
                    selectedMonth: selectedMonth,
                    range: lowerBound...upperBound
                ) { month in
                    selectedMonth = month
                }
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: 上部の年月セレクター

    private var monthBar: some View {
        HStack(spacing: AppSpacing.xs) {
            arrowButton(system: "chevron.left", enabled: canGoEarlier) { step(-1) }
                .accessibilityLabel("前の月")

            Button {
                showsMonthPicker = true
            } label: {
                Text(AppFormatters.yearMonth(selectedMonth))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("年月を選びます")

            arrowButton(system: "chevron.right", enabled: canGoLater) { step(1) }
                .accessibilityLabel("次の月")

            Spacer(minLength: AppSpacing.m)

            Text(AppFormatters.yen(selectedMonthTotal))
                .font(.amountMedium)
                .foregroundStyle(theme.accent)
                .accessibilityLabel("この月の合計 \(AppFormatters.yen(selectedMonthTotal))")
        }
        .padding(.horizontal, AppSpacing.screen)
        .padding(.vertical, AppSpacing.m)
        .background(AppTheme.groupedBackground)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < 0 { step(1) } else { step(-1) }
                }
        )
    }

    private func arrowButton(system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? theme.accent : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }

    // MARK: 選択月の明細

    @ViewBuilder
    private var monthContent: some View {
        if selectedMonthBills.isEmpty {
            EmptyStateView(
                icon: "calendar",
                title: "この月の請求はありません",
                message: "矢印で前後の月に移動できます。"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(selectedMonthBills) { bill in
                        Button {
                            editingBill = bill
                        } label: {
                            BillRowView(bill: bill)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("\(selectedMonthBills.count)件")
                        .monospacedDigit()
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
        }
    }
}

// MARK: - 年月ピッカー

private struct MonthPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let range: ClosedRange<Date>
    let onSelect: (Date) -> Void

    @State private var year: Int
    @State private var month: Int

    init(selectedMonth: Date, range: ClosedRange<Date>, onSelect: @escaping (Date) -> Void) {
        self.range = range
        self.onSelect = onSelect
        let components = Calendar.current.dateComponents([.year, .month], from: selectedMonth)
        _year = State(initialValue: components.year ?? Calendar.current.component(.year, from: Date()))
        _month = State(initialValue: components.month ?? 1)
    }

    private var years: [Int] {
        let low = Calendar.current.component(.year, from: range.lowerBound)
        let high = Calendar.current.component(.year, from: range.upperBound)
        return Array(low...max(low, high))
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("年", selection: $year) {
                    ForEach(years, id: \.self) { value in
                        Text(verbatim: "\(value)年").tag(value)
                    }
                }
                .pickerStyle(.wheel)

                Picker("月", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(verbatim: "\(value)月").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .navigationTitle("年月を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("表示") {
                        if let date = Calendar.current.date(from: DateComponents(year: year, month: month)) {
                            onSelect(date)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
