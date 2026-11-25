import Foundation
import SwiftUI

struct Transaction: Codable, Identifiable {
    var id = UUID()
    var day = Transaction.dateFormatter.string(from: Date())
    var amount: Decimal = 0
    var description = ""
    var category = "待分類"
    var merchant = ""

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct KeywordRule: Codable, Hashable {
    var keyword: String
    var category: String
}

struct LedgerPreferences: Codable {
    var categories = ["餐飲", "交通", "網購", "休閒", "醫療", "退款", "購物", "待分類"]
    var keyword_rules: [KeywordRule] = []
}

struct LedgerBook: Codable {
    var transactions: [Transaction] = []
    var settings = LedgerPreferences()
    var recurringExpenses: [RecurringExpense]?

    var csv: String {
        let header = "spend_date,amount,description,category,merchant"
        let rows = transactions.map { transaction in
            [transaction.day, String(describing: transaction.amount), transaction.description,
             transaction.category, transaction.merchant]
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n")
    }
}

enum LedgerError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var book = LedgerBook()
    @Published private(set) var revision = 0
    @Published var message: String?
    private let file = URL.applicationSupportDirectory.appendingPathComponent("ledger.json")
    private var canWrite = true

    var canSynchronize: Bool { canWrite }

    init() {
        do {
            book = try JSONDecoder().decode(LedgerBook.self, from: Data(contentsOf: file))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoSuchFileError {
            return
        } catch {
            canWrite = false
            message = "無法讀取 iPhone 上的記帳資料。\n\(error.localizedDescription)"
        }
    }

    var categories: [String] {
        let all = book.settings.categories + book.transactions.map(\.category) +
            (book.recurringExpenses ?? []).map(\.category) + ["待分類", "退款"]
        return Set(all).sorted()
    }

    func save(_ transaction: Transaction) {
        var transaction = transaction
        if transaction.category == "待分類",
           let match = book.settings.keyword_rules.first(where: {
               (transaction.description + " " + transaction.merchant).localizedCaseInsensitiveContains($0.keyword)
           }) {
            transaction.category = match.category
        }
        var updated = book
        if let index = updated.transactions.firstIndex(where: { $0.id == transaction.id }) {
            updated.transactions[index] = transaction
        } else {
            updated.transactions.append(transaction)
        }
        persist(updated)
    }

    func delete(_ ids: Set<UUID>) {
        var updated = book
        updated.transactions.removeAll { ids.contains($0.id) }
        persist(updated)
    }

    func addRecognized(_ transactions: [Transaction]) throws {
        var updated = book
        updated.transactions.append(contentsOf: transactions.map { item in
            var item = item
            if item.amount < 0 {
                item.category = "退款"
            } else if let rule = updated.settings.keyword_rules.first(where: {
                (item.description + " " + item.merchant).localizedCaseInsensitiveContains($0.keyword)
            }) {
                item.category = rule.category
            }
            return item
        })
        try write(updated)
    }

    @discardableResult
    func restore(_ backup: LedgerBook) throws -> Bool {
        var restored = backup
        let added = postDueExpenses(in: &restored)
        try write(restored)
        return added
    }

    func saveRecurring(_ expense: RecurringExpense) throws {
        var updated = book
        var expenses = updated.recurringExpenses ?? []
        if let index = expenses.firstIndex(where: { $0.id == expense.id }) {
            expenses[index] = expense
        } else {
            expenses.append(expense)
        }
        updated.recurringExpenses = expenses
        _ = postDueExpenses(in: &updated)
        try write(updated)
    }

    func deleteRecurring(_ id: UUID) throws {
        var updated = book
        updated.recurringExpenses?.removeAll { $0.id == id }
        try write(updated)
    }

    func postDueExpenses() {
        var updated = book
        if postDueExpenses(in: &updated) { persist(updated) }
    }

    @discardableResult
    private func postDueExpenses(in updated: inout LedgerBook) -> Bool {
        guard var rules = updated.recurringExpenses, !rules.isEmpty else { return false }
        let today = Transaction.dateFormatter.string(from: Date())
        var existing = Set(updated.transactions.map(\.id))
        var advanced = false
        for index in rules.indices where rules[index].amount > 0 {
            while let day = rules[index].nextDay, day <= today {
                let transaction = rules[index].transaction(on: day)
                if existing.insert(transaction.id).inserted {
                    updated.transactions.append(transaction)
                }
                rules[index].nextIndex += 1
                advanced = true
            }
        }
        if advanced { updated.recurringExpenses = rules }
        return advanced
    }

    func legacyBackup(csv: Data?, settings: Data?) throws -> LedgerBook {
        var backup = LedgerBook()
        if let csv {
            guard let source = String(data: csv, encoding: .utf8) else {
                throw LedgerError.invalid("Drive 交易備份不是 UTF-8 CSV。")
            }
            backup.transactions = try LedgerCSV.transactions(from: source)
        }
        if let settings {
            backup.settings = try JSONDecoder().decode(LedgerPreferences.self, from: settings)
        }
        return backup
    }

    var hasLocalData: Bool {
        let defaults = LedgerPreferences()
        return !book.transactions.isEmpty || !(book.recurringExpenses ?? []).isEmpty || !book.settings.keyword_rules.isEmpty ||
            Set(book.settings.categories) != Set(defaults.categories)
    }

    func addCategory(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !book.settings.categories.contains(name) else { return }
        var updated = book
        updated.settings.categories.append(name)
        persist(updated)
    }

    func addRule(keyword: String, category: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let rule = KeywordRule(keyword: keyword, category: category)
        guard !book.settings.keyword_rules.contains(rule) else { return }
        var updated = book
        updated.settings.keyword_rules.append(rule)
        persist(updated)
    }

    func deleteRules(_ indexes: IndexSet) {
        var updated = book
        updated.settings.keyword_rules.remove(atOffsets: indexes)
        persist(updated)
    }

    func importFile(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        var updated = book
        if url.pathExtension.lowercased() == "json" {
            let settings = try JSONDecoder().decode(LedgerPreferences.self, from: data)
            updated.settings.categories = Array(Set(updated.settings.categories + settings.categories)).sorted()
            for rule in settings.keyword_rules where !rule.keyword.isEmpty &&
                !updated.settings.keyword_rules.contains(rule) {
                updated.settings.keyword_rules.append(rule)
            }
            try write(updated)
            message = "已匯入分類與關鍵字。"
        } else {
            guard let source = String(data: data, encoding: .utf8) else {
                throw LedgerError.invalid("請選擇 UTF-8 編碼的 CSV。")
            }
            let transactions = try LedgerCSV.transactions(from: source)
            // Track counts so multiple identical rows in an original backup survive the first import.
            var counts = Dictionary(grouping: updated.transactions, by: LedgerCSV.identity).mapValues(\.count)
            let additions = transactions.filter {
                let key = LedgerCSV.identity($0)
                guard let count = counts[key], count > 0 else { return true }
                counts[key] = count - 1
                return false
            }
            updated.transactions.append(contentsOf: additions)
            try write(updated)
            message = "已匯入 \(additions.count) 筆交易。"
        }
    }

    private func persist(_ updated: LedgerBook) {
        do { try write(updated) }
        catch { message = error.localizedDescription }
    }

    private func write(_ updated: LedgerBook) throws {
        guard canWrite else { throw LedgerError.invalid("無法儲存，原本的記帳資料讀取失敗。") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        book = updated
        revision += 1
    }
}

private enum LedgerCSV {
    static func identity(_ transaction: Transaction) -> [String] {
        [transaction.day, String(describing: transaction.amount), transaction.description,
         transaction.category, transaction.merchant]
    }

    static func transactions(from source: String) throws -> [Transaction] {
        let records = try rows(source)
        guard let heading = records.first else { return [] }
        let columns = heading.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let day = columns.firstIndex(where: { ["spend_date", "date", "日期", "消費日期", "交易日期", "入帳日期"].contains($0) }),
              let amount = columns.firstIndex(where: { ["amount", "金額", "交易金額", "消費金額"].contains($0) }),
              let description = columns.firstIndex(where: { ["description", "內容", "消費內容", "交易內容", "品項", "摘要", "備註", "說明"].contains($0) }) else {
            throw LedgerError.invalid("CSV 必須包含日期、金額和交易內容。")
        }
        let category = columns.firstIndex(where: { ["category", "分類", "類別"].contains($0) })
        let merchant = columns.firstIndex(where: { ["merchant", "商家", "店家", "商店", "收款方"].contains($0) })

        return try records.dropFirst().enumerated().map { offset, row in
            func value(_ index: Int?) -> String {
                guard let index, row.indices.contains(index) else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let dayText = value(day).replacingOccurrences(of: "/", with: "-")
            let rawAmount = value(amount).replacingOccurrences(of: ",", with: "")
            guard let date = Transaction.dateFormatter.date(from: dayText),
                  let money = Decimal(string: rawAmount, locale: Locale(identifier: "en_US_POSIX")),
                  money != 0 else {
                throw LedgerError.invalid("第 \(offset + 2) 筆 CSV 記錄的日期或金額無效。")
            }
            var item = Transaction()
            item.day = Transaction.dateFormatter.string(from: date)
            item.amount = money
            item.description = value(description).isEmpty ? "匯入交易" : value(description)
            item.category = value(category).isEmpty ? "待分類" : value(category)
            item.merchant = value(merchant)
            return item
        }
    }

    private static func rows(_ source: String) throws -> [[String]] {
        var cursor = (source.first == "\u{FEFF}" ? source.dropFirst() : source[...]).makeIterator()
        var character = cursor.next()
        var quoted = false
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        while let current = character {
            character = cursor.next()
            switch current {
            case "\"" where quoted && character == "\"":
                field.append("\"")
                character = cursor.next()
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                row.append(field)
                field = ""
            case "\n", "\r", "\r\n":
                if quoted {
                    field.append(current)
                } else {
                    row.append(field)
                    if row.contains(where: { !$0.isEmpty }) { records.append(row) }
                    row = []
                    field = ""
                }
            default:
                field.append(current)
            }
        }
        guard !quoted else { throw LedgerError.invalid("CSV 有未結束的引號。") }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { records.append(row) }
        return records
    }
}
