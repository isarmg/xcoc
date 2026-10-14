import XCTest
import XcocRust
@testable import XcocCamera

final class RustBridgeTests: XCTestCase {
    func testCurrentABIHandlesOpenStopCloseWithoutNetworkAccess() throws {
        let pairing: [String: Any] = [
            "server": "https://example.invalid",
            "installation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "instance_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "access_token": String(repeating: "a", count: 43),
            "name": "fixture"
        ]
        let opened = try RustBridge.call(0, ["operation": "open", "pairing": pairing])
        let handle = try XCTUnwrap(opened["value"] as? NSNumber).uint64Value
        XCTAssertNotEqual(handle, 0)
        defer { _ = try? RustBridge.call(handle, ["operation": "close"]) }
        XCTAssertFalse(RustBridge.frame(handle, Data([0, 0, 0, 1, 0x65, 1]), timestamp: 1000))
        _ = try RustBridge.call(handle, ["operation": "stop"])
        _ = try RustBridge.call(handle, ["operation": "close"])
        XCTAssertThrowsError(try RustBridge.call(handle, ["operation": "stop"]))
    }

    func testInvalidInputIsRejected() {
        XCTAssertThrowsError(try RustBridge.call(0, ["operation": "open", "pairing": [:]]))
        XCTAssertFalse(RustBridge.frame(0, Data([0x65]), timestamp: 0))
    }

    func testMalformedResultDescriptorIsRejectedBeforeReadingItsPointer() {
        var result = XcscFfiResultV1()
        result.abi_revision = UInt32(XCSC_FFI_ABI_REVISION)
        result.status = Int32(XCSC_FFI_OK)
        result.bytes.length = 1
        XCTAssertThrowsError(try RustBridge.checkedOutput(&result, status: Int32(XCSC_FFI_OK)))
        result.bytes.data = UnsafeMutablePointer<UInt8>(bitPattern: 1)
        result.bytes.length = Int(XCSC_FFI_MAX_OUTPUT_BYTES) + 1
        XCTAssertThrowsError(try RustBridge.checkedOutput(&result, status: Int32(XCSC_FFI_OK)))
        result.bytes.length = 1
        result.status = Int32(XCSC_FFI_INVALID_ARGUMENT)
        XCTAssertThrowsError(try RustBridge.checkedOutput(&result, status: Int32(XCSC_FFI_OK)))
        result.status = Int32(XCSC_FFI_OK)
        result.abi_revision += 1
        XCTAssertThrowsError(try RustBridge.checkedOutput(&result, status: Int32(XCSC_FFI_OK)))
    }
}
