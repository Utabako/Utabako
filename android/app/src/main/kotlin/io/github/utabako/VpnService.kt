package io.github.utabako

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService as AndroidVpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import libbox.*
import java.io.File

class VpnService : AndroidVpnService(), PlatformInterface, CommandServerHandler {

    private enum class LifecycleState(val wireValue: String) {
        STOPPED("stopped"),
        STARTING("starting"),
        STARTED("started"),
        STOPPING("stopping"),
        ERROR("error")
    }

    companion object {
        const val TAG = "UtabakoVpn"
        const val ACTION_START = "io.github.utabako.START"
        const val ACTION_STOP = "io.github.utabako.STOP"
        const val ACTION_STATE_CHANGED = "io.github.utabako.VPN_STATE"
        private const val EXTRA_CONFIG_PATH = "configPath"
        const val EXTRA_PER_APP_PROXY = "perAppProxy"
        const val NOTIFICATION_CHANNEL = "vpn_service"
        const val NOTIFICATION_ID = 1

        @Volatile
        private var lifecycleState = LifecycleState.STOPPED

        @Volatile
        private var stateError: String? = null

        val currentState: String
            get() = if (lifecycleState == LifecycleState.ERROR) {
                "error:${stateError ?: "Unknown VPN error"}"
            } else {
                lifecycleState.wireValue
            }

        val isRunning: Boolean
            get() = lifecycleState == LifecycleState.STARTED

        /** Wall-clock time (epoch millis) when the service last entered STARTED; null while not started. */
        @Volatile
        var startedAtMillis: Long? = null
            private set

        @Volatile
        var commandClient: CommandClient? = null
            private set

        @Volatile
        var cachedGroups: List<OutboundGroupData> = emptyList()
            private set

        @Volatile
        var trafficHistory: List<TrafficSample> = emptyList()
            private set

        fun start(context: android.content.Context, config: String) {
            require(config.isNotBlank()) { "VPN config is required" }
            val appContext = context.applicationContext
            val prefs = appContext.getSharedPreferences("utabako", MODE_PRIVATE)
            val policy = PerAppProxyPolicy.parse(
                prefs.getString("perAppProxy", PerAppProxyPolicy.ALL.toJson())
                    ?: PerAppProxyPolicy.ALL.toJson()
            )
            val configFile = File.createTempFile("vpn-start-", ".json", appContext.cacheDir)
            try {
                configFile.writeText(config)
                val intent = Intent(appContext, VpnService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_CONFIG_PATH, configFile.absolutePath)
                    putExtra(EXTRA_PER_APP_PROXY, policy.toJson())
                }
                appContext.startForegroundService(intent)
            } catch (error: Throwable) {
                configFile.delete()
                throw error
            }
        }

