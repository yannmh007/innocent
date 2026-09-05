package com.innocent.media

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * Keeps the download engine current without anyone asking.
 *
 * The engine is the part of this app that goes stale on its own: sites change
 * what they accept, the fix ships in yt-dlp within days, and a copy that is
 * months old simply stops working. Checking only when the downloader screen is
 * opened means the check happens least often for exactly the people who use
 * the app rarely — who then find it broken every single time they come back.
 *
 * So the update also runs on a schedule the app takes no part in: once a week,
 * on a connection nobody is paying by the megabyte for, only when idle and
 * charging is not required. It survives a reboot, which matters on phones that
 * are restarted more often than they are used.
 *
 * JobScheduler rather than an alarm: alarms wake the device and cost battery
 * for something that has no deadline at all, while the scheduler is free to
 * wait for a moment that costs the user nothing.
 *
 * Deliberately no new dependency. WorkManager would be the usual answer and
 * would also be another library to fight into a build that is already delicate;
 * JobScheduler is part of Android and does everything needed here.
 */
class EngineUpdateJobService : JobService() {

    companion object {
        private const val JOB_ID = 0xE17E

        /** Once a week. The scheduler may run it later, never much sooner. */
        private const val INTERVAL_MS = 7L * 24 * 60 * 60 * 1000

        /**
         * Registers the job, replacing any previous one. Safe to call on every
         * launch — scheduling the same id twice does not stack up.
         */
        fun schedule(context: Context): Boolean {
            return try {
                val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE)
                    as? JobScheduler ?: return false
                val info = JobInfo.Builder(
                    JOB_ID,
                    ComponentName(context, EngineUpdateJobService::class.java)
                )
                    .setPeriodic(INTERVAL_MS)
                    // Unmetered only: nobody's data allowance pays for a
                    // maintenance download they did not ask for.
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_UNMETERED)
                    // Survive a reboot. Needs RECEIVE_BOOT_COMPLETED, which
                    // this app already declares.
                    .setPersisted(true)
                    .build()
                scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
            } catch (_: Throwable) {
                false
            }
        }
    }

    @Volatile
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters?): Boolean {
        // Off the main thread: this unpacks and downloads. Returning true tells
        // the system the work outlives this call.
        val thread = Thread {
            try {
                DownloadEngine.updateInBackground(applicationContext)
            } catch (_: Throwable) {
                // A failed maintenance update is not worth waking anyone over;
                // the next opening of the app checks again anyway.
            }
            worker = null
            try {
                jobFinished(params, false)
            } catch (_: Throwable) {
            }
        }
        worker = thread
        thread.start()
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        // The system wants its resources back. Don't fight it — say yes to
        // being rescheduled and let the thread finish or die with the process.
        worker?.interrupt()
        worker = null
        return true
    }
}
