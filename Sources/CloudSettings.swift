import CryptoKit
import SwiftUI

@MainActor
final class LedgerCloud: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var hasGeminiKey = false
    @AppStorage("gemini-model") var geminiModel = "gemini-3.5-flash-lite"
    @AppStorage("google-drive-backup-marker") private var marker = ""
    private let authorization = GoogleAuthorization()
    private var backupRequested = false

    init() {
        connected = authorization.saved != nil
        hasGeminiKey = LedgerSecrets.read("gemini-key") != nil
    }

    var geminiKey: String? {
        LedgerSecrets.read("gemini-key").flatMap { String(data: $0, encoding: .utf8) }
    }

    var clientID: String { authorization.saved?.clientID ?? "" }

    func setGeminiKey(_ key: String, model: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.range(of: "^gemini-[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw LedgerError.invalid("請輸入有效的 Gemini 模型名稱。")
        }
        if !key.isEmpty {
            try LedgerSecrets.write(Data(key.utf8), key: "gemini-key")
        }
        geminiModel = model
        hasGeminiKey = geminiKey != nil
    }

    func removeGeminiKey() throws {
        try LedgerSecrets.write(nil, key: "gemini-key")
        hasGeminiKey = false
    }

    func connect(clientID: String, store: LedgerStore) async {
        guard !busy, !connected else { return }
        busy = true
        defer { busy = false }
        do {
            try await authorization.signIn(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
            marker = ""
            connected = true
            try await synchronize(store, restore: false)
        } catch { status = error.localizedDescription }
        if backupRequested {
            busy = false
            await backup(store)
        }
    }

    func disconnect() {
        guard !busy else { return }
        do {
            try authorization.signOut()
            connected = false
            backupRequested = false
            marker = ""
            status = "已登出 Google。"
        } catch { status = error.localizedDescription }
    }

    func backup(_ store: LedgerStore) async {
        guard connected else { return }
        backupRequested = true
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while backupRequested {
            backupRequested = false
            do { try await synchronize(store, restore: false) }
            catch { status = error.localizedDescription }
        }
    }

    func restore(_ store: LedgerStore) async {
        guard connected, !busy else { return }
        busy = true
        do { try await synchronize(store, restore: true) }
        catch { status = error.localizedDescription }
        busy = false
        if backupRequested { await backup(store) }
    }

    private func synchronize(_ store: LedgerStore, restore: Bool) async throws {
        guard store.canSynchronize else {
            throw LedgerError.invalid("本機資料讀取失敗，已停止 Drive 同步以保留原本的備份。")
        }
        let drive = try await DriveBackup(token: authorization.token())
        let file = try await drive.file(named: DriveBackup.filename)
        if let file {
            let remoteMarker = file.id + ":" + (file.md5Checksum ?? "")
            if restore || (!store.hasLocalData && marker.isEmpty) {
                let revision = store.revision
                let backup = try JSONDecoder().decode(LedgerBook.self, from: await drive.download(file))
                guard store.revision == revision else {
                    throw LedgerError.invalid("下載期間修改了交易。請再按一次還原。")
                }
                let addedDueExpenses = try store.restore(backup)
                marker = remoteMarker
                if addedDueExpenses { backupRequested = true }
                status = "已從 Google Drive 還原。"
                return
            }
            guard marker == remoteMarker, file.md5Checksum != nil else {
                throw LedgerError.invalid("Drive 備份與此 iPhone 的資料不同。請先匯出本機 CSV，確認後再從 Drive 還原。")
            }
        } else {
            if restore || marker.isEmpty {
                let legacyTransactions = try await drive.file(named: "transactions_backup.csv")
                let legacySettings = try await drive.file(named: "settings_backup.json")
                if legacyTransactions != nil || legacySettings != nil {
                    guard restore || !store.hasLocalData else {
                        throw LedgerError.invalid("Drive 有舊版備份。請先匯出本機 CSV，再選擇是否還原。")
                    }
                    let revision = store.revision
                    var csv: Data?
                    var settings: Data?
                    if let legacyTransactions { csv = try await drive.download(legacyTransactions) }
                    if let legacySettings { settings = try await drive.download(legacySettings) }
                    let backup = try store.legacyBackup(csv: csv, settings: settings)
                    guard store.revision == revision else {
                        throw LedgerError.invalid("下載期間修改了交易。請再按一次還原。")
                    }
                    try store.restore(backup)
                    status = "已還原 Drive 上的舊版備份。"
                    backupRequested = true
                    // Continue to create the native backup before handling a subsequent change.
                } else if restore || !store.hasLocalData {
                    status = "這個 App 在 Drive 尚無可讀取的備份。"
                    return
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store.book)
        let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let file, file.md5Checksum == checksum {
            status = "Google Drive 備份已是最新。"
            return
        }
        let uploaded = try await drive.upload(data, updating: file)
        marker = uploaded.id + ":" + (uploaded.md5Checksum ?? checksum)
        status = "已備份至 Google Drive。"
    }
}

struct CloudSettings: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: LedgerCloud
    @ObservedObject var store: LedgerStore
    @State private var clientID = ""
    @State private var key = ""
    @State private var model = ""
    @State private var message: String?
    @State private var confirmRestore = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Google Drive") {
                    if cloud.connected {
                        Label("Google 已登入", systemImage: "checkmark.circle")
                        Button("立即備份") { Task { await cloud.backup(store) } }.disabled(cloud.busy)
                        Button("從 Drive 還原", role: .destructive) { confirmRestore = true }.disabled(cloud.busy)
                        Button("登出 Google") { cloud.disconnect() }.disabled(cloud.busy)
                    } else {
                        TextField("iOS OAuth Client ID", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("使用 Google 登入") {
                            Task { await cloud.connect(clientID: clientID, store: store) }
                        }
                        .disabled(cloud.busy || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if cloud.busy { ProgressView() }
                    if !cloud.status.isEmpty { Text(cloud.status).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    SecureField(cloud.hasGeminiKey ? "已設定，輸入以更換" : "Gemini API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("儲存 Gemini 設定") {
                        do {
                            try cloud.setGeminiKey(key, model: model)
                            key = ""
                            message = "Gemini 設定已儲存。"
                        } catch { message = error.localizedDescription }
                    }
                    if cloud.hasGeminiKey {
                        Button("移除 API Key", role: .destructive) {
                            do { try cloud.removeGeminiKey() }
                            catch { message = error.localizedDescription }
                        }
                    }
                } header: {
                    Text("Gemini 帳單解析")
                } footer: {
                    Text("選擇用 Gemini 解析時，帳單照片會傳給 Google。請先確認解析結果再匯入。")
                }
            }
            .navigationTitle("雲端與帳單解析")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { clientID = cloud.clientID; model = cloud.geminiModel }
            .confirmationDialog("用 Drive 備份取代此 iPhone 的交易和設定？", isPresented: $confirmRestore,
                                titleVisibility: .visible) {
                Button("還原並取代", role: .destructive) { Task { await cloud.restore(store) } }
            }
            .alert("智慧記帳", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
}
