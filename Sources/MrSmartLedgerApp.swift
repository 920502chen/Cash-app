import SafariServices
import SwiftUI

@main
struct MrSmartLedgerApp: App {
    var body: some Scene {
        WindowGroup {
            LedgerHome()
        }
    }
}

private struct LedgerHome: View {
    private let ledgerURL = URL(string: "https://mrsmartledger.streamlit.app/")!
    @State private var showingLedger = true

    var body: some View {
        VStack(spacing: 20) {
            Label("智慧記帳", systemImage: "book.closed")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Button("開啟記帳") {
                showingLedger = true
            }
            .buttonStyle(.borderedProminent)
            Link("使用瀏覽器開啟", destination: ledgerURL)
        }
        .padding()
        .fullScreenCover(isPresented: $showingLedger) {
            LedgerBrowser(url: ledgerURL)
                .ignoresSafeArea()
        }
    }
}

private struct LedgerBrowser: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            dismiss()
        }
    }
}
