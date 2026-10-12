package org.sarmg.xcoc

/** Process-wide ownership shared by the Activity and the foreground Service. */
class CameraRuntimeCoordinator {
    enum class Phase { IDLE, PAIRING, STARTING, RUNNING, STOPPING }
    enum class Cleanup { CAPTURE, NATIVE }
    data class Snapshot(
        val generation: Long = 0,
        val phase: Phase = Phase.IDLE,
        val server: String? = null,
        val name: String? = null,
        val message: String = "摄像头未启动"
    )

    private var current = Snapshot()
    private var claimed = false
    private var captureClosed = false
    private var nativeClosed = false
    private val observers = linkedSetOf<(Snapshot) -> Unit>()

    @Synchronized fun snapshot(): Snapshot = current
    @Synchronized fun observe(observer: (Snapshot) -> Unit): () -> Unit {
        observers.add(observer)
        observer(current)
        return { removeObserver(observer) }
    }
    @Synchronized private fun removeObserver(observer: (Snapshot) -> Unit) { observers.remove(observer) }
    private fun publish(value: Snapshot) {
        current = value
        observers.toList().forEach { it(value) }
    }
    @Synchronized fun beginPairing(): Long? {
        if (current.phase != Phase.IDLE) return null
        publish(Snapshot(current.generation + 1, Phase.PAIRING, message = "正在配对并保存凭据"))
        return current.generation
    }
    @Synchronized fun finishPairing(generation: Long, message: String) {
        if (current.generation == generation && current.phase == Phase.PAIRING) {
            publish(Snapshot(generation, message = message))
        }
    }
    @Synchronized fun beginStart(): Long? {
        if (current.phase != Phase.IDLE) return null
        claimed = false
        captureClosed = false
        nativeClosed = false
        publish(Snapshot(current.generation + 1, Phase.STARTING, message = "正在读取已保存配对并启动摄像头"))
        return current.generation
    }
    @Synchronized fun claimStart(generation: Long?): Long? {
        val ticket = generation ?: beginStart() ?: return null
        if (current.generation != ticket || claimed ||
            (current.phase != Phase.STARTING && current.phase != Phase.STOPPING)) return null
        claimed = true
        return ticket
    }
    @Synchronized fun opened(generation: Long, server: String, name: String): Boolean {
        if (current.generation != generation || !claimed || current.phase != Phase.STARTING) return false
        publish(current.copy(phase = Phase.RUNNING, server = server, name = name, message = "等待摄像头画面"))
        return true
    }
    @Synchronized fun report(generation: Long, message: String) {
        if (current.generation == generation &&
            (current.phase == Phase.STARTING || current.phase == Phase.RUNNING)) publish(current.copy(message = message))
    }
    @Synchronized fun requestStop(): Long? {
        if (current.phase != Phase.STARTING && current.phase != Phase.RUNNING && current.phase != Phase.STOPPING) return null
        publish(current.copy(phase = Phase.STOPPING, message = "正在关闭摄像头和连接，完成后可重新配对"))
        return current.generation
    }
    @Synchronized fun cancelUnclaimedStart(generation: Long, message: String) {
        if (current.generation == generation && !claimed &&
            (current.phase == Phase.STARTING || current.phase == Phase.STOPPING)) {
            // Invalidate any delayed foreground-service Intent before allowing pairing.
            publish(Snapshot(generation + 1, message = message))
        }
    }
    @Synchronized fun beginStopping(generation: Long) {
        if (current.generation == generation && claimed) requestStop()
    }
    @Synchronized fun cleanupFailed(generation: Long, message: String) {
        if (current.generation == generation && claimed && current.phase == Phase.STOPPING) {
            publish(current.copy(message = message))
        }
    }
    @Synchronized fun finished(generation: Long, part: Cleanup) {
        if (current.generation != generation || !claimed || current.phase != Phase.STOPPING) return
        when (part) { Cleanup.CAPTURE -> captureClosed = true; Cleanup.NATIVE -> nativeClosed = true }
        if (captureClosed && nativeClosed) {
            claimed = false
            publish(Snapshot(generation, message = "摄像头和连接已停止"))
        }
    }
}

object CameraRuntimeState { val coordinator = CameraRuntimeCoordinator() }
