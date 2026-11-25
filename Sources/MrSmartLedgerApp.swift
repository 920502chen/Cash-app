import PhotosUI
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

@main
struct MrSmartLedgerApp: App {
    var body: some Scene {
        WindowGroup { LedgerView().tint(LedgerAppearance.accent) }
    }
}

struct LedgerView: View {
    @StateObject private var store = LedgerStore()
    @StateObject private var cloud = LedgerCloud()
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: String?
    @State private var selectedMonth = String(Transaction.dateFormatter.string(from: Date()).prefix(7))
    @State private var editing: Transaction?
    @State private var photoDraftFailures: [String] = []
    @State private var importing = false
    @State private var exporting = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var billPhotoMode = BillPhotoMode.text
    @State private var photoProgress: String?
    private var processingPhoto: Bool { photoProgress != nil }
    @State private var showSettings = false
    @State private var showCloud = false
    @State private var showRecurring = false
    @State private var billReview: BillReview?

    private var currentMonth: String {
        String(Transaction.dateFormatter.string(from: Date()).prefix(7))
    }

    private var monthOptions: [String] {
        let recordedMonths = store.book.transactions.map { String($0.day.prefix(7)) }
        return Set(recordedMonths + [currentMonth, selectedMonth]).sorted(by: >)
    }

    private var monthTransactions: [Transaction] {
        store.book.transactions.filter { String($0.day.prefix(7)) == selectedMonth }
    }

    private var visible: [Transaction] {
        monthTransactions.filter { filter == nil || $0.category == filter }
            .sorted { $0.day > $1.day }
    }

