package com.innocent.media

import android.content.ComponentName
import android.content.ServiceConnection
import android.content.pm.PackageManager
import androidx.annotation.RequiresApi
import com.iadb.Iadb

/**
 * The ONLY class in Innocent that references `com.iadb.*`.
 *
 * The iADB client libraries require Android 11 (API 30); Innocent supports API
 * 24. Android's class verifier loads and verifies a class the first time it's
 * referenced, and a class that references API-30 symbols can fail to verify on
 * older devices. By funnelling every com.iadb.* call through this one class, and
 * only ever calling into it from [IadbClient] methods that have already checked
 * `Build.VERSION.SDK_INT >= R`, the iADB classes are never loaded on API < 30 —
 * so nothing to verify, nothing to crash. [IadbClient] holds no com.iadb.* field
 * or lambda, so merely touching IadbClient on an old device is safe.
 *
 * @RequiresApi(30) documents the contract; the real guarantee is that callers
 * gate on the API level before reaching here.
 */
@RequiresApi(30)
internal object IadbBridge {

    const val PERM_GRANTED = 0
    const val PERM_SHOULD_EXPLAIN = 1
    const val PERM_NEEDS_REQUEST = 2

    fun pingBinder(): Boolean = Iadb.pingBinder()

    fun registerListeners(
        onBinderReceived: () -> Unit,
        onBinderDead: () -> Unit,
        onPermissionResult: (granted: Boolean) -> Unit,
    ) {
        Iadb.addBinderReceivedListener { onBinderReceived() }
        Iadb.addBinderDeadListener { onBinderDead() }
        Iadb.addRequestPermissionResultListener { _, grantResult ->
            onPermissionResult(grantResult == PackageManager.PERMISSION_GRANTED)
        }
    }

    fun permissionState(): Int = when {
        Iadb.checkSelfPermission() == PackageManager.PERMISSION_GRANTED ->
            PERM_GRANTED
        Iadb.shouldShowRequestPermissionRationale() -> PERM_SHOULD_EXPLAIN
        else -> PERM_NEEDS_REQUEST
    }

    fun requestPermission(code: Int) = Iadb.requestPermission(code)

    fun bindUserService(
        packageName: String,
        userServiceClassName: String,
        connection: ServiceConnection,
    ) {
        Iadb.bindUserService(buildArgs(packageName, userServiceClassName), connection)
    }

    fun unbindUserService(
        packageName: String,
        userServiceClassName: String,
        connection: ServiceConnection,
    ) {
        Iadb.unbindUserService(
            buildArgs(packageName, userServiceClassName), connection, true,
        )
    }

    private fun buildArgs(
        packageName: String,
        userServiceClassName: String,
    ): Iadb.UserServiceArgs =
        Iadb.UserServiceArgs(ComponentName(packageName, userServiceClassName))
            .daemon(false)
            .processNameSuffix("iadb")
            .debuggable(false)
            .version(1)
}
