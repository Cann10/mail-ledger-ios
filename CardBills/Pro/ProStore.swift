import Combine
import StoreKit

enum ProPurchaseOutcome {
    case purchased
    case pending
    case cancelled
}

enum ProStoreError: LocalizedError {
    case configurationMissing
    case productUnavailable
    case verificationFailed
    case unknownPurchaseResult

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "ProのProduct IDが設定されていません。"
        case .productUnavailable:
            return "Proの商品情報を取得できませんでした。時間をおいて再試行してください。"
        case .verificationFailed:
            return "購入情報を検証できませんでした。"
        case .unknownPurchaseResult:
            return "購入結果を確認できませんでした。"
        }
    }
}

@MainActor
final class ProStore: ObservableObject {
    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false

    var entitlements: Set<ProEntitlement> {
        isPro ? Set(ProEntitlement.allCases) : []
    }

    var mailAccountLimit: Int {
        entitlements.contains(.secondMailAccount) ? 2 : 1
    }

    var gmailAccountLimit: Int { mailAccountLimit }

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = observeTransactionUpdates()
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        await refreshEntitlements()
        await loadProductIfNeeded()
    }

    func loadProductIfNeeded() async {
        guard product == nil, !isLoadingProduct else { return }
        guard let productID = ProProductConfiguration.productID else { return }

        isLoadingProduct = true
        defer { isLoadingProduct = false }

        do {
            product = try await Product.products(for: [productID])
                .first { $0.type == .nonConsumable }
        } catch {
            product = nil
        }
    }

    func purchase() async throws -> ProPurchaseOutcome {
        if product == nil {
            await loadProductIfNeeded()
        }
        guard ProProductConfiguration.productID != nil else {
            throw ProStoreError.configurationMissing
        }
        guard let product else {
            throw ProStoreError.productUnavailable
        }

        switch try await product.purchase() {
        case .success(let result):
            let transaction = try verified(result)
            await transaction.finish()
            await refreshEntitlements()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw ProStoreError.unknownPurchaseResult
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        guard let productID = ProProductConfiguration.productID else {
            isPro = false
            return
        }

        var hasActiveProTransaction = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == productID,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else {
                continue
            }
            hasActiveProTransaction = true
        }
        isPro = hasActiveProTransaction
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result else { continue }
                guard transaction.productID == ProProductConfiguration.productID else { continue }

                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw ProStoreError.verificationFailed
        }
    }
}
