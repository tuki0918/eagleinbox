import Foundation
import StoreKit

struct ProPurchaseNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ProPurchaseManager: ObservableObject {
    @Published private(set) var entitlementState: ProEntitlementState
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var hasAttemptedProductLoad = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var notice: ProPurchaseNotice?

    private let entitlementStore: ProEntitlementStore
    private let isStoreKitEnabled: Bool
    private var transactionUpdatesTask: Task<Void, Never>?
    private var isPrepared = false
    private var isPreparing = false
    private var entitlementRefreshGeneration = 0

    init(
        entitlementStore: ProEntitlementStore = ProEntitlementStore(),
        isStoreKitEnabled: Bool = true
    ) {
        self.entitlementStore = entitlementStore
        self.isStoreKitEnabled = isStoreKitEnabled
        if isStoreKitEnabled {
            entitlementState = entitlementStore.state
            observeTransactionUpdates()
        } else {
            let storedState = entitlementStore.state
            if storedState == .unknown {
                entitlementStore.save(isPro: false)
                entitlementState = .free
            } else {
                entitlementState = storedState
            }
        }
    }

    var hasProAccess: Bool {
        entitlementState == .pro
    }

    var purchaseButtonTitle: String {
        if let product {
            return String(localized: "Unlock for \(product.displayPrice)")
        }
        if isLoadingProduct || !hasAttemptedProductLoad {
            return String(localized: "Loading Price…")
        }
        return String(localized: "Try Again")
    }

    var isPurchaseButtonDisabled: Bool {
        if isBusy {
            return true
        }
        return product == nil && !hasAttemptedProductLoad
    }

    var isBusy: Bool {
        isLoadingProduct || isPurchasing || isRestoring
    }

    func prepare() async {
        guard isStoreKitEnabled, !isPrepared, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        await finishUnfinishedTransactions()
        guard !Task.isCancelled else { return }
        await refreshEntitlements()
        guard !Task.isCancelled else { return }
        await loadProduct(showsError: false)
        guard !Task.isCancelled else { return }
        isPrepared = true
    }

    func purchase() async {
        guard isStoreKitEnabled,
              !hasProAccess,
              !isPurchasing,
              !isRestoring,
              let product else {
            return
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case let .success(result):
                let transaction = try verifiedTransaction(result)
                grantProAccess()
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                notice = ProPurchaseNotice(
                    title: String(localized: "Purchase Pending"),
                    message: String(
                        localized: "Your purchase is waiting for approval. Pro will unlock automatically after it is approved."
                    )
                )
            case .userCancelled:
                break
            @unknown default:
                showPurchaseError()
            }
        } catch {
            showPurchaseError(error)
        }
    }

    func performPurchaseButtonAction() async {
        if product == nil {
            await loadProduct(showsError: true)
            return
        }
        await purchase()
    }

    func restorePurchases() async {
        guard isStoreKitEnabled, !isPurchasing, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !hasProAccess {
                notice = ProPurchaseNotice(
                    title: String(localized: "No Purchase Found"),
                    message: String(
                        localized: "Make sure you’re signed in with the Apple Account used to buy Eagle Inbox Pro."
                    )
                )
            }
        } catch {
            showPurchaseError(error)
        }
    }

    private func loadProduct(showsError: Bool) async {
        guard !isLoadingProduct else { return }
        isLoadingProduct = true
        defer {
            isLoadingProduct = false
            hasAttemptedProductLoad = true
        }

        do {
            product = try await Product.products(
                for: [SharedIdentifiers.proProductID]
            ).first
            if product == nil, showsError {
                notice = ProPurchaseNotice(
                    title: String(localized: "Purchase Couldn’t Be Completed"),
                    message: String(
                        localized: "Eagle Inbox Pro is temporarily unavailable. Check your connection and try again."
                    )
                )
            }
        } catch {
            if showsError {
                showPurchaseError(error)
            }
        }
    }

    private func refreshEntitlements() async {
        entitlementRefreshGeneration &+= 1
        let generation = entitlementRefreshGeneration
        var hasVerifiedProEntitlement = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.productID == SharedIdentifiers.proProductID,
                  transaction.revocationDate == nil else {
                continue
            }
            hasVerifiedProEntitlement = true
        }

        guard !Task.isCancelled,
              generation == entitlementRefreshGeneration else {
            return
        }
        entitlementStore.save(isPro: hasVerifiedProEntitlement)
        entitlementState = hasVerifiedProEntitlement ? .pro : .free
    }

    private func finishUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard case let .verified(transaction) = result,
                  transaction.productID == SharedIdentifiers.proProductID else {
                continue
            }
            if transaction.revocationDate == nil {
                grantProAccess()
            } else {
                await refreshEntitlements()
            }
            await transaction.finish()
        }
    }

    private func observeTransactionUpdates() {
        transactionUpdatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                guard case let .verified(transaction) = result else {
                    continue
                }
                guard transaction.productID == SharedIdentifiers.proProductID else {
                    continue
                }
                if transaction.revocationDate == nil {
                    self.grantProAccess()
                } else {
                    await self.refreshEntitlements()
                }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func verifiedTransaction(
        _ result: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch result {
        case let .verified(transaction):
            guard transaction.productID == SharedIdentifiers.proProductID,
                  transaction.revocationDate == nil else {
                throw ProPurchaseError.failedVerification
            }
            return transaction
        case .unverified:
            throw ProPurchaseError.failedVerification
        }
    }

    private func grantProAccess() {
        entitlementRefreshGeneration &+= 1
        entitlementStore.save(isPro: true)
        entitlementState = .pro
    }

    private func showPurchaseError(_ error: Error? = nil) {
        let fallback = String(
            localized: "The purchase could not be completed. Please try again."
        )
        let message = error?.localizedDescription.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        notice = ProPurchaseNotice(
            title: String(localized: "Purchase Couldn’t Be Completed"),
            message: message?.isEmpty == false ? message! : fallback
        )
    }
}

private enum ProPurchaseError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        String(
            localized: "The App Store could not verify this purchase. Please try again."
        )
    }
}
