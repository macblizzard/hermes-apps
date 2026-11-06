#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// Pending files belong to the bot whose composer picked them. A switch must hide them, not
/// upload them into the next profile, and returning to the first bot must bring them back.
@MainActor
final class AppModelAttachmentScopeTests: XCTestCase {

    private func makeModel() async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "s1")
        host.bots = [Bot(id: "alpha"), Bot(id: "beta")]
        let model = AppModel(client: host, hostName: "attachment-scope-\(UUID().uuidString)")
        await model.start()
        return (model, host)
    }

    func testPendingAttachmentsAreScopedToTheBotThatPickedThem() async {
        let (model, _) = await makeModel()
        await model.selectBot("alpha")
        model.addPendingAttachment(name: "alpha.pdf", data: Data("alpha".utf8), isImage: false)

        await model.selectBot("beta")

        XCTAssertTrue(model.pendingAttachments.isEmpty,
                      "alpha's file must not appear in beta's composer")
        XCTAssertTrue(model.draft.isEmpty)

        model.addPendingAttachment(name: "beta.png", data: Data("beta".utf8), isImage: true)
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["beta.png"])

        await model.selectBot("alpha")

        XCTAssertEqual(model.pendingAttachments.map(\.name), ["alpha.pdf"],
                       "returning to alpha restores only alpha's file")
        XCTAssertFalse(model.pendingAttachments.contains { $0.name == "beta.png" })
        await model.stop()
    }

    func testRemovingAnAttachmentOnlyTouchesTheSelectedBotsComposer() async throws {
        let (model, _) = await makeModel()
        await model.selectBot("alpha")
        model.addPendingAttachment(name: "alpha.pdf", data: Data("alpha".utf8), isImage: false)
        let alphaID = try XCTUnwrap(model.pendingAttachments.first?.id)

        await model.selectBot("beta")
        model.addPendingAttachment(name: "beta.pdf", data: Data("beta".utf8), isImage: false)

        // The removal call is scoped to beta; alpha's id is not present there.
        model.removePendingAttachment(alphaID)
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["beta.pdf"])

        await model.selectBot("alpha")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["alpha.pdf"],
                       "removing an id in another bot's composer must not delete alpha's file")
        await model.stop()
    }
}
#endif
