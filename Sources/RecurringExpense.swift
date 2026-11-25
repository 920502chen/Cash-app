import CryptoKit
import Foundation

enum ExpenseCadence: String, Codable, CaseIterable, Identifiable {
    case day, week, month, year

    var id: Self { self }

    var label: String {
        switch self {
        case .day: return "天"
        case .week: return "週"
        case .month: return "個月"
        case .year: return "年"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

struct RecurringExpense: Codable, Identifiable {
    var id = UUID()
    var description = ""
    var amount: Decimal = 0
    var merchant = ""
    var category = "待分類"
    var interval = 1
    var cadence = ExpenseCadence.month
    var startDay = Transaction.dateFormatter.string(from: Date())
    var nextIndex = 0

    var nextDay: String? {
        let formatter = Self.scheduleFormatter
        let calendar = formatter.calendar!
        let (offset, overflow) = nextIndex.multipliedReportingOverflow(by: interval)
        guard !overflow, interval > 0, nextIndex >= 0,
              let start = formatter.date(from: startDay),
              formatter.string(from: start) == startDay else { return nil }

        if cadence == .month || cadence == .year {
            let anchorDay = calendar.component(.day, from: start)
            guard let monthStart = calendar.dateInterval(of: .month, for: start)?.start,
                  let target = calendar.date(byAdding: cadence.component, value: offset, to: monthStart),
                  let days = calendar.range(of: .day, in: .month, for: target),
                  let date = calendar.date(byAdding: .day, value: min(anchorDay, days.count) - 1, to: target) else { return nil }
            return formatter.string(from: date)
        }
        return calendar.date(byAdding: cadence.component, value: offset, to: start).map(formatter.string)
    }

    func transaction(on day: String) -> Transaction {
        let fingerprint = SHA256.hash(data: Data("\(id.uuidString):\(day)".utf8))
        let b = Array(fingerprint.prefix(16))
        let transactionID = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return Transaction(id: transactionID, day: day, amount: amount, description: description,
                           category: category, merchant: merchant)
    }

    private static let scheduleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}
