package com.innocent.media

import android.app.Application
import android.os.Build
import org.lsposed.hiddenapibypass.HiddenApiBypass

/**
 * Custom Application for Innocent (Phase 64 / M1b-A).
 *
 * Android 9+ (API 28) restricts reflective access to non-SDK ("hidden") APIs.
 * libadb-android's TLS handshake for ADB pairing/connect on Android 11+ reaches
 * the platform Conscrypt provider through those hidden APIs, so we lift the
 * restriction once at startup. Without this, pairing/connect fail at runtime on
 * modern devices. This is a no-op below API 28.
 */
class InnocentApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                HiddenApiBypass.addHiddenApiExemptions("L")
                exemptionStatus = "applied"
            } catch (e: Throwable) {
                exemptionStatus = "failed (${e.javaClass.simpleName}: ${e.message})"
            }
        } else {
            exemptionStatus = "not needed (API < 28)"
        }
    }

    companion object {
        /** Surfaced in the ADB self-test so we can confirm this ran on-device. */
        @Volatile
        var exemptionStatus: String = "not run"
    }
}
