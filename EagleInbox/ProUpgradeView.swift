import SwiftUI

struct ProUpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var purchases: ProPurchaseManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)

                        HStack(alignment: .center, spacing: 10) {
                            Text("Eagle Inbox")
                                .font(.largeTitle.bold())
                            AccessPlanBadge(plan: .pro)
                                .offset(y: 2)
                        }
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Eagle Inbox Pro")
                        .accessibilityIdentifier("pro.title")

                        Text(
                            "Unlock unlimited connections and all Shortcut actions."
                        )
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        benefit(
                            systemImage: "externaldrive.connected.to.line.below",
                            title: "Unlimited Connections",
                            description: "Save and switch between as many Eagle destinations as you need."
                        )
                        benefit(
                            systemImage: "square.stack.3d.up.fill",
                            title: "All Shortcut Actions",
                            description: "Automate sending with tags and annotations."
                        )
                        benefit(
                            systemImage: "button.programmable",
                            title: "Quick Send",
                            description: "Send to Eagle with the Action Button."
                        )
                    }
                    .frame(maxWidth: 520)

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await purchases.performPurchaseButtonAction()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if purchases.isLoadingProduct ||
                                    purchases.isPurchasing {
                                    ProgressView()
                                        .tint(.white)
                                }
                                Text(purchases.purchaseButtonTitle)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(purchases.isPurchaseButtonDisabled)
                        .accessibilityIdentifier("pro.purchase")

                        Text("One-time purchase. No recurring fees.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            Task { await purchases.restorePurchases() }
                        } label: {
                            HStack(spacing: 6) {
                                if purchases.isRestoring {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Restore Purchases")
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .font(.footnote)
                        .disabled(
                            purchases.isPurchasing || purchases.isRestoring
                        )
                        .accessibilityIdentifier("pro.restore")
                    }
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await purchases.prepare()
        }
        .onChange(of: purchases.hasProAccess) { _, hasProAccess in
            if hasProAccess {
                dismiss()
            }
        }
        .alert(item: $purchases.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .accessibilityIdentifier("pro.upgrade")
    }

    private func benefit(
        systemImage: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct AccessPlanBadge: View {
    enum Plan {
        case free
        case pro

        var label: String {
            switch self {
            case .free: "FREE"
            case .pro: "PRO"
            }
        }

        var tint: Color {
            switch self {
            case .free: Color.secondary
            case .pro: Color.accentColor
            }
        }

        var foreground: Color {
            switch self {
            case .free: Color.white.opacity(0.95)
            case .pro: tint
            }
        }

        var background: Color {
            switch self {
            case .free: Color.black.opacity(0.78)
            case .pro: tint.opacity(0.1)
            }
        }

        var border: Color {
            switch self {
            case .free: Color.white.opacity(0.16)
            case .pro: tint.opacity(0.65)
            }
        }
    }

    let plan: Plan

    var body: some View {
        Text(verbatim: plan.label)
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(plan.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(plan.background, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(plan.border, lineWidth: 1)
            }
            .fixedSize()
            .accessibilityLabel(
                plan == .pro ? Text("Pro plan") : Text("Free plan")
            )
    }
}
