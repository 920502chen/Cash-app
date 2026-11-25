import SwiftUI

struct SpendingChart: View {
    let transactions: [Transaction]
    @Binding var selection: String?
    private let colors: [Color] = [.teal, .blue, .orange, .pink, .indigo, .green, .purple, .brown]

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
            Text("目前沒有支出").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 12) {
                ZStack {
                    ForEach(segments) { slice in
                        let shape = Wedge(start: slice.start, end: slice.end)
                        shape.fill(slice.color.opacity(selection == nil || selection == slice.id ? 1 : 0.28))
                            .contentShape(shape)
                            .onTapGesture { select(slice.id) }
                            .accessibilityHidden(true)
                    }
                    ForEach(segments.filter { $0.share >= 0.09 }) { slice in
                        let angle = (slice.start + slice.end) / 2 * .pi / 180
                        Text(slice.percent)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.65), radius: 2)
                            .offset(x: CGFloat(cos(angle) * 51), y: CGFloat(sin(angle) * 51))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 156, height: 156)
                ForEach(segments) { slice in
                    Button { select(slice.id) } label: {
                        HStack {
                            Circle().fill(slice.color).frame(width: 10, height: 10)
                            Text(slice.id)
                            if selection == slice.id { Image(systemName: "checkmark") }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(slice.amount.formatted())
                                Text(slice.percent).font(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                        }
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

private struct Wedge: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        if end - start >= 359.999999 {
            return Path(ellipseIn: rect)
        }
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                    endAngle: .degrees(end), clockwise: false)
        path.closeSubpath()
        return path
    }
}
