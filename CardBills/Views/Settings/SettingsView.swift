import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager
    @EnvironmentObject private var advertising: AdvertisingManager
    @EnvironmentObject private var proStore: ProStore
    @EnvironmentObject private var themeManager: ThemeManager
    @Query private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    @State private var showsDeleteConfirmation = false
    @State private var showsDemoDataAlert = false
    @State private var showsPaywall = false
    @State private var completionMessage: String?
    @State private var errorMessage: String?

    private var hasData: Bool {
        !cards.isEmpty
            || !bills.isEmpty
            || gmailIntegration.isConnected
            || themeManager.selectedPreset != .blue
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Mail Ledger Pro") {
                    if proStore.isPro {
                        Label("Mail Ledger Pro 利用中", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(theme.accent)
                    } else {
                        Button {
                            showsPaywall = true
                        } label: {
                            Label("Mail Ledger Proにアップグレード", systemImage: "sparkles")
                        }
                    }

                    LabeledContent("購入方式", value: "買い切り")
                }

                Section("メール連携") {
                    MailIntegrationControls()
                } footer: {
                    Text("メールを一度連携。アプリを開くだけでクレカ請求を自動チェックします。手入力とメール本文の貼り付けも利用できます。")
                }

                Section("テーマ") {
                    if proStore.isPro {
                        Picker("テーマカラー", selection: $themeManager.selectedPreset) {
                            ForEach(AppThemePreset.allCases) { preset in
                                Label {
                                    Text(preset.displayName)
                                } icon: {
                                    ThemeSwatch(preset: preset)
                                }
                                .tag(preset)
                            }
                        }
                        .pickerStyle(.inline)
                    } else {
                        Button {
                            showsPaywall = true
                        } label: {
                            LabeledContent {
                                Text("Blue")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Label {
                                    Text("テーマカラー")
                                        .foregroundStyle(.primary)
                                } icon: {
                                    ThemeSwatch(preset: .blue)
                                }
                            }
                        }
                        .accessibilityHint("Mail Ledger Proで6色のテーマから選べます")
                    }
                } footer: {
                    Text(proStore.isPro
                         ? "ライト・ダーク対応のプリセットから選べます。選ぶとアプリ全体へすぐに反映されます。"
                         : "テーマカラーの変更はMail Ledger Proで利用できます。")
                }

                Section("プライバシー") {
                    Label {
                        Text("メール本文の抽出処理はiPhone内で行い、開発者のサーバー・広告SDK・外部AIへ送信しません。")
                    } icon: {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .foregroundStyle(theme.accent)
                    }

                    Label {
                        Text("カード番号・セキュリティコード・カード会社のログイン情報は取得しません。")
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(theme.accent)
                    }

                    NavigationLink("Mail Ledgerのプライバシーポリシー") {
                        PrivacyPolicyView()
                    }
                }

                if !proStore.isPro && advertising.isPrivacyOptionsRequired {
                    Section("広告") {
                        Button {
                            presentAdPrivacyOptions()
                        } label: {
                            Label("広告のプライバシー設定", systemImage: "hand.raised.fill")
                        }
                    }
                }

                Section("データ") {
                    Button {
                        if hasData {
                            showsDemoDataAlert = true
                        } else {
                            addDemoData()
                        }
                    } label: {
                        Label("デモデータを追加", systemImage: "wand.and.stars")
                    }

                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("すべてのデータを削除", systemImage: "trash")
                    }
                    .disabled(!hasData)
                } footer: {
                    Text("カードと請求は、この端末のアプリ内だけに保存されます。")
                }

                Section("Mail Ledgerについて") {
                    LabeledContent("通信", value: "メールサービス / Google広告")
                    LabeledContent("アカウント", value: "不要")
                    LabeledContent("外部SDK", value: "Google Mobile Ads / UMP")
                    LabeledContent("Mail Ledger Pro", value: proStore.isPro ? "購入済み" : "未購入")
                    LabeledContent("対応OS", value: "iOS 17以降")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.groupedBackground)
            .navigationTitle("設定")
            .sheet(isPresented: $showsPaywall) {
                ProPaywallView()
            }
            .alert("すべてのデータを削除しますか？", isPresented: $showsDeleteConfirmation) {
                Button("すべて削除", role: .destructive) {
                    deleteAllData()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("登録カード、請求履歴、メールのmessage ID、端末のメールアカウント認証情報、テーマ設定を削除します。Mail Ledger Proの購入履歴は削除されません。Google側の許可も取り消すには、先に各Gmailアカウントの連携を解除してください。")
            }
            .alert("デモデータを追加しますか？", isPresented: $showsDemoDataAlert) {
                Button("追加") { addDemoData() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("現在のデータは残したまま、カード2件と請求2件を追加します。")
            }
            .alert("完了", isPresented: Binding(
                get: { completionMessage != nil },
                set: { if !$0 { completionMessage = nil } }
            )) {
                Button("OK", role: .cancel) { completionMessage = nil }
            } message: {
                Text(completionMessage ?? "")
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

    private func addDemoData() {
        do {
            try DemoDataSeeder.seed(into: modelContext)
            completionMessage = "デモデータを追加しました。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentAdPrivacyOptions() {
        Task {
            do {
                try await advertising.presentPrivacyOptions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAllData() {
        do {
            let allBills = try modelContext.fetch(FetchDescriptor<Bill>())
            allBills.forEach { modelContext.delete($0) }

            let allCards = try modelContext.fetch(FetchDescriptor<PaymentCard>())
            allCards.forEach { modelContext.delete($0) }

            try modelContext.save()
            try gmailIntegration.clearLocalAuthorization()
            themeManager.selectedPreset = .blue
            completionMessage = "すべてのデータを削除しました。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// テーマ選択行の色見本。プリセットの `accent` を塗り、hairline で縁取る。
/// 色情報は行のテーマ名テキストが担うため VoiceOver からは隠す。
private struct ThemeSwatch: View {
    let preset: AppThemePreset

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(preset.palette.accent)
            .frame(width: 24, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

private struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section("取得・保存する情報") {
                Text("登録したカード名、任意の支払日、請求額、請求の支払日、登録日時、メールから取り込んだ場合は重複防止と確定通知の判定に必要なprovider・アカウント識別子・message ID・メール受信日時を端末内に保存します。最終確認日時はUserDefaults、GmailのOAuth tokenとiCloud Mailのメールアドレス・アプリ用パスワードはKeychainに保存します。")
            }

            Section("メール本文") {
                Text("メール本文の抽出処理はiPhone内で行います。メール本文をMail Ledgerのデータとして保存したり、開発者のサーバー・広告SDK・外部AIへ送信したりしません。")
            }

            Section("外部送信") {
                Text("Gmail連携時はGoogle OAuthとGmail API、iCloud Mail連携時はimap.mail.me.comへTLSで受信専用通信します。広告表示時はGoogle Mobile Ads SDKとUMP SDKがGoogleへ通信します。メール本文、請求解析結果、カード名、請求額、支払日、message ID、メール受信日時を広告SDKへ渡しません。")
            }

            Section("広告と同意管理") {
                Text("無料版ではホーム画面にGoogle AdMobのバナー広告を表示します。Mail Ledger Pro購入済みの場合は広告を読み込まず、表示領域も設けません。広告SDKは広告配信、効果測定、不正防止、診断のため、IPアドレスから推定されるおおよその位置情報、端末識別子、広告データ、アプリ操作情報、クラッシュ情報、パフォーマンス情報を収集する場合があります。広告の個人向け最適化とpublisher first-party IDはアプリ側で無効にしています。ATTによる追跡許可は要求しません。必要な地域ではGoogle UMPにより同意画面とプライバシー設定を提供します。")
            }

            Section("Mail Ledger Pro") {
                Text("Mail Ledger ProはApp Storeの買い切り型アプリ内課金です。購入状態はStoreKit 2が提供する検証済みTransaction entitlementで確認し、アプリ独自のPro判定値として保存しません。")
            }

            Section("取得しない情報") {
                Text("カード番号、有効期限、セキュリティコード、カード会社のログイン情報、Googleパスワード、Apple Accountの通常のパスワードは取得しません。GmailのOAuth tokenとiCloud Mailのアプリ用パスワードはKeychainにのみ保存します。")
            }

            Section("データの削除") {
                Text("「すべてのデータを削除」で、カード、請求、message ID、端末のGmail OAuth token、iCloud Mailのメールアドレスとアプリ用パスワード、テーマ設定を削除できます。Mail Ledger Proの購入履歴はApp Storeで管理されるため削除されません。Google側の許可も取り消す場合は、先に各Gmailアカウントの連携を解除してください。広告の同意設定を変更できる地域では、設定画面の「広告のプライバシー設定」を使用できます。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.groupedBackground)
        .navigationTitle("Mail Ledger プライバシーポリシー")
        .navigationBarTitleDisplayMode(.inline)
    }
}
