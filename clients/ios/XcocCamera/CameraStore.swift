import AVFoundation
import Combine
import Foundation
import UIKit

final class CameraStore: ObservableObject {
    @Published var status = "先在 Server 创建实例并填写授权码"
    @Published var paired = false
    @Published var pairing = false
    @Published var starting = false
    @Published var running = false
    @Published var stopping = false
    @Published var cleanupPending = false
    private let pairOperation: (String, String, String) throws -> Void
    private let requestCameraAccess: (@escaping (Bool) -> Void) -> Void
    private let applicationIsActive: () -> Bool
    private let readPairing: () throws -> Data?
    private let nativeCall: (UInt64, [String: Any]) throws -> [String: Any]
    private let nativeFrame: (UInt64, Data, UInt64) -> Bool
    private let control = DispatchQueue(label: "xcoc.control")
    private let lock = NSLock()
    private let encoder: CameraEncoding
    private let lifecycle = CaptureGeneration()
    private var handle: UInt64 = 0
    private var sps = Data()
    private var pps = Data()
    private var width = 1280
    private var height = 720
    private var timer: DispatchSourceTimer?
    private var stopFailure: String?

    init(pairOperation: ((String, String, String) throws -> Void)? = nil,
         requestCameraAccess: @escaping (@escaping (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) },
         applicationIsActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         readPairing: @escaping () throws -> Data? = { try KeychainPairing.read("pairing") },
         nativeCall: @escaping (UInt64, [String: Any]) throws -> [String: Any] = RustBridge.call,
         nativeFrame: @escaping (UInt64, Data, UInt64) -> Bool = { RustBridge.frame($0, $1, timestamp: $2) },
         encoder: CameraEncoding? = nil) {
        self.pairOperation = pairOperation ?? CameraStore.savePairing
        self.requestCameraAccess = requestCameraAccess
        self.applicationIsActive = applicationIsActive
        self.readPairing = readPairing
        self.nativeCall = nativeCall
        self.nativeFrame = nativeFrame
        self.encoder = encoder ?? CameraEncoder()
        paired = (try? readPairing()) != nil
        if paired { status = "已配对，可启动摄像头" }
        self.encoder.onFrame = { [weak self] generation, data, timestamp, sps, pps, width, height in
            guard let self else { return false }
            self.lock.lock()
            guard self.lifecycle.isCurrent(generation) else { self.lock.unlock(); return false }
            self.sps = sps; self.pps = pps; self.width = width; self.height = height
            let handle = self.handle
            self.lock.unlock()
            return handle != 0 && self.nativeFrame(handle, data, timestamp)
        }
        self.encoder.onFailure = { [weak self] generation in DispatchQueue.main.async {
            guard let self, self.lifecycle.isCurrent(generation) else { return }
            self.stop(failure: "摄像头不可用，请核对权限")
        } }
    }
    private static func savePairing(server: String, code: String, name: String) throws {
        let result = try RustBridge.call(0, ["operation": "pair", "server": server.trimmingCharacters(in: .whitespacesAndNewlines), "authorization_code": code.trimmingCharacters(in: .whitespacesAndNewlines), "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "installation_id": try KeychainPairing.installationId()])
        try KeychainPairing.save("pairing", data: JSONSerialization.data(withJSONObject: result))
    }
    func pair(server: String, code: String, name: String) {
        guard !starting, !running, !stopping, !cleanupPending, !pairing else { return }
        pairing = true
        status = "正在配对"
        control.async {
            do {
                try self.pairOperation(server, code, name)
                DispatchQueue.main.async { self.pairing = false; self.paired = true; self.status = "已配对，可启动摄像头" }
            } catch { DispatchQueue.main.async { self.pairing = false; self.status = "配对失败，请核对地址、授权码和网络" } }
        }
    }
    func start(front: Bool) {
        guard !starting, !running, !stopping, !cleanupPending, !pairing, paired else { return }
        let generation = lifecycle.begin()
        stopFailure = nil
        starting = true; status = "正在等待摄像头权限"
        requestCameraAccess { allowed in
            DispatchQueue.main.async {
                guard self.lifecycle.isCurrent(generation), self.starting, !self.running, !self.stopping, !self.pairing else { return }
                self.starting = false
                guard self.applicationIsActive() else {
                    self.lifecycle.cancel(); self.status = "摄像头已停止"; return
                }
                guard allowed else {
                    self.lifecycle.cancel(); self.status = "请在系统设置中允许摄像头权限"; return
                }
                self.running = true; self.status = "正在启动摄像头"
                self.control.async {
                    do {
                        guard self.lifecycle.isCurrent(generation) else { return }
                        guard let data = try self.readPairing(), let pairing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RustBridge.NativeError.failed }
                        let result = try self.nativeCall(0, ["operation": "open", "pairing": pairing])
                        guard let value = result["value"] as? NSNumber, value.uint64Value != 0 else { throw RustBridge.NativeError.failed }
                        guard self.lifecycle.isCurrent(generation) else {
                            do { _ = try self.nativeCall(value.uint64Value, ["operation": "close"]) }
                            catch {
                                self.lock.lock(); self.handle = value.uint64Value; self.lock.unlock()
                            }
                            return
                        }
                        self.lock.lock(); self.handle = value.uint64Value; self.sps = Data(); self.pps = Data(); self.lock.unlock()
                        self.encoder.start(front: front, owner: self.lifecycle, generation: generation)
                        let timer = DispatchSource.makeTimerSource(queue: self.control)
                        timer.schedule(deadline: .now() + 1, repeating: 3)
                        timer.setEventHandler { [weak self] in self?.poll(active: true, generation: generation) }
                        self.timer = timer; timer.resume()
                    } catch { DispatchQueue.main.async {
                        guard self.lifecycle.isCurrent(generation) else { return }
                        self.lifecycle.cancel(); self.running = false; self.status = "配对不可读，请重新配对"
                    } }
                }
            }
        }
    }
    private func poll(active: Bool, generation: UUID? = nil) {
        if active {
            guard let generation, lifecycle.isCurrent(generation) else { return }
        }
        lock.lock()
        let current = handle, sps = self.sps, pps = self.pps, width = self.width, height = self.height
        lock.unlock()
        guard current != 0 else { return }
        do {
            let metadata: [String: Any] = ["platform": "ios", "model": UIDevice.current.model, "width": width, "height": height, "frame_rate": 30, "active": active && !sps.isEmpty && !pps.isEmpty]
            let result = try nativeCall(current, ["operation": "poll", "metadata": metadata, "sps": sps.base64EncodedString(), "pps": pps.base64EncodedString()])
            if active, let generation { DispatchQueue.main.async {
                if self.running, self.lifecycle.isCurrent(generation) { self.status = result["publishing"] as? Bool == true ? "正在向 Server 发布视频" : "正在连接 Server" }
            } }
        } catch { if active, let generation { DispatchQueue.main.async {
            if self.running, self.lifecycle.isCurrent(generation) { self.status = "连接中断，正在重试" }
        } } }
    }
    func stop(failure: String? = nil) {
        guard !stopping, starting || running || cleanupPending else { return }
        if let failure { stopFailure = failure }
        if starting {
            starting = false; lifecycle.cancel(); status = "摄像头已停止"
            return
        }
        // The encoder stops before the handle is destroyed; no camera frames survive stop.
        running = false; stopping = true; cleanupPending = false; status = "正在停止摄像头"
        let failureReason = stopFailure
        lifecycle.cancel()
        control.async { self.timer?.cancel(); self.timer = nil }
        // Capture stops independently of an in-flight network poll. A late
        // encoder.start carries the cancelled owner generation and is rejected.
        encoder.stop { [weak self] in
            guard let self else { return }
            self.control.async {
                self.lock.lock(); let current = self.handle; self.lock.unlock()
                let closed: Bool
                if current != 0 {
                    _ = try? self.nativeCall(current, ["operation": "stop"])
                    self.poll(active: false)
                    do { _ = try self.nativeCall(current, ["operation": "close"]); closed = true }
                    catch { closed = false }
                } else { closed = true }
                if closed { self.lock.lock(); self.handle = 0; self.lock.unlock() }
                DispatchQueue.main.async {
                    self.stopping = false; self.cleanupPending = !closed
                    self.status = closed ? (failureReason.map { $0 + "；摄像头和连接已停止" } ?? "摄像头已停止") :
                        (failureReason.map { $0 + "；" } ?? "") + "摄像头已停止采集，但连接关闭未确认；请重试停止"
                }
            }
        }
    }
}
