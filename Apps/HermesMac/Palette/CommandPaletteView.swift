import HermesAppKit
import OpenBotUI
import SwiftUI

/// ⌘K. A filter over the live command list, nothing more.
///
/// The catalogue comes from `WorkspaceStore.commands`, so a verb that cannot run right now
/// (interrupt, with no turn in flight) is listed disabled with its reason instead of
/// vanishing — the palette doubles as a map of what this window can do.
struct CommandPaletteView: View {
    @ObservedObject var store: WorkspaceStore

    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [WorkspaceCommand] {
        store.commands.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Hairline()
            resultsList
            Hairline()
            footer
        }
        .frame(width: 560, height: 440)
        .background(Tokens.sheet)
        .onAppear { focused = true }
        .preferredColorScheme(.dark)
    }

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.textDim)

            TextField("",
                      text: $query,
                      prompt: Text("Run a command…").foregroundColor(Tokens.textPlaceholder))
                .textFieldStyle(.plain)
                .font(TypeScale.font(Tokens.textXL))
                .foregroundStyle(Tokens.textPrimary)
                .tint(Tokens.accent)
                .focused($focused)
                .onSubmit { runFirst() }
                .accessibilityLabel("Search commands")

            Text("esc")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.textDim)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                        .fill(Tokens.control)
                )
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Text("No command matches “\(query)”.")
                    .font(TypeScale.font(Tokens.textMD))
                    .foregroundStyle(Tokens.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(results) { command in
                        row(command)
                    }
                }
                .padding(6)
            }
        }
    }

    private func row(_ command: WorkspaceCommand) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(command.isEnabled ? Tokens.textSecondary : Tokens.textDim)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.radiusSmall, style: .continuous)
                            .fill(Tokens.control)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(TypeScale.font(Tokens.textMD, weight: .medium))
                        .foregroundStyle(command.isEnabled ? Tokens.textPrimary : Tokens.textDim)
                        .lineLimit(1)

                    Text(command.subtitle)
                        .font(TypeScale.font(TypeScale.label))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(command.group.rawValue.uppercased())
                    .font(TypeScale.font(9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Tokens.textDim)

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Tokens.textDim)
                        .frame(minWidth: 26, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(rest: .clear, hover: Tokens.control, radius: Tokens.radiusControl)
        .disabled(!command.isEnabled)
        .accessibilityLabel("\(command.title). \(command.subtitle)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(results.count == 1 ? "1 command" : "\(results.count) commands")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)

            Spacer(minLength: 0)

            Text("⏎ run · ⇧⌘K closes")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Actions

    private func runFirst() {
        guard let first = results.first(where: { $0.isEnabled }) else { return }
        run(first)
    }

    private func run(_ command: WorkspaceCommand) {
        guard command.isEnabled else { return }
        store.closePalette()
        command.run()
    }
}

// MARK: - Previews

private struct CommandPalettePreview: View {
    @StateObject private var store = PreviewWorkspace.store()

    var body: some View {
        CommandPaletteView(store: store)
            .padding(24)
            .background(Tokens.canvas)
            .task { await store.attachPreviewHost() }
            .preferredColorScheme(.dark)
    }
}

#Preview("Command palette") {
    CommandPalettePreview()
}
