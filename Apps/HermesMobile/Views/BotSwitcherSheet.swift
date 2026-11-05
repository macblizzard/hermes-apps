import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// The bot switcher, as a native sheet from the Chats nav bar.
///
/// A Hermes host is not one assistant: one gateway serves every profile, and each profile
/// is a bot with its own sessions. This sheet is a plain grouped `List` — avatar, name, the
/// profile id when it differs, and a checkmark on the one in use — so switching is a tap
/// rather than a menu the user has to read twice.
struct BotSwitcherSheet: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !app.isPaired {
                        unpairedRow
                    } else if model.bots.isEmpty {
                        emptyRow
                    } else {
                        ForEach(model.bots) { bot in
                            row(for: bot)
                        }
                    }
                } header: {
                    Text(app.isPaired ? "On \(app.hostLabel)" : "No host")
                } footer: {
                    if app.isPaired && !model.bots.isEmpty {
                        Text("A bot is a Hermes profile. Switching bots changes the session list and the conversation; the host stays connected.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Tokens.canvas)
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Tokens.accentText)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: Rows

    private func row(for bot: Bot) -> some View {
        let isSelected = bot.id == model.selectedBotID
        return Button {
            guard !isSelected else {
                dismiss()
                return
            }
            Haptics.selection()
            app.selectBot(bot.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Avatar(bot.displayName,
                       size: .large,
                       presence: presence(for: bot),
                       initials: bot.avatarInitials)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.displayName)
                        .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)

                    if isSelected {
                        Text("Current bot")
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textMuted)
                    } else if bot.id != bot.displayName {
                        Text(bot.id)
                            .font(Tokens.mono)
                            .foregroundStyle(Tokens.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isSelected && model.hasPendingRequests {
                    StatusChip("needs you", tone: .warning, showsDot: true, size: .small)
                }

                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.accentText)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(bot.displayName), current bot" : bot.displayName)
    }

    /// The live state is known for the bot whose sessions are loaded. Other bots stay
    /// `idle`: a dot on them would be a guess.
    // TODO(bot-model): per-bot attention when `Bot` carries a running/pending bit.
    private func presence(for bot: Bot) -> Avatar.Presence {
        guard bot.id == model.selectedBotID else { return .idle }
        if model.hasPendingRequests { return .needsYou }
        if model.isStreaming { return .running }
        return .idle
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyRow: some View {
        Group {
            if model.botsLoading {
                HStack(spacing: 10) {
                    SpinningRing(color: Tokens.textMuted, size: 12, lineWidth: 1.5)
                    Text("Looking for bots…")
                        .font(TypeScale.font(TypeScale.lg))
                        .foregroundStyle(Tokens.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let error = model.botsError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Tokens.textDim)

                    Text("Could not list this host's bots")
                        .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)

                    Text(error)
                        .font(TypeScale.font(TypeScale.lg))
                        .foregroundStyle(Tokens.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    OpenBotButton("Try again",
                                  systemImage: "arrow.clockwise",
                                  kind: .secondary,
                                  size: .small,
                                  corners: .capsule) {
                        Task { await app.loadBots() }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Tokens.textDim)

                    Text("No bots found on this host")
                        .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)

                    Text("The gateway answered, but listed no profiles. Check that this host has a Hermes bot to talk to, then look again.")
                        .font(TypeScale.font(TypeScale.lg))
                        .foregroundStyle(Tokens.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    OpenBotButton("Check again",
                                  systemImage: "arrow.clockwise",
                                  kind: .secondary,
                                  size: .small,
                                  corners: .capsule) {
                        Task { await app.loadBots() }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var unpairedRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.textDim)

            Text("Pair a host first")
                .font(TypeScale.font(TypeScale.xl, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)

            Text("Bots come from the host this phone is paired with. Scan the pairing code, then switch between its profiles here.")
                .font(TypeScale.font(TypeScale.lg))
                .foregroundStyle(Tokens.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Previews

#Preview("Bot switcher · several bots") {
    let environment = AppEnvironment.preview()
    BotSwitcherSheet(model: environment.model)
        .environmentObject(environment)
        .preferredColorScheme(.dark)
        .task { await environment.start() }
}

#Preview("Bot switcher · unpaired") {
    let environment = AppEnvironment.preview(paired: false)
    BotSwitcherSheet(model: environment.model)
        .environmentObject(environment)
        .preferredColorScheme(.dark)
}
