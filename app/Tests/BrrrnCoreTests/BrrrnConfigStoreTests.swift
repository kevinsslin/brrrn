import Foundation
import XCTest
@testable import BrrrnCore

final class BrrrnConfigStoreTests: XCTestCase {
    func testLoadDistinguishesMissingMalformedAndValidFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = BrrrnConfigStore(url: fixture.configURL)

        let missing = await store.load()
        XCTAssertEqual(missing, .missing)

        try Data("{broken".utf8).write(to: fixture.configURL)
        guard case .malformed = await store.load() else {
            return XCTFail("expected malformed config state")
        }

        try Data(#"{"hub_url":"https://hub.example","handle":"kevin"}"#.utf8).write(to: fixture.configURL)
        guard case .valid(let config) = await store.load() else {
            return XCTFail("expected valid config state")
        }
        XCTAssertEqual(config.hubURL, "https://hub.example")
    }

    func testMutationsAreIdempotentPrivateAndPreserveUnknownFields() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"hub_url":"https://old.example","handle":"kevin","pits":["pit_one"],"backfilled_pits":["pit_one"],"future":{"enabled":true}}"#.utf8)
            .write(to: fixture.configURL)
        let store = BrrrnConfigStore(url: fixture.configURL)

        try await store.setHubURL("https://hub.example/")
        try await store.appendPit("pit_one")
        try await store.appendRelationship("rel_one")
        try await store.appendRelationship("rel_one")
        try await store.appendBackfillMarker("rel_one")

        guard case .valid(let config) = await store.load() else {
            return XCTFail("expected valid config")
        }
        XCTAssertEqual(config.hubURL, "https://hub.example")
        XCTAssertEqual(config.pits, ["pit_one"])
        XCTAssertEqual(config.relationships, ["rel_one"])
        XCTAssertEqual(config.backfilledPits, ["pit_one", "rel_one"])

        let data = try Data(contentsOf: fixture.configURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["future"] as? [String: Bool])?["enabled"], true)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMalformedConfigIsNeverReplacedByMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("{broken".utf8)
        try original.write(to: fixture.configURL)
        let store = BrrrnConfigStore(url: fixture.configURL)

        do {
            try await store.appendPit("pit_one")
            XCTFail("expected malformed config error")
        } catch let error as BrrrnConfigStoreError {
            guard case .malformed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.configURL), original)
    }

    func testHubValidationRequiresHTTPSExceptForLocalDevelopment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = BrrrnConfigStore(url: fixture.configURL)

        do {
            try await store.setHubURL("http://hub.example")
            XCTFail("expected insecure URL rejection")
        } catch let error as BrrrnConfigStoreError {
            XCTAssertEqual(error, .invalidHubURL)
        }

        try await store.setHubURL("http://127.0.0.1:8787/")
        guard case .valid(let config) = await store.load() else {
            return XCTFail("expected valid localhost config")
        }
        XCTAssertEqual(config.hubURL, "http://127.0.0.1:8787")
    }

    func testSeparateStoreInstancesSerializeMutationsForSamePath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = BrrrnConfigStore(url: fixture.configURL)
        let second = BrrrnConfigStore(url: fixture.configURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await store.appendRelationship("rel_\(index)")
                }
            }
            try await group.waitForAll()
        }

        guard case .valid(let config) = await first.load() else {
            return XCTFail("expected valid config")
        }
        XCTAssertEqual(Set(config.relationships), Set((0..<40).map { "rel_\($0)" }))
    }

    func testSerializedOperationBlocksConcurrentStoreMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = BrrrnConfigStore(url: fixture.configURL)
        let blocker = AsyncBlocker()
        let mutation = CompletionFlag()

        let operation = Task {
            await store.serialize {
                await blocker.wait()
            }
        }
        await blocker.waitUntilEntered()

        let append = Task {
            try await store.appendPit("pit_one")
            await mutation.finish()
        }
        try await Task.sleep(for: .milliseconds(50))
        let finishedEarly = await mutation.isFinished
        XCTAssertFalse(finishedEarly)

        await blocker.release()
        await operation.value
        try await append.value
        let finished = await mutation.isFinished
        XCTAssertTrue(finished)
    }
}

private struct Fixture {
    let directory: URL
    let configURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brrrn-config-tests-\(UUID().uuidString)", isDirectory: true)
        configURL = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor AsyncBlocker {
    private var entered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        for waiter in enterWaiters { waiter.resume() }
        enterWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionFlag {
    private var finished = false

    var isFinished: Bool { finished }

    func finish() {
        finished = true
    }
}
