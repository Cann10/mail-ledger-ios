import Foundation

enum AdConfiguration {
    private enum Key {
        static let homeBannerAdUnitID = "AdMobHomeBannerAdUnitID"
    }

    static var homeBannerAdUnitID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: Key.homeBannerAdUnitID) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.hasPrefix("ca-app-pub-"), trimmedValue.contains("/") else {
            return nil
        }
        return trimmedValue
    }
}
