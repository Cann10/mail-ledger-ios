import SwiftData
import SwiftUI

@main
struct CardBillsApp: App {
    @StateObject private var gmailIntegration = GmailIntegrationManager()
    @StateObject private var advertising = AdvertisingManager()
    @StateObject private var proStore = ProStore()
    @StateObject private var themeManager = ThemeManager()

    private let modelContainer: ModelContainer = {
        let schema = Schema([
            PaymentCard.self,
            Bill.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [configuration]
            )
        } catch {
            fatalError("ローカルデータベースを作成できませんでした: \(error.localizedDescription)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(
                    \.appTheme,
                    themeManager.effectivePreset(isPro: proStore.isPro).palette
                )
                .tint(themeManager.effectivePreset(isPro: proStore.isPro).palette.accent)
                .environmentObject(gmailIntegration)
                .environmentObject(advertising)
                .environmentObject(proStore)
                .environmentObject(themeManager)
                .task {
                    await proStore.prepare()
                    await advertising.updateProStatus(proStore.isPro)
                }
                .onChange(of: proStore.isPro) { _, isPro in
                    Task {
                        await advertising.updateProStatus(isPro)
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
