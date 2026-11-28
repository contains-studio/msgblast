import AppKit
import SwiftUI
import msgblastCore

/// Settings → CLI tools → ChatGPT plan: Connect with ChatGPT for the msgblast agent.
struct ChatGPTConnectionView: View {
    @ObservedObject var connection: ChatGPTConnection
    private static let icon = Bundle.main.url(forResource: "chatgpt.jpg", withExtension: nil, subdirectory: "WebAgentIcons").flatMap(NSImage.init(contentsOf:))

    private var detail: String {
        if connection.cannotStore { return ChatGPTSignInError.storageUnavailable.errorDescription ?? "" }
        if connection.signingIn { return connection.demo ? "Signing in (simulated)…" : "Finish signing in in your browser." }
        guard let status = connection.status else { return "Lets the msgblast agent use your ChatGPT plan." }
        let account = status.email ?? "your ChatGPT account"
        return status.sharesPlan ? "Connected as \(account)" : "Plan usage is off for \(account)."
    }

    @ViewBuilder private var action: some View {
        if connection.signingIn {
            Button("Cancel") { connection.cancel() }.disabled(connection.demo)
        } else if connection.status?.sharesPlan == true {
            Button("Disconnect") { connection.disconnect() }
        } else {
            Button("Continue with ChatGPT") { connection.connect() }
                .disabled(connection.cannotStore).accessibilityIdentifier("chatgpt-plan-connect")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let icon = Self.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.demo ? "ChatGPT plan (simulated)" : "ChatGPT plan").fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("chatgpt-plan-status")
                }
                Spacer(minLength: 12)
                action
            }.padding(.vertical, 10)
            if connection.status?.sharesPlan == true {
                Text("Set a limit for msgblast in ChatGPT Settings. On Plus, the five-hour limit is shared with ChatGPT and your other apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Manage usage", destination: ChatGPTTokenSharing.usageSettings).font(.caption)
            }
            if let message = connection.message {
                Text(message).font(.caption).foregroundStyle(.red)
                if connection.offerNewAccount { Button("Use Another Account") { connection.connect(newAccount: true) }.controlSize(.small) }
            }
        }
        .task { await connection.load() }
        .alert("You’re using your ChatGPT plan", isPresented: $connection.welcome) {
            Button("Got it") {}
            Button("Manage usage") { NSWorkspace.shared.open(ChatGPTTokenSharing.usageSettings) }
        } message: {
            Text("Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
        }
    }
}
