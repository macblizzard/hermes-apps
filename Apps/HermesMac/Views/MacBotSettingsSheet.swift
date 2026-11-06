import HermesAppKit
import HermesKit
import OpenBotUI
import SwiftUI

/// The Mac twin of the phone's `BotModelSettingsScreen`.
///
/// Same two jobs, same order and same rules: a description stored on the host, and the profile's
/// default model chosen from a searchable catalogue. The confirmation gate is the host's, not this
/// sheet's — a refusal comes back as `.confirmationRequired(message)` and is only retried with
/// `confirm: true` after the user reads that sentence.
///
/// A live conversation keeps the model it was created with; the host pins it per session, so the
/// footer says what changing the default does and does not do.
struct MacBotSettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkspaceStore
    let bot: Bot
    /// True when this bot's conversation is the one on screen (the copy differs, the write does not).
    let conversationIsOpen: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var showingIconPicker = false
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

    init(model: AppModel, store: WorkspaceStore, bot: Bot, conversationIsOpen: Bool) {
        self.model = model
        self.store = store
        self.bot = bot
        self.conversationIsOpen = conversationIsOpen
        _descriptionText = State(initialValue: bot.description ?? "")
        _savedDescription = State(initialValue: bot.description ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    if let error {
                        Text(error)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Choose bot icon…") { showingIconPicker = true }
                        .disabled(store.pairing == nil || store.pairing?.isTicketOnly == true)
                    if let iconError = store.botIconsError {
                        Text("Could not refresh bot icons: \(iconError)")
                            .font(TypeScale.font(TypeScale.caption)).foregroundStyle(Tokens.danger)
                    }
                    descriptionSection

                    if let catalog {
                        currentSection(catalog)
                        modelsSection(catalog)
                    } else if error == nil {
                        loadingRow
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 560)
        .background(Tokens.canvas)
        .task { await refresh() }
        .sheet(isPresented: $showingIconPicker) {
            MacBotIconPicker(bot: bot, store: store)
        }
        .alert("Confirm model", isPresented: pendingBinding) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Confirm") {
                guard let option = pending else { return }
                pending = nil
                Task { await select(option, confirmed: true) }
            }
        } message: {
            Text(confirmation)
        }
    }

    // MARK: Chrome

    private var titleBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.displayName)
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)

                Text(bot.id == bot.displayName ? "Hermes profile" : bot.id)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            OpenBotButton("Done", kind: .secondary, size: .small) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            SpinningRing(color: Tokens.textDim, size: 10, lineWidth: 1.4)
            Text("Loading models…")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
        }
    }

    // MARK: Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("DESCRIPTION")

            TextField("What this bot does",
                      text: $descriptionText,
                      prompt: Text("What this bot does").foregroundColor(Tokens.textPlaceholder),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .lineLimit(1...3)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(Tokens.borderStrong, lineWidth: 1)
                )
                .disabled(descriptionBusy)

            HStack(spacing: 8) {
                OpenBotButton("Save description", kind: .secondary, size: .small,
                              isDisabled: descriptionBusy || trimmedDescription == savedDescription) {
                    Task { await writeDescription() }
                }

                if descriptionBusy {
                    SpinningRing(color: Tokens.textDim, size: 9, lineWidth: 1.3)
                } else if let descriptionError {
                    Text(descriptionError)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .lineLimit(2)
                } else if descriptionSaved {
                    Text("Saved")
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                }
            }

            Text("Shown under this bot's name in the list. Stored on the host, so it follows the bot to every device.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedDescription: String {
        descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeDescription() async {
        descriptionBusy = true
        descriptionError = nil
        descriptionSaved = false
        defer { descriptionBusy = false }
        let text = trimmedDescription
        do {
            try await model.configureDescription(botID: bot.id, description: text)
            descriptionText = text
            savedDescription = text
            descriptionSaved = true
        } catch {
            descriptionError = error.localizedDescription
        }
    }

    // MARK: Models

    private func currentSection(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionCaption("PROFILE DEFAULT")
            Text(catalog.current.map { "\($0.label) · \($0.provider)" } ?? "The host named no model.")
                .font(TypeScale.font(Tokens.textSM, weight: .medium))
                .foregroundStyle(catalog.current == nil ? Tokens.textMuted : Tokens.textPrimary)
                .lineLimit(1)
        }
    }

    private func modelsSection(_ catalog: ModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionCaption("MODELS")

            MacSidebarSearchField(text: $modelQuery, prompt: "Search models")

            VStack(alignment: .leading, spacing: 1) {
                ForEach(filteredOptions(catalog), id: \.self) { option in
                    optionRow(option, current: catalog.current)
                }
            }

            Text(conversationIsOpen
                 ? "This becomes the bot's default. The conversation you have open keeps the model it started with; its history is left unchanged."
                 : "This becomes the bot's default for new conversations with this bot.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ option: ModelOption, current: ModelOption?) -> some View {
        let isCurrent = option.id == current?.id && option.provider == current?.provider
        return Button {
            Task { await select(option, confirmed: false) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(TypeScale.font(Tokens.textSM, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)

                    Text(option.provider)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.accentText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: isCurrent ? Tokens.controlActive : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous))
        .disabled(busy)
    }

    /// The catalogue is long (dozens of entries across providers), so it is searchable by label,
    /// id and provider — the same three fields the phone searches.
    private func filteredOptions(_ catalog: ModelCatalog) -> [ModelOption] {
        let query = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.options }
        return catalog.options.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.provider.localizedCaseInsensitiveContains(query)
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pending != nil },
                set: { presented in
                    if !presented { pending = nil }
                })
    }

    private func refresh() async {
        do {
            catalog = try await model.modelCatalog(for: bot.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Mirrors the phone: ask without consent first, show the host's sentence, and only repeat the
    /// write with `confirm: true` when the user says so.
    private func select(_ option: ModelOption, confirmed: Bool) async {
        busy = true
        defer { busy = false }
        do {
            switch try await model.configureModel(botID: bot.id,
                                                 model: option.id,
                                                 provider: option.provider,
                                                 confirm: confirmed) {
            case .applied:
                await refresh()
                if bot.id == model.selectedBotID {
                    await store.refreshOpenBotModelLabel()
                }
            case .confirmationRequired(let message):
                confirmation = message
                pending = option
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Previews

private struct MacBotSettingsSheetPreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        MacBotSettingsSheet(model: store.model,
                            store: store,
                            bot: Bot(id: "cody", displayName: "Cody",
                                     description: "Personal assistant on this host"),
                            conversationIsOpen: true)
            .preferredColorScheme(.dark)
    }
}

#Preview("Bot settings") {
    MacBotSettingsSheetPreview()
}
