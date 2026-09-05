package com.innocent.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

/**
 * Receives the direct-reply typed into the ADB pairing notification and hands
 * the 6-digit code to [AdbPairingService] to complete pairing.
 *
 * Declared in the manifest (exported=false) rather than registered at runtime
 * inside the service, so the reply is captured even if Android killed the
 * service while the user was in the Settings pairing dialog. The actual pairing
 * (which can take longer than a receiver is allowed to run) happens inside the
 * service on a worker thread, not here.
 */
class AdbPairReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AdbPairingService.ACTION_REPLY) return
        val code = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(AdbPairingService.KEY_CODE)
            ?.toString()
            ?.trim()
            ?.filter { it.isDigit() }
            ?: ""
        // Forward to the service; it re-enters the foreground and pairs. Even an
        // empty/short code is forwarded so the service can show the "enter all 6
        // digits" hint and keep the reply action alive.
        AdbPairingService.pairWithCode(context.applicationContext, code)
    }
}
