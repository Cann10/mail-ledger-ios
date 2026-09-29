import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var gmailIntegration: GmailIntegrationManager
    @Query(sort: \PaymentCard.createdAt) private var cards: [PaymentCard]
    @Query private var bills: [Bill]

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("ホーム", systemImage: "house.fill")
                }

            HistoryView()
                .tabItem {
                    Label("履歴", systemImage: "clock.fill")
                }

            CardsView()
                .tabItem {
                    Label("カード", systemImage: "creditcard.fill")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape.fill")
                }
        }
        .task {
            await checkMail(trigger: .appLaunch)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await checkMail(trigger: .foreground)
            }
        }
        .sheet(isPresented: Binding(
            get: { !gmailIntegration.pendingCandidates.isEmpty },
            set: { isPresented in
                if !isPresented { gmailIntegration.clearPendingCandidates() }
            }
        )) {
            GmailImportReviewView(
                candidates: gmailIntegration.pendingCandidates,
                onFinished: { gmailIntegration.clearPendingCandidates() }
            )
        }
        .alert("メールを確認できませんでした", isPresented: Binding(
            get: { gmailIntegration.checkErrorMessage != nil },
            set: { isPresented in
                if !isPresented { gmailIntegration.clearCheckError() }
            }
        )) {
            Button("OK", role: .cancel) {
                gmailIntegration.clearCheckError()
            }
        } message: {
            Text(gmailIntegration.checkErrorMessage ?? "")
        }
    }

    private func checkMail(trigger: GmailAutomaticCheckTrigger) async {
        await gmailIntegration.checkForNewBills(
            cards: cards,
            existingBills: bills,
            trigger: trigger
        )
    }
}
