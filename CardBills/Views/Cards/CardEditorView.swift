import SwiftData
import SwiftUI

struct CardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let card: PaymentCard?

    @State private var name: String
    @State private var hasPaymentDay: Bool
    @State private var paymentDay: Int
    @State private var errorMessage: String?

    init(card: PaymentCard? = nil) {
        self.card = card
        _name = State(initialValue: card?.name ?? "")
        _hasPaymentDay = State(initialValue: card?.paymentDay != nil)
        _paymentDay = State(initialValue: card?.paymentDay ?? 27)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("カード情報") {
                    TextField("カード名（例：楽天カード）", text: $name)
                        .textInputAutocapitalization(.never)

                    Toggle("支払日を設定", isOn: $hasPaymentDay)

                    if hasPaymentDay {
                        Picker("毎月の支払日", selection: $paymentDay) {
                            ForEach(1...31, id: \.self) { day in
                                Text("\(day)日").tag(day)
                            }
                        }
                    }
                }

                if hasPaymentDay {
                    Section {
                        Text("その日が存在しない月は、請求追加時に月末の日付を提案します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("入力しない情報") {
                    Label("カード番号", systemImage: "nosign")
                    Label("有効期限・セキュリティコード", systemImage: "nosign")
                    Label("カード会社のログイン情報", systemImage: "nosign")
                }
                .foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
            .navigationTitle(card == nil ? "カードを追加" : "カードを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .alert("保存できませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let selectedDay = hasPaymentDay ? paymentDay : nil

        if let card {
            let cardID = card.id
            card.name = trimmedName
            card.paymentDay = selectedDay

            do {
                let descriptor = FetchDescriptor<Bill>(
                    predicate: #Predicate { bill in
                        bill.cardID == cardID
                    }
                )
                let linkedBills = try modelContext.fetch(descriptor)
                linkedBills.forEach { $0.cardName = trimmedName }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            modelContext.insert(PaymentCard(
                name: trimmedName,
                paymentDay: selectedDay
            ))
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
