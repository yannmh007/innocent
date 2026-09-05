// IUserService.aidl
package com.innocent.media;

/**
 * The interface Innocent exposes INSIDE iADB's privileged server process.
 *
 * When Innocent binds to the installed iADB app (Shizuku-style), iADB launches
 * an instance of our UserService running as the shell user (uid 2000). That
 * process can read Android/data and Android/obb — folders a normal app can't
 * touch on Android 11+. Innocent (the normal app) calls these methods across
 * the binder; the work happens in the privileged process.
 *
 * IMPORTANT: transaction codes are FIXED by the iAdb server contract.
 *  - destroy() MUST be 57320 (iAdb server calls this to tear the service down).
 *  - exit()    is the user-defined exit (1).
 * Our own operations use codes 2+.
 */
interface IUserService {
    // Destroy method defined by the iAdb server — do NOT change this code.
    void destroy() = 57320;

    // Exit method (user-defined).
    void exit() = 1;

    /**
     * Open a file as the privileged (shell) user and return its descriptor.
     * mode uses ParcelFileDescriptor.MODE_* flags (READ_ONLY for playback).
     * Returns null if the path can't be opened.
     */
    ParcelFileDescriptor getFD(String path, int mode) = 2;

    /**
     * Run a shell command in the privileged process and return its combined
     * stdout (truncated to a sane cap on the server side). Used to `find`
     * videos inside Android/data + Android/obb and to `stat` sizes — things the
     * normal app can't enumerate. Returns "" on failure.
     */
    String exec(String command) = 3;

    /**
     * Lightweight liveness/ready check — returns "shell:<uid>" so the client can
     * confirm the privileged process is actually alive (not a half-open binder).
     */
    String ping() = 4;
}
