#if canImport(Combine)
import Foundation
import XCTest
@testable import HermesAppKit
import HermesKit

/// A send clears the composer before its upload/submit completes. If either fails, the words and
/// files still belong to the bot that typed them — including when the user has already switched
/// away by the time the failure lands.
@MainActor
final class AppModelSendFailureTests: XCTestCase {

    private func makeModel() async -> (AppModel, ScriptedHost) {
        let host = ScriptedHost(session: "s1", entries: [
            TranscriptEntry(id: "u1", role: .user, text: "start"),
        ])
        host.bots = [Bot(id: "alpha"), Bot(id: "beta")]
        let model = AppModel(client: host, hostName: "send-failure-\(UUID().uuidString)")
        await model.start()
        await model.selectBot("alpha")
        await model.select("s1")
        return (model, host)
    }

    func testUploadFailureAfterASwitchRestoresTheOwnerDraftAndFiles() async {
        let (model, host) = await makeModel()
        var restored: [(String, String)] = []
        model.onDraftRestore = { bot, text in restored.append((bot, text)) }

        model.draft = "alpha upload text"
        model.addPendingAttachment(name: "alpha.pdf", data: Data("alpha".utf8), isImage: false)
        host.attachError = GatewayError.rpc(RPCError(code: 5000, message: "upload failed"))

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onAttach = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let send = Task { await model.send() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        await model.selectBot("beta")
        releaseContinuation.yield(())
        await send.value

        XCTAssertEqual(restored.map { $0.0 }, ["alpha"])
        XCTAssertEqual(restored.map { $0.1 }, ["alpha upload text"])
        XCTAssertTrue(model.pendingAttachments.isEmpty,
                      "the failed upload must not leak alpha's files into beta's composer")
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(host.submitted.isEmpty)

        await model.selectBot("alpha")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["alpha.pdf"],
                       "alpha's file comes back with alpha")
    }

    func testSubmitFailureAfterASwitchRestoresBothTheDraftAndUploadedFiles() async {
        let (model, host) = await makeModel()
        var restored: [(String, String)] = []
        model.onDraftRestore = { bot, text in restored.append((bot, text)) }

        model.draft = "alpha submit text"
        model.addPendingAttachment(name: "alpha.pdf", data: Data("alpha".utf8), isImage: false)
        model.addPendingAttachment(name: "shot.png", data: Data("png".utf8), isImage: true)
        host.submitError = GatewayError.rpc(RPCError(code: 5001, message: "submit failed"))

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        host.onSubmit = {
            enteredContinuation.yield(())
            var iterator = release.makeAsyncIterator()
            _ = await iterator.next()
        }

        let send = Task { await model.send() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // The upload has completed and removed the files from the composer; the submit then fails
        // only after the user has left the bot.
        XCTAssertEqual(host.attached.map(\.name), ["alpha.pdf", "shot.png"])
        await model.selectBot("beta")
        releaseContinuation.yield(())
        await send.value

        XCTAssertEqual(restored.map { $0.0 }, ["alpha"])
        XCTAssertEqual(restored.map { $0.1 }, ["alpha submit text"])
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertTrue(host.submitted.isEmpty)

        await model.selectBot("alpha")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["alpha.pdf", "shot.png"],
                       "a failed submit must retain the files it had already uploaded")
    }

    func testSubmitFailureOnTheSameBotKeepsTheDraftAndAttachments() async {
        let (model, host) = await makeModel()
        var restored: [(String, String)] = []
        model.onDraftRestore = { bot, text in restored.append((bot, text)) }

        model.draft = "retry me"
        model.addPendingAttachment(name: "spec.pdf", data: Data("pdf".utf8), isImage: false)
        host.submitError = GatewayError.rpc(RPCError(code: 5002, message: "no turn"))

        await model.send()

        XCTAssertEqual(model.draft, "retry me")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["spec.pdf"])
        XCTAssertEqual(restored.map { $0.1 }, ["retry me"])
        XCTAssertTrue(model.lastSendError?.contains("no turn") == true)
        XCTAssertFalse(model.isStreaming)
    }

    func testUploadFailureOnTheSameBotKeepsTheDraftAndAttachments() async {
        let (model, host) = await makeModel()
        model.draft = "retry upload"
        model.addPendingAttachment(name: "spec.pdf", data: Data("pdf".utf8), isImage: false)
        host.attachError = GatewayError.rpc(RPCError(code: 5003, message: "upload refused"))

        await model.send()

        XCTAssertEqual(model.draft, "retry upload")
        XCTAssertEqual(model.pendingAttachments.map(\.name), ["spec.pdf"])
        XCTAssertTrue(model.lastSendError?.contains("upload refused") == true)
    }
}
#endif
