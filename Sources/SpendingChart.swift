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
            angle += 360 * NSDecimalNumber(decimal: category.value / total).doubleValue
            return Slice(id: category.key, amount: category.value, start: start, end: angle,
                         color: colors[index % colors.count])
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
                }
                .frame(width: 156, height: 156)
                ForEach(segments) { slice in
                    Button { select(slice.id) } label: {
                        HStack {
                            Circle().fill(slice.color).frame(width: 10, height: 10)
                            Text(slice.id)
                            if selection == slice.id { Image(systemName: "checkmark") }
                            Spacer()
                            Text(slice.amount.formatted()).monospacedDigit()
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
