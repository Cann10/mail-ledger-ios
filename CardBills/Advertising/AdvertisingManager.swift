import Combine
import Foundation
import GoogleMobileAds
import UserMessagingPlatform

@MainActor
final class AdvertisingManager: ObservableObject {
    @Published private(set) var canRequestAds = false
    @Published private(set) var isPrivacyOptionsRequired = false

    private var didPrepare = false
    private var didStartMobileAds = false
    private var isPro = false

    func updateProStatus(_ isPro: Bool) async {
        self.isPro = isPro
        if isPro {
            canRequestAds = false
            return
        }

        if didPrepare {
            startMobileAdsIfAllowed()
        } else {
            await prepareIfNeeded()
        }
    }

    private func prepareIfNeeded() async {
        guard !didPrepare else { return }
        didPrepare = true

        let updateError = await requestConsentInformationUpdate()
        refreshConsentState()

        if updateError == nil {
            try? await ConsentForm.loadAndPresentIfRequired(from: nil)
            refreshConsentState()
        }

        startMobileAdsIfAllowed()
    }

    func presentPrivacyOptions() async throws {
        guard !isPro else { return }
        try await ConsentForm.presentPrivacyOptionsForm(from: nil)
        refreshConsentState()
        startMobileAdsIfAllowed()
    }

    private func requestConsentInformationUpdate() async -> Error? {
        await withCheckedContinuation { continuation in
            ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func refreshConsentState() {
        let consentInformation = ConsentInformation.shared
        isPrivacyOptionsRequired = consentInformation.privacyOptionsRequirementStatus == .required
        canRequestAds = consentInformation.canRequestAds && didStartMobileAds
    }

    private func startMobileAdsIfAllowed() {
        guard !isPro, ConsentInformation.shared.canRequestAds else {
            canRequestAds = false
            return
        }

        if !didStartMobileAds {
            let requestConfiguration = MobileAds.shared.requestConfiguration
            requestConfiguration.publisherPrivacyPersonalizationState = .disabled
            requestConfiguration.setPublisherFirstPartyIDEnabled(false)

            MobileAds.shared.start()
            didStartMobileAds = true
        }

        canRequestAds = true
    }
}
