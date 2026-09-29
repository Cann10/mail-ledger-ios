import SwiftData
import SwiftUI

struct GmailIntegrationControls: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager
    @EnvironmentObject private var proStore: ProStore
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    @State private var showsConnectionDisclosure = false
    @State private var showsPaywall = false
    @State private var isDisconnecting = false
    @State private var accountToDisconnect: GmailAccount?
    @State private var errorMessage: String?

    private var isUpdating: Bool { gmailIntegration.isChecking || isDisconnecting }

    private var statusText: String {
        if !gmailIntegration.isConfigured { return "設定が必要" }
        guard !gmailIntegration.accounts.isEmpty else { return "未連携" }
        return "\(gmailIntegration.accounts.count)アカウント連携中"
    }

    var body: some View {
        Group {
            LabeledContent("Gmail", value: statusText)

            if gmailIntegration.isConnected {
                ForEach(gmailIntegration.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(theme.accent)

                        Text(account.emailAddress)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        Button(role: .destructive) {
                            accountToDisconnect = account
                        } label: {
                            Image(systemName: "link.badge.minus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(account.emailAddress)の連携を解除")
                        .disabled(isUpdating)
                    }
                }

                Button {
                    updateFromGmail()
                } label: {
                    Label("Gmailから請求を更新", systemImage: "arrow.clockwise")
                }
                .disabled(isUpdating)

                GmailCheckStatusSummaryView()

            }

            if gmailIntegration.accounts.count < 2 {
                Button {
                    requestAccountConnection()
                } label: {
                    Label(
                        gmailIntegration.isConnected ? "Gmailアカウントを追加" : "Gmailを連携",
                        systemImage: "link"
                    )
                }
                .disabled(!gmailIntegration.isConfigured || isUpdating)
            }

        }
        .sheet(isPresented: $showsConnectionDisclosure) {
            GmailConnectionDisclosureView(
                maxAccounts: proStore.gmailAccountLimit,
                onConnected: {
                    Task {
                        await gmailIntegration.checkForNewBills(
                            cards: cards,
                            existingBills: bills,
                            trigger: .connectionCompleted
                        )
                    }
                }
            )
                .environmentObject(gmailIntegration)
        }
        .sheet(isPresented: $showsPaywall) {
            ProPaywallView()
        }
        .alert("Gmail連携を解除しますか？", isPresented: Binding(
            get: { accountToDisconnect != nil },
            set: { if !$0 { accountToDisconnect = nil } }
        )) {
            Button("連携解除", role: .destructive) {
                guard let accountToDisconnect else { return }
                disconnect(accountToDisconnect)
            }
            Button("キャンセル", role: .cancel) { accountToDisconnect = nil }
        } message: {
            Text("\(accountToDisconnect?.emailAddress ?? "このアカウント")のGoogle許可を取り消し、端末のKeychainからOAuth tokenを削除します。保存済みの請求は残ります。")
        }
        .alert("Gmailを更新できませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func requestAccountConnection() {
        if gmailIntegration.accounts.count >= proStore.gmailAccountLimit {
            showsPaywall = true
        } else {
            showsConnectionDisclosure = true
        }
    }

    private func updateFromGmail() {
        Task {
            await gmailIntegration.checkForNewBills(
                cards: cards,
                existingBills: bills,
                trigger: .manual
            )
        }
    }

    private func disconnect(_ account: GmailAccount) {
        isDisconnecting = true
        Task {
            defer { isDisconnecting = false }
            do {
                try await gmailIntegration.disconnect(account: account)
                accountToDisconnect = nil
            } catch {
                accountToDisconnect = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct GmailConnectionDisclosureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager

    let maxAccounts: Int
    let onConnected: () -> Void

    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(theme.accent)
                        .accessibilityHidden(true)

                    Text("Gmailを一度連携。アプリを開くだけで請求を自動チェック")
                        .font(.title2.weight(.bold))

                    Text("登録カードの請求メールだけを検索し、メール本文の解析はiPhoneの中で行います。")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    disclosureGroup(
                        title: "Mail Ledgerが行うこと",
                        rows: [
                            "読み取り専用のgmail.readonlyだけを要求",
                            "登録カードに関係する請求メールだけを検索",
                            "抽出処理はiPhoneの中だけで実行"
                        ],
                        symbol: "checkmark.circle.fill",
                        tint: AppTheme.success
                    )

                    disclosureGroup(
                        title: "行わないこと",
                        rows: [
                            "本文と請求情報を開発者のサーバー・広告SDK・外部AIへ送信しない",
                            "メールの送信・削除・既読化・ラベル変更はしない",
                            "メール本文をMail Ledgerのデータとして保存しない"
                        ],
                        symbol: "xmark.circle",
                        tint: .secondary
                    )
                }
                .padding(AppSpacing.screen)
            }
            .background(AppTheme.groupedBackground)
            .safeAreaInset(edge: .bottom) {
                Button {
                    connect()
                } label: {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Googleで続ける")
                    }
                }
                .buttonStyle(.primary)
                .disabled(isConnecting)
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.m)
                .background(.bar, ignoresSafeAreaEdges: .bottom)
                .overlay(alignment: .top) { Divider() }
            }
            .navigationTitle("Gmailを連携")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isConnecting)
                }
            }
            .interactiveDismissDisabled(isConnecting)
            .alert("Gmailを連携できませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func disclosureGroup(
        title: String,
        rows: [String],
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: AppSpacing.s) {
                ForEach(rows, id: \.self) { row in
                    Label {
                        Text(row)
                    } icon: {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func connect() {
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await gmailIntegration.connect(maxAccounts: maxAccounts)
                dismiss()
                onConnected()
            } catch GmailIntegrationError.authorizationCancelled {
                // Cancellation is an expected user action; keep the disclosure visible.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct GmailImportDraft: Identifiable {
    let id: String
    let provider: MailProvider
    let accountIdentifier: String
    let accountEmailAddress: String
    let companyID: String
    let receivedAt: Date
    let existingBillID: UUID?
    var selectedCardID: UUID?
    var amountText: String
    var paymentDate: Date?
    var isIncluded: Bool
    let extractionState: GmailCandidateExtractionState
    let amountWasDetected: Bool
    let dateWasDetected: Bool
    var amountWasConfirmed: Bool
    var dateWasConfirmed: Bool
    /// 送信元の認証が確認できなかった場合の控えめな注記（それ以外は nil）。
    let senderVerificationNotice: String?
    /// limited 信頼度。抽出済みでも金額・支払日をユーザーが明示確認するまで保存させない。
    let requiresSenderConfirmation: Bool

    init(candidate: GmailBillCandidate) {
        id = candidate.messageID
        provider = candidate.provider
        accountIdentifier = candidate.accountIdentifier
        accountEmailAddress = candidate.accountEmailAddress
        companyID = candidate.companyID
        receivedAt = candidate.receivedAt
        existingBillID = candidate.existingBillID
        selectedCardID = candidate.cardID
        amountText = candidate.amount.map(String.init) ?? ""
        paymentDate = candidate.paymentDate
        isIncluded = true
        extractionState = candidate.extractionState
        amountWasDetected = candidate.amount != nil
        dateWasDetected = candidate.paymentDate != nil
        amountWasConfirmed = false
        dateWasConfirmed = false
        senderVerificationNotice = candidate.senderVerificationNotice
        requiresSenderConfirmation = candidate.trustLevel != .trusted
    }

    var canSave: Bool {
        guard !isIncluded else {
            let amountReady = requiresSenderConfirmation
                ? amountWasConfirmed
                : (amountWasDetected || amountWasConfirmed)
            let dateReady = requiresSenderConfirmation
                ? dateWasConfirmed
                : (dateWasDetected || dateWasConfirmed)
            return selectedCardID != nil
                && parsedAmount != nil
                && paymentDate != nil
                && amountReady
                && dateReady
        }
        return true
    }

    var parsedAmount: Int? {
        guard let amount = Int(amountText.replacingOccurrences(of: ",", with: "")),
              amount > 0 else { return nil }
        return amount
    }

    var reviewPrompt: String? {
        guard isIncluded else { return nil }
        var missing: [String] = []
        if selectedCardID == nil { missing.append("カード") }
        if parsedAmount == nil { missing.append("金額") }
        if paymentDate == nil { missing.append("支払日") }

        if missing.isEmpty { return nil }
        if missing == ["金額"] { return "金額だけ入力してください" }
        if missing == ["支払日"] { return "支払日を確認してください" }
        if missing == ["カード"] { return "カードを選択してください" }
        return "一部の情報を確認してください（\(missing.joined(separator: "・"))）"
    }

    mutating func confirmAmountText(_ text: String) {
        amountText = text
        amountWasConfirmed = parsedAmount != nil
    }

    mutating func confirmPaymentDate(_ date: Date) {
        paymentDate = Calendar.current.startOfDay(for: date)
        dateWasConfirmed = true
    }
}

struct GmailImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    @State private var drafts: [GmailImportDraft]
    @State private var errorMessage: String?
    @State private var dateSelectionRequest: GmailDateSelectionRequest?

    let onFinished: () -> Void

    init(candidates: [GmailBillCandidate], onFinished: @escaping () -> Void) {
        _drafts = State(initialValue: candidates.map(GmailImportDraft.init(candidate:)))
        self.onFinished = onFinished
    }

    private var canSave: Bool {
        let included = drafts.filter(\.isIncluded)
        return !included.isEmpty && included.allSatisfy { draft in
            draft.canSave
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("メール本文はすでに破棄されています。抽出結果を確認・修正してから保存してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach($drafts) { $draft in
                    Section {
                        Toggle("この請求を保存", isOn: $draft.isIncluded)

                        LabeledContent(draft.provider.displayName, value: draft.accountEmailAddress)
                            .font(.footnote)

                        if draft.existingBillID != nil {
                            Label("後から届いた確定通知として既存の請求を更新します", systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        extractionStateLabel(draft.extractionState)

                        if let notice = draft.senderVerificationNotice {
                            Label(notice, systemImage: "questionmark.shield")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let reviewPrompt = draft.reviewPrompt {
                            Label(reviewPrompt, systemImage: "exclamationmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.warmWarning)
                        }

                        Group {
                            Picker("カード", selection: $draft.selectedCardID) {
                                Text("選択してください").tag(UUID?.none)
                                ForEach(cards) { card in
                                    Text(card.name).tag(Optional(card.id))
                                }
                            }

                            HStack {
                                Text("請求額")
                                Spacer()
                                Text("¥").foregroundStyle(.secondary)
                                TextField(
                                    "金額を入力してください",
                                    text: Binding(
                                        get: { draft.amountText },
                                        set: { draft.confirmAmountText($0) }
                                    )
                                )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 140)
                            }

                            if draft.paymentDate != nil {
                                DatePicker(
                                    "支払日",
                                    selection: Binding(
                                        get: { draft.paymentDate ?? Date.distantPast },
                                        set: { draft.confirmPaymentDate($0) }
                                    ),
                                    displayedComponents: .date
                                )
                            } else {
                                Button("支払日を選択してください") {
                                    dateSelectionRequest = GmailDateSelectionRequest(
                                        draftID: draft.id
                                    )
                                }
                            }

                            HStack {
                                detectionLabel(
                                    "金額",
                                    detected: draft.amountWasDetected,
                                    confirmed: draft.amountWasConfirmed
                                )
                                Spacer()
                                detectionLabel(
                                    "日付",
                                    detected: draft.dateWasDetected,
                                    confirmed: draft.dateWasConfirmed
                                )
                            }
                        }
                        .disabled(!draft.isIncluded)
                    } header: {
                        Text("抽出候補")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
            .navigationTitle("メールの請求を確認")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $dateSelectionRequest) { request in
                GmailPaymentDateSelectionView { date in
                    guard let index = drafts.firstIndex(where: { $0.id == request.draftID }) else {
                        return
                    }
                    drafts[index].confirmPaymentDate(date)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
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

    private func detectionLabel(
        _ label: String,
        detected: Bool,
        confirmed: Bool = false
    ) -> some View {
        let text: String = {
            if detected { return "\(label)：読取済み" }
            if confirmed { return "\(label)：設定済み" }
            return "\(label)：要確認"
        }()
        return StatusChip(status: detected || confirmed ? .success(text) : .attention(text))
    }

    @ViewBuilder
    private func extractionStateLabel(
        _ state: GmailCandidateExtractionState
    ) -> some View {
        switch state {
        case .complete:
            StatusChip(status: .success("自動取得"))
        case .needsReview:
            StatusChip(status: .attention("一部確認が必要"))
        }
    }

    private func save() {
        let candidates = drafts.compactMap { draft -> GmailBillCandidate? in
            guard draft.isIncluded,
                  let cardID = draft.selectedCardID,
                  let card = cards.first(where: { $0.id == cardID }),
                  let amount = draft.parsedAmount,
                  let paymentDate = draft.paymentDate,
                  draft.amountWasDetected || draft.amountWasConfirmed,
                  draft.dateWasDetected || draft.dateWasConfirmed else { return nil }

            return GmailBillCandidate(
                messageID: draft.id,
                provider: draft.provider,
                accountIdentifier: draft.accountIdentifier,
                accountEmailAddress: draft.accountEmailAddress,
                companyID: CardMailRuleRegistry().rule(for: card.name)?.id ?? draft.companyID,
                cardID: card.id,
                cardName: card.name,
                amount: amount,
                paymentDate: Calendar.current.startOfDay(for: paymentDate),
                receivedAt: draft.receivedAt,
                existingBillID: draft.existingBillID
            )
        }

        let reconciled = BillingCandidateReconciler().reconcile(
            candidates: candidates,
            existingBills: bills
        )

        for candidate in reconciled {
            guard let amount = candidate.amount,
                  let paymentDate = candidate.paymentDate else { continue }

            if let existingBillID = candidate.existingBillID,
               let existing = bills.first(where: { $0.id == existingBillID }) {
                existing.cardID = candidate.cardID
                existing.cardName = candidate.cardName
                existing.amount = amount
                existing.paymentDate = paymentDate
                existing.gmailMessageID = candidate.messageID
                existing.gmailReceivedAt = candidate.receivedAt
                existing.mailProvider = candidate.provider
                existing.mailAccountIdentifier = candidate.accountIdentifier
                continue
            }

            let cardID = candidate.cardID
            guard let card = cards.first(where: { $0.id == cardID }) else { continue }

            modelContext.insert(Bill(
                cardID: card.id,
                cardName: card.name,
                amount: amount,
                paymentDate: Calendar.current.startOfDay(for: paymentDate),
                gmailMessageID: candidate.messageID,
                gmailReceivedAt: candidate.receivedAt,
                mailProvider: candidate.provider,
                mailAccountIdentifier: candidate.accountIdentifier
            ))
        }

        do {
            try modelContext.save()
            finish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}

private struct GmailDateSelectionRequest: Identifiable {
    let draftID: String
    var id: String { draftID }
}

private struct GmailPaymentDateSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date()

    let onConfirm: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "支払日",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("支払日を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("設定") {
                        onConfirm(selectedDate)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct GmailCheckStatusSummaryView: View {
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if gmailIntegration.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.subheadline.weight(.medium))

                if let lastCheckedAt = gmailIntegration.lastCheckedAt {
                    Text("\(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))に確認済み")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if gmailIntegration.isChecking {
            return "メールで請求予定を確認中…"
        }
        switch gmailIntegration.lastCheckStatus {
        case .some(.noNewBills):
            return "新しい請求はありません"
        case .some(.candidatesFound(let count)):
            return "\(count)件の請求候補を確認してください"
        case .none:
            return "メールを一度連携。アプリを開くだけでクレカ請求を自動チェック"
        }
    }
}
