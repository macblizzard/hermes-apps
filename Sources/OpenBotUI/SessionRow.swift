import Foundation
import SwiftUI
import HermesKit

/// One session in a list: avatar, title, one line of preview, relative time, state.
///
/// The row is deliberately not a `Button`: a sidebar row, a `List` row and a
/// `NavigationLink` label all need the same pixels but different interaction. Wrap it —
/// `Button { open(session) } label: { SessionRow(session) }` — and the hover, selection
/// and state rendering still come from here.
public struct SessionRow: View {
    private let title: String
    private let preview: String?
    private let updatedAt: Date?
    private let presence: Avatar.Presence
    private let isUnread: Bool
    private let isSelected: Bool
    private let showsProgress: Bool
    private let now: Date

    public init(title: String,
                preview: String? = nil,
                updatedAt: Date? = nil,
                presence: Avatar.Presence = .idle,
                isUnread: Bool = false,
                isSelected: Bool = false,
                showsProgress: Bool = false,
                now: Date = Date()) {
        self.title = title
        self.preview = preview
        self.updatedAt = updatedAt
        self.presence = presence
        self.isUnread = isUnread
        self.isSelected = isSelected
        self.showsProgress = showsProgress
        self.now = now
    }

    /// The wire model's own initialiser. `needsYou` is not on `SessionSummary` — a
    /// pending approval is the store's business, not the session record's — so the screen
    /// passes it in when it knows of one.
    public init(_ session: SessionSummary,
                needsYou: Bool = false,
                isUnread: Bool = false,
                isSelected: Bool = false,
                now: Date = Date()) {
        self.init(title: session.title,
                  preview: session.preview,
                  updatedAt: session.updatedAt,
                  presence: needsYou ? .needsYou : (session.running ? .running : .idle),
                  isUnread: isUnread,
                  isSelected: isSelected,
                  showsProgress: session.running,
                  now: now)
    }

    private var time: String? {
        guard let updatedAt else { return nil }
        return RelativeTime.short(updatedAt, now: now)
    }

    private var restFill: Color {
        isSelected ? Tokens.controlActive : .clear
    }

    private var hoverColor: Color {
        isSelected ? Tokens.controlActive : Tokens.controlHover
    }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macOSBody
            #else
            iOSBody
            #endif

            if showsProgress {
                IndeterminateProgressBar()
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.bottom, 5)
            }
        }
        .hoverFill(rest: restFill, hover: hoverColor, radius: Tokens.radiusControl)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Platform density

    #if os(macOS)
    /// 13/500 title, 11 pt preview, one line, 26 pt avatar — the desktop sidebar row.
    private var macOSBody: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(title, size: .small, presence: presence)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(TypeScale.font(TypeScale.sessionTitle,
                                             weight: isUnread ? .semibold : .medium))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isUnread {
                        Circle()
                            .fill(Tokens.accent)
                            .frame(width: 5, height: 5)
                    }

                    Spacer(minLength: 4)

                    if let time {
                        Text(time)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textDim)
                            .fixedSize()
                    }
                }

                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(TypeScale.font(TypeScale.sessionPreview))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, showsProgress ? 6 : 7)
    }
    #else
    /// 15/600 title, 13 pt preview over two lines, 44 pt avatar — the phone row.
    private var iOSBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(title, size: .large, presence: presence)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(TypeScale.font(TypeScale.sessionTitle, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isUnread {
                        Circle()
                            .fill(Tokens.accent)
                            .frame(width: 6, height: 6)
                    }

                    Spacer(minLength: 4)

                    if let time {
                        Text(time)
                            .font(TypeScale.font(TypeScale.label))
                            .foregroundStyle(Tokens.textMuted)
                            .fixedSize()
                    }
                }

                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(TypeScale.font(TypeScale.sessionPreview))
                        .foregroundStyle(Tokens.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if presence != .idle {
                    StatusChip(presence == .needsYou ? "needs you" : "running",
                               tone: presence == .needsYou ? .warning : .success,
                               showsDot: true,
                               size: .small)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    #endif

    private var accessibilityText: String {
        var parts = [title]
        switch presence {
        case .running: parts.append("running")
        case .needsYou: parts.append("needs you")
        case .idle: break
        }
        if isUnread { parts.append("unread") }
        if let preview, !preview.isEmpty { parts.append(preview) }
        if let time { parts.append(time) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("Session rows") {
    VStack(spacing: 2) {
        SessionRow(title: "Fix the gateway handshake",
                   preview: "Reading tui_gateway/ws.py — the ticket is only valid once",
                   updatedAt: Date().addingTimeInterval(-120),
                   presence: .running,
                   isUnread: true,
                   isSelected: true)
        SessionRow(title: "Nightly homelab audit",
                   preview: "12 findings, 2 need attention",
                   updatedAt: Date().addingTimeInterval(-4 * 3_600),
                   presence: .needsYou)
        SessionRow(title: "Write the paper on sparse routing",
                   preview: "Draft is in Obsidian under research/",
                   updatedAt: Date().addingTimeInterval(-3 * 86_400))
    }
    .padding(8)
    .frame(width: 300)
    .background(Tokens.sidebar)
    .preferredColorScheme(.dark)
}
