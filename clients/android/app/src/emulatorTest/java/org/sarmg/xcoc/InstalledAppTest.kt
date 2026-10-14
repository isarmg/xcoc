package org.sarmg.xcoc

import android.app.Activity
import android.content.Intent
import android.test.InstrumentationTestCase

/** Runs inside an installed APK on a disposable emulator, without a server or account. */
@Suppress("DEPRECATION")
class InstalledAppTest : InstrumentationTestCase() {
    fun testInstalledActivityCanCloseAndRelaunch() {
        repeat(2) {
            val intent = Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val activity: Activity = instrumentation.startActivitySync(intent)
            dismissNotificationPrompt()
            instrumentation.waitForIdleSync()
            assertFalse(activity.isFinishing)
            instrumentation.runOnMainSync { activity.finish() }
            // An idle main queue does not imply the asynchronous finish transaction
            // has destroyed the Activity. Relaunching sooner can deliver to the
            // finishing task (START_DELIVERED_TO_TOP), leaving startActivitySync
            // waiting forever for an instance that Android did not create.
            val destroyed = java.util.concurrent.atomic.AtomicBoolean(false)
            val deadline = android.os.SystemClock.uptimeMillis() + 10_000
            while (!destroyed.get() && android.os.SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync { destroyed.set(activity.isDestroyed) }
                if (!destroyed.get()) android.os.SystemClock.sleep(50)
            }
            assertTrue("Activity destruction did not complete before relaunch", destroyed.get())
        }
    }

    private fun dismissNotificationPrompt() {
        // First launch asks for notifications. Explicitly deny this optional
        // permission so no system Activity survives in the task during relaunch.
        // Do not grant notifications, camera, or access to any user account.
        val automation = instrumentation.uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        val permissionPackages = setOf("com.android.permissioncontroller", "com.google.android.permissioncontroller")
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        var denied = false
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            val root = automation.rootInActiveWindow
            if (root?.packageName?.toString() in permissionPackages) {
                checkNotNull(root)
                val messages = permissionPackages.flatMap {
                    root.findAccessibilityNodeInfosByViewId("$it:id/permission_message")
                }
                assertTrue("Unexpected system permission prompt; refusing to interact",
                    messages.any { it.text?.toString()?.contains("notification", ignoreCase = true) == true })
                // Android uses a distinct deny resource after a previous denial.
                // Both exact IDs are defined by PermissionController and its CTS.
                val denyIds = listOf("permission_deny_button", "permission_deny_and_dont_ask_again_button")
                val buttons = permissionPackages.flatMap { pkg ->
                    denyIds.flatMap { id -> root.findAccessibilityNodeInfosByViewId("$pkg:id/$id") }
                }.filter { it.isVisibleToUser && it.isEnabled }
                if (buttons.isNotEmpty()) {
                    android.util.Log.i("XcocInstalledTest", "Denying notification via ${buttons.first().viewIdResourceName}")
                    assertTrue("Notification denial click failed", buttons.first().performAction(
                        android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                    denied = true
                    break
                }
            }
            android.os.SystemClock.sleep(50)
        }
        val dismissedDeadline = android.os.SystemClock.uptimeMillis() + 5_000
        while (automation.rootInActiveWindow?.packageName?.toString() in permissionPackages &&
            android.os.SystemClock.uptimeMillis() < dismissedDeadline) {
            android.os.SystemClock.sleep(50)
        }
        assertFalse("System permission dialog remained over the installed application",
            automation.rootInActiveWindow?.packageName?.toString() in permissionPackages)
        android.util.Log.i("XcocInstalledTest", "Notification prompt denied=$denied; system dialog dismissed")
    }

    fun testInstalledJniOpensStopsClosesAndRejectsStaleHandle() {
        val pairing = """{"server":"https://example.invalid","installation_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","instance_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","access_token":"${"a".repeat(43)}","name":"isolated emulator fixture"}"""
        repeat(2) {
            val opened = NativeBridge.call(0, """{"operation":"open","pairing":$pairing}""")
            val handle = org.json.JSONObject(opened).getLong("value")
            assertTrue(handle != 0L)
            try {
                NativeBridge.call(handle, """{"operation":"stop"}""")
            } finally {
                NativeBridge.call(handle, """{"operation":"close"}""")
            }
            try {
                NativeBridge.call(handle, """{"operation":"stop"}""")
                fail("Closed JNI handle unexpectedly remained usable")
            } catch (_: IllegalStateException) { }
        }
    }

    fun testDeviceKeystorePreservesOnlyEncryptedFixture() {
        val context = instrumentation.targetContext
        val store = SecurePairing(context)
        val fixture = "isolated-emulator-pairing"
        store.save(fixture)
        assertEquals(fixture, SecurePairing(context).load())
        assertEquals(store.installationId(), SecurePairing(context).installationId())
        assertFalse(context.getSharedPreferences("xcoc", 0).getString("pairing", "")!!.contains(fixture))
        // Leave the application unpaired for the activity and force-stop smoke checks.
        assertTrue(context.getSharedPreferences("xcoc", 0).edit().remove("pairing").commit())
    }
}
