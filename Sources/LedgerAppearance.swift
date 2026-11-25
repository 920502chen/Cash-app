import SwiftUI
import UIKit

enum LedgerAppearance {
    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.77, green: 0.68, blue: 1, alpha: 1)
        }
        return UIColor(red: 0.34, green: 0.23, blue: 0.65, alpha: 1)
    })
}

struct LedgerBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if !reduceTransparency {
                RadialGradient(colors: [LedgerAppearance.accent.opacity(scheme == .dark ? 0.27 : 0.17), .clear],
                               center: .topLeading, startRadius: 8, endRadius: 320)
                RadialGradient(colors: [Color.indigo.opacity(scheme == .dark ? 0.18 : 0.10), .clear],
                               center: .topTrailing, startRadius: 24, endRadius: 280)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct LedgerGlassControls<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func ledgerGlassControl<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

struct LedgerMonthSummary: View {
    let net: Decimal
    let transactionCount: Int
    let refunds: Decimal
    let comparison: String
    let comparisonIcon: String

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 44

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 5) {
                Text("本月淨額")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(net.formatted())
                    .font(.system(size: amountSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .accessibilityLabel("本月淨額 \(net.formatted())")
                Label("較前月淨花費\(comparison)", systemImage: comparisonIcon)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LedgerAppearance.accent)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    metric("交易筆數", "\(transactionCount.formatted()) 筆")
                    metric("退款／折讓合計", refunds.formatted())
                }
                VStack(alignment: .leading, spacing: 12) {
                    metric("交易筆數", "\(transactionCount.formatted()) 筆")
                    metric("退款／折讓合計", refunds.formatted())
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                if !reduceTransparency {
                    shape.fill(LinearGradient(colors: [LedgerAppearance.accent.opacity(scheme == .dark ? 0.19 : 0.12),
                                                       LedgerAppearance.accent.opacity(scheme == .dark ? 0.05 : 0.025)],
                                              startPoint: .topTrailing, endPoint: .bottomLeading))
                }
            }
        }
        .overlay {
            shape.strokeBorder(LedgerAppearance.accent.opacity(scheme == .dark ? 0.25 : 0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
