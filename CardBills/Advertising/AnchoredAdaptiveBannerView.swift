import GoogleMobileAds
import SwiftUI

struct HomeAnchoredAdaptiveBannerView: View {
    @EnvironmentObject private var advertising: AdvertisingManager

    @State private var isLoaded = false
    @State private var loadedHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if advertising.canRequestAds,
               let adUnitID = AdConfiguration.homeBannerAdUnitID {
                let width = max(geometry.size.width, 1)
                let adSize = largeAnchoredAdaptiveBanner(width: width)

                BannerViewContainer(
                    adSize: adSize,
                    adUnitID: adUnitID,
                    isLoaded: $isLoaded
                )
                .id("\(adUnitID)-\(Int(width.rounded()))")
                .frame(width: adSize.size.width, height: adSize.size.height)
                .frame(maxWidth: .infinity)
                .task(id: Int(width.rounded())) {
                    isLoaded = false
                    loadedHeight = adSize.size.height
                }
            }
        }
        .frame(height: advertising.canRequestAds && isLoaded ? loadedHeight : 0)
        .clipped()
        .accessibilityHidden(!isLoaded)
        .onChange(of: advertising.canRequestAds) { _, canRequestAds in
            if !canRequestAds {
                isLoaded = false
                loadedHeight = 0
            }
        }
    }
}

@MainActor
private struct BannerViewContainer: UIViewRepresentable {
    let adSize: AdSize
    let adUnitID: String
    @Binding var isLoaded: Bool

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.delegate = context.coordinator
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoaded: $isLoaded)
    }

    final class Coordinator: NSObject, BannerViewDelegate {
        private let isLoaded: Binding<Bool>

        init(isLoaded: Binding<Bool>) {
            self.isLoaded = isLoaded
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            isLoaded.wrappedValue = true
        }

        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
            isLoaded.wrappedValue = false
        }
    }
}
