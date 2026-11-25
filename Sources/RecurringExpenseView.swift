import SwiftUI

struct RecurringExpenseList: View {
    @ObservedObject var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: RecurringExpense?
    @State private var removing: RecurringExpense?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let expenses = store.book.recurringExpenses ?? []
                    if expenses.isEmpty {
                        Text("尚未設定週期性消費").foregroundStyle(.secondary)
                    }
                    ForEach(expenses) { expense in
                        Button { editing = expense } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                LabeledContent(expense.description, value: expense.amount.formatted())
                                    .foregroundStyle(.primary)
                                Text("每 \(expense.interval.formatted()) \(expense.cadence.label) · 下次 \(expense.nextDay ?? "未設定")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { removing = expense } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("編輯") { editing = expense }
                            Button("刪除", role: .destructive) { removing = expense }
                        }
                    }
                } footer: {
                    Text("開啟 App 或回到前景時會補登已到期的消費。刪除規則後，已入帳的交易仍可在交易明細查看。")
                }
            }
            .navigationTitle("週期性消費")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = RecurringExpense() } label: {
                        Label("新增週期性消費", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { expense in
                RecurringExpenseEditor(expense: expense, store: store)
            }
            .confirmationDialog("刪除這筆週期性消費？", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { expense in
                Button("刪除規則", role: .destructive) {
                    do { try store.deleteRecurring(expense.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            } message: { expense in
                Text(expense.description)
            }
            .alert("無法刪除規則", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct RecurringExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @State private var expense: RecurringExpense
    @State private var amountText: String
    @State private var nextDate: Date
    @State private var errorMessage: String?
    private let original: RecurringExpense

    init(expense: RecurringExpense, store: LedgerStore) {
        self.store = store
        original = expense
        _expense = State(initialValue: expense)
        _amountText = State(initialValue: expense.amount == 0 ? "" :
            expense.amount.formatted(.number.grouping(.never)))
        _nextDate = State(initialValue: expense.nextDay.flatMap { Transaction.dateFormatter.date(from: $0) } ?? Date())
    }

    private var amount: Decimal? {
        let value = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines), locale: .current)
        return value.flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("交易") {
                    TextField("名稱，例如房租", text: $expense.description)
                    TextField("每筆金額", text: $amountText).keyboardType(.decimalPad)
                    TextField("商家（選填）", text: $expense.merchant)
                    Picker("分類", selection: $expense.category) {
                        ForEach(store.categories, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    DatePicker("下次入帳日期", selection: $nextDate, displayedComponents: .date)
                    Stepper("每 \(expense.interval.formatted()) \(expense.cadence.label)", value: $expense.interval, in: 1...999)
                    Picker("週期單位", selection: $expense.cadence) {
                        ForEach(ExpenseCadence.allCases) { cadence in Text(cadence.label).tag(cadence) }
                    }
                } header: {
                    Text("週期")
                } footer: {
                    Text("例如每 1 個月扣繳一次房租。遇到沒有指定日期的月份，會在該月最後一天入帳。")
                }
            }
            .navigationTitle("週期設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }
                        .disabled(amount == nil || expense.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("無法儲存規則", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard let amount else { return }
        expense.amount = amount
        expense.description = expense.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = Transaction.dateFormatter.string(from: nextDate)
        if date != original.nextDay || expense.interval != original.interval || expense.cadence != original.cadence {
            expense.startDay = date
            expense.nextIndex = 0
        }
        do {
            try store.saveRecurring(expense)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
