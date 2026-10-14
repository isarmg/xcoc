import Foundation
import XcocRust

enum RustBridge {
    static func call(_ handle: UInt64, _ input: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: input)
        var result = XcscFfiResultV1()
        defer { xcsc_ffi_result_free_v1(&result) }
        let status = data.withUnsafeBytes { bytes in
            xcoc_call_v1(handle, bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &result)
        }
        let output = try checkedOutput(&result, status: status)
        guard !output.isEmpty else { return ["value": result.value] }
        guard let value = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw NativeError.failed }
        return value
    }
    static func frame(_ handle: UInt64, _ bytes: Data, timestamp: UInt64) -> Bool {
        var result = XcscFfiResultV1()
        defer { xcsc_ffi_result_free_v1(&result) }
        let status = bytes.withUnsafeBytes { buffer in
            xcoc_frame_v1(handle, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count, timestamp, &result)
        }
        guard let output = try? checkedOutput(&result, status: status), output.isEmpty else { return false }
        return result.value == 1
    }

    static func checkedOutput(_ result: inout XcscFfiResultV1, status: Int32) throws -> Data {
        guard result.abi_revision == UInt32(XCSC_FFI_ABI_REVISION),
              status == result.status, status == Int32(XCSC_FFI_OK),
              result.bytes.length <= Int(XCSC_FFI_MAX_OUTPUT_BYTES),
              result.bytes.data != nil || result.bytes.length == 0 else { throw NativeError.failed }
        guard let pointer = result.bytes.data, result.bytes.length > 0 else { return Data() }
        return Data(bytes: pointer, count: result.bytes.length)
    }
    enum NativeError: Error { case failed }
}
