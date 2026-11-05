import Foundation
import XCTest
@testable import HermesKit

/// Multi-bot behaviour: one gateway, many Hermes profiles.
///
/// The measured facts these tests pin (deployed host, over TLS):
/// - `profiles.list {}` answers `{"profiles":[…], "bot_mode_protocol":…, "install_id":…}`;
/// - `session.list` needs `include_hidden: true` or a normal profile answers 0 rows
///   (`cody` 0 → 1), and takes `profile: "<name>"` to scope to one bot
///   (`jason` 5, `anika` 2, `atlas` 1 at `limit: 5`).
///
/// The failure they exist to prevent is *mixing*: bot A's rows rendered under bot B's name.
final class BotDirectoryTests: XCTestCase {

    private func makeClient(_ fake: FakeGateway) -> GatewayClient {
        GatewayClient(makeTransport: { fake.bridge() }, timeouts: .testing, reconnect: .disabled)
    }

    /// A body shaped like the real one, including an entry the client must survive: one that names
    /// itself `profile` instead of `name`, one that is a bare string, and the host-level fields.
    private static let measuredProfiles: JSONValue = .object([
        "profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]),
            .object(["name": .string("anika")]),
            .object(["profile": .string("night-shift")]),
            .string("scribe"),
            .object(["unexpected": .string("ignored")]),
        ]),
        "bot_mode_protocol": .int(2),
        "install_id": .string("install-abc123"),
    ])

    // MARK: profiles.list

    func testListBotsDecodesTheDirectoryInTheHostsOrder() async throws {
        let fake = FakeGateway()
        await fake.setResult(Self.measuredProfiles, for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()

        XCTAssertEqual(bots.map(\.id), ["default", "anika", "night-shift", "scribe"],
                       "the id is the wire value `profile` takes; an entry without a name is skipped, not fatal")
        XCTAssertEqual(bots.map(\.name), ["default", "anika", "night-shift", "scribe"])
        XCTAssertEqual(bots.map(\.displayName), ["default", "anika", "night-shift", "scribe"],
                       "no label on the wire means the profile name is the label")

        let params = await fake.params(method: "profiles.list")
        XCTAssertEqual(params, JSONValue.object([:]), "profiles.list takes no parameters")

        XCTAssertEqual(bots.first?.avatarInitials, "D")
        XCTAssertEqual(bots[3].avatarInitials, "S")
    }

    func testBotFallsBackToTheProfileNameWhenNoDisplayLabelIsSent() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object([
            "profiles": .array([
                .object(["name": .string("cody"), "display_name": .string("Cody (work)")]),
                .object(["name": .string("atlas")]),
                .object(["name": .string("aria"), "label": .string("Aria")]),
            ]),
        ]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()
        XCTAssertEqual(bots.map(\.id), ["cody", "atlas", "aria"], "a label never leaks into the id")
        XCTAssertEqual(bots.map(\.displayName), ["Cody (work)", "atlas", "Aria"])
        XCTAssertEqual(bots[1].label, "atlas", "an unlabelled bot is still labelled by its name")
    }

    func testBotInitialsSurviveHyphenatedProfileNames() {
        XCTAssertEqual(Bot(id: "night-shift").avatarInitials, "NS")
        XCTAssertEqual(Bot(id: "cody").avatarInitials, "C")
        XCTAssertEqual(Bot(id: "c").avatarInitials, "C")
    }

    func testListBotsRejectsAReplyWithoutAProfilesArray() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["profiles": .string("nope")]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        do {
            _ = try await client.listBots()
            XCTFail("a reply with no profile list is malformed, not an empty directory")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .malformedResponse(method: "profiles.list"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testListBotsSurfacesAnOlderBackendsUnknownMethodInsteadOfNoBots() async throws {
        let fake = FakeGateway()
        await fake.setError(RPCError(code: -32601, message: "unknown method: profiles.list"),
                            for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        do {
            let bots = try await client.listBots()
            XCTFail("version skew must not look like 'this host has no bots': \(bots)")
        } catch let error as GatewayError {
            XCTAssertEqual(error.rpcError?.code, -32601)
            XCTAssertTrue(error.message.contains("profiles.list"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnEmptyDirectoryIsAnAnswerNotAnError() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["profiles": .array([])]), for: "profiles.list")
        let client = makeClient(fake)
        try await client.connect()

        let bots = try await client.listBots()
        XCTAssertTrue(bots.isEmpty)
    }

    // MARK: session.list scoping

    func testListSessionsSendsIncludeHiddenAndTheProfile() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 5, profile: "jason", includeHidden: true)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params, JSONValue.object([
            "limit": .int(5),
            "include_hidden": .bool(true),
            "profile": .string("jason"),
        ]), "the exact map: without include_hidden a normal profile answers 0 rows")
    }

    /// The default path is a bots surface too: a caller that forgets the new arguments must still
    /// get hidden sessions, because dropping them reads as "this bot is empty".
    func testTheSingleArgumentCallStillAsksForHiddenSessions() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 3)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["include_hidden"]?.boolValue, true)
        XCTAssertNil(params?["profile"], "no bot selected means the host's own default profile")
    }

    func testExplicitlyExcludingHiddenSessionsIsStillPossible() async throws {
        let fake = FakeGateway()
        let client = makeClient(fake)
        try await client.connect()

        _ = try await client.listSessions(limit: 3, profile: "cody", includeHidden: false)

        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["include_hidden"]?.boolValue, false)
    }

    /// The one that matters: two bots, two lists, and no way for one to answer the other.
    func testEachBotsListComesFromItsOwnProfileAndNeverMixes() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("jason-1"), "title": .string("cron audit")]),
            .object(["id": .string("jason-2"), "title": .string("tailnet")]),
        ])]), for: "session.list", whenParam: "profile", equals: "jason")
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("anika-1"), "title": .string("studio notes")]),
        ])]), for: "session.list", whenParam: "profile", equals: "anika")
        await fake.setResult(.object(["sessions": .array([])]),
                             for: "session.list", whenParam: "profile", equals: "atlas")

        let client = makeClient(fake)
        try await client.connect()

        let jason = try await client.listSessions(limit: 5, profile: "jason", includeHidden: true)
        let anika = try await client.listSessions(limit: 5, profile: "anika", includeHidden: true)
        let atlas = try await client.listSessions(limit: 5, profile: "atlas", includeHidden: true)

        XCTAssertEqual(jason.map(\.id), ["jason-1", "jason-2"])
        XCTAssertEqual(anika.map(\.id), ["anika-1"])
        XCTAssertTrue(atlas.isEmpty, "a bot with no sessions is empty, and that is not the same as unloaded")

        let sent = await fake.frames(method: "session.list").compactMap { $0["params"] }
        XCTAssertEqual(sent.map { $0["profile"]?.stringValue }, ["jason", "anika", "atlas"],
                       "each call carried the bot it was made for")
        XCTAssertEqual(sent.map { $0["include_hidden"]?.boolValue }, [true, true, true])
        XCTAssertFalse(jason.contains { $0.id.hasPrefix("anika") })
        XCTAssertFalse(anika.contains { $0.id.hasPrefix("jason") })
    }

    /// A slow answer for the bot the user just left must not overwrite the bot they are on.
    /// The protocol layer cannot enforce this — the model does, with a generation counter — but the
    /// client must at least never *reuse* one profile's body for another, which is the same bug one
    /// layer down.
    func testConcurrentListsForDifferentBotsResolveIndependently() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("jason-1"), "title": .string("cron audit")]),
        ])]), for: "session.list", whenParam: "profile", equals: "jason")
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("anika-1"), "title": .string("studio notes")]),
        ])]), for: "session.list", whenParam: "profile", equals: "anika")
        let client = makeClient(fake)
        try await client.connect()

        async let jason = client.listSessions(limit: 5, profile: "jason", includeHidden: true)
        async let anika = client.listSessions(limit: 5, profile: "anika", includeHidden: true)
        let (jasonRows, anikaRows) = try await (jason, anika)

        XCTAssertEqual(jasonRows.map(\.id), ["jason-1"])
        XCTAssertEqual(anikaRows.map(\.id), ["anika-1"])
    }
}
