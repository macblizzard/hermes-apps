import Foundation
import HermesKit

/// One caption + its rows in the sidebar.
struct SessionSection: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionSummary]
}

/// How the session list is cut into groups.
///
/// Run state is the first cut because it is the only group that changes while you are
/// looking at it: a turn that is running belongs at the top, above "today", whatever its
/// timestamp says. Everything else is grouped by recency — the cut OpenBot uses, and the one
/// that needs no extra state to stay right.
enum SessionGrouping {

    static func sections(sessions: [SessionSummary],
                         running: Set<SessionID>,
                         needsYou: SessionID?,
                         query: String,
                         now: Date = Date(),
                         calendar: Calendar = .current) -> [SessionSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = needle.isEmpty ? sessions : sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(needle)
                || (session.preview?.localizedCaseInsensitiveContains(needle) ?? false)
        }

        var runningRows: [SessionSummary] = []
        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var earlier: [SessionSummary] = []

        for session in filtered {
            let isRunning = session.running || running.contains(session.id)
            if isRunning {
                runningRows.append(session)
                continue
            }
            guard let updated = session.updatedAt else {
                earlier.append(session)
                continue
            }
            if calendar.isDate(updated, inSameDayAs: now) {
                today.append(session)
            } else if calendar.isDateInYesterday(updated) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        // Newest first inside a group; a session with no timestamp sorts last.
        let byRecency: (SessionSummary, SessionSummary) -> Bool = { lhs, rhs in
            (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }

        var sections: [SessionSection] = []
        if !runningRows.isEmpty {
            sections.append(SessionSection(id: "running", title: "RUNNING", sessions: runningRows.sorted(by: byRecency)))
        }
        if !today.isEmpty {
            sections.append(SessionSection(id: "today", title: "TODAY", sessions: today.sorted(by: byRecency)))
        }
        if !yesterday.isEmpty {
            sections.append(SessionSection(id: "yesterday", title: "YESTERDAY", sessions: yesterday.sorted(by: byRecency)))
        }
        if !earlier.isEmpty {
            sections.append(SessionSection(id: "earlier", title: "EARLIER", sessions: earlier.sorted(by: byRecency)))
        }
        return sections
    }

    /// A session needs the user when it is the open one and the agent is blocked on an
    /// answer. `ServerRequest` carries no session id we can trust across hosts, so the
    /// pending queue is attributed to the open session — which is the one the gateway
    /// blocks.
    static func needsYou(selected: SessionID?, hasPendingRequests: Bool) -> SessionID? {
        guard hasPendingRequests, let selected else { return nil }
        return selected
    }
}
