package io.github.utabako

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService as AndroidVpnService
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import libbox.Libbox
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        // One process-wide limit, including queued calls from a previous activity.
        private val urlTestExecutor = Executors.newFixedThreadPool(10) {
            Thread(it, "UtabakoURLTest")
        }
    }

    private val CHANNEL = "io.github.utabako/vpn"
    private val VPN_PREPARE_REQUEST = 1001

    private var channel: MethodChannel? = null
    private var pendingConfig: String? = null
    private val profileStore by lazy { ProfileStore(this) }
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private data class EncodedOutbounds(
        val groups: List<VpnService.OutboundGroupData>,
        val json: String
    )

    // Accessed only by the single-threaded IO executor.
    private var encodedOutbounds: EncodedOutbounds? = null

    private val vpnStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val state = intent?.getStringExtra("state") ?: return
            channel?.invokeMethod("onStateChanged", state)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "setup" -> runIo(result) {
                    LibboxRuntime.ensureInitialized(this)
                    null
                }
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("NO_CONFIG", "Config is required", null)
                        return@setMethodCallHandler
                    }
                    startVpn(config, result)
                }
                "stop" -> {
                    stopVpn()
                    result.success(null)
                }
                "isRunning" -> result.success(VpnService.isRunning)
                "version" -> result.success(Libbox.version())
                "appVersion" -> result.success(
                    packageManager.getPackageInfo(packageName, 0).let {
                        "${it.versionName} (${it.longVersionCode})"
                    }
                )
                "zerotierStatus" -> runIo(result, operation = Libbox::getZeroTierStatus)
                "exportLog" -> runIo(result) {
                    val logFile = File(filesDir, "sing-box/box.log")
                    require(logFile.exists()) { "box.log not found" }
                    val destination = File(getExternalFilesDir(null), "box.log")
                    logFile.copyTo(destination, overwrite = true)
                    destination.absolutePath
                }
                "checkConfig" -> {
                    val config = call.argument<String>("config") ?: ""
                    runIo(result) {
                        Libbox.checkConfig(config)
                        null
                    }
                }
                "listProfiles" -> runIo(result) {
                    profileStore.list().toString()
                }
                "getProfile" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("NO_ID", "Profile ID is required", null)
                        return@setMethodCallHandler
                    }
                    runIo(result) { profileStore.get(id) }
                }
                "saveProfile" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error("NO_CONFIG", "Config is required", null)
                        return@setMethodCallHandler
                    }
                    val id = call.argument<String>("id")
                    val name = call.argument<String>("name") ?: "Unnamed"
                    val url = call.argument<String>("url")
                    runIo(result) {
                        val preparedConfig = Libbox.prepareRuleSets(config).value
                        profileStore.save(id, name, preparedConfig, url)
                    }
                }
                "deleteProfile" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("NO_ID", "Profile ID is required", null)
                        return@setMethodCallHandler
                    }
                    runIo(result) {
                        profileStore.delete(id)
                        null
                    }
                }
                "setActiveProfile" -> {
                    val id = call.argument<String>("id")
                    if (id == null) {
                        result.error("NO_ID", "Profile ID is required", null)
                        return@setMethodCallHandler
                    }
                    runIo(result) {
                        profileStore.setActive(id)
                        null
                    }
                }
                "readLog" -> runIo(result, operation = ::readLogTail)
                "clearLog" -> runIo(result) {
                    val logFile = File(filesDir, "sing-box/box.log")
                    if (logFile.exists()) logFile.writeText("")
                    null
                }
                "getState" -> result.success(VpnService.currentState)
                "getStartupStage" -> runIo(result) { VpnService.startupStage }
                "getStartedAt" -> result.success(VpnService.startedAtMillis)
                "queryOutbounds" -> runIo(result) {
                    val groups = VpnService.cachedGroups
                    val previous = encodedOutbounds
                    if (previous != null && previous.groups == groups) {
                        return@runIo previous.json
                    }
                    val arr = org.json.JSONArray()
                    for (group in groups) {
                        val items = org.json.JSONArray()
                        group.items.forEach { item ->
                            items.put(JSONObject().apply {
                                put("tag", item.tag)
                                put("urlTestResult", item.urlTestResult?.let { testResult ->
                                    JSONObject().apply {
                                        put("time", testResult.time)
                                        put("delay", testResult.delay)
                                        put("success", testResult.success)
                                        put("error", testResult.error)
                                    }
                                } ?: JSONObject.NULL)
                            })
                        }
                        arr.put(JSONObject().apply {
                            put("tag", group.tag)
                            put("type", group.type)
                            put("now", group.selected)
                            put("selectable", group.selectable)
                            put("items", items)
                        })
                    }
                    val json = arr.toString()
                    encodedOutbounds = EncodedOutbounds(groups, json)
                    json
                }
                "selectOutbound" -> {
                    val groupTag = call.argument<String>("groupTag")
                    val outboundTag = call.argument<String>("outboundTag")
                    if (groupTag == null || outboundTag == null) {
                        result.error("INVALID_ARGS", "groupTag and outboundTag required", null)
                        return@setMethodCallHandler
                    }
                    runIo(result) {
                        val client = VpnService.commandClient
                            ?: throw IllegalStateException("VPN command client is not connected")
                        client.selectOutbound(groupTag, outboundTag)
                        null
                    }
                }
                "urlTest" -> {
                    val outboundTag = call.argument<String>("outboundTag")
                    if (outboundTag == null) {
                        result.error("INVALID_ARGS", "outboundTag required", null)
                        return@setMethodCallHandler
                    }
                    val client = VpnService.commandClient
                    runIo(result, executor = urlTestExecutor) {
                        if (client == null) {
                            throw IllegalStateException("VPN command client is not connected")
                        }
                        val iterator = client.urlTestWithResult(outboundTag)
                        val items = JSONArray()
                        while (iterator.hasNext()) {
                            val item = iterator.next()
                            val testResult = item.urlTestResult
                            items.put(JSONObject().apply {
                                put("tag", item.tag)
                                put("urlTestResult", JSONObject().apply {
                                    put("time", testResult.time)
                                    put("delay", testResult.delay)
                                    put("success", testResult.success)
                                    put("error", testResult.error)
                                })
                            })
                        }
                        items.toString()
                    }
                }
                "queryTrafficStats" -> runIo(result) {
                    val history = VpnService.trafficHistory
                    val samples = JSONArray()
                    for (sample in history) {
                        samples.put(JSONObject().apply {
                            put("uplink", sample.uplink)
                            put("downlink", sample.downlink)
                            put("uplinkTotal", sample.uplinkTotal)
                            put("downlinkTotal", sample.downlinkTotal)
                            put("connectionsIn", sample.connectionsIn)
                            put("connectionsOut", sample.connectionsOut)
                        })
                    }
                    samples.toString()
                }
                "getInstalledApps" -> runIo(result, operation = ::getLauncherAppsJson)
                "getPerAppProxy" -> {
                    val prefs = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                    result.success(
                        prefs.getString("perAppProxy", PerAppProxyPolicy.ALL.toJson())
                    )
                }
                "setPerAppProxy" -> {
                    val json = call.argument<String>("config")
                    if (json == null) {
                        result.error("NO_CONFIG", "config required", null)
                        return@setMethodCallHandler
                    }
                    val policy = try {
                        PerAppProxyPolicy.parse(json)
                    } catch (error: Exception) {
                        result.error("INVALID_PER_APP_PROXY", error.message, null)
                        return@setMethodCallHandler
                    }
                    runIo(result) {
                        val saved = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                            .edit()
                            .putString("perAppProxy", policy.toJson())
                            .commit()
                        check(saved) { "Failed to persist per-app proxy settings" }
                        null
                    }
                }
                "getDisableIpv6" -> {
                    val prefs = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                    result.success(prefs.getBoolean("disableIpv6", false))
                }
                "setDisableIpv6" -> {
                    val disabled = call.argument<Boolean>("disabled")
                    if (disabled == null) {
                        result.error("INVALID_ARGS", "disabled required", null)
                        return@setMethodCallHandler
                    }
                    runIo(result) {
                        val saved = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                            .edit()
                            .putBoolean("disableIpv6", disabled)
                            .commit()
                        check(saved) { "Failed to persist IPv6 setting" }
                        null
                    }
                }
                "getAutostart" -> {
                    val prefs = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                    result.success(prefs.getBoolean("autostart", false))
                }
                "setAutostart" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    getSharedPreferences("utabako", Context.MODE_PRIVATE)
                        .edit().putBoolean("autostart", enabled).apply()
                    result.success(null)
                }
                "getThemeMode" -> {
                    val prefs = getSharedPreferences("utabako", Context.MODE_PRIVATE)
                    result.success(prefs.getString("themeMode", "system"))
                }
                "setThemeMode" -> {
                    val mode = call.argument<String>("mode") ?: "system"
                    getSharedPreferences("utabako", Context.MODE_PRIVATE)
                        .edit().putString("themeMode", mode).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }


    private fun startVpn(config: String, result: MethodChannel.Result) {
        val permissionIntent = AndroidVpnService.prepare(this)
        if (permissionIntent != null) {
            pendingConfig = config
            startActivityForResult(permissionIntent, VPN_PREPARE_REQUEST)
            result.success(null)
            return
        }
        try {
            VpnService.start(this, config)
            result.success(null)
        } catch (error: Exception) {
            result.error("START_FAILED", error.message, null)
        }
    }

    private fun stopVpn() {
        if (pendingConfig != null) {
            pendingConfig = null
            channel?.invokeMethod("onStateChanged", VpnService.currentState)
        } else {
            VpnService.stop(this)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_PREPARE_REQUEST) return
        val config = pendingConfig ?: return
        pendingConfig = null
        if (resultCode == Activity.RESULT_OK) {
            try {
                VpnService.start(this, config)
            } catch (error: Exception) {
                channel?.invokeMethod(
                    "onStateChanged",
                    "error:${error.message ?: "VPN start failed"}"
                )
            }
        } else {
            channel?.invokeMethod("onStateChanged", "error:VPN permission denied")
        }
    }

    override fun onResume() {
        super.onResume()
        registerReceiver(
            vpnStateReceiver,
            IntentFilter(VpnService.ACTION_STATE_CHANGED),
            Context.RECEIVER_NOT_EXPORTED
        )
        channel?.invokeMethod("onStateChanged", VpnService.currentState)
    }

    override fun onPause() {
        super.onPause()
        try {
            unregisterReceiver(vpnStateReceiver)
        } catch (_: IllegalArgumentException) {
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun <T> runIo(
        result: MethodChannel.Result,
        executor: Executor = ioExecutor,
        operation: () -> T
    ) {
        executor.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post { result.error("ERROR", error.message, null) }
            }
        }
    }

    private fun readLogTail(): String {
        val logFile = File(filesDir, "sing-box/box.log")
        if (!logFile.exists()) return ""
        val maxBytes = 64 * 1024L
        if (logFile.length() <= maxBytes) return logFile.readText()
        return logFile.inputStream().use { stream ->
            stream.skip(logFile.length() - maxBytes)
            stream.bufferedReader().readText()
        }
    }

    private fun getLauncherAppsJson(): String {
        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val apps = queryLauncherActivities(launcherIntent)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .map { app ->
                app.packageName to packageManager.getApplicationLabel(app).toString()
            }
            .sortedBy { (_, label) -> label.lowercase() }
        return org.json.JSONArray().apply {
            for ((packageName, label) in apps) {
                put(JSONObject().apply {
                    put("packageName", packageName)
                    put("label", label)
                })
            }
        }.toString()
    }

    private fun queryLauncherActivities(intent: Intent) =
        packageManager.queryIntentActivities(
            intent,
            android.content.pm.PackageManager.ResolveInfoFlags.of(0)
        )
}
