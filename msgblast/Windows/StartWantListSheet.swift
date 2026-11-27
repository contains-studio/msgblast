import SwiftUI
#if os(iOS)
import msgblastMobileKit
#else
import msgblastCore
#endif

struct StartWantListSheet: View {
    let start: (String, WantFormat) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var format = WantFormat.shopping
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $title)
                Picker("List type", selection: $format) {
                    Text("Shopping").tag(WantFormat.shopping)
                    Text("Tasks").tag(WantFormat.tasks)
                    Text("Research").tag(WantFormat.research)
                }
                Text("Your list starts private. Choose Keep this list within 24 hours to save it.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error { Text(error) }
            }
            .formStyle(.grouped)
            .navigationTitle("Start a list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create list") { Task { await create() } }
                        .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        #if os(macOS)
        .frame(minWidth: 370, minHeight: 260)
        #endif
    }

    private func create() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await start(title.trimmingCharacters(in: .whitespacesAndNewlines), format); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
