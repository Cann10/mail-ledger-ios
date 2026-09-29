import SwiftData
import SwiftUI

struct BillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]

    private let bill: Bill?
    private let preselectedCardID: UUID?

    @State private var selectedCardID: UUID?
    @State private var amountText: String
    @State private var paymentDate: Date
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    init(bill: Bill? = nil, preselectedCardID: UUID? = nil) {
        self.bill = bill
        self.preselectedCardID = preselectedCardID
        _selectedCardID = State(initialValue: bill?.cardID ?? preselectedCardID)
        _amountText = State(initialValue: bill.map { String($0.amount) } ?? "")
        _paymentDate = State(initialValue: bill?.paymentDate ?? Date())
    }

    private var parsedAmount: Int? {
        Int(amountText.replacingOccurrences(of: ",", with: ""))
    }

    private var selectedCard: PaymentCard? {
        cards.first { $0.id == selectedCardID }
    }

    private var canSave: Bool {
        selectedCard != nil && (parsedAmount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "カードが必要です",
                        systemImage: "creditcard",
                        description: Text("カード画面からカードを登録してから、請求を追加してください。")
                    )
                } else {
                    Section("請求内容") {
                        Picker("カード", selection: $selectedCardID) {
                            Text("選択してください").tag(UUID?.none)
                            ForEach(cards) { card in
                                Text(card.name).tag(Optional(card.id))
                            }
                        }

                        HStack {
                            Text("¥")
                                .foregroundStyle(.secondary)
                            TextField("38,240", text: $amountText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("請求額")
                        }

                        DatePicker(
                            "支払日",
                            selection: $paymentDate,
                            displayedComponents: .date
                        )
                    }

                    Section {
                        Label("カード番号やセキュリティコードは入力しないでください。", systemImage: "lock.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                }

                if bill != nil {
                    Section {
                        Button("この請求を削除", role: .destructive) {
                            showsDeleteConfirmation = true
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
            .navigationTitle(bill == nil ? "請求を追加" : "請求を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if selectedCardID == nil, let firstCard = cards.first {
                    selectedCardID = firstCard.id
                    applyDefaultPaymentDate(from: firstCard)
                } else if bill == nil,
                          let selectedCard,
                          preselectedCardID != nil {
                    applyDefaultPaymentDate(from: selectedCard)
                }
            }
            .onChange(of: selectedCardID) { _, newValue in
                guard bill == nil,
                      let newValue,
                      let card = cards.first(where: { $0.id == newValue }) else { return }
                applyDefaultPaymentDate(from: card)
            }
            .confirmationDialog(
                "この請求を削除しますか？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    deleteBill()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作は取り消せません。")
            }
            .alert("処理できませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func applyDefaultPaymentDate(from card: PaymentCard) {
        guard let day = card.paymentDay else { return }
        paymentDate = DateSupport.paymentDate(day: day)
    }

    private func save() {
        guard let selectedCard,
              let amount = parsedAmount,
              amount > 0 else { return }

        if let bill {
            bill.cardID = selectedCard.id
            bill.cardName = selectedCard.name
            bill.amount = amount
            bill.paymentDate = Calendar.current.startOfDay(for: paymentDate)
        } else {
            modelContext.insert(Bill(
                cardID: selectedCard.id,
                cardName: selectedCard.name,
                amount: amount,
                paymentDate: Calendar.current.startOfDay(for: paymentDate)
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteBill() {
        guard let bill else { return }
        modelContext.delete(bill)

        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
