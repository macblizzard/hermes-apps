import SwiftUI
import HermesKit

/// A profile default is distinct from any live session override. The caller supplies
/// profile-scoped gateway operations; this screen never creates or replaces a chat.
struct BotModelSettingsScreen: View {
    enum SaveResult {
        case saved
        case confirmationRequired(String)
    }

    let bot: Bot
    let load: (String) async throws -> ModelCatalog
    let save: (String, ModelOption, Bool) async throws -> SaveResult

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if let catalog {
                    if let current = catalog.current {
                        Section("Profile default") {
                            Text("\(current.label) · \(current.provider)")
                        }
                    }
                    Section {
                        ForEach(catalog.options, id: \.self) { option in
                            Button {
                                Task { await select(option, confirmed: false) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(option.label)
                                        Text(option.provider).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if option.id == catalog.current?.id && option.provider == catalog.current?.provider {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }.disabled(busy)
                        }
                    } header: {
                        Text("Models")
                    } footer: {
                        Text("Changes this bot's profile default. An existing conversation may keep a session-specific model override.")
                    }
                } else if error == nil {
                    ProgressView("Loading models…")
                }
            }
            .navigationTitle("\(bot.displayName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }
            .alert("Confirm model", isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            )) {
                Button("Cancel", role: .cancel) { pending = nil }
                Button("Confirm") {
                    guard let option = pending else { return }
                    pending = nil
                    Task { await select(option, confirmed: true) }
                }
            } message: { Text(confirmation) }
        }
    }

    private func refresh() async {
        do { catalog = try await load(bot.id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ option: ModelOption, confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await save(bot.id, option, confirmed) {
            case .saved: await refresh()
            case .confirmationRequired(let message):
                confirmation = message
                pending = option
            }
        } catch { self.error = error.localizedDescription }
    }
}
