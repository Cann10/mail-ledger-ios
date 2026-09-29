import SwiftData
import SwiftUI

struct MailIntegrationControls: View {
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var mailIntegration: GmailIntegrationManager
    @EnvironmentObject private var proStore: ProStore
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    @State private var showsProviderSelection = false
    @State private var showsGmailDisclosure = false
    @State private var showsICloudConnection = false
    @State private var showsPaywall = false
    @State private var isDisconnecting = false
    @State private var accountToDisconnect: MailAccountReference?
    @State private var errorMessage: String?

    private var isUpdating: Bool { mailIntegration.isChecking || isDisconnecting }

    var body: some View {
        Group {
            LabeledContent(
                "メール",
                value: mailIntegration.isConnected
                    ? "\(mailIntegration.mailAccountCount)アカウント連携中"
                    : "未連携"
            )

            ForEach(mailIntegration.accounts) { account in
                accountRow(
                    provider: .gmail,
                    emailAddress: account.emailAddress,
                    disconnect: .gmail(account)
                )
            }

            ForEach(mailIntegration.iCloudAccounts) { account in
                accountRow(
                    provider: .iCloud,
                    emailAddress: account.emailAddress,
                    disconnect: .iCloud(account)
                )
            }

            if mailIntegration.isConnected {
                Button {
                    updateFromMail()
                } label: {
                    Label("メールから請求を更新", systemImage: "arrow.clockwise")
                }
                .disabled(isUpdating)

                GmailCheckStatusSummaryView()
            }

            if mailIntegration.mailAccountCount < 2 {
                Button {
                    requestAccountConnection()
                } label: {
                    Label(
                        mailIntegration.isConnected ? "メールアカウントを追加" : "メールを連携",
                        systemImage: "link"
                    )
                }
                .disabled(isUpdating)
            }
        }
        .confirmationDialog(
            "メールサービスを選択",
            isPresented: $showsProviderSelection,
            titleVisibility: .visible
        ) {
            Button("Gmail") {
                guard mailIntegration.isConfigured else {
                    errorMessage = "Gmail OAuthの設定が必要です。"
                    return
                }
                showsGmailDisclosure = true
            }
            Button("iCloud Mail") {
                showsICloudConnection = true
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("請求メールを受信しているサービスを選んでください。")
        }
        .sheet(isPresented: $showsGmailDisclosure) {
            GmailConnectionDisclosureView(
                maxAccounts: proStore.mailAccountLimit,
                onConnected: runInitialCheck
            )
            .environmentObject(mailIntegration)
        }
        .sheet(isPresented: $showsICloudConnection) {
            ICloudMailConnectionView(
                maxAccounts: proStore.mailAccountLimit,
                onConnected: runInitialCheck
            )
            .environmentObject(mailIntegration)
        }
        .sheet(isPresented: $showsPaywall) {
            ProPaywallView()
        }
        .alert("メール連携を解除しますか？", isPresented: Binding(
            get: { accountToDisconnect != nil },
            set: { if !$0 { accountToDisconnect = nil } }
        )) {
            Button("連携解除", role: .destructive) {
                guard let accountToDisconnect else { return }
                disconnect(accountToDisconnect)
            }
            Button("キャンセル", role: .cancel) { accountToDisconnect = nil }
        } message: {
            Text(disconnectionMessage)
        }
        .alert("メールを更新できませんでした", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func accountRow(
        provider: MailProvider,
        emailAddress: String,
        disconnect: MailAccountReference
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: provider == .gmail ? "envelope.fill" : "icloud.fill")
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(emailAddress)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive) {
                accountToDisconnect = disconnect
            } label: {
                Image(systemName: "link.badge.minus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(emailAddress)の連携を解除")
            .disabled(isUpdating)
        }
    }

    private var disconnectionMessage: String {
        guard let accountToDisconnect else { return "" }
        switch accountToDisconnect {
        case .gmail(let account):
            return "\(account.emailAddress)のGoogle許可を取り消し、端末のKeychainからOAuth tokenを削除します。保存済みの請求は残ります。"
        case .iCloud(let account):
            return "\(account.emailAddress)のメールアドレスとアプリ用パスワードを端末のKeychainから削除します。保存済みの請求は残ります。"
        }
    }

    private func requestAccountConnection() {
        if mailIntegration.mailAccountCount >= proStore.mailAccountLimit {
            showsPaywall = true
        } else {
            showsProviderSelection = true
        }
    }

    private func updateFromMail() {
        Task {
            await mailIntegration.checkForNewBills(
                cards: cards,
                existingBills: bills,
                trigger: .manual
            )
        }
    }

    private func runInitialCheck() {
        Task {
            await mailIntegration.checkForNewBills(
                cards: cards,
                existingBills: bills,
                trigger: .connectionCompleted
            )
        }
    }

    private func disconnect(_ account: MailAccountReference) {
        isDisconnecting = true
        Task {
            defer { isDisconnecting = false }
            do {
                switch account {
                case .gmail(let gmailAccount):
                    try await mailIntegration.disconnect(account: gmailAccount)
                case .iCloud(let iCloudAccount):
                    try mailIntegration.disconnectICloud(account: iCloudAccount)
                }
                accountToDisconnect = nil
            } catch {
                accountToDisconnect = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum MailAccountReference: Identifiable {
    case gmail(GmailAccount)
    case iCloud(ICloudMailAccount)

    var id: String {
        switch self {
        case .gmail(let account): return "gmail:\(account.id)"
        case .iCloud(let account): return "icloud:\(account.id)"
        }
    }
}

private struct ICloudMailConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mailIntegration: GmailIntegrationManager

    let maxAccounts: Int
    let onConnected: () -> Void

    @State private var emailAddress = ""
    @State private var appSpecificPassword = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    private var canConnect: Bool {
        emailAddress.contains("@")
            && !appSpecificPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Apple Accountの通常のパスワードは入力しないでください")
                            .font(.body.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(AppTheme.warmWarning)
                    }
                } footer: {
                    Text("Mail Ledgerでは、iCloud Mail専用に発行したアプリ用パスワードだけを使用します。")
                }

                Section("1. iCloudメールアドレス") {
                    TextField("name@icloud.com", text: $emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                }

                Section("2. アプリ用パスワードを発行") {
                    Text("Apple公式サイトへサインインし、「サインインとセキュリティ」→「アプリ用パスワード」→「アプリ用パスワードを作成」の順に進みます。")
                        .font(.subheadline)

                    Text("アプリ用パスワードの発行には、Apple Accountの2ファクタ認証が必要です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Link(destination: URL(string: "https://account.apple.com/")!) {
                        Label("Apple公式サイトを開く", systemImage: "safari")
                    }

                    Link(destination: URL(string: "https://support.apple.com/ja-jp/102654")!) {
                        Label("Apple公式の手順を確認", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    SecureField("xxxx-xxxx-xxxx-xxxx", text: $appSpecificPassword)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("3. アプリ用パスワード")
                } footer: {
                    Text("メールアドレスとアプリ用パスワードはKeychainに保存し、UserDefaultsやSwiftDataには保存しません。")
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            ProgressView().tint(.white)
                        } else {
                            Text("接続を確認して連携")
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(!canConnect)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("imap.mail.me.comへポート993・TLSで受信専用接続します。メール送信機能はありません。")
                }

                Section("プライバシー") {
                    Text("メール本文の抽出処理はiPhone内で行います。メール本文をMail Ledgerのデータとして保存したり、開発者のサーバー・広告SDK・外部AIへ送信したりしません。")
                        .font(.subheadline)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
            .navigationTitle("iCloud Mailを連携")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isConnecting)
                }
            }
            .interactiveDismissDisabled(isConnecting)
            .alert("iCloud Mailを連携できませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func connect() {
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await mailIntegration.connectICloud(
                    emailAddress: emailAddress,
                    appSpecificPassword: appSpecificPassword,
                    maxAccounts: maxAccounts
                )
                appSpecificPassword = ""
                dismiss()
                onConnected()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
