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
    /// True when this bot's conversation is the one currently open. A live conversation keeps the
    /// model it was created with — the gateway pins it per session and offers no way to change it.
    var conversationIsOpen: Bool = false
    let save: (String, ModelOption, Bool) async throws -> SaveResult
    /// Writes the human-readable description on the host (`profiles.configure`, description
    /// section). `nil` hides the editor entirely — a client that cannot write it must not offer it.
    var saveDescription: ((String, String) async throws -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var error: String?
    @State private var busy = false
    @State private var pending: ModelOption?
    @State private var confirmation = ""
    @State private var modelQuery = ""

    @State private var descriptionText: String
    @State private var savedDescription: String
    @State private var descriptionBusy = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false

    init(bot: Bot,
         load: @escaping (String) async throws -> ModelCatalog,
         conversationIsOpen: Bool = false,
         save: @escaping (String, ModelOption, Bool) async throws -> SaveResult,
         saveDescription: ((String, String) async throws -> Void)? = nil) {
        self.bot = bot
        self.load = load
        self.conversationIsOpen = conversationIsOpen
        self.save = save
        self.saveDescription = saveDescription
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                descriptionSection
                if let catalog {
                    if let current = catalog.current {
                        Section("Profile default") {
                            Text("\(current.label) · \(current.provider)")
                        }
                    }
                    Section {
                        ForEach(filteredOptions(catalog), id: \.self) { option in
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
                        Text(conversationIsOpen
                             ? "This becomes the bot's default. The conversation you have open keeps the model it started with; its history is left unchanged."
                             : "This becomes the bot's default for new conversations with this bot.")
                    }
                } else if error == nil {
                    ProgressView("Loading models…")
                }
            }
            .searchable(text: $modelQuery, prompt: "Search models")
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

    // MARK: Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let saveDescription {
            Section {
                TextField("What this bot does", text: $descriptionText, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.sentences)
                    .disabled(descriptionBusy)
                Button {
                    Task { await writeDescription(saveDescription) }
                } label: {
                    HStack {
                        if descriptionBusy { ProgressView().controlSize(.small) }
                        Text("Save description")
                    }
                }
                .disabled(descriptionBusy || trimmedDescription == savedDescription)
                if let descriptionError {
                    Text(descriptionError).font(.caption).foregroundStyle(.red)
                } else if descriptionSaved {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Description")
            } footer: {
                Text("Shown under this bot's name in the list. Stored on the host, so it follows the bot to every device.")
            }
        }
    }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeDescription(_ write: @escaping (String, String) async throws -> Void) async {
        descriptionBusy = true
        descriptionError = nil
        descriptionSaved = false
        defer { descriptionBusy = false }
        let text = trimmedDescription
        do {
            try await write(bot.id, text)
            descriptionText = text
            savedDescription = text
            descriptionSaved = true
        } catch {
            descriptionError = error.localizedDescription
        }
    }

    // MARK: Models

    /// The catalogue is long (dozens of entries across providers), so it is searchable.
    private func filteredOptions(_ catalog: ModelCatalog) -> [ModelOption] {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.options }
        return catalog.options.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.provider.localizedCaseInsensitiveContains(query)
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
