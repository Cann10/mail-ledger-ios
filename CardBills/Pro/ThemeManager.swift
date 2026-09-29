import Combine
import SwiftUI

enum AppThemePreset: String, CaseIterable, Identifiable, Sendable {
    case blue
    case indigo
    case mint
    case orange
    case pink
    case monochrome

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .mint: return "Mint"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .monochrome: return "Monochrome"
        }
    }

    var palette: AppThemePalette {
        switch self {
        case .blue:
            return AppThemePalette(
                accent: Color("AccentColor"),
                summaryBackground: Color("AppSummaryBackground"),
                softAccent: Color("AppSoftAccent")
            )
        case .indigo:
            return AppThemePalette(
                accent: Color("ThemeIndigoAccent"),
                summaryBackground: Color("ThemeIndigoSummary"),
                softAccent: Color("ThemeIndigoSoft")
            )
        case .mint:
            return AppThemePalette(
                accent: Color("ThemeMintAccent"),
                summaryBackground: Color("ThemeMintSummary"),
                softAccent: Color("ThemeMintSoft")
            )
        case .orange:
            return AppThemePalette(
                accent: Color("ThemeOrangeAccent"),
                summaryBackground: Color("ThemeOrangeSummary"),
                softAccent: Color("ThemeOrangeSoft")
            )
        case .pink:
            return AppThemePalette(
                accent: Color("ThemePinkAccent"),
                summaryBackground: Color("ThemePinkSummary"),
                softAccent: Color("ThemePinkSoft")
            )
        case .monochrome:
            return AppThemePalette(
                accent: Color("ThemeMonochromeAccent"),
                summaryBackground: Color("ThemeMonochromeSummary"),
                softAccent: Color("ThemeMonochromeSoft")
            )
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    private static let defaultsKey = "selected-pro-theme"

    @Published var selectedPreset: AppThemePreset {
        didSet {
            UserDefaults.standard.set(selectedPreset.rawValue, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        if let stored = defaults.string(forKey: Self.defaultsKey),
           let preset = AppThemePreset(rawValue: stored) {
            selectedPreset = preset
        } else {
            selectedPreset = .blue
        }
    }

    func effectivePreset(isPro: Bool) -> AppThemePreset {
        isPro ? selectedPreset : .blue
    }
}
