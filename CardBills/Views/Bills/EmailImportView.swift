import SwiftData
import SwiftUI

private struct ParsedBillDraft: Equatable {
    var selectedCardID: UUID?
    var amountText: String
    var paymentDate: Date
    let cardWasDetected: Bool
    let amountWasDetected: Bool
    let dateWasDetected: Bool
}

struct EmailImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]

    @State private var emailText = ""
    @State private var draft: ParsedBillDraft?
    @State private var errorMessage: String?

    private var selectedCard: PaymentCard? {
        guard let id = draft?.selectedCardID else { return nil }
        return cards.first { $0.id == id }
    }

    private var parsedAmount: Int? {
        guard let text = draft?.amountText else { return nil }
        return Int(text.replacingOccurrences(of: ",", with: ""))
    }

    private var canSave: Bool {
        selectedCard != nil && (parsedAmount ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if draft == nil {
                    pasteStep
                } else {
                    confirmationStep
                }
            }
            .navigationTitle(draft == nil ? "メールから読み取り" : "内容を確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft == nil ? "キャンセル" : "戻る") {
                        if draft == nil {
                            discardAndDismiss()
                        } else {
                            draft = nil
                        }
                    }
                }

                if draft != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(!emailText.isEmpty)
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

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: AppSpacing.l) {
            PrivacyCallout(text: "メール本文は端末内で解析し、保存しません。")

            Text("カード会社から届いた請求案内の本文を貼り付けてください。カード番号やログイン情報を含む文章は貼り付けないでください。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextEditor(text: $emailText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(
                    AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                )
                .overlay(alignment: .topLeading) {
                    if emailText.isEmpty {
                        Text("例：\n楽天カード\nご請求予定額 38,240円\nお支払日 2026年9月27日")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                analyze()
            } label: {
                Label("内容を読み取る", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.primary)
            .disabled(emailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(AppSpacing.screen)
        .background(AppTheme.groupedBackground)
    }

    private var confirmationStep: some View {
        Form {
            Section {
                Picker("カード", selection: Binding(
                    get: { draft?.selectedCardID },
                    set: { draft?.selectedCardID = $0 }
                )) {
                    Text("選択してください").tag(UUID?.none)
                    ForEach(cards) { card in
                        Text(card.name).tag(Optional(card.id))
                    }
                }

                HStack {
                    Text("請求額")
                    Spacer()
                    Text("¥")
                        .foregroundStyle(.secondary)
                    TextField("38,240", text: Binding(
                        get: { draft?.amountText ?? "" },
                        set: { draft?.amountText = $0 }
                    ))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
                }

                DatePicker(
                    "支払日",
                    selection: Binding(
                        get: { draft?.paymentDate ?? Date() },
                        set: { draft?.paymentDate = $0 }
                    ),
                    displayedComponents: .date
                )
            } header: {
                Text("抽出結果")
            } footer: {
                Text("正しく読み取れなかった項目は、保存前に修正できます。")
            }

            Section("読み取り状況") {
                detectionRow("カード", detected: draft?.cardWasDetected == true)
                detectionRow("請求額", detected: draft?.amountWasDetected == true)
                detectionRow("支払日", detected: draft?.dateWasDetected == true)
            }

            Section {
                Label("保存されるのはカード名・金額・支払日・登録日時だけです。", systemImage: "externaldrive.fill.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.groupedBackground)
    }

    private func detectionRow(_ label: String, detected: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            StatusChip(status: detected ? .success("読取済み") : .attention("要確認"))
        }
    }

    private func analyze() {
        let candidates = cards.map { EmailCardCandidate(id: $0.id, name: $0.name) }
        let result = EmailBillingParser().parse(emailText, cards: candidates)

        draft = ParsedBillDraft(
            selectedCardID: result.card?.id,
            amountText: result.amount.map(String.init) ?? "",
            paymentDate: result.paymentDate ?? Date(),
            cardWasDetected: result.card != nil,
            amountWasDetected: result.amount != nil,
            dateWasDetected: result.paymentDate != nil
        )
    }

    private func save() {
        guard let selectedCard,
              let amount = parsedAmount,
              amount > 0,
              let paymentDate = draft?.paymentDate else { return }

        modelContext.insert(Bill(
            cardID: selectedCard.id,
            cardName: selectedCard.name,
            amount: amount,
            paymentDate: Calendar.current.startOfDay(for: paymentDate)
        ))

        do {
            try modelContext.save()
            emailText = ""
            draft = nil
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardAndDismiss() {
        emailText = ""
        draft = nil
        dismiss()
    }
}
