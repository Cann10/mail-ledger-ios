import SwiftUI

struct AppThemePalette: Sendable {
    let accent: Color
    let summaryBackground: Color
    let softAccent: Color

    static let blue = AppThemePreset.blue.palette
}

private struct AppThemePaletteKey: EnvironmentKey {
    static let defaultValue = AppThemePalette.blue
}

extension EnvironmentValues {
    var appTheme: AppThemePalette {
        get { self[AppThemePaletteKey.self] }
        set { self[AppThemePaletteKey.self] = newValue }
    }
}

enum AppTheme {
    static let warmWarning = Color("AppWarmWarning")
    static let success = Color("AppSuccess")

    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let hairline = Color(uiColor: .separator)

    /// 角丸は `.continuous` 前提で4段階に整理する。
    static let panelCornerRadius: CGFloat = 20   // ホーム hero・大きめパネル
    static let cardCornerRadius: CGFloat = 16    // 標準カード・リストコンテナ・比較表
    static let ctaCornerRadius: CGFloat = 14     // 主要ボタン
    static let compactCornerRadius: CGFloat = 12 // 日付チップ・アイコン箱・コールアウト
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24

    /// 画面の水平パディング。
    static let screen: CGFloat = 20
}

extension Font {
    /// 行内・カード内の金額（Dynamic Type 対応・等幅数字）。カード名より一段強くする。
    static let amountRow = Font.body.weight(.semibold).monospacedDigit()
    /// 次の引き落とし・月合計などの中位の金額。
    static let amountMedium = Font.title3.weight(.semibold).monospacedDigit()
}

enum AppFormatters {
    static func yen(_ amount: Int) -> String {
        amount.formatted(
            .currency(code: "JPY")
            .locale(Locale(identifier: "ja_JP"))
            .precision(.fractionLength(0))
        )
    }

    static func monthDay(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .locale(Locale(identifier: "ja_JP"))
                .month(.defaultDigits)
                .day()
        )
    }

    static func yearMonth(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .locale(Locale(identifier: "ja_JP"))
                .year()
                .month(.wide)
        )
    }
}

enum DateSupport {
    static func daysUntil(_ date: Date, from referenceDate: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: referenceDate)
        let end = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func paymentDate(day: Int, from referenceDate: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)

        for monthOffset in 0...1 {
            guard let targetMonth = calendar.date(byAdding: .month, value: monthOffset, to: today),
                  let monthRange = calendar.range(of: .day, in: .month, for: targetMonth) else {
                continue
            }

            let components = DateComponents(
                year: calendar.component(.year, from: targetMonth),
                month: calendar.component(.month, from: targetMonth),
                day: min(day, monthRange.count)
            )

            if let candidate = calendar.date(from: components), candidate >= today {
                return candidate
            }
        }

        return today
    }
}

// MARK: - 共通コンポーネント

/// 「いつ」を表す日付チップ。ホーム・履歴・確認画面で共通利用する。
struct DateChip: View {
    @Environment(\.appTheme) private var theme

    let date: Date

    var body: some View {
        VStack(spacing: 1) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(date, format: .dateTime.day())
                .font(.title3.weight(.bold).monospacedDigit())
        }
        // 固定サイズのチップなので、大きな Dynamic Type でも枠内に収まるよう縮小を許可する。
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: 48, height: 50)
        .background(
            theme.softAccent,
            in: RoundedRectangle(cornerRadius: AppTheme.compactCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppFormatters.monthDay(date))
    }
}

/// 状態表示（成功 / 要確認 / 中立）を色・アイコン・文字の3点で伝える。
enum AppStatus {
    case success(String)
    case attention(String)
    case neutral(String)

    var text: String {
        switch self {
        case .success(let value), .attention(let value), .neutral(let value):
            return value
        }
    }

