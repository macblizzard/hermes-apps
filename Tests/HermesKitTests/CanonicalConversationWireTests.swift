import Foundation
import XCTest
@testable import HermesKit

/// The client calls behind the bot's shared conversation identity.
///
/// These are wire-shape tests, not UI tests: the exact-title lookup must carry the bot, hidden
/// rows must be included, `session.most_recent` must be profile-scoped (it stays a read-only
/// capability, never an identity fallback), and the title write must use the runtime id the
/// gateway attached (a stored id is refused there).
final class CanonicalConversationWireTests: XCTestCase {

    private func connectedClient(_ fake: FakeGateway) async throws -> GatewayClient {
        let client = GatewayClient(makeTransport: { fake.bridge() },
                                   timeouts: .testing,
                                   reconnect: .disabled)
        try await client.connect()
        return client
    }

    func testExactTitleLookupIsProfileScopedAndIncludesHiddenRows() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("stored-1"), "title": .string("First")]),
            .object(["id": .string("stored-2"), "title": .string("Bot Chat")]),
        ])]), for: "session.list")
        let client = try await connectedClient(fake)

        let found = try await client.sessionID(titled: "Bot Chat", profile: "cody")

        XCTAssertEqual(found, "stored-2")
        let params = await fake.params(method: "session.list")
        XCTAssertEqual(params?["title"]?.stringValue, "Bot Chat")
        XCTAssertEqual(params?["profile"]?.stringValue, "cody")
        XCTAssertEqual(params?["include_hidden"]?.boolValue, true)
    }

    func testExactTitleLookupDoesNotAcceptAnUnrelatedRow() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["sessions": .array([
            .object(["id": .string("stored-1"), "title": .string("Not the canonical title")]),
        ])]), for: "session.list")
        let client = try await connectedClient(fake)

        let found = try await client.sessionID(titled: "Bot Chat", profile: "cody")

        XCTAssertNil(found, "a host that ignored `title` must not be mistaken for a match")
    }

    func testMostRecentCarriesTheProfileAndParsesTheStoredId() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["session_id": .string("stored-9"), "title": .string("Thread")]),
                             for: "session.most_recent")
        let client = try await connectedClient(fake)

        let found = try await client.mostRecentSession(profile: "atlas")

        XCTAssertEqual(found, "stored-9")
        let params = await fake.params(method: "session.most_recent")
        XCTAssertEqual(params?["profile"]?.stringValue, "atlas")
    }

    func testMostRecentNullMeansNoConversationNotAFailure() async throws {
        let fake = FakeGateway()
        await fake.setResult(.object(["session_id": .null]), for: "session.most_recent")
        let client = try await connectedClient(fake)

        let found = try await client.mostRecentSession(profile: "cody")

        XCTAssertNil(found)
    }

    func testTitleWriteUsesTheAttachedRuntimeId() async throws {
        let fake = FakeGateway()
        let client = try await connectedClient(fake)
        _ = try await client.resumeSession("stored-1", profile: "cody")

        try await client.setSessionTitle("stored-1", title: "Bot Chat")

        let params = await fake.params(method: "session.title")
        XCTAssertEqual(params?["session_id"]?.stringValue, "rt-1",
                       "session.title addresses the live runtime id, not the stored id")
        XCTAssertEqual(params?["title"]?.stringValue, "Bot Chat")
    }

    func testCreateCarriesProfileAndTitleAndReturnsTheStoredId() async throws {
        let fake = FakeGateway()
        let client = try await connectedClient(fake)

        let created = try await client.createSession(model: nil, provider: nil,
                                                      profile: "scribe", title: "Bot Chat")

        XCTAssertEqual(created, "stored-new")
        let params = await fake.params(method: "session.create")
        XCTAssertEqual(params?["profile"]?.stringValue, "scribe")
        XCTAssertEqual(params?["title"]?.stringValue, "Bot Chat")
    }
}
