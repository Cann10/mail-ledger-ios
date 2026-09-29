import SwiftData
import SwiftUI

private enum NewBillSheet: String, Identifiable {
    case manual
    case email

    var id: String { rawValue }
}

struct HomeView: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager
    @EnvironmentObject private var proStore: ProStore
    @Query(sort: \Bill.paymentDate) private var bills: [Bill]
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]

    @State private var newBillSheet: NewBillSheet?
    @State private var editingBill: Bill?

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var upcomingBills: [Bill] {
        bills.filter { $0.paymentDate >= today }
    }

    private var remainingThisMonth: [Bill] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: today) else { return [] }
        return bills.filter {
            $0.paymentDate >= today && $0.paymentDate < interval.end
        }
    }

    private var monthlyTotal: Int {
        remainingThisMonth.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.xxl) {
                    summaryHero

                    if gmailIntegration.isConnected {
                        GmailCheckStatusSummaryView()
                            .appCard()
                    }

                    if let nextBill = upcomingBills.first {
                        nextPaymentSection(nextBill)
                    }

                    laterSection
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.m)
                .padding(.bottom, 32)
            }
            .background(AppTheme.groupedBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !proStore.isPro {
                    HomeAnchoredAdaptiveBannerView()
                }
            }
            .navigationTitle("Mail Ledger")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newBillSheet = .manual
                        } label: {
                            Label("手入力で追加", systemImage: "square.and.pencil")
                        }

                        Button {
                            newBillSheet = .email
                        } label: {
                            Label("メールから読み取る", systemImage: "doc.on.clipboard")
                        }
                        .disabled(cards.isEmpty)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("請求を追加")
                }
            }
            .sheet(item: $newBillSheet) { sheet in
                switch sheet {
                case .manual:
                    BillEditorView()
                case .email:
                    EmailImportView()
                }
            }
            .sheet(item: $editingBill) { bill in
                BillEditorView(bill: bill)
            }
        }
    }

    // MARK: 第1階層 — 今月の残り請求

    private var summaryHero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            HStack {
                Text("今月の残り請求")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(remainingThisMonth.count)件")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(AppFormatters.yen(monthlyTotal))
                .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(theme.accent)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Text(remainingThisMonth.isEmpty
                 ? "今月の支払い予定はありません"
                 : "今日以降、月末までの合計")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.softAccent,
            in: RoundedRectangle(cornerRadius: AppTheme.panelCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: 第2階層 — 次の引き落とし

    private func nextPaymentSection(_ bill: Bill) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("次の引き落とし")
                .font(.headline)

            Button {
                editingBill = bill
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(AppFormatters.monthDay(bill.paymentDate))
                            .font(.title2.weight(.bold))
                        Text(bill.cardName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                        Text(AppFormatters.yen(bill.amount))
                            .font(.amountMedium)
                        Text(daysLabel(for: bill.paymentDate))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isUrgent(bill.paymentDate)
                                             ? AppTheme.warmWarning
                                             : Color(uiColor: .secondaryLabel))
                    }
                }
                .appCard(padding: 18)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("請求の詳細を開きます")
        }
    }

    // MARK: 第3階層 — その後の請求

    @ViewBuilder
    private var laterSection: some View {
        let laterBills = Array(upcomingBills.dropFirst())

        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("その後の請求")
                .font(.headline)

            if laterBills.isEmpty {
                InlineNoticeRow(
                    title: upcomingBills.isEmpty ? "請求予定はありません" : "その後の請求はありません",
                    message: upcomingBills.isEmpty
                        ? (cards.isEmpty
                           ? "カードを登録すると請求を追加できます。"
                           : "右上の＋から請求を追加できます。")
                        : nil
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(laterBills.enumerated()), id: \.element.id) { index, bill in
                        Button {
                            editingBill = bill
                        } label: {
                            BillRowView(bill: bill)
                                .padding(.vertical, AppSpacing.m)
                        }
                        .buttonStyle(.plain)

                        if index < laterBills.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.l)
                .background(
                    AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                )
            }
        }
    }

    // MARK: ヘルパー

    private func isUrgent(_ date: Date) -> Bool {
        let days = DateSupport.daysUntil(date)
        return days >= 0 && days <= 3
    }

    private func daysLabel(for date: Date) -> String {
        let days = DateSupport.daysUntil(date)
        switch days {
        case 0: return "今日"
        case 1: return "明日"
        default: return "あと\(days)日"
        }
    }
}