    var color: Color {
        switch self {
        case .success: return AppTheme.success
        case .attention: return AppTheme.warmWarning
        case .neutral: return Color(uiColor: .secondaryLabel)
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .neutral: return "circle"
        }
    }
}

struct StatusChip: View {
    let status: AppStatus
    var showsSymbol = true

    var body: some View {
        Label {
            Text(status.text)
        } icon: {
            if showsSymbol {
                Image(systemName: status.symbol)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.color)
        .accessibilityElement(children: .combine)
    }
}

/// `ContentUnavailableView` ベースの共通空状態。全画面で同じ語彙を使う。
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// カード内やホームの階層内で使う、控えめな1行の「まだない」表示。
struct InlineNoticeRow: View {
    var icon: String = "calendar"
    let title: String
    var message: String? = nil

    var body: some View {
        HStack(spacing: AppSpacing.m) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .appCard()
        .accessibilityElement(children: .combine)
    }
}

/// カードを一覧で見分けるためのモノグラム。色は増やさず頭文字で識別する。
struct CardAvatar: View {
    @Environment(\.appTheme) private var theme

    let name: String
    var size: CGFloat = 44

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        Text(initial.isEmpty ? "?" : initial)
            .font(.headline.weight(.bold))
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .background(
                theme.softAccent,
                in: RoundedRectangle(cornerRadius: AppTheme.compactCornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 安心メッセージのコールアウト。断定表現を含めない事実文を渡す。
/// `title` を渡すと「見出し＋補足」の2行構成（Paywall の "安心に関わる機能は無料のまま" 等）。
struct PrivacyCallout: View {
    @Environment(\.appTheme) private var theme

    let text: String
    var title: String? = nil
    var systemImage = "lock.shield.fill"

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.s) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(theme.accent)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(text)
                        .font(.subheadline)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            theme.softAccent,
            in: RoundedRectangle(cornerRadius: AppTheme.compactCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 共通スタイル / モディファイア

extension View {
    /// 標準カード面（`surface` + 角丸 + 影なし）。
    func appCard(
        padding: CGFloat = AppSpacing.l,
        cornerRadius: CGFloat = AppTheme.cardCornerRadius
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppTheme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

/// 主要 CTA。アクセント色・幅いっぱい・角丸 14・最小高さ 50。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        @Environment(\.appTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(
                    theme.accent.opacity(isEnabled ? 1 : 0.4),
                    in: RoundedRectangle(cornerRadius: AppTheme.ctaCornerRadius, style: .continuous)
                )
                .opacity(configuration.isPressed ? 0.82 : 1)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.ctaCornerRadius, style: .continuous))
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: configuration.isPressed
                )
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

// MARK: - 請求行

struct BillRowView: View {
    let bill: Bill

    private var daysText: String {
        let days = DateSupport.daysUntil(bill.paymentDate)
        switch days {
        case ..<0: return "支払日経過"
        case 0: return "今日"
        case 1: return "明日"
        default: return "あと\(days)日"
        }
    }

    private var isUrgent: Bool {
        let days = DateSupport.daysUntil(bill.paymentDate)
        return days >= 0 && days <= 3
    }

    /// VoiceOver は視覚順ではなく「日付・カード名・金額・残り日数」の順で 1 要素にまとめる（DESIGN.md §7）。
    private var accessibilityText: String {
        "\(AppFormatters.monthDay(bill.paymentDate))、\(bill.cardName)、\(AppFormatters.yen(bill.amount))、\(daysText)"
    }

    var body: some View {
        HStack(spacing: 14) {
            DateChip(date: bill.paymentDate)

            VStack(alignment: .leading, spacing: 4) {
                Text(bill.cardName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(daysText)
                    .font(.caption)
                    .foregroundStyle(isUrgent ? AppTheme.warmWarning : Color(uiColor: .secondaryLabel))
            }

            Spacer(minLength: 8)

            Text(AppFormatters.yen(bill.amount))
                .font(.amountRow)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}
