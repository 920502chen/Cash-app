import Foundation

var monthly = RecurringExpense(amount: 1_000, startDay: "2024-01-31")
precondition(monthly.nextDay == "2024-01-31")
monthly.nextIndex = 1
precondition(monthly.nextDay == "2024-02-29")
monthly.nextIndex = 2
precondition(monthly.nextDay == "2024-03-31")

var yearly = RecurringExpense(cadence: .year, startDay: "2024-02-29", nextIndex: 1)
precondition(yearly.nextDay == "2025-02-28")
yearly.nextIndex = 4
precondition(yearly.nextDay == "2028-02-29")

let weekly = RecurringExpense(interval: 2, cadence: .week, startDay: "2026-12-25", nextIndex: 1)
precondition(weekly.nextDay == "2027-01-08")

let first = monthly.transaction(on: "2024-03-31")
let repeatPosting = monthly.transaction(on: "2024-03-31")
precondition(first.id == repeatPosting.id)
precondition(first.id != monthly.transaction(on: "2024-02-29").id)

let encoder = JSONEncoder()
let decoder = JSONDecoder()
let oldBackup = try encoder.encode(LedgerBook())
let olderBook = try decoder.decode(LedgerBook.self, from: oldBackup)
precondition(olderBook.recurringExpenses == nil)
let backup = try encoder.encode(LedgerBook(transactions: [first], recurringExpenses: [monthly]))
let restored = try decoder.decode(LedgerBook.self, from: backup)
precondition(restored.transactions.first?.id == first.id)
precondition(restored.recurringExpenses?.first?.nextDay == "2024-03-31")
