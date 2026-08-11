import SwiftUI

enum SendActionVisualState: Hashable {
    case disabled
    case ready
    case adding
    case sending
    case failed
}

struct SendActionButtonLabel: View {
    let title: String
    let state: SendActionVisualState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background

            if state == .sending {
                SendButtonShimmer()
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                glyph
                    .frame(width: 24, height: 24)
                    .id(state)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                    .accessibilityHidden(true)

                Text(title)
                    .font(.body.weight(.semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.28),
            value: state
        )
        .sensoryFeedback(.error, trigger: state) { _, newState in
            newState == .failed
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .ready, .sending:
            LinearGradient(
                colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .failed:
            Color.red.opacity(0.11)
        case .disabled, .adding:
            Color.secondary.opacity(0.12)
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .ready, .sending:
            .white
        case .failed:
            .red
        case .disabled, .adding:
            .secondary
        }
    }

    private var strokeColor: Color {
        switch state {
        case .failed:
            Color.red.opacity(0.24)
        case .disabled, .adding:
            Color.secondary.opacity(0.16)
        case .ready, .sending:
            .clear
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .sending:
            SendingGlyph()
        case .adding:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .ready:
            Image(systemName: "paperplane.fill")
        case .disabled:
            Image(systemName: "paperplane")
        }
    }
}

struct SendActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(
                .spring(response: 0.24, dampingFraction: 0.76),
                value: configuration.isPressed
            )
    }
}

struct OperationMessageCard: View {
    let message: String
    let accessibilityPrefix: String
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 56)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier(
                    "\(accessibilityPrefix).operationMessage.text"
                )

            HStack(spacing: 0) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss Message")
                .accessibilityIdentifier(
                    "\(accessibilityPrefix).operationMessage.dismiss"
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

private struct SendingGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.74)
                .stroke(
                    Color.white.opacity(0.72),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(
                    .degrees(isAnimating && !reduceMotion ? 360 : 0)
                )

            Image(systemName: "paperplane.fill")
                .font(.system(size: 9, weight: .bold))
                .offset(
                    x: isAnimating && !reduceMotion ? 1.5 : 0,
                    y: isAnimating && !reduceMotion ? -1.5 : 0
                )
        }
        .frame(width: 22, height: 22)
        .onAppear {
            startAnimationIfAllowed()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                withAnimation(nil) {
                    isAnimating = false
                }
            } else {
                startAnimationIfAllowed()
            }
        }
    }

    private func startAnimationIfAllowed() {
        guard !reduceMotion else { return }
        isAnimating = false
        withAnimation(.linear(duration: 0.86).repeatForever(autoreverses: false)) {
            isAnimating = true
        }
    }
}

private struct SendButtonShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = -0.5

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.2), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(80, proxy.size.width * 0.34))
            .skewedHorizontally()
            .offset(x: progress * proxy.size.width)
        }
        .opacity(reduceMotion ? 0 : 1)
        .allowsHitTesting(false)
        .onAppear {
            startAnimationIfAllowed()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                withAnimation(nil) {
                    progress = -0.5
                }
            } else {
                startAnimationIfAllowed()
            }
        }
    }

    private func startAnimationIfAllowed() {
        guard !reduceMotion else { return }
        progress = -0.5
        withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
            progress = 1.25
        }
    }
}

private struct HorizontalSkewModifier: GeometryEffect {
    var amount: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(a: 1, b: 0, c: amount, d: 1, tx: 0, ty: 0)
        )
    }
}

private extension View {
    func skewedHorizontally() -> some View {
        modifier(HorizontalSkewModifier(amount: -0.28))
    }
}
