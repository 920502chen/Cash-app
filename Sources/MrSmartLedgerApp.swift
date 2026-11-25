import PhotosUI
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

@main
struct MrSmartLedgerApp: App {
    var body: some Scene {
        WindowGroup { LedgerView() }
    }
}

struct LedgerView: View {
    @StateObject private var store = LedgerStore()
    @StateObject private var cloud = LedgerCloud()
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: String?
    @State private var editing: Transaction?
    @State private var importing = false
    @State private var exporting = false
    @State private var photo: PhotosPickerItem?
    @State private var showSettings = false
    @State private var showCloud = false
    @State private var billPhoto: PhotosPickerItem?
    @State private var parsingBill = false
    @State private var billReview: BillReview?

    private var visible: [Transaction] {
        store.book.transactions.filter { filter == nil || $0.category == filter }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                if parsingBill {
                    ProgressView("Gemini 正在解析帳單…")
                }
                Section("支出分類") {
                    SpendingChart(transactions: store.book.transactions, selection: $filter)
                }
                Section(filter ?? "交易明細") {
                    if visible.isEmpty {
                        Text("目前沒有交易").foregroundStyle(.secondary)
                    }
                    ForEach(visible) { transaction in
                        Button {
                            editing = transaction
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transaction.description).foregroundStyle(.primary)
                                    Text([transaction.day, transaction.category, transaction.merchant]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(transaction.amount.formatted()).monospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .onDelete { indexes in
                        store.delete(Set(indexes.map { visible[$0].id }))
                    }
                }
            }
            .navigationTitle("智慧記帳")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button { showSettings = true } label: { Label("分類與關鍵字", systemImage: "tag") }
                        Button { showCloud = true } label: { Label("Google Drive 與 Gemini", systemImage: "icloud") }
                        PhotosPicker(selection: $billPhoto, matching: .images) {
                            Label("用 Gemini 解析帳單", systemImage: "sparkles")
                        }.disabled(parsingBill)
                        Button { importing = true } label: { Label("匯入 CSV 或 JSON", systemImage: "square.and.arrow.down") }
                        Button { exporting = true } label: { Label("匯出交易 CSV", systemImage: "square.and.arrow.up") }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("從帳單照片辨識文字", systemImage: "text.viewfinder")
                        }
                    } label: {
                        Label("工具", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { editing = Transaction() } label: {
                        Label("新增交易", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { transaction in
                TransactionEditor(transaction: transaction, store: store)
            }
            .sheet(isPresented: $showSettings) { LedgerSettings(store: store) }
            .sheet(isPresented: $showCloud) { CloudSettings(cloud: cloud, store: store) }
            .sheet(item: $billReview) { review in
                NavigationStack {
                    List(review.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            LabeledContent(item.description, value: item.amount.formatted())
                            Text([item.day, item.category, item.merchant].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
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
            .task(id: photo) {
                guard let photo else { return }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        throw LedgerError.invalid("無法讀取圖片。")
                    }
                    let recognized = try await Task.detached(priority: .userInitiated) {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.automaticallyDetectsLanguage = true
                        try VNImageRequestHandler(data: data).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    }.value
                    guard !Task.isCancelled else { return }
                    guard !recognized.isEmpty else { throw LedgerError.invalid("照片中找不到可辨識的文字。") }
                    var draft = Transaction()
                    draft.description = recognized.joined(separator: "\n")
                    draft.merchant = recognized[0]
                    editing = draft
                } catch {
                    if !Task.isCancelled { store.message = error.localizedDescription }
                }
                if !Task.isCancelled { self.photo = nil }
            }
            .task { await cloud.backup(store) }
            .onChange(of: store.revision) { _ in Task { await cloud.backup(store) } }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await cloud.backup(store) } }
            }
            .task(id: billPhoto) {
                guard let billPhoto else { return }
                defer {
                    if !Task.isCancelled {
                        parsingBill = false
                        self.billPhoto = nil
                    }
                }
                guard let key = cloud.geminiKey else {
                    showCloud = true
                    return
                }
                parsingBill = true
                do {
                    guard let data = try await billPhoto.loadTransferable(type: Data.self),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2400
                          ] as CFDictionary),
                          let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.83) else {
                        throw LedgerError.invalid("無法讀取帳單圖片。")
                    }
                    let transactions = try await GeminiBillParser.parse(
                        jpeg: jpeg, key: key, model: cloud.geminiModel,
                        today: Transaction.dateFormatter.string(from: Date()),
                        categories: store.categories, rules: store.book.settings.keyword_rules)
                    guard !Task.isCancelled else { return }
                    guard !transactions.isEmpty else {
                        throw LedgerError.invalid("Gemini 沒有從這張照片找到交易。")
                    }
                    billReview = BillReview(items: transactions)
                } catch {
                    if !Task.isCancelled { store.message = error.localizedDescription }
                }
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
}

private struct BillReview: Identifiable {
    let id = UUID()
    let items: [Transaction]
}

private struct TransactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LedgerStore
    @State private var transaction: Transaction
    @State private var date: Date
    @State private var amountText: String

    init(transaction: Transaction, store: LedgerStore) {
        self.store = store
        _transaction = State(initialValue: transaction)
        _date = State(initialValue: Transaction.dateFormatter.date(from: transaction.day) ?? Date())
        _amountText = State(initialValue: transaction.amount == 0 ? "" : String(describing: transaction.amount))
    }

    private var amount: Decimal? { Decimal(string: amountText, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
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
