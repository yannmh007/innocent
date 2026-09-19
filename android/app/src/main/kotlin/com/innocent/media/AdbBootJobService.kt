package com.innocent.media

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * Turns wireless debugging back on after a reboot and reconnects.
 *
 * ─── WHY THIS IS A JOB AND NOT A SLEEP IN THE RECEIVER (audit_adb.md A5) ──
 *
 * [BootReceiver] used to do the whole thing itself: `goAsync()`, then
 * `sleep(45s)` → enable → `sleep(8s)` → a connect with a 25 s deadline. Up to
 * **78 seconds** before `PendingResult.finish()`.
 *
 * `goAsync()` does not buy unlimited time. The result must be finished inside
 * the broadcast timeout — about ten seconds for a foreground broadcast, sixty
 * for a background one. Past it the system logs a timeout, may declare an ANR,
 * and is free to kill the process. And it held the process alive and
 * un-reclaimable AT BOOT, the moment the device is under the most memory
 * pressure it will ever be under.
 *
 * Worse than the timeout: if the process was killed mid-sleep, nothing
 * happened and NOBODY WAS TOLD. Every branch sat inside `catch (_) {}`, there
 * was no notification, no log the user could see and no state written. The
 * user found their Android/data videos missing the next morning with no reason
 * for it.
 *
 * And the sleeps were guesses standing in for things that are observable.
 * `sleep(45000)` means "Wi-Fi is probably up by now".
 *
 * So: the receiver now only schedules this job and returns, in microseconds.
 * The waiting is expressed as constraints the system already tracks —
 * a network, and a minimum latency it holds for us without keeping our process
 * alive — and a failure is a retry with backoff rather than a silence. The job
 * outlives the process: if the system kills us mid-boot, JobScheduler starts
 * us again when the constraints are met.
 *
 * Deliberately no new dependency, matching [EngineUpdateJobService]:
 * WorkManager is the usual answer and is also another library to fight into a
 * build that is already delicate. JobScheduler is part of Android.
 *
 * The outcome is written to the `adb_state` prefs and shown on the ADB screen,
 * because "it silently did not happen" was the actual complaint.
 */
class AdbBootJobService : JobService() {

    companion object {
        private const val JOB_ID = 0x4442

        /**
         * A short settle before the first attempt. The old code slept 45 s
         * here on the broadcast thread; the system holds this one for us,
         * with our process free to be reclaimed in the meantime.
         */
        private const val LATENCY_MS = 20_000L

        /**
         * Run even if the network constraint is never satisfied. Reconnecting
         * happens over loopback, so a device that comes up with no Wi-Fi at
         * all can still succeed — the network constraint is the fast path, not
         * a precondition, and waiting for it forever would be worse than
         * trying.
         */
        private const val DEADLINE_MS = 120_000L

        private const val BACKOFF_MS = 30_000L

        /** Attempts, including the first. After this the job gives up. */
        private const val MAX_ATTEMPTS = 4

        const val PREF_AT = "boot_restore_at"
        const val PREF_RESULT = "boot_restore_result"
        private const val PREF_ATTEMPT = "boot_restore_attempt"

        /** Schedule the post-boot restore. Returns false if it could not be. */
        fun schedule(context: Context): Boolean {
            return try {
                // A new boot is a new count, not a continuation of the last
                // one's failures.
                resetAttempts(context)
                val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE)
                    as? JobScheduler ?: return false
                val info = JobInfo.Builder(
                    JOB_ID,
                    ComponentName(context, AdbBootJobService::class.java),
                )
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setMinimumLatency(LATENCY_MS)
                    .setOverrideDeadline(DEADLINE_MS)
                    .setBackoffCriteria(
                        BACKOFF_MS,
                        JobInfo.BACKOFF_POLICY_LINEAR,
                    )
                    .build()
                scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
            } catch (_: Throwable) {
                false
            }
        }

        /** What the last post-boot restore did, for the ADB screen. */
        fun lastResult(context: Context): String =
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .getString(PREF_RESULT, "") ?: ""

