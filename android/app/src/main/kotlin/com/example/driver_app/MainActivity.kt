package com.projectworlds.driver_app

import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The bits of §7 Layer 1 that Flutter cannot see for itself.
 *
 * permission_handler already covers location, notifications, exact alarms and
 * the battery-optimisation exemption. What is left is device-specific and has
 * no plugin worth adding a dependency for:
 *
 *  - OEM autostart. The single biggest cause of dead tracking in the field, and
 *    there is NO API to read its state — only a per-manufacturer settings screen
 *    to open. That is why the Dart side treats it as "acknowledge", never as a
 *    check it can verify.
 *  - Automatic date & time. A handset with a wrong clock silently mis-fires
 *    every local alarm, and the driver has no way of knowing.
 *  - Battery level for the liveness heartbeat (Layer 5).
 */
class MainActivity : FlutterActivity() {

    private val channelName = "pw.driver/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAutoTimeEnabled" -> result.success(isAutoTimeEnabled())
                    "openDateTimeSettings" -> result.success(openDateTimeSettings())
                    "hasAutostartSettings" -> result.success(autostartIntent() != null)
                    "openAutostartSettings" -> result.success(openAutostartSettings())
                    "manufacturer" -> result.success(Build.MANUFACTURER ?: "")
                    "batteryStatus" -> result.success(batteryStatus())
                    "openChannelSettings" ->
                        result.success(openChannelSettings(call.argument<String>("channelId")))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Reads Settings.Global.AUTO_TIME. Anything other than an explicit 0 counts
     * as on, because a device that will not answer must not be reported as
     * misconfigured — a false red row trains drivers to ignore the screen.
     */
    private fun isAutoTimeEnabled(): Boolean = try {
        Settings.Global.getInt(contentResolver, Settings.Global.AUTO_TIME, 1) != 0
    } catch (e: Exception) {
        true
    }

    private fun openDateTimeSettings(): Boolean = try {
        startActivity(Intent(Settings.ACTION_DATE_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        true
    } catch (e: Exception) {
        false
    }

    /**
     * Per-manufacturer autostart / protected-app screens.
     *
     * These are undocumented internal activities: they get renamed between
     * firmware versions, so every candidate is checked against the package
     * manager first and a miss simply means the row falls back to a generic
     * "open app settings" fix rather than crashing the app.
     */
    private fun autostartIntent(): Intent? {
        val candidates = listOf(
            // Xiaomi / Redmi / POCO
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // Oppo / Realme
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            // Vivo / iQOO
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            // Huawei / Honor
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
            // Samsung
            "com.samsung.android.lool" to "com.samsung.android.sm.ui.battery.BatteryActivity",
            // Letv / OnePlus / Asus / Nokia
            "com.letv.android.letvsafe" to "com.letv.android.letvsafe.AutobootManageActivity",
            "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            "com.asus.mobilemanager" to "com.asus.mobilemanager.autostart.AutoStartActivity",
            "com.transsion.phonemaster" to "com.itel.autoboot.AutoBootActivity"
        )

        for ((pkg, cls) in candidates) {
            val intent = Intent().setComponent(ComponentName(pkg, cls))

            if (packageManager.resolveActivity(intent, 0) != null) {
                return intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        return null
    }

    private fun openAutostartSettings(): Boolean {
        val intent = autostartIntent() ?: return false

        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Straight to the "Trip Alarms" channel, not the app's notification list.
     *
     * A muted channel is one toggle deep inside a screen most drivers will not
     * find; §7 Layer 1 promises a one-tap fix for every red row, and a generic
     * "open settings" is not that. Falls back to the app-level screen on the
     * pre-Oreo devices that have no channels at all.
     */
    private fun openChannelSettings(channelId: String?): Boolean = try {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && channelId != null) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        }

        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
    }

    /**
     * Sticky ACTION_BATTERY_CHANGED rather than BatteryManager.isCharging:
     * the broadcast is readable on every API level this app supports, and it
     * carries level and charge state in one shot.
     */
    private fun batteryStatus(): Map<String, Any?> {
        return try {
            val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                ?: return mapOf("level" to null, "is_charging" to null)

            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)

            mapOf(
                "level" to if (level >= 0 && scale > 0) level * 100 / scale else null,
                "is_charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL)
            )
        } catch (e: Exception) {
            mapOf("level" to null, "is_charging" to null)
        }
    }
}
