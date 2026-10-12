import Combine
import Foundation
import XCTest
@testable import XcocCamera

final class CameraStoreTests: XCTestCase {
    @MainActor
    func testPendingPairBlocksDuplicatePairAndCaptureStart() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let duplicate = expectation(description: "duplicate pairing is rejected")
        duplicate.isInverted = true
        var first = true // Only read and written on the store's serial control queue.
        let store = CameraStore { _, _, _ in
            if !first { duplicate.fulfill() }
            first = false
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        store.paired = true
        store.pair(server: "test", code: "test", name: "test")
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(store.pairing)
        store.pair(server: "test", code: "test", name: "test")
        store.start(front: false)
        XCTAssertFalse(store.running)
        XCTAssertEqual(store.status, "正在配对")
        let finished = expectation(description: "pairing completed")
        let observation = store.$status.sink { status in
            if status == "已配对，可启动摄像头" { finished.fulfill() }
        }
        release.signal()
        wait(for: [finished, duplicate], timeout: 1)
        XCTAssertFalse(store.pairing)
        XCTAssertTrue(store.paired)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testFailedPairReleasesReservationAndPreservesExistingPairing() {
        let store = CameraStore { _, _, _ in throw NSError(domain: "test", code: 1) }
        store.paired = true
        let finished = expectation(description: "failed pairing completed")
        let observation = store.$status.sink { status in
            if status.hasPrefix("配对失败") { finished.fulfill() }
        }
        store.pair(server: "test", code: "test", name: "test")
        XCTAssertTrue(store.pairing)
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(store.pairing)
        XCTAssertTrue(store.paired)
        withExtendedLifetime(observation) {}
    }
}