    private func neighboringMonth(_ offset: Int) -> String? {
        guard let date = Transaction.dateFormatter.date(from: selectedMonth + "-01"),
              let other = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: date) else { return nil }
        return String(Transaction.dateFormatter.string(from: other).prefix(7))
    }

    private func selectMonth(_ month: String) {
        selectedMonth = month
        filter = nil
    }

    private var monthNavigation: some View {
        LedgerGlassControls {
            HStack(spacing: 12) {
                monthArrow("上一個月", symbol: "chevron.left", offset: -1)
                Spacer(minLength: 0)
                Menu {
                    Picker("月份", selection: Binding(get: { selectedMonth }, set: selectMonth)) {
                        ForEach(monthOptions, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar").foregroundStyle(LedgerAppearance.accent)
                        Text(selectedMonth).monospacedDigit()
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 17)
                    .frame(minHeight: 46)
                    .contentShape(Capsule())
                    .ledgerGlassControl(in: Capsule())
                    .accessibilityLabel("選擇月份 \(selectedMonth)")
                }
                Spacer(minLength: 0)
                monthArrow("下一個月", symbol: "chevron.right", offset: 1)
                    .disabled(selectedMonth >= (monthOptions.first ?? currentMonth))
            }
        }
    }

    private func monthArrow(_ title: String, symbol: String, offset: Int) -> some View {
        Button {
            if let month = neighboringMonth(offset) { selectMonth(month) }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .ledgerGlassControl(in: Circle())
        }
        .buttonStyle(.borderless)
    }

    private var monthSummary: some View {
        let transactions = monthTransactions
        let net = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        let refunds = transactions.filter { $0.amount < 0 }.reduce(Decimal.zero) { $0 + $1.amount }
        let previousMonth = neighboringMonth(-1)
        let previousNet = store.book.transactions
            .filter { String($0.day.prefix(7)) == previousMonth }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let difference = net - previousNet
        let comparison = difference == 0 ? "持平" :
            "\(difference > 0 ? "增加" : "減少") \((difference > 0 ? difference : -difference).formatted())"
        let comparisonIcon = difference == 0 ? "equal" : difference > 0 ? "arrow.up.right" : "arrow.down.right"
        return LedgerMonthSummary(net: net, transactionCount: transactions.count, refunds: refunds,
                                  comparison: comparison, comparisonIcon: comparisonIcon)
    }

    var body: some View {
        ledgerNavigation
            .photosPicker(isPresented: $showingPhotoPicker, selection: $photos, selectionBehavior: .ordered,
                          matching: .images, preferredItemEncoding: .compatible)
            .task(id: showingPhotoPicker ? [] : photos) {
                if !showingPhotoPicker, !photos.isEmpty {
                    await processBillPhotos(photos, mode: billPhotoMode)
                }
            }
    }

    private var ledgerNavigation: some View {
        NavigationStack {
            ledgerList
            .navigationTitle("智慧記帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button { showSettings = true } label: { Label("分類與關鍵字", systemImage: "tag") }
                        Button { showRecurring = true } label: { Label("週期性消費", systemImage: "repeat") }
                        Button { showCloud = true } label: { Label("Google Drive 與 Gemini", systemImage: "icloud") }
                        Button { selectBillPhoto(.gemini) } label: {
                            Label("用 Gemini 解析帳單", systemImage: "sparkles")
                        }.disabled(processingPhoto)
                        Button { importing = true } label: { Label("匯入 CSV 或 JSON", systemImage: "square.and.arrow.down") }
                        Button { exporting = true } label: { Label("匯出交易 CSV", systemImage: "square.and.arrow.up") }
                        Button { selectBillPhoto(.text) } label: {
                            Label("從帳單照片辨識文字", systemImage: "text.viewfinder")
                        }.disabled(processingPhoto)
                    } label: {
                        Label("工具", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        var draft = Transaction()
                        if selectedMonth != currentMonth { draft.day = selectedMonth + "-01" }
                        editing = draft
                    } label: {
                        Label("新增交易", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(item: $editing, onDismiss: { photoDraftFailures = [] }) { transaction in
                TransactionEditor(transaction: transaction, store: store, photoFailures: photoDraftFailures)
            }
            .sheet(isPresented: $showSettings) { LedgerSettings(store: store) }
            .sheet(isPresented: $showCloud) { CloudSettings(cloud: cloud, store: store) }
            .sheet(isPresented: $showRecurring) { RecurringExpenseList(store: store) }
            .sheet(item: $billReview) { review in
                NavigationStack {
                    List {
                        PhotoImportFailures(messages: review.failures)
                        ForEach(review.items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                LabeledContent(item.description, value: item.amount.formatted())
                                Text([item.day, item.category, item.merchant].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle("確認帳單交易")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { billReview = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("匯入 \(review.items.count) 筆") {
                                do {
                                    try store.addRecognized(review.items)
                                    billReview = nil
                                } catch {
                                    billReview = nil
                                    store.message = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .json]) { result in
                do { try store.importFile(result.get()) }
                catch { store.message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: CSVDocument(text: store.book.csv),
                          contentType: .commaSeparatedText, defaultFilename: "transactions_backup") { result in
                if case .failure(let error) = result { store.message = error.localizedDescription }
            }
            .task {
                store.postDueExpenses()
                await cloud.backup(store)
            }
            .onChange(of: store.revision) { _ in Task { await cloud.backup(store) } }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    store.postDueExpenses()
                    Task { await cloud.backup(store) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                store.postDueExpenses()
            }
            .alert("智慧記帳", isPresented: Binding(get: { store.message != nil }, set: {
                if !$0 { store.message = nil }
            })) {
                Button("好") { store.message = nil }
            } message: {
                Text(store.message ?? "")
            }
        }
    }

    private var ledgerList: some View {
        List {
            Section {
                VStack(spacing: 15) {
                    monthNavigation
                    monthSummary
                    if let photoProgress {
                        ProgressView(photoProgress)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
                .listRowInsets(EdgeInsets(top: 9, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
            }
            Section("支出分類百分比") {
                SpendingChart(transactions: monthTransactions, selection: $filter)
            }
            transactionSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { LedgerBackdrop() }
    }

    private var transactionSection: some View {
        let transactions = visible
        return Section(filter ?? "交易明細") {
            if transactions.isEmpty {
                Label("目前沒有交易", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
            ForEach(transactions) { transaction in
                Button {
                    editing = transaction
                } label: {
                    LabeledContent {
                        Text(transaction.amount.formatted())
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(transaction.amount < 0 ? LedgerAppearance.accent : .primary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.description).foregroundStyle(.primary)
                            Text([transaction.day, transaction.category, transaction.merchant]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
            }
            .onDelete { indexes in
                store.delete(Set(indexes.map { transactions[$0].id }))
            }
        }
    }

    private func selectBillPhoto(_ mode: BillPhotoMode) {
        guard !processingPhoto else { return }
        if mode == .gemini && cloud.geminiKey == nil {
            showCloud = true
            return
        }
        billPhotoMode = mode
        photos = []
        showingPhotoPicker = true
    }

    private func processBillPhotos(_ items: [PhotosPickerItem], mode: BillPhotoMode) async {
        let key = cloud.geminiKey
        let model = cloud.geminiModel
        let categories = store.categories
        let rules = store.book.settings.keyword_rules
        let today = Transaction.dateFormatter.string(from: Date())
        if mode == .gemini && key == nil {
            photos = []
            showCloud = true
            return
        }
        defer {
            photoProgress = nil
            photos = []
        }
        var transactions: [Transaction] = []
        var recognizedPages: [[String]] = []
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            let process = mode == .gemini ? "Gemini 正在解析" : "正在辨識文字"
            photoProgress = "\(process)（\(index + 1)/\(items.count)）"
            do {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LedgerError.invalid("無法讀取照片，請確認照片已下載。")
                }
                if let key, mode == .gemini {
                    let parsed = try await GeminiBillParser.parse(
                        jpeg: try billJPEG(from: data), key: key, model: model, today: today,
                        categories: categories, rules: rules)
                    guard !parsed.isEmpty else {
                        throw LedgerError.invalid("Gemini 沒有從這張照片找到交易。")
                    }
                    transactions.append(contentsOf: parsed)
                } else {
                    let recognized = try await recognizeBillText(data)
                    guard !recognized.isEmpty else {
                        throw LedgerError.invalid("照片中找不到可辨識的文字。")
                    }
                    recognizedPages.append(recognized)
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures.append("第 \(index + 1) 張：\(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled else { return }
        if !transactions.isEmpty {
            billReview = BillReview(items: transactions, failures: failures)
        } else if let first = recognizedPages.first?.first {
            var draft = Transaction()
            draft.description = recognizedPages.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
            draft.merchant = first
            photoDraftFailures = failures
            editing = draft
        } else {
            store.message = failures.joined(separator: "\n")
        }
    }

    private func recognizeBillText(_ data: Data) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(data: data).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private func billJPEG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.83) else {
            throw LedgerError.invalid("無法轉換帳單照片。")
        }
        return jpeg
    }
}

private enum BillPhotoMode {
    case text, gemini
}

private struct BillReview: Identifiable {
    let id = UUID()
    let items: [Transaction]
    let failures: [String]
}

private struct PhotoImportFailures: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            Section("未完成的照片") {
                ForEach(messages, id: \.self) { message in
                    Text(message).font(.footnote)
                }
            }
        }
    }
}

private struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    let photoFailures: [String]
    @State private var transaction: Transaction
    @State private var date: Date
    @State private var amountText: String

    init(transaction: Transaction, store: LedgerStore, photoFailures: [String]) {
        self.store = store
        self.photoFailures = photoFailures
        _transaction = State(initialValue: transaction)
        _date = State(initialValue: Transaction.dateFormatter.date(from: transaction.day) ?? Date())
        _amountText = State(initialValue: transaction.amount == 0 ? "" : String(describing: transaction.amount))
    }

    private var amount: Decimal? { Decimal(string: amountText, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
                PhotoImportFailures(messages: photoFailures)
                DatePicker("交易日期", selection: $date, displayedComponents: .date)
                TextField("金額", text: $amountText).keyboardType(.numbersAndPunctuation)
                TextField("商家", text: $transaction.merchant)
                TextField("交易內容", text: $transaction.description, axis: .vertical)
                Picker("分類", selection: $transaction.category) {
                    ForEach(store.categories, id: \.self) { Text($0).tag($0) }
                }
            }
            .navigationTitle("交易")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        guard let amount else { return }
                        transaction.amount = amount
                        transaction.day = Transaction.dateFormatter.string(from: date)
                        store.save(transaction)
                        dismiss()
                    }
                    .disabled(amount == nil || amount == 0 || transaction.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct LedgerSettings: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @State private var category = ""
    @State private var keyword = ""
    @State private var ruleCategory = "待分類"

    var body: some View {
        NavigationStack {
            Form {
                Section("分類") {
                    ForEach(store.categories, id: \.self) { Text($0) }
                    TextField("新增分類", text: $category)
                    Button("加入分類") {
                        store.addCategory(category)
                        category = ""
                    }.disabled(category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("分類關鍵字") {
                    ForEach(Array(store.book.settings.keyword_rules.enumerated()), id: \.offset) { entry in
                        LabeledContent(entry.element.keyword, value: entry.element.category)
                    }
                    .onDelete { store.deleteRules($0) }
                    TextField("關鍵字", text: $keyword)
                    Picker("套用分類", selection: $ruleCategory) {
                        ForEach(store.categories, id: \.self) { Text($0).tag($0) }
                    }
                    Button("加入規則") {
                        store.addRule(keyword: keyword, category: ruleCategory)
                        keyword = ""
                    }.disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("記帳設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
