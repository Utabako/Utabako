package io.github.utabako

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService as AndroidVpnService
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences("utabako", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("autostart", false)) return

        if (AndroidVpnService.prepare(context) != null) {
            Log.w(TAG, "Autostart skipped: VPN permission is not granted")
            return
        }

        val config = try {
            ProfileStore(context).getActiveConfig()
        } catch (error: Exception) {
            Log.e(TAG, "Autostart failed to read the active profile", error)
            return
        }
        if (config == null) {
            Log.w(TAG, "Autostart skipped: no active profile")
            return
        }

        try {
            VpnService.start(context, config)
            Log.i(TAG, "VPN autostart initiated")
        } catch (error: Exception) {
            Log.e(TAG, "VPN autostart failed", error)
        }
    }

    companion object {
        private const val TAG = "Utabako/Boot"
    }
}