        /** When [lastResult] was written, in epoch millis, or 0. */
        fun lastResultAt(context: Context): Long =
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .getLong(PREF_AT, 0L)

        /**
         * Bump and return this restore's attempt number, counting from 1.
         *
         * Counted here because JobScheduler does not expose it: `JobParameters`
         * carries the job id, the extras and (from API 31) the stop reason, but
         * nothing about how many times the job has been retried — that is
         * WorkManager's `WorkInfo.runAttemptCount`, and WorkManager is the
         * dependency this file exists to avoid.
         *
         * In SharedPreferences rather than a field, because the whole point of
         * the job is that it survives the process being killed between
         * retries, and a field would not.
         */
        private fun nextAttempt(context: Context): Int {
            return try {
                val prefs = context.getSharedPreferences(
                    "adb_state",
                    Context.MODE_PRIVATE,
                )
                val n = prefs.getInt(PREF_ATTEMPT, 0) + 1
                prefs.edit().putInt(PREF_ATTEMPT, n).apply()
                n
            } catch (_: Throwable) {
                1
            }
        }

        /** Start a fresh count. Called when a new restore is scheduled. */
        private fun resetAttempts(context: Context) {
            try {
                context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                    .edit().putInt(PREF_ATTEMPT, 0).apply()
            } catch (_: Throwable) {
            }
        }

        private fun record(context: Context, text: String) {
            try {
                context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                    .edit()
                    .putString(PREF_RESULT, text)
                    .putLong(PREF_AT, System.currentTimeMillis())
                    .apply()
            } catch (_: Throwable) {
            }
        }
    }

    @Volatile
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters?): Boolean {
        val ctx = applicationContext
        val thread = Thread {
            var retry = false
            try {
                retry = restore(ctx)
            } catch (e: Throwable) {
                record(ctx, "Failed: ${e.javaClass.simpleName}: ${e.message}")
            }
            worker = null
            try {
                jobFinished(params, retry)
            } catch (_: Throwable) {
            }
        }
        worker = thread
        thread.name = "adb-boot-job"
        thread.start()
        // The work outlives this call.
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        // The system wants its resources back. Don't fight it: say yes to
        // being rescheduled and let the thread finish or die with the process.
        worker?.interrupt()
        worker = null
        record(applicationContext, "Interrupted by the system — will retry.")
        return true
    }

    /** Returns true when the caller should ask for a retry. */
    private fun restore(context: Context): Boolean {
        // Re-checked HERE, not only at schedule time: the user can turn the
        // feature off, or the permission can go away, between the boot and the
        // moment the constraints are met.
        if (!AdbManager.autoEnableOn(context)) {
            record(context, "Skipped — auto-reconnect is off.")
            return false
        }
        if (!AdbManager.hasSecureSettings(context)) {
            record(
                context,
                "Skipped — the app no longer holds WRITE_SECURE_SETTINGS.",
            )
            return false
        }

        val attempt = nextAttempt(context)

        if (!AdbManager.enableWirelessDebugging(context)) {
            record(context, "Could not turn Wireless debugging on (try $attempt).")
            return attempt < MAX_ATTEMPTS
        }

        // adbd needs a moment to start listening and advertising after the
        // setting flips. This sleep is on a job thread with no broadcast
        // deadline over it, which is the difference that matters; it is short
        // because a failure here is a retry, not a lost feature.
        try {
            Thread.sleep(5_000)
        } catch (_: InterruptedException) {
            return true
        }

        val out = AdbManager.autoConnectAndRun(context, "id", 25_000L)
        if (!out.startsWith("ERROR")) {
            record(context, "Reconnected after reboot.")
            return false
        }
        val more = attempt < MAX_ATTEMPTS
        record(
            context,
            if (more) {
                "Could not reconnect (try $attempt) — retrying. $out"
            } else {
                "Could not reconnect after $attempt tries. " +
                    "Open this screen and connect once. $out"
            },
        )
        return more
    }
}
