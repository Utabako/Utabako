package io.github.utabako

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService as AndroidVpnService
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import android.widget.Toast
import java.util.concurrent.Executors

class VpnTileService : TileService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            updateTile()
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        registerReceiver(
            stateReceiver,
            IntentFilter(VpnService.ACTION_STATE_CHANGED),
            Context.RECEIVER_NOT_EXPORTED
        )
        updateTile()
    }

    override fun onStopListening() {
        unregisterReceiver(stateReceiver)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            unlockAndRun { toggleVpn() }
        } else {
            toggleVpn()
        }
    }

    private fun toggleVpn() {
        val state = VpnService.currentState
        if (state == "starting" || state == "stopping") return
        val stopping = state == "started"
        if (!stopping && AndroidVpnService.prepare(this) != null) {
            openActivity(VpnPermissionActivity::class.java)
            return
        }
        updateTile(if (stopping) "stopping" else "starting")
        ioExecutor.execute {
            try {
                if (stopping) {
                    VpnService.stop(this)
                } else {
                    val config = ProfileStore(this).getActiveConfig()
                    if (config == null) {
                        mainHandler.post {
                            updateTile()
                            Toast.makeText(this, "请先添加并选择配置", Toast.LENGTH_LONG).show()
                            openActivity(MainActivity::class.java)
                        }
                        return@execute
                    }
                    VpnService.start(this, config)
                }
            } catch (error: Exception) {
                Log.e(VpnService.TAG, "Quick settings VPN toggle failed", error)
                mainHandler.post {
                    updateTile()
                    Toast.makeText(this, error.message, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun updateTile(state: String = VpnService.currentState) {
        val tile = qsTile ?: return
        tile.state = when (state) {
            "started" -> Tile.STATE_ACTIVE
            "starting", "stopping" -> Tile.STATE_UNAVAILABLE
            else -> Tile.STATE_INACTIVE
        }
        val description = when (state) {
            "started" -> "已连接"
            "starting" -> "正在连接"
            "stopping" -> "正在断开"
            "stopped" -> "未连接"
            else -> "连接失败"
        }
        tile.label = "Utabako"
        tile.subtitle = description
        tile.stateDescription = description
        tile.contentDescription = "Utabako，$description"
        tile.updateTile()
    }

    private fun openActivity(activity: Class<out android.app.Activity>) {
        val intent = Intent(this, activity).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        startActivityAndCollapse(
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        )
    }

    override fun onDestroy() {
        ioExecutor.shutdown()
        super.onDestroy()
    }
}
