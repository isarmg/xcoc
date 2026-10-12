package org.sarmg.xcoc

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class CameraRuntimeStateTest {
    @Test fun pairingAndServiceStartHaveOneProcessOwner() {
        val runtime = CameraRuntimeCoordinator()
        val start = CountDownLatch(1)
        val paired = AtomicReference<Long?>()
        val started = AtomicReference<Long?>()
        val pairThread = thread { start.await(); paired.set(runtime.beginPairing()) }
        val serviceThread = thread { start.await(); started.set(runtime.beginStart()) }
        start.countDown(); pairThread.join(); serviceThread.join()
        assertTrue((paired.get() == null) != (started.get() == null))
        assertNull(runtime.beginPairing())
        assertNull(runtime.beginStart())
    }

    @Test fun pairingWaitsForBothCaptureAndNativeCleanupInEitherOrder() {
        for (first in CameraRuntimeCoordinator.Cleanup.entries) {
            val runtime = CameraRuntimeCoordinator()
            val generation = runtime.beginStart()!!
            assertEquals(generation, runtime.claimStart(generation))
            assertTrue(runtime.opened(generation, "https://active.example", "Active camera"))
            assertNull(runtime.beginPairing())
            runtime.requestStop()
            runtime.finished(generation, first)
            runtime.finished(generation, first) // Repeated callback cannot count twice.
            assertNull(runtime.beginPairing())
            assertEquals("https://active.example", runtime.snapshot().server)
            val second = CameraRuntimeCoordinator.Cleanup.entries.first { it != first }
            runtime.finished(generation, second)
            assertEquals(CameraRuntimeCoordinator.Phase.IDLE, runtime.snapshot().phase)
            assertNull(runtime.snapshot().server)
            assertNotNull(runtime.beginPairing())
        }
    }

    @Test fun aStoppedUnclaimedStartCannotOpenAfterNewPairing() {
        val runtime = CameraRuntimeCoordinator()
        val old = runtime.beginStart()!!
        runtime.requestStop()
        runtime.cancelUnclaimedStart(old, "Stopped")
        val pair = runtime.beginPairing()!!
        assertNull(runtime.claimStart(old))
        assertFalse(runtime.opened(old, "https://old.example", "Old"))
        assertEquals(CameraRuntimeCoordinator.Phase.PAIRING, runtime.snapshot().phase)
        runtime.finishPairing(pair, "Saved")
        assertNotNull(runtime.beginStart())
    }

    @Test fun aServiceClaimedWhileStoppingNeverBecomesRunning() {
        val runtime = CameraRuntimeCoordinator()
        val generation = runtime.beginStart()!!
        runtime.requestStop()
        assertEquals(generation, runtime.claimStart(generation))
        assertFalse(runtime.opened(generation, "https://old.example", "Old"))
        assertNull(runtime.beginPairing())
        runtime.finished(generation, CameraRuntimeCoordinator.Cleanup.NATIVE)
        runtime.finished(generation, CameraRuntimeCoordinator.Cleanup.CAPTURE)
        assertNotNull(runtime.beginPairing())
    }

    @Test fun lateOldCallbacksCannotUnlockANewServiceOrReplaceItsTarget() {
        val runtime = CameraRuntimeCoordinator()
        val old = runtime.beginStart()!!
        runtime.claimStart(old); runtime.requestStop()
        runtime.finished(old, CameraRuntimeCoordinator.Cleanup.CAPTURE)
        runtime.finished(old, CameraRuntimeCoordinator.Cleanup.NATIVE)
        val current = runtime.beginStart()!!
        runtime.claimStart(current)
        assertTrue(runtime.opened(current, "https://new.example", "New"))
        runtime.beginStopping(old)
        runtime.finished(old, CameraRuntimeCoordinator.Cleanup.NATIVE)
        runtime.finished(old, CameraRuntimeCoordinator.Cleanup.CAPTURE)
        runtime.report(old, "Old connection failed")
        assertEquals(CameraRuntimeCoordinator.Phase.RUNNING, runtime.snapshot().phase)
        assertEquals("https://new.example", runtime.snapshot().server)
        assertNull(runtime.beginPairing())
    }

    @Test fun recreatedActivityReceivesTheActualServiceTargetAndUnsubscribes() {
        val runtime = CameraRuntimeCoordinator()
        val generation = runtime.beginStart()!!
        runtime.claimStart(generation)
        runtime.opened(generation, "https://active.example", "Active")
        val observed = mutableListOf<CameraRuntimeCoordinator.Snapshot>()
        val unsubscribe = runtime.observe { observed.add(it) }
        assertEquals("https://active.example", observed.single().server)
        runtime.report(generation, "Publishing")
        assertEquals("Publishing", observed.last().message)
        unsubscribe()
        runtime.requestStop()
        assertEquals(2, observed.size)
    }

    @Test fun unconfirmedNativeCloseDoesNotUnlockPairing() {
        val runtime = CameraRuntimeCoordinator()
        val generation = runtime.beginStart()!!
        runtime.claimStart(generation); runtime.requestStop()
        runtime.finished(generation, CameraRuntimeCoordinator.Cleanup.CAPTURE)
        runtime.cleanupFailed(generation, "Close not confirmed")
        assertEquals(CameraRuntimeCoordinator.Phase.STOPPING, runtime.snapshot().phase)
        assertEquals("Close not confirmed", runtime.snapshot().message)
        assertNull(runtime.beginPairing())
        assertNull(runtime.beginStart())
    }
}