        fun stop(context: android.content.Context) {
            val appContext = context.applicationContext
            appContext.startService(
                Intent(appContext, VpnService::class.java).apply {
                    action = ACTION_STOP
                }
            )
        }
    }

    data class OutboundGroupData(
        val tag: String,
        val type: String,
        val selected: String,
        val selectable: Boolean,
        val items: List<OutboundGroupItemData>
    )

    data class OutboundGroupItemData(
        val tag: String,
        val urlTestResult: UrlTestResultData?
    )

    data class UrlTestResultData(
        val time: Long,
        val delay: Int,
        val success: Boolean,
        val error: String
    )

    data class TrafficSample(
        val uplink: Long,
        val downlink: Long,
        val uplinkTotal: Long,
        val downlinkTotal: Long,
        val connectionsIn: Int,
        val connectionsOut: Int
    )

    @Volatile
    private var perAppProxyPolicy = PerAppProxyPolicy.ALL
    @Volatile
    private var disableIpv6 = false
    private var commandServer: CommandServer? = null
    private var conn: ParcelFileDescriptor? = null
    private var interfaceUpdateListener: InterfaceUpdateListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile
    private var defaultNetwork: Network? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lifecycleExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val commandClientLock = Any()

    @Volatile
    private var runGeneration = 0

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground()
        when (intent?.action) {
            ACTION_START -> {
                val configPath = intent.getStringExtra(EXTRA_CONFIG_PATH)
                val policyJson = intent.getStringExtra(EXTRA_PER_APP_PROXY)
                if (configPath == null || policyJson == null) {
                    configPath?.let { File(it).delete() }
                    publishState(LifecycleState.ERROR, "Incomplete VPN start request")
                    stopSelfResult(startId)
                    return START_NOT_STICKY
                }
                lifecycleExecutor.execute {
                    startBox(File(configPath), policyJson, startId)
                }
            }
            ACTION_STOP -> lifecycleExecutor.execute {
                stopBox(startId)
            }
            else -> lifecycleExecutor.execute {
                stopBox(startId)
            }
        }
        return START_NOT_STICKY
    }

    private fun startForeground() {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, VpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setContentTitle("Utabako")
            .setContentText("VPN is running")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_delete, "Disconnect", disconnectIntent)
            .setOngoing(true)
            .build()
        startForeground(
            NOTIFICATION_ID,
            notification,
            android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        )
    }

    @Synchronized
    private fun startBox(configFile: File, policyJson: String, startId: Int) {
        if (lifecycleState == LifecycleState.STARTED ||
            lifecycleState == LifecycleState.STARTING
        ) {
            configFile.delete()
            return
        }

        val generation = synchronized(commandClientLock) {
            trafficHistory = emptyList()
            ++runGeneration
        }
        publishState(LifecycleState.STARTING)
        try {
            val config = configFile.readText()
            LibboxRuntime.ensureInitialized(this)
            perAppProxyPolicy = PerAppProxyPolicy.parse(policyJson)
            disableIpv6 = getSharedPreferences("utabako", MODE_PRIVATE)
                .getBoolean("disableIpv6", false)

            val server = Libbox.newCommandServer(this, this)
            commandServer = server
            server.start()
            val overrides = OverrideOptions().apply {
                disableIPv6 = disableIpv6
            }
            server.startOrReloadService(config, overrides)

            if (generation != runGeneration) {
                cleanupResources()
                return
            }
            publishState(LifecycleState.STARTED)
            Log.i(TAG, "sing-box started")
            startCommandClient(generation)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to start sing-box", error)
            cleanupResources()
            publishState(
                LifecycleState.ERROR,
                error.message ?: error.javaClass.simpleName
            )
            stopSelfResult(startId)
        } finally {
            configFile.delete()
        }
    }

    private fun startCommandClient(generation: Int) {
        Thread({
            var client: CommandClient? = null
            try {
                val options = CommandClientOptions().apply {
                    addCommand(Libbox.CommandGroup)
                    addCommand(Libbox.CommandStatus)
                    setStatusInterval(1_000_000_000L)
                }
                client = Libbox.newCommandClient(ClientHandler(generation), options)
                val active = synchronized(commandClientLock) {
                    if (isGenerationActive(generation)) {
                        commandClient = client
                        true
                    } else {
                        false
                    }
                }
                if (!active) {
                    client.disconnect()
                    return@Thread
                }
                client.connect()
            } catch (error: Exception) {
                Log.w(TAG, "CommandClient connect failed: ${error.message}")
                synchronized(commandClientLock) {
                    if (commandClient === client) commandClient = null
                }
            }
        }, "UtabakoCommandClient").start()
    }

    private fun isGenerationActive(generation: Int): Boolean =
        generation == runGeneration && lifecycleState == LifecycleState.STARTED

    private inner class ClientHandler(
        private val generation: Int
    ) : CommandClientHandler {
        override fun connected() {
            Log.d(TAG, "CommandClient connected")
        }

        override fun disconnected(message: String) {
            Log.d(TAG, "CommandClient disconnected: $message")
            synchronized(commandClientLock) {
                if (generation != runGeneration) return
                commandClient = null
                cachedGroups = emptyList()
                trafficHistory = emptyList()
            }
        }

        override fun writeGroups(iterator: OutboundGroupIterator) {
            if (!isGenerationActive(generation)) return
            val groups = mutableListOf<OutboundGroupData>()
            while (iterator.hasNext()) {
                val group = iterator.next()
                val items = mutableListOf<OutboundGroupItemData>()
                val itemIterator = group.getItems()
                while (itemIterator.hasNext()) {
                    val item = itemIterator.next()
                    val testResult = item.urlTestResult?.let {
                        UrlTestResultData(it.time, it.delay, it.success, it.error)
                    }
                    items.add(OutboundGroupItemData(item.tag, testResult))
                }
                groups.add(
                    OutboundGroupData(
                        group.tag,
                        group.type,
                        group.selected,
                        group.selectable,
                        items
                    )
                )
            }
            cachedGroups = groups
        }

        override fun writeStatus(status: StatusMessage) {
            val sample = TrafficSample(
                status.uplink,
                status.downlink,
                status.uplinkTotal,
                status.downlinkTotal,
                status.connectionsIn,
                status.connectionsOut
            )
            synchronized(commandClientLock) {
                if (!isGenerationActive(generation) || commandClient == null) return
                trafficHistory = java.util.Collections.unmodifiableList(
                    (trafficHistory + sample).takeLast(60)
                )
            }
        }

        override fun writeLogs(logs: LogIterator) {}
        override fun writeOutbounds(outbounds: OutboundGroupItemIterator) {}
        override fun writeConnectionEvents(events: ConnectionEvents) {}
        override fun initializeClashMode(modes: StringIterator, current: String) {}
        override fun updateClashMode(mode: String) {}
        override fun clearLogs() {}
        override fun setDefaultLogLevel(level: Int) {}
    }

    private fun stopBox(startId: Int? = null) {
        if (lifecycleState != LifecycleState.STOPPED) {
            publishState(LifecycleState.STOPPING)
        }
        synchronized(commandClientLock) {
            runGeneration++
        }
        cleanupResources()
        publishState(LifecycleState.STOPPED)
        if (startId == null) {
            stopSelf()
        } else {
            stopSelfResult(startId)
        }
    }

    @Synchronized
    private fun cleanupResources() {
        val client = synchronized(commandClientLock) {
            cachedGroups = emptyList()
            trafficHistory = emptyList()
            commandClient.also { commandClient = null }
        }
        try {
            client?.disconnect()
        } catch (_: Exception) {
        }

        try {
            commandServer?.closeService()
        } catch (error: Exception) {
            Log.e(TAG, "Failed to close service", error)
        }
        try {
            commandServer?.close()
        } catch (_: Exception) {
        }
        commandServer = null

        try {
            conn?.close()
        } catch (_: Exception) {
        }
        conn = null
        closeNetworkCallback()
    }

    private fun publishState(state: LifecycleState, error: String? = null) {
        synchronized(commandClientLock) {
            stateError = error
            if (state == LifecycleState.STARTED) {
                if (lifecycleState != LifecycleState.STARTED) startedAtMillis = System.currentTimeMillis()
            } else {
                startedAtMillis = null
                trafficHistory = emptyList()
            }
            lifecycleState = state
        }
        sendBroadcast(
            Intent(ACTION_STATE_CHANGED).apply {
                setPackage(packageName)
                putExtra("state", currentState)
            }
        )
    }

    override fun onDestroy() {
        lifecycleExecutor.shutdownNow()
        synchronized(commandClientLock) {
            runGeneration++
        }
        cleanupResources()
        if (lifecycleState != LifecycleState.ERROR &&
            lifecycleState != LifecycleState.STOPPED
        ) {
            publishState(LifecycleState.STOPPED)
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        lifecycleExecutor.execute { stopBox() }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL,
            "VPN Service",
            NotificationManager.IMPORTANCE_LOW
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    // --- PlatformInterface ---

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(tunOptions: TunOptions): Int {
        val builder = Builder().apply {
            setSession("Utabako")
            setMtu(tunOptions.mtu.takeIf { it > 0 } ?: 9000)

            val inet4Address = tunOptions.inet4Address
            while (inet4Address.hasNext()) {
                val prefix = inet4Address.next()
                addAddress(prefix.address(), prefix.prefix())
            }
            // Android blocks IPv6 only when no address, route or DNS server enables it.
            if (!disableIpv6) {
                val inet6Address = tunOptions.inet6Address
                while (inet6Address.hasNext()) {
                    val prefix = inet6Address.next()
                    addAddress(prefix.address(), prefix.prefix())
                }
            }

            if (tunOptions.autoRoute) {
                val inet4Route = tunOptions.inet4RouteAddress
                if (inet4Route.hasNext()) {
                    while (inet4Route.hasNext()) {
                        val prefix = inet4Route.next()
                        addRoute(prefix.address(), prefix.prefix())
                    }
                } else {
                    addRoute("0.0.0.0", 0)
                }
                if (!disableIpv6) {
                    val inet6Route = tunOptions.inet6RouteAddress
                    if (inet6Route.hasNext()) {
                        while (inet6Route.hasNext()) {
                            val prefix = inet6Route.next()
                            addRoute(prefix.address(), prefix.prefix())
                        }
                    } else {
                        addRoute("::", 0)
                    }
                }
            }

            if (tunOptions.getDNSMode().value != Libbox.DNSModeDisabled) {
                val dnsServers = tunOptions.getDNSServerAddress()
                while (dnsServers.hasNext()) {
                    val address = android.net.InetAddresses.parseNumericAddress(dnsServers.next())
                    if (!disableIpv6 || address is java.net.Inet4Address) {
                        addDnsServer(address)
                    }
                }
            }

            val policy = perAppProxyPolicy
            var configuredIncludes = 0
            var configuredAllowedApplications = 0
            val includePackage = tunOptions.includePackage
            while (includePackage.hasNext()) {
                val packageName = includePackage.next()
                configuredIncludes++
                if (policy.mode == PerAppProxyMode.ALL) {
                    try {
                        addAllowedApplication(packageName)
                        configuredAllowedApplications++
                    } catch (_: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "Configured include package is not installed: $packageName")
                    }
                }
            }
            val excludePackage = tunOptions.excludePackage
            while (excludePackage.hasNext()) {
                val packageName = excludePackage.next()
                if (policy.mode == PerAppProxyMode.ALL) {
                    try {
                        addDisallowedApplication(packageName)
                    } catch (_: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "Configured exclude package is not installed: $packageName")
                    }
                }
            }

            if (policy.mode == PerAppProxyMode.ALL && configuredIncludes > 0) {
                check(configuredAllowedApplications > 0) {
                    "Configured include packages are not installed"
                }
            }

            when (policy.mode) {
                PerAppProxyMode.ALL -> Unit
                PerAppProxyMode.INCLUDE -> {
                    var allowedApplications = 0
                    for (packageName in policy.packages) {
                        try {
                            addAllowedApplication(packageName)
                            allowedApplications++
                        } catch (_: PackageManager.NameNotFoundException) {
                            Log.w(TAG, "Selected include package is not installed: $packageName")
                        }
                    }
                    check(allowedApplications > 0) {
                        "Include mode has no installed applications"
                    }
                }
                PerAppProxyMode.EXCLUDE -> {
                    for (packageName in policy.packages) {
                        try {
                            addDisallowedApplication(packageName)
                        } catch (_: PackageManager.NameNotFoundException) {
                            Log.w(TAG, "Selected exclude package is not installed: $packageName")
                        }
                    }
                }
            }

            // Exclude ZeroTier planet server IPs from VPN routing.
            // protect() doesn't work reliably on some devices (e.g. Xiaomi Android 16),
            // so we exclude planet IPs at the routing level.
            try {
                val planetIPs = Libbox.getZeroTierPlanetIPs()
                if (planetIPs.isNotEmpty()) {
                    for (ip in planetIPs.split(",")) {
                        val trimmed = ip.trim()
                        if (trimmed.isNotEmpty()) {
                            val address = java.net.InetAddress.getByName(trimmed)
                            if (disableIpv6 && address is java.net.Inet6Address) continue
                            val prefixLength = when (address) {
                                is java.net.Inet4Address -> 32
                                is java.net.Inet6Address -> 128
                                else -> throw IllegalArgumentException("Unsupported planet address: $trimmed")
                            }
                            excludeRoute(android.net.IpPrefix(address, prefixLength))
                            Log.i(TAG, "Excluded planet route: $trimmed/$prefixLength")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to exclude planet routes: ${e.message}")
            }
        }

        conn?.close()
        conn = builder.establish() ?: throw Exception("VPN permission not granted")
        return conn!!.fd
    }

    override fun sendNotification(notification: Notification) {
        // Minimal: use foreground notification
    }

    override fun cancelNotification(identifier: String, typeID: Int) {
        getSystemService(NotificationManager::class.java).cancel(identifier, typeID)
    }

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {
        throw UnsupportedOperationException("Neighbor monitoring is not supported")
    }

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun registerMyInterface(name: String) {
        // libbox's interface monitor already records the TUN interface.
    }

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {
        throw UnsupportedOperationException("Platform shell is not supported")
    }

    override fun openShellSession(
        user: PlatformUser,
        command: String,
        environ: StringIterator,
        term: String,
        rows: Int,
        cols: Int
    ): ShellSession {
        throw UnsupportedOperationException("Platform shell is not supported")
    }

    override fun lookupUser(username: String): PlatformUser {
        throw UnsupportedOperationException("Platform users are not supported")
    }

    override fun lookupSFTPServer(): String {
        throw UnsupportedOperationException("SFTP server is not supported")
    }

    override fun readSystemSSHHostKey(): String {
        throw UnsupportedOperationException("System SSH host keys are not supported")
    }

    override fun tailscaleHostname(): String = Build.MODEL

    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(options: BridgeOptions): BridgeSession {
        throw UnsupportedOperationException("Platform bridge is not supported")
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState = Libbox.newWIFIState("", "")

    override fun findConnectionOwner(ipProto: Int, srcIp: String, srcPort: Int, destIp: String, destPort: Int): ConnectionOwner {
        val owner = ConnectionOwner()
        val connectivityManager = getSystemService(ConnectivityManager::class.java)
        if (connectivityManager != null) {
            try {
                val uid = connectivityManager.getConnectionOwnerUid(
                    ipProto,
                    java.net.InetSocketAddress(srcIp, srcPort),
                    java.net.InetSocketAddress(destIp, destPort)
                )
                owner.userId = uid
                val packages = packageManager.getPackagesForUid(uid)
                if (packages != null && packages.isNotEmpty()) {
                    owner.processPath = packages[0]
                }
            } catch (_: Exception) {}
        }
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        closeNetworkCallback()
        interfaceUpdateListener = listener
        val connectivityManager =
            getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                notifyDefaultInterface(connectivityManager, network)
            }

            override fun onLinkPropertiesChanged(
                network: Network,
                linkProperties: LinkProperties
            ) {
                notifyDefaultInterface(connectivityManager, network)
            }

            override fun onCapabilitiesChanged(
                network: Network,
                caps: NetworkCapabilities
            ) {
                notifyDefaultInterface(connectivityManager, network)
            }

            override fun onLost(network: Network) {
                if (defaultNetwork != network) return
                defaultNetwork = null
                try {
                    listener.updateDefaultInterface("", -1, false, false)
                } catch (error: Exception) {
                    Log.w(TAG, "Failed to notify interface lost", error)
                }
            }
        }
        networkCallback = callback
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivityManager.registerBestMatchingNetworkCallback(
                request,
                callback,
                mainHandler
            )
        } catch (error: Exception) {
            networkCallback = null
            Log.w(TAG, "Failed to register network callback, falling back", error)
            connectivityManager.activeNetwork?.let {
                notifyDefaultInterface(connectivityManager, it)
            }
        }
    }

    private fun notifyDefaultInterface(cm: ConnectivityManager, network: Network) {
        val listener = interfaceUpdateListener ?: return
        try {
            val linkProps = cm.getLinkProperties(network)
            val interfaceName = linkProps?.interfaceName ?: return
            defaultNetwork = network
            val capabilities = cm.getNetworkCapabilities(network)
            val isExpensive =
                capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true
            val isConstrained =
                capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED) != true
            val iface = java.net.NetworkInterface.getByName(interfaceName)
            val interfaceIndex = iface?.index ?: 0
            Log.d(TAG, "Default interface: $interfaceName (index=$interfaceIndex)")
            listener.updateDefaultInterface(interfaceName, interfaceIndex, isExpensive, isConstrained)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to notify default interface", e)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        closeNetworkCallback()
    }

    private fun closeNetworkCallback() {
        interfaceUpdateListener = null
        defaultNetwork = null
        val callback = networkCallback ?: return
        networkCallback = null
        try {
            getSystemService(ConnectivityManager::class.java)
                ?.unregisterNetworkCallback(callback)
        } catch (error: Exception) {
            Log.w(TAG, "Failed to unregister network callback", error)
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        return object : NetworkInterfaceIterator {
            private val interfaces = java.net.NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
            private var index = 0
            override fun hasNext(): Boolean = index < interfaces.size
            override fun next(): libbox.NetworkInterface {
                val iface = interfaces[index++]
                val ni = libbox.NetworkInterface()
                ni.name = iface.name
                ni.index = iface.index
                ni.mtu = try { iface.mtu } catch (_: Exception) { 0 }
                // Build raw Linux IFF_ flags
                var flags = 0
                if (iface.isUp) flags = flags or 0x1          // IFF_UP
                if (iface.isLoopback) flags = flags or 0x8     // IFF_LOOPBACK
                if (iface.isPointToPoint) flags = flags or 0x10 // IFF_POINTOPOINT
                if (iface.supportsMulticast()) flags = flags or 0x1000 // IFF_MULTICAST
                if (iface.isUp) flags = flags or 0x40          // IFF_RUNNING (assume running if up)
                if (!iface.isLoopback && !iface.isPointToPoint) flags = flags or 0x2 // IFF_BROADCAST
                ni.flags = flags
                // Addresses
                val addrs = mutableListOf<String>()
                for (addr in iface.interfaceAddresses) {
                    val hostAddr = addr.address?.hostAddress ?: continue
                    // Strip IPv6 zone ID (e.g. %wlan0) - netip.MustParsePrefix can't handle it
                    val cleanAddr = hostAddr.substringBefore('%')
                    val prefix = addr.networkPrefixLength.toInt()
                    addrs.add("$cleanAddr/$prefix")
                }
                ni.addresses = object : libbox.StringIterator {
                    private var i = 0
                    override fun hasNext(): Boolean = i < addrs.size
                    override fun next(): String = addrs[i++]
                    override fun len(): Int = addrs.size
                }
                return ni
            }
        }
    }

    override fun localDNSTransport(): LocalDNSTransport =
        AndroidDnsTransport { defaultNetwork }

    // --- CommandServerHandler ---

    override fun getSystemProxyStatus(): SystemProxyStatus {
        return SystemProxyStatus().apply {
            available = false
            enabled = false
        }
    }

    override fun serviceStop() {
        if (!lifecycleExecutor.isShutdown) {
            lifecycleExecutor.execute { stopBox() }
        }
    }

    override fun serviceReload() {
        // Not implemented yet
    }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        // Not applicable on Android
    }

    override fun triggerNativeCrash() {
        throw UnsupportedOperationException("Native crash triggering is not supported")
    }

    override fun connectSSHAgent(): Int {
        throw UnsupportedOperationException("SSH agent is not supported")
    }

    override fun writeDebugMessage(message: String) {
        Log.d(TAG, "debug: $message")
    }
}
