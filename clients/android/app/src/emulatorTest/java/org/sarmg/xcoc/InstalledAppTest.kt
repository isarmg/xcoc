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
            instrumentation.waitForIdleSync()
            assertFalse(activity.isFinishing)
            instrumentation.runOnMainSync { activity.finish() }
            instrumentation.waitForIdleSync()
            assertTrue(activity.isFinishing)
        }
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
