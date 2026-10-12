package org.sarmg.xcoc

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.*
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val runtime = CameraRuntimeState.coordinator
    private lateinit var status: TextView
    private lateinit var front: Switch
    private lateinit var server: EditText
    private lateinit var name: EditText
    private lateinit var code: EditText
    private lateinit var pair: Button
    private lateinit var start: Button
    private lateinit var stop: Button
    private var unsubscribe: (() -> Unit)? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = SecurePairing(this)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32) }
        fun text(hint: String) = EditText(this).apply { this.hint = hint; setSingleLine(true); layout.addView(this) }
        layout.addView(TextView(this).apply { text = "Xcoc 手机摄像头"; textSize = 24f })
        server = text("已保存的 Server HTTPS 地址")
        name = text("已保存的摄像头名称")
        code = text("实例授权码")
        status = TextView(this)
        pair = Button(this).apply {
            text = "配对"
            setOnClickListener {
                val generation = runtime.beginPairing() ?: return@setOnClickListener
                try {
                    val input = JSONObject().put("operation", "pair").put("server", server.text.toString().trim())
                        .put("name", name.text.toString().trim()).put("authorization_code", code.text.toString().trim())
                        .put("installation_id", store.installationId()).toString()
                    worker.execute {
                        val message = try {
                            store.save(NativeBridge.call(0, input))
                            "配对已保存，启动摄像头后使用新配对"
                        } catch (_: Exception) { "配对失败，请核对地址、授权码和网络" }
                        runtime.finishPairing(generation, message)
                        runOnUiThread { code.setText("") }
                    }
                } catch (_: Exception) {
                    runtime.finishPairing(generation, "配对失败，请核对输入")
                    code.setText("")
                }
            }
        }; layout.addView(pair)
        front = Switch(this).apply { text = "使用前置摄像头" }; layout.addView(front)
        start = Button(this).apply { text = "启动摄像头"; setOnClickListener {
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.CAMERA), 1)
            else startCamera()
        } }; layout.addView(start)
        stop = Button(this).apply { text = "停止摄像头"; setOnClickListener {
            val generation = runtime.requestStop() ?: return@setOnClickListener
            if (!stopService(Intent(this@MainActivity, CameraService::class.java))) {
                runtime.cancelUnclaimedStart(generation, "摄像头已停止")
            }
        } }; layout.addView(stop)
        layout.addView(status)
        layout.addView(TextView(this).apply { text = "运行目标显示在状态和常驻通知中。更换配对须先停止，等待摄像头和连接关闭。视频在 Server 录像。" })
        setContentView(layout)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
    }
    override fun onStart() {
        super.onStart()
        unsubscribe = runtime.observe { snapshot -> runOnUiThread { if (!isDestroyed) showRuntime(snapshot) } }
    }
    override fun onStop() { unsubscribe?.invoke(); unsubscribe = null; super.onStop() }
    private fun showRuntime(snapshot: CameraRuntimeCoordinator.Snapshot) {
        val idle = snapshot.phase == CameraRuntimeCoordinator.Phase.IDLE
        pair.isEnabled = idle; start.isEnabled = idle
        server.isEnabled = idle; name.isEnabled = idle; code.isEnabled = idle; front.isEnabled = idle
        stop.isEnabled = snapshot.phase == CameraRuntimeCoordinator.Phase.STARTING || snapshot.phase == CameraRuntimeCoordinator.Phase.RUNNING
        if (idle) {
            status.text = try {
                SecurePairing(this).load()?.let { saved ->
                    val pairing = JSONObject(saved)
                    server.setText(pairing.getString("server")); name.setText(pairing.getString("name"))
                    "${snapshot.message}。已保存配对，可启动摄像头"
                } ?: "${snapshot.message}。先在 Server 创建实例并填写授权码"
            } catch (_: Exception) { "${snapshot.message}。配对数据不可读，请重新配对" }
        } else {
            val target = snapshot.server?.let { "运行目标：$it / ${snapshot.name}\n" } ?: ""
            status.text = "$target${snapshot.message}。更换配对请先停止摄像头"
        }
    }
    private fun startCamera() {
        var generation: Long? = null
        try {
            if (SecurePairing(this).load() == null) { status.text = "请先配对"; return }
            val ticket = runtime.beginStart() ?: return
            generation = ticket
            startForegroundService(Intent(this, CameraService::class.java).putExtra("front", front.isChecked).putExtra("generation", ticket))
        } catch (_: Exception) {
            generation?.let { runtime.cancelUnclaimedStart(it, "摄像头启动失败，请核对权限和配对状态") }
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1 && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startCamera()
    }
    override fun onDestroy() { unsubscribe?.invoke(); worker.shutdown(); super.onDestroy() }
}
