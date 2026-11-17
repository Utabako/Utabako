package io.github.utabako

import android.app.Activity
import android.content.Intent
import android.net.VpnService as AndroidVpnService
import android.os.Bundle
import android.util.Log
import android.widget.Toast

class VpnPermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val permissionIntent = AndroidVpnService.prepare(this)
        if (permissionIntent == null) {
            startVpn()
        } else {
            startActivityForResult(permissionIntent, VPN_PREPARE_REQUEST)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PREPARE_REQUEST) return
        if (resultCode == RESULT_OK) {
            startVpn()
        } else {
            Toast.makeText(this, "未获得 VPN 授权", Toast.LENGTH_LONG).show()
            finish()
        }
    }

    private fun startVpn() {
        Thread({
            try {
                val config = ProfileStore(this).getActiveConfig()
                if (config == null) {
                    runOnUiThread {
                        Toast.makeText(this, "请先添加并选择配置", Toast.LENGTH_LONG).show()
                        startActivity(Intent(this, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                        })
                    }
                } else {
                    VpnService.start(this, config)
                }
            } catch (error: Exception) {
                Log.e(VpnService.TAG, "Quick settings VPN permission start failed", error)
                runOnUiThread {
                    Toast.makeText(this, error.message, Toast.LENGTH_LONG).show()
                }
            } finally {
                runOnUiThread { finish() }
            }
        }, "UtabakoVpnPermission").start()
    }

    companion object {
        private const val VPN_PREPARE_REQUEST = 1001
    }
}
