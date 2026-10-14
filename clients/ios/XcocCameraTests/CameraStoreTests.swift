import Combine
import Foundation
import XCTest
@testable import XcocCamera

final class CameraStoreTests: XCTestCase {
    private final class TestEncoder: CameraEncoding {
        var onFrame: ((UUID, Data, UInt64, Data, Data, Int, Int) -> Bool)?
        var onFailure: ((UUID) -> Void)?
        var onStart: (() -> Void)?
        private let lock = NSLock()
        private var latest: UUID?
        var generation: UUID? { lock.lock(); defer { lock.unlock() }; return latest }
        func start(front: Bool, owner: CaptureGeneration, generation: UUID) {
            lock.lock(); latest = generation; lock.unlock()
            onStart?()
        }
        func stop(completion: (() -> Void)?) { completion?() }
    }

    private final class NativeFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: Int
        private var closed = [UInt64]()
        private var nextHandle: UInt64 = 101
        var beforeClose: (() -> Void)?
        init(failures: Int) { self.failures = failures }
        var closeHandles: [UInt64] { lock.lock(); defer { lock.unlock() }; return closed }
        func call(handle: UInt64, input: [String: Any]) throws -> [String: Any] {
            switch input["operation"] as? String {
            case "open":
                lock.lock(); let handle = nextHandle; nextHandle += 1; lock.unlock()
                return ["value": NSNumber(value: handle)]
            case "poll": return ["publishing": false]
            case "close":
                beforeClose?()
                lock.lock(); closed.append(handle)
                let fail = failures > 0
                if fail { failures -= 1 }
                lock.unlock()
                if fail { throw NSError(domain: "fixture-native-close", code: 1) }
                return [:]
            default: return [:]
            }
        }
    }
    @MainActor
    func testPendingPairBlocksDuplicatePairAndCaptureStart() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let duplicate = expectation(description: "duplicate pairing is rejected")
        duplicate.isInverted = true
        var first = true // Only read and written on the store's serial control queue.
        let store = CameraStore(pairOperation: { _, _, _ in
            if !first { duplicate.fulfill() }
            first = false
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        }, readPairing: { nil })
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
        let store = CameraStore(pairOperation: { _, _, _ in throw NSError(domain: "test", code: 1) }, readPairing: { nil })
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

    @MainActor
    func testStopCancelsPendingPermissionAndLateGrantDoesNotStartCapture() {
        var permissionCallbacks = [(Bool) -> Void]()
        let store = CameraStore(requestCameraAccess: { permissionCallbacks.append($0) }, readPairing: { nil })
        store.paired = true
        store.start(front: false)
        XCTAssertTrue(store.starting)
        XCTAssertFalse(store.running)
        store.start(front: true)
        XCTAssertEqual(permissionCallbacks.count, 1)
        store.stop()
        XCTAssertFalse(store.starting)
        XCTAssertFalse(store.running)
        permissionCallbacks[0](true)
        let drained = expectation(description: "late permission result ignored")
        DispatchQueue.main.async {
            XCTAssertFalse(store.starting)
            XCTAssertFalse(store.running)
            XCTAssertEqual(store.status, "摄像头已停止")
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
        permissionCallbacks.removeAll()
    }

    @MainActor
    func testOldPermissionResultCannotChangeRestartedRequest() {
        var permissionCallbacks = [(Bool) -> Void]()
        let store = CameraStore(requestCameraAccess: { permissionCallbacks.append($0) }, readPairing: { nil })
        store.paired = true
        store.start(front: false)
        store.stop()
        store.start(front: true)
        XCTAssertEqual(permissionCallbacks.count, 2)
        permissionCallbacks[0](true)
        let oldDrained = expectation(description: "old permission result ignored")
        DispatchQueue.main.async {
            XCTAssertTrue(store.starting)
            XCTAssertFalse(store.running)
            XCTAssertEqual(store.status, "正在等待摄像头权限")
            oldDrained.fulfill()
        }
        wait(for: [oldDrained], timeout: 1)
        permissionCallbacks[1](false)
        let newDrained = expectation(description: "current permission result applied")
        DispatchQueue.main.async {
            XCTAssertFalse(store.starting)
            XCTAssertFalse(store.running)
            XCTAssertEqual(store.status, "请在系统设置中允许摄像头权限")
            newDrained.fulfill()
        }
        wait(for: [newDrained], timeout: 1)
        permissionCallbacks.removeAll()
    }

    @MainActor
    func testPendingPermissionBlocksPairingUntilCancelled() {
        let paired = expectation(description: "pairing after cancelled start completed")
        var permissionCallbacks = [(Bool) -> Void]()
        let store = CameraStore(pairOperation: { _, _, _ in paired.fulfill() },
                                requestCameraAccess: { permissionCallbacks.append($0) }, readPairing: { nil })
        store.paired = true
        store.start(front: false)
        store.pair(server: "test", code: "test", name: "test")
        XCTAssertFalse(store.pairing)
        XCTAssertEqual(store.status, "正在等待摄像头权限")
        store.stop()
        let finished = expectation(description: "new pairing result applied")
        let observation = store.$status.sink { status in
            if status == "已配对，可启动摄像头" { finished.fulfill() }
        }
        store.pair(server: "test", code: "test", name: "test")
        wait(for: [paired, finished], timeout: 1)
        permissionCallbacks[0](true)
        let drained = expectation(description: "pair completion and cancelled grant drained")
        DispatchQueue.main.async {
            XCTAssertFalse(store.starting)
            XCTAssertFalse(store.running)
            XCTAssertFalse(store.pairing)
            XCTAssertEqual(store.status, "已配对，可启动摄像头")
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
        permissionCallbacks.removeAll()
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testPermissionGrantWhileInactiveReleasesStartReservation() {
        var permissionCallback: ((Bool) -> Void)?
        let store = CameraStore(requestCameraAccess: { permissionCallback = $0 },
                                applicationIsActive: { false }, readPairing: { nil })
        store.paired = true
        store.start(front: false)
        permissionCallback?(true)
        let drained = expectation(description: "inactive permission grant stopped")
        DispatchQueue.main.async {
            XCTAssertFalse(store.starting)
            XCTAssertFalse(store.running)
            XCTAssertEqual(store.status, "摄像头已停止")
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
        permissionCallback = nil
    }

    @MainActor
    func testFailedNativeCloseRetainsHandleBlocksReplacementAndRetries() throws {
        let encoder = TestEncoder(), native = NativeFixture(failures: 1)
        let started = expectation(description: "capture fixture started")
        encoder.onStart = { started.fulfill() }
        var permissionRequests = 0
        let store = CameraStore(requestCameraAccess: { permissionRequests += 1; $0(true) },
                                applicationIsActive: { true }, readPairing: { Data("{}".utf8) },
                                nativeCall: native.call, encoder: encoder)
        store.start(front: false)
        wait(for: [started], timeout: 1)
        let unconfirmed = expectation(description: "close failure remains visible")
        let failedObservation = store.$status.sink { status in
            if status.contains("连接关闭未确认") { unconfirmed.fulfill() }
        }
        store.stop()
        wait(for: [unconfirmed], timeout: 1)
        XCTAssertFalse(store.running)
        XCTAssertFalse(store.stopping)
        XCTAssertTrue(store.cleanupPending)
        store.start(front: true)
        store.pair(server: "test", code: "test", name: "test")
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertFalse(store.pairing)
        let stopped = expectation(description: "retry confirms close")
        let stoppedObservation = store.$status.sink { status in
            if status == "摄像头已停止" { stopped.fulfill() }
        }
        store.stop()
        wait(for: [stopped], timeout: 1)
        XCTAssertFalse(store.cleanupPending)
        XCTAssertEqual(native.closeHandles, [101, 101])
        withExtendedLifetime((failedObservation, stoppedObservation)) {}
    }

    @MainActor
    func testStopWaitsForNativeCloseAndRejectsOldEncoderFailure() throws {
        let encoder = TestEncoder(), native = NativeFixture(failures: 0)
        let started = expectation(description: "capture fixture started")
        encoder.onStart = { started.fulfill() }
        let closeEntered = DispatchSemaphore(value: 0), releaseClose = DispatchSemaphore(value: 0)
        native.beforeClose = {
            closeEntered.signal()
            _ = releaseClose.wait(timeout: .now() + 2)
        }
        var permissionRequests = 0
        let store = CameraStore(requestCameraAccess: { permissionRequests += 1; $0(true) },
                                applicationIsActive: { true }, readPairing: { Data("{}".utf8) },
                                nativeCall: native.call, encoder: encoder)
        store.start(front: false)
        wait(for: [started], timeout: 1)
        let oldGeneration = try XCTUnwrap(encoder.generation)
        let stopped = expectation(description: "native close confirmed")
        let observation = store.$status.sink { status in
            if status == "摄像头已停止" { stopped.fulfill() }
        }
        store.stop()
        XCTAssertEqual(closeEntered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(store.stopping)
        XCTAssertEqual(store.status, "正在停止摄像头")
        store.start(front: true)
        XCTAssertEqual(permissionRequests, 1)
        encoder.onFailure?(oldGeneration)
        releaseClose.signal()
        wait(for: [stopped], timeout: 1)
        XCTAssertFalse(store.stopping)
        XCTAssertFalse(store.cleanupPending)
        XCTAssertEqual(store.status, "摄像头已停止")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDelayedOldFrameCannotBorrowRestartedNativeHandle() throws {
        let encoder = TestEncoder(), native = NativeFixture(failures: 0)
        let started = expectation(description: "first capture started")
        encoder.onStart = { started.fulfill() }
        var submitted = [UInt64]()
        let store = CameraStore(requestCameraAccess: { $0(true) }, applicationIsActive: { true },
                                readPairing: { Data("{}".utf8) }, nativeCall: native.call,
                                nativeFrame: { handle, _, _ in submitted.append(handle); return true }, encoder: encoder)
        store.start(front: false)
        wait(for: [started], timeout: 1)
        let old = try XCTUnwrap(encoder.generation)
        let stopped = expectation(description: "first close confirmed")
        let observation = store.$status.sink { if $0 == "摄像头已停止" { stopped.fulfill() } }
        store.stop()
        wait(for: [stopped], timeout: 1)
        XCTAssertFalse(try XCTUnwrap(encoder.onFrame)(old, Data([0x65]), 1, Data(), Data(), 1280, 720))
        let restarted = expectation(description: "new capture started")
        encoder.onStart = { restarted.fulfill() }
        store.start(front: true)
        wait(for: [restarted], timeout: 1)
        let current = try XCTUnwrap(encoder.generation)
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(try XCTUnwrap(encoder.onFrame)(old, Data([0x65]), 2, Data(), Data(), 1280, 720))
        XCTAssertTrue(try XCTUnwrap(encoder.onFrame)(current, Data([0x65]), 3, Data(), Data(), 1280, 720))
        XCTAssertEqual(submitted, [102])
        observation.cancel()
        let finished = expectation(description: "second close confirmed")
        let finalObservation = store.$status.sink { if $0 == "摄像头已停止" { finished.fulfill() } }
        store.stop()
        wait(for: [finished], timeout: 1)
        withExtendedLifetime(finalObservation) {}
    }

    @MainActor
    func testCurrentEncoderFailureRemainsVisibleAfterConfirmedClose() throws {
        let encoder = TestEncoder(), native = NativeFixture(failures: 0)
        let started = expectation(description: "capture fixture started")
        encoder.onStart = { started.fulfill() }
        let store = CameraStore(requestCameraAccess: { $0(true) }, applicationIsActive: { true },
                                readPairing: { Data("{}".utf8) }, nativeCall: native.call, encoder: encoder)
        store.start(front: false)
        wait(for: [started], timeout: 1)
        let closed = expectation(description: "failure and real cleanup remain visible")
        let observation = store.$status.sink { status in
            if status.contains("摄像头不可用") && status.contains("连接已停止") { closed.fulfill() }
        }
        encoder.onFailure?(try XCTUnwrap(encoder.generation))
        wait(for: [closed], timeout: 1)
        XCTAssertFalse(store.running)
        XCTAssertFalse(store.stopping)
        XCTAssertFalse(store.cleanupPending)
        XCTAssertEqual(native.closeHandles, [101])
        XCTAssertNotEqual(store.status, "摄像头已停止")
        withExtendedLifetime(observation) {}
    }
}
