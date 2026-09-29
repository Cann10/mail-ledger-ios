import StoreKit
import SwiftUI

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var proStore: ProStore

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showsSuccess = false
    @State private var message: String?
    @State private var errorMessage: String?

    // 同じ公開版で実際に使える機能だけを掲載する（PAYWALL_SPEC §5）。
    private let benefits: [Benefit] = [
        Benefit(icon: "rectangle.slash", title: "広告なし", detail: "ホームのバナーを完全に非表示"),
        Benefit(icon: "envelope.badge", title: "メールを合計2アカウント連携", detail: "GmailとiCloud Mailを合計2件まで"),
        Benefit(icon: "paintpalette", title: "6テーマ", detail: "見やすさを保ったプリセットカラー")
    ]

    private let comparison: [ComparisonRow] = [
        ComparisonRow(name: "基本の請求管理", free: "利用可", pro: "利用可"),
        ComparisonRow(name: "メール自動取込", free: "1アカウント", pro: "2アカウント"),
        ComparisonRow(name: "端末内で解析・保存", free: "利用可", pro: "利用可"),
        ComparisonRow(name: "広告", free: "バナーあり", pro: "なし"),
        ComparisonRow(name: "テーマ", free: "ブルー", pro: "6テーマ")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.xxl) {
                    hero
                    benefitList
                    comparisonTable
                    freeSafetyNote
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.s)
                .padding(.bottom, AppSpacing.xxl)
            }
            .background(AppTheme.groupedBackground)
            .safeAreaInset(edge: .bottom) {
                purchaseBar
            }
            .navigationTitle("Mail Ledger Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .disabled(isPurchasing || isRestoring)
                }
            }
            .task {
                await proStore.loadProductIfNeeded()
            }
            .onChange(of: proStore.isPro) { _, isPro in
                if isPro && !showsSuccess { dismiss() }
            }
            .sheet(isPresented: $showsSuccess, onDismiss: { dismiss() }) {
                ProPurchaseSuccessView()
            }
            .alert("お知らせ", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .alert("購入を完了できませんでした", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: AppSpacing.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 56, height: 56)
                .background(
                    theme.softAccent,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                )

            Text("一度買えば、ずっと快適。月額料金なし。")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            priceView

            Text("月額・年額料金なし")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.xxl)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var priceView: some View {
        if let product = proStore.product {
            Text(product.displayPrice)
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(theme.accent)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel("価格 \(product.displayPrice)")
        } else if proStore.isLoadingProduct {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.hairline)
                .frame(width: 148, height: 44)
                .redacted(reason: .placeholder)
                .accessibilityLabel("価格を確認中")
        } else {
            Text("価格を取得できません")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pro 機能一覧

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Mail Ledger Proでできること")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(benefits.enumerated()), id: \.offset) { index, benefit in
                    HStack(spacing: 14) {
                        Image(systemName: benefit.icon)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(benefit.title)
                                .font(.body.weight(.semibold))
                            Text(benefit.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AppSpacing.m)
                    .accessibilityElement(children: .combine)

                    if index < benefits.count - 1 {
                        Divider()
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

    // MARK: Free / Pro 比較

    private var comparisonTable: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Free と Pro のちがい")
                .font(.headline)

            VStack(spacing: 0) {
                comparisonRow(ComparisonRow(name: "機能", free: "Free", pro: "Pro"), isHeader: true)
                Divider()
                ForEach(Array(comparison.enumerated()), id: \.offset) { index, row in
                    comparisonRow(row, isHeader: false)
                    if index < comparison.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                AppTheme.surface,
                in: RoundedRectangle(cornerRadius: AppTheme.ctaCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.ctaCornerRadius, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 0.5)
            )
        }
    }

    private func comparisonRow(_ row: ComparisonRow, isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            comparisonCell(row.name, alignment: .leading, isHeader: isHeader, emphasized: !isHeader)
                .overlay(alignment: .trailing) { columnSeparator }

            comparisonCell(row.free, alignment: .center, isHeader: isHeader)
                .overlay(alignment: .trailing) { columnSeparator }

            comparisonCell(row.pro, alignment: .center, isHeader: isHeader, isProColumn: true)
        }
        .frame(minHeight: isHeader ? 38 : 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isHeader ? "" : "\(row.name)、Free \(row.free)、Pro \(row.pro)")
        // 見出し行（機能 / Free / Pro）は各データ行が列名を含むため VoiceOver では読み飛ばす。
        .accessibilityHidden(isHeader)
    }

    private func comparisonCell(
        _ text: String,
        alignment: Alignment,
        isHeader: Bool,
        emphasized: Bool = false,
        isProColumn: Bool = false
    ) -> some View {
        Text(text)
            .font(.caption.weight(isHeader || emphasized ? .semibold : .regular))
            .foregroundStyle(isProColumn && !isHeader ? theme.accent : (isHeader ? Color.secondary : Color.primary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.horizontal, 10)
            .padding(.vertical, AppSpacing.s)
            .background(isProColumn && !isHeader ? theme.accent.opacity(0.06) : Color.clear)
    }

    private var columnSeparator: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(width: 0.5)
    }

    // MARK: 無料でも守られること

    private var freeSafetyNote: some View {
        PrivacyCallout(
            text: "基本の請求管理、メール自動取込、端末内での解析・保存はFreeでも利用できます。",
            title: "安心に関わる機能は無料のまま"
        )
    }

    // MARK: 下部固定の購入バー

    private var purchaseBar: some View {
        VStack(spacing: AppSpacing.s) {
            Text("一度きりの買い切りです。追加料金はありません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            Button {
                purchase()
            } label: {
                if isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(purchaseButtonTitle)
                }
            }
            .buttonStyle(.primary)
            .disabled(proStore.product == nil || isPurchasing || isRestoring)

            Button("購入を復元") {
                restore()
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .disabled(isPurchasing || isRestoring)

            if proStore.isLoadingProduct {
                Text("価格を確認中…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.screen)
        .padding(.top, AppSpacing.m)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
    }

    private var purchaseButtonTitle: String {
        guard let product = proStore.product else { return "価格を取得できません" }
        return "\(product.displayPrice)でMail Ledger Proを購入"
    }

    // MARK: アクション

    private func purchase() {
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                switch try await proStore.purchase() {
                case .purchased:
                    showsSuccess = true
                case .pending:
                    message = "購入は承認待ちです。承認後に自動で反映されます。"
                case .cancelled:
                    break
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await proStore.restorePurchases()
                message = proStore.isPro
                    ? "購入を復元しました。"
                    : "復元できるMail Ledger Pro購入は見つかりませんでした。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct Benefit {
    let icon: String
    let title: String
    let detail: String
}

private struct ComparisonRow {
    let name: String
    let free: String
    let pro: String
}

// MARK: - 購入完了

struct ProPurchaseSuccessView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    private let changes = [
        "ホームの広告が消えます",
        "メールを合計2アカウント連携できます",
        "テーマカラーを選べます"
    ]

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(AppTheme.success)
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.s) {
                Text("Mail Ledger Proを購入しました")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("この端末ですぐに利用できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: AppSpacing.m) {
                ForEach(changes, id: \.self) { change in
                    Label {
                        Text(change)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCard()

            Spacer()

            Button("閉じる") { dismiss() }
                .buttonStyle(.primary)
        }
        .padding(AppSpacing.screen)
        .background(AppTheme.groupedBackground)
    }
}
