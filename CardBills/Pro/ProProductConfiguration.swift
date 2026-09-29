import Foundation

enum ProProductConfiguration {
    private static let infoPlistKey = "ProProductID"

    static var productID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains(".") else { return nil }
        return trimmed
    }
}
