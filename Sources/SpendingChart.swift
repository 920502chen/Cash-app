import SwiftUI

struct SpendingChart: View {
    let transactions: [Transaction]
    @Binding var selection: String?
    private let colors: [Color] = [
        Color(red: 0.40, green: 0.26, blue: 0.73), Color(red: 0.08, green: 0.48, blue: 0.52),
        Color(red: 0.67, green: 0.32, blue: 0.18), Color(red: 0.53, green: 0.24, blue: 0.54),
        Color(red: 0.22, green: 0.40, blue: 0.67), Color(red: 0.32, green: 0.45, blue: 0.26)
    ]

    private struct Slice: Identifiable {
        let id: String
        let amount: Decimal
        let start: Double
        let end: Double
        let color: Color
        let share: Double

        var percent: String {
            share.formatted(.percent.precision(.fractionLength(0...1)))
        }
    }

    private var slices: [Slice] {
        var amounts: [String: Decimal] = [:]
        for item in transactions where item.amount > 0 && item.category != "退款" {
            amounts[item.category, default: 0] += item.amount
        }
        let total = amounts.values.reduce(0, +)
        var angle = -90.0
        return amounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.enumerated().map { index, category in
            let start = angle
            let share = NSDecimalNumber(decimal: category.value / total).doubleValue
            angle += 360 * share
            return Slice(id: category.key, amount: category.value, start: start, end: angle,
                         color: colors[index % colors.count], share: share)
        }
    }

    var body: some View {
        let segments = slices
        if segments.isEmpty {
            Label("目前沒有支出", systemImage: "chart.pie").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 15) {
                ZStack {
                    ForEach(segments) { slice in
                        let shape = RingSlice(start: slice.start, end: slice.end)
                        shape.fill(slice.color.opacity(selection == nil || selection == slice.id ? 1 : 0.28),
                                   style: FillStyle(eoFill: true))
                            .contentShape(shape, eoFill: true)
                            .onTapGesture { select(slice.id) }
                            .accessibilityHidden(true)
                    }
                    ForEach(segments.filter { $0.share >= 0.09 }) { slice in
                        let angle = (slice.start + slice.end) / 2 * .pi / 180
                        Text(slice.percent)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(selection == nil || selection == slice.id ? Color.white : Color.primary)
                            .offset(x: CGFloat(cos(angle) * 70), y: CGFloat(sin(angle) * 70))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 4) {
                        Text("支出合計")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(segments.reduce(Decimal.zero) { $0 + $1.amount }.formatted())
                            .font(.headline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(width: 88)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
                .frame(width: 184, height: 184)
                ForEach(segments) { slice in
                    Button { select(slice.id) } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 4).fill(slice.color).frame(width: 11, height: 11)
                            Text(slice.id)
                            if selection == slice.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(LedgerAppearance.accent)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(slice.amount.formatted())
                                Text(slice.percent).font(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        if selection != nil {
            Button("清除篩選") { selection = nil }
        }
    }

    private func select(_ category: String) {
        selection = selection == category ? nil : category
    }
}

private struct RingSlice: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius * 0.53
        if end - start >= 359.999999 {
            var ring = Path(ellipseIn: rect)
            ring.addEllipse(in: rect.insetBy(dx: radius - innerRadius, dy: radius - innerRadius))
            return ring
        }
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                    endAngle: .degrees(end), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .degrees(end),
                    endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
