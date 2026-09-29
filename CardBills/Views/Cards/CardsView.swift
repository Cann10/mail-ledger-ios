import SwiftData
import SwiftUI

struct CardsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTheme) private var theme
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    @State private var isAddingCard = false
    @State private var editingCard: PaymentCard?
    @State private var cardToDelete: PaymentCard?

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty {
                    ContentUnavailableView {
                        Label("カードはまだありません", systemImage: "creditcard")
                    } description: {
                        Text("カード名と支払日だけを登録します。カード番号は必要ありません。")
                    } actions: {
                        Button("カードを追加") {
                            isAddingCard = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(cards) { card in
                                Button {
                                    editingCard = card
                                } label: {
                                    cardRow(card)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button("削除", role: .destructive) {
                                        cardToDelete = card
                                    }
                                    Button("編集") {
                                        editingCard = card
                                    }
                                    .tint(theme.accent)
                                }
                            }
                        } footer: {
                            Text("カード番号・有効期限・セキュリティコードは登録しません。")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.groupedBackground)
                }
            }
            .background(AppTheme.groupedBackground)
            .navigationTitle("カード")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingCard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("カードを追加")
                }
            }
            .sheet(isPresented: $isAddingCard) {
                CardEditorView()
            }
            .sheet(item: $editingCard) { card in
                CardEditorView(card: card)
            }
            .alert("カードを削除しますか？", isPresented: Binding(
                get: { cardToDelete != nil },
                set: { if !$0 { cardToDelete = nil } }
            )) {
                Button("削除", role: .destructive) {
                    guard let cardToDelete else { return }
                    modelContext.delete(cardToDelete)
                    try? modelContext.save()
                    self.cardToDelete = nil
                }
                Button("キャンセル", role: .cancel) {
                    cardToDelete = nil
                }
            } message: {
                Text("登録済みの請求履歴は、カード名の記録を残したまま保持されます。")
            }
        }
    }

    private func cardRow(_ card: PaymentCard) -> some View {
        HStack(spacing: 14) {
            CardAvatar(name: card.name)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(nextPaymentText(for: card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let count = bills.filter { $0.cardID == card.id }.count
            if count > 0 {
                Text("\(count)件")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func nextPaymentText(for card: PaymentCard) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        if let next = bills
            .filter({ $0.cardID == card.id && $0.paymentDate >= today })
            .min(by: { $0.paymentDate < $1.paymentDate }) {
            return "次回 \(AppFormatters.monthDay(next.paymentDate))"
        }
        return card.paymentDay.map { "毎月\($0)日" } ?? "支払日 未設定"
    }
}
