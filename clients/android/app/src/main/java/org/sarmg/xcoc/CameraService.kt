package org.sarmg.xcoc

import android.Manifest
import android.app.*
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.*
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.Uri
import android.os.*
import android.util.Base64
import android.view.Surface
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CameraService : Service() {
    private val runtime = CameraRuntimeState.coordinator
    @Volatile private var generation: Long? = null
    private val control = Executors.newSingleThreadScheduledExecutor()
    private val cameraThread = HandlerThread("xcoc-capture")
    private lateinit var handler: Handler
    private var camera: CameraDevice? = null
    private var capture: CameraCaptureSession? = null
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    // Capture-thread state: an asynchronous open/close still owns the capture lease.
    private var cameraOpening = false
    private var cameraClosing = false
    private var captureReleased = false
    private var captureCleanupCompleted = false
    @Volatile private var handle = 0L
    @Volatile private var closing = false
    @Volatile private var active = false
    @Volatile private var sps = ByteArray(0)
    @Volatile private var pps = ByteArray(0)
    private var width = 1280
    private var height = 720
    private var started = false
    private var lastKeyframeRequest = 0L

    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("capture", "摄像头采集", NotificationManager.IMPORTANCE_LOW))
        startForeground(1, notification("正在启动摄像头"))
        cameraThread.start(); handler = Handler(cameraThread.looper)
    }
    private fun notification(message: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = Notification.Builder(this, "capture").setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle("Xcoc Camera").setContentText(message).setContentIntent(open).setOngoing(true)
        generation?.let { ticket ->
            val intent = Intent(this, CameraService::class.java).setAction("stop")
                .setData(Uri.parse("xcoc://capture/$ticket/stop")).putExtra("generation", ticket)
            val stop = PendingIntent.getService(this, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            builder.addAction(Notification.Action.Builder(null, "停止摄像头", stop).build())
        }
        return builder.build()
    }
    private fun report(message: String) {
        val ticket = generation ?: return
        val snapshot = runtime.snapshot()
        if (closing || snapshot.generation != ticket ||
            (snapshot.phase != CameraRuntimeCoordinator.Phase.STARTING && snapshot.phase != CameraRuntimeCoordinator.Phase.RUNNING)) return
        runtime.report(ticket, message)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val target = snapshot.server?.let { "$it / ${snapshot.name}: " } ?: ""
        getSystemService(NotificationManager::class.java).notify(1, notification("$target$message"))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            val ticket = generation
            if (ticket != null && intent.getLongExtra("generation", -1) == ticket) {
                runtime.beginStopping(ticket); stopSelf()
            } else if (ticket == null && runtime.snapshot().phase != CameraRuntimeCoordinator.Phase.STARTING) {
                stopSelf()
            }
            return START_NOT_STICKY
        }
        if (started) return START_NOT_STICKY
        val requested = if (intent?.hasExtra("generation") == true) intent.getLongExtra("generation", -1) else null
        val ticket = runtime.claimStart(requested)
        if (ticket == null) {
            // A delayed old start must not stop the Service awaiting a newer reservation.
            if (runtime.snapshot().phase != CameraRuntimeCoordinator.Phase.STARTING) stopSelf()
            return START_NOT_STICKY
        }
        generation = ticket
        started = true
        if (runtime.snapshot().phase == CameraRuntimeCoordinator.Phase.STOPPING) { stopSelf(); return START_NOT_STICKY }
        report("正在启动摄像头")
        val front = intent?.getBooleanExtra("front", false) ?: false
        control.execute {
            try {
                if (closing) return@execute
                val pairing = SecurePairing(this).load() ?: error("pairing missing")
                val saved = JSONObject(pairing)
                handle = JSONObject(NativeBridge.call(0, JSONObject().put("operation", "open").put("pairing", saved).toString())).getLong("value")
                if (!runtime.opened(ticket, saved.getString("server"), saved.getString("name"))) { stopSelf(); return@execute }
                handler.post { try { startCapture(front) } catch (_: Exception) { report("采集失败，请核对摄像头权限"); stopSelf() } }
                control.scheduleWithFixedDelay({ poll() }, 1, 3, TimeUnit.SECONDS)
            } catch (_: Exception) { report("配对不可读，请重新配对"); stopSelf() }
        }
        return START_NOT_STICKY
    }

    private fun metadata(isActive: Boolean) = JSONObject().put("platform", "android").put("model", Build.MODEL.take(128))
        .put("width", width).put("height", height).put("frame_rate", 30).put("active", isActive)
    private fun poll() {
        if (closing || handle == 0L) return
        try {
            val ready = active && sps.isNotEmpty() && pps.isNotEmpty()
            val input = JSONObject().put("operation", "poll").put("metadata", metadata(ready))
                .put("sps", Base64.encodeToString(sps, Base64.NO_WRAP)).put("pps", Base64.encodeToString(pps, Base64.NO_WRAP))
            val result = JSONObject(NativeBridge.call(handle, input.toString()))
            report(if (result.optBoolean("publishing")) "正在向 Server 发布视频" else if (ready) "正在连接 Server" else "等待摄像头画面")
        } catch (_: Exception) { report("连接中断，正在重试") }
    }
    private fun bytes(buffer: ByteBuffer): ByteArray = ByteArray(buffer.remaining()).also { buffer.duplicate().get(it) }
    private fun startCapture(front: Boolean) {
        if (closing) return
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) throw SecurityException("camera permission missing")
        val manager = getSystemService(CameraManager::class.java)
        val facing = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing }
            ?: error("selected camera unavailable")
        val characteristics = manager.getCameraCharacteristics(id)
        val sizes = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!.getOutputSizes(MediaCodec::class.java)
        val size = sizes.firstOrNull { it.width == 1280 && it.height == 720 }
            ?: sizes.filter { it.width <= 1280 && it.height <= 720 && it.width % 2 == 0 && it.height % 2 == 0 }.maxByOrNull { it.width * it.height }
            ?: error("capture size unavailable")
        width = size.width; height = size.height
        val format = MediaFormat.createVideoFormat("video/avc", width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 2_000_000); setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        val encoder = MediaCodec.createEncoderByType("video/avc"); codec = encoder
        encoder.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}
            override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) { active = false; report("视频编码失败"); stopSelf() }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                val configuration = listOfNotNull(format.getByteBuffer("csd-0"), format.getByteBuffer("csd-1")).flatMap { H264.units(bytes(it)) }
                sps = configuration.firstOrNull { it[0].toInt() and 31 == 7 } ?: ByteArray(0)
                pps = configuration.firstOrNull { it[0].toInt() and 31 == 8 } ?: ByteArray(0)
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    if (!closing && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        val buffer = codec.getOutputBuffer(index)!!
                        buffer.position(info.offset); buffer.limit(info.offset + info.size)
                        val accepted = NativeBridge.frame(handle, H264.annexB(bytes(buffer)), info.presentationTimeUs)
                        if (!accepted && SystemClock.elapsedRealtime() - lastKeyframeRequest >= 2000) {
                            lastKeyframeRequest = SystemClock.elapsedRealtime()
                            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
                        }
                    }
                } catch (_: Exception) { /* Native failures retry at the next poll; private data is never logged. */ }
                finally { codec.releaseOutputBuffer(index, false) }
            }
        }, handler)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val target = encoder.createInputSurface(); surface = target; encoder.start()
        cameraOpening = true
        try { manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraOpening = false
                camera = device
                if (closing) { cameraClosing = true; device.close(); return }
                @Suppress("DEPRECATION")
                device.createCaptureSession(listOf(target), object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        if (closing) { session.close(); return }
                        capture = session
                        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            addTarget(target)
                            characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.filter { it.lower <= 30 && it.upper >= 30 }
                                ?.minByOrNull { it.upper - it.lower }?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        }.build()
                        session.setRepeatingRequest(request, null, handler); active = true
                    }
                    override fun onConfigureFailed(session: CameraCaptureSession) { report("摄像头不支持所选采集格式"); stopSelf() }
                }, handler)
            }
            override fun onDisconnected(device: CameraDevice) { cameraOpening = false; camera = device; cameraClosing = true; device.close(); active = false; stopSelf() }
            override fun onError(device: CameraDevice, error: Int) { cameraOpening = false; camera = device; cameraClosing = true; device.close(); active = false; stopSelf() }
            override fun onClosed(device: CameraDevice) {
                camera = null; cameraOpening = false; cameraClosing = false
                completeCaptureCleanup()
            }
        }, handler) } catch (error: Exception) { cameraOpening = false; throw error }
    }
    private fun completeCaptureCleanup() {
        if (!closing || !captureReleased || cameraOpening || cameraClosing || captureCleanupCompleted) return
        captureCleanupCompleted = true
        cameraThread.quitSafely()
        generation?.let { runtime.finished(it, CameraRuntimeCoordinator.Cleanup.CAPTURE) }
    }
    override fun onDestroy() {
        closing = true; active = false
        val ticket = generation
        ticket?.let { runtime.beginStopping(it) }
        handler.post {
            try {
                try { capture?.close() } catch (_: Exception) {}
                camera?.let { device ->
                    cameraClosing = true
                    try { device.close() } catch (_: Exception) {
                        ticket?.let { runtime.cleanupFailed(it, "摄像头关闭未确认，请从系统设置强制停止应用，再重新打开") }
                    }
                }
                try { codec?.stop() } catch (_: Exception) {}
                try { codec?.release() } catch (_: Exception) {}
                try { surface?.release() } catch (_: Exception) {}
            } finally {
                captureReleased = true
                completeCaptureCleanup()
            }
        }
        control.execute {
            try {
                if (handle != 0L) {
                    try {
                        NativeBridge.call(handle, JSONObject().put("operation", "stop").toString())
                        NativeBridge.call(handle, JSONObject().put("operation", "poll").put("metadata", metadata(false)).put("sps", "").put("pps", "").toString())
                    } catch (_: Exception) {}
                    try {
                        NativeBridge.call(handle, "{\"operation\":\"close\"}")
                        handle = 0
                    } catch (_: Exception) {
                        ticket?.let { runtime.cleanupFailed(it, "连接关闭未确认，请从系统设置强制停止应用，再重新打开") }
                    }
                }
            } finally {
                if (handle == 0L) ticket?.let { runtime.finished(it, CameraRuntimeCoordinator.Cleanup.NATIVE) }
            }
        }
        control.shutdown(); stopForeground(STOP_FOREGROUND_REMOVE); super.onDestroy()
    }
}
