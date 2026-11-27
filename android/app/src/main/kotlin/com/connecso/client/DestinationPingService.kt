package com.connecso.client

import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Runs destination RTT probes in an isolated Xray process, away from the live tunnel core. */
open class DestinationPingService : VpnService(), DialerController {
    protected open val socksPort = DEFAULT_SOCKS_PORT
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var physicalNetwork: Network? = null
    @Volatile private var retiring = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_PING) return START_NOT_STICKY
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID).orEmpty()
        val configs = intent.getStringExtra(EXTRA_CONFIGS).orEmpty()
        val requestStartedAt = SystemClock.elapsedRealtime()
        if (retiring) {
            sendFailure(requestId, "RTT worker is restarting; retry the probe.")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        worker.execute {
            val results = JSONArray()
            var success = true
            var error: String? = null
            try {
                if (!bindToPhysicalNetwork()) {
                    throw IllegalStateException("No physical Wi-Fi or mobile network is available for destination pings.")
                }
                LibXray.registerDialerController(this)
                val nodes = JSONArray(configs)
                val batch = buildBatchConfig(nodes)
                Log.i(TAG, "RTT worker start request=$requestId node=${batch.entries.firstOrNull()?.nodeId} configReadyMs=${SystemClock.elapsedRealtime() - requestStartedAt}")
                invoke("runXray", JSONObject().put("xrayJson", batch.config.toString()))
                var ready = false
                for (attempt in 0 until XRAY_READY_ATTEMPTS) {
                    if (xrayRunning()) {
                        ready = true
                        break
                    }
                    Thread.sleep(XRAY_READY_POLL_MS)
                }
                if (!ready) throw IllegalStateException("Destination RTT Xray batch did not start.")
                Log.i(TAG, "RTT worker ready request=$requestId xrayReadyMs=${SystemClock.elapsedRealtime() - requestStartedAt}")

                // Keep independent routes concurrent, but avoid opening a
                // TLS handshake for every configured node at once. Large
                // subscriptions often point several nodes at the same edge,
                // which can otherwise trigger resets/timeouts and false
                // Invalid results during Ping all.
                val pool = Executors.newFixedThreadPool(
                    batch.entries.size.coerceAtMost(DESTINATION_PING_CONCURRENCY).coerceAtLeast(1),
                )
                try {
                    val completed = ExecutorCompletionService<JSONObject>(pool)
                    batch.entries.forEach { entry ->
                        completed.submit(Callable {
                            val result = runCatching {
                                probeThroughInbound(entry.nodeId, entry.country, entry.port)
                            }.getOrElse { ProbeResult(false, -1L) }
                            JSONObject()
                                .put("nodeId", entry.nodeId)
                                .put("success", result.success)
                                .put("latencyMs", result.latencyMs)
                        })
                    }
                    // Never let a stalled socket hold the manual-ping queue
                    // forever. Successful probes are published immediately;
                    // the remaining routes get a bounded batch deadline and
                    // are reported as failed before the next queued batch runs.
                    var received = 0
                    val completedIds = mutableSetOf<String>()
                    val deadline = SystemClock.elapsedRealtime() + BATCH_TIMEOUT_MS
                    while (received < batch.entries.size) {
                        val remainingMs = deadline - SystemClock.elapsedRealtime()
                        val future = if (remainingMs > 0) {
                            completed.poll(remainingMs, TimeUnit.MILLISECONDS)
                        } else null
                        if (future == null) break
                        val item = runCatching { future.get() }.getOrElse { failure ->
                            Log.w(TAG, "RTT probe task failed", failure)
                            // A completed future should normally carry its node ID;
                            // retain a valid failure object if an unexpected task error occurs.
                            JSONObject().put("success", false).put("latencyMs", -1L)
                        }
                        val nodeId = item.optString("nodeId")
                        if (nodeId.isNotBlank()) completedIds.add(nodeId)
                        results.put(item)
                        sendProgress(requestId, item)
                        received++
                    }
                    if (received < batch.entries.size) {
                        batch.entries.filterNot { it.nodeId in completedIds }.forEach { entry ->
                            val timeout = JSONObject()
                                .put("nodeId", entry.nodeId)
                                .put("success", false)
                                .put("latencyMs", -1L)
                            results.put(timeout)
                            sendProgress(requestId, timeout)
                        }
                        Log.w(TAG, "RTT batch deadline request=$requestId completed=$received/${batch.entries.size} timeoutMs=$BATCH_TIMEOUT_MS")
                    }
                } finally {
                    pool.shutdownNow()
                }
            } catch (failure: Throwable) {
                success = false
                error = failure.message ?: "Destination ping failed."
                Log.w(TAG, "Destination RTT batch failed", failure)
            } finally {
                retiring = true
                runCatching { invoke("stopXray") }
                // Wait only for actual shutdown; do not spend the full 1.5 s
                // polling after the core is already stopped.
                for (attempt in 0 until XRAY_STOP_ATTEMPTS) {
                    if (!xrayRunning()) break
                    Thread.sleep(XRAY_STOP_POLL_MS)
                }
                if (xrayRunning()) {
                    Log.w(TAG, "Xray runtime remained active after stop; retiring ping process")
                }
                runCatching { LibXray.resetDNS() }
                physicalNetwork = null
                runCatching {
                    (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager)
                        .bindProcessToNetwork(null)
                }
                val response = Intent(ConnecsoVpnService.ACTION_RESULT)
                    .setPackage(packageName)
                    .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, requestId)
                    .putExtra(ConnecsoVpnService.EXTRA_OPERATION, OPERATION)
                    .putExtra(ConnecsoVpnService.EXTRA_SUCCESS, success)
                    .putExtra(EXTRA_RESULTS, results.toString())
                    .putExtra(ConnecsoVpnService.EXTRA_ERROR, error)
                sendBroadcast(response)
                worker.shutdown()
                stopSelf(startId)
                Handler(Looper.getMainLooper()).postDelayed(
                    { Process.killProcess(Process.myPid()) },
                    PROCESS_RETIRE_DELAY_MS,
                )
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        worker.shutdownNow()
        runCatching { invoke("stopXray") }
        runCatching { LibXray.resetDNS() }
        physicalNetwork = null
        runCatching {
            (getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager)
                .bindProcessToNetwork(null)
        }
        Handler(Looper.getMainLooper()).postDelayed(
            { Process.killProcess(Process.myPid()) },
            CANCEL_RETIRE_DELAY_MS,
        )
        super.onDestroy()
    }

    override fun protectFd(fd: Long): Boolean = physicalNetwork != null && protect(fd.toInt())

    private fun bindToPhysicalNetwork(): Boolean {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val candidates = manager.allNetworks.mapNotNull { network ->
            val caps = manager.getNetworkCapabilities(network) ?: return@mapNotNull null
            val physical = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            if (!physical || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return@mapNotNull null
            network to caps
        }.sortedWith(
            compareByDescending<Pair<Network, NetworkCapabilities>> {
                it.second.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }.thenByDescending { it.second.linkDownstreamBandwidthKbps },
        )
        for ((network, _) in candidates) {
            if (manager.bindProcessToNetwork(network)) {
                physicalNetwork = network
                Log.i(TAG, "Bound isolated RTT worker to validated physical network=${network.networkHandle}")
                return true
            }
        }
        Log.w(TAG, "No validated non-VPN network could be bound for destination RTT")
        return false
    }

    private data class BatchEntry(val nodeId: String, val country: String, val port: Int)
    private data class BatchConfig(val config: JSONObject, val entries: List<BatchEntry>)

    /**
     * Merge a bounded group of complete node configs into one temporary core.
     * Each SOCKS inbound has an explicit route to exactly one node outbound,
     * so warm RTT requests stay isolated while Xray startup is paid once.
     */
    private fun buildBatchConfig(nodes: JSONArray): BatchConfig {
        require(nodes.length() in 1..MAX_BATCH_SIZE) {
            "Destination RTT batch must contain 1-$MAX_BATCH_SIZE nodes."
        }
        val configs = (0 until nodes.length()).map { index ->
            val item = nodes.optJSONObject(index)
                ?: throw IllegalArgumentException("Destination RTT node is missing.")
            val config = runCatching { JSONObject(item.optString("config")) }.getOrNull()
                ?: throw IllegalArgumentException("Destination Xray config is invalid.")
            Triple(item, config, index)
        }
        val merged = JSONObject(configs.first().second.toString())
        val mergedInbounds = JSONArray()
        val mergedOutbounds = JSONArray()
        val baseOutbounds = merged.optJSONArray("outbounds")
            ?: throw IllegalArgumentException("Destination Xray config has no outbound.")
        var hasSharedOutbound = false
        for (index in 0 until baseOutbounds.length()) {
            val outbound = baseOutbounds.optJSONObject(index) ?: continue
            if (outbound.optString("tag") != PROXY_TAG) {
                mergedOutbounds.put(JSONObject(outbound.toString()))
                hasSharedOutbound = true
            }
        }
        require(hasSharedOutbound) { "Destination Xray config has no shared outbounds." }

        val entries = mutableListOf<BatchEntry>()
        val proxyTags = mutableSetOf<String>()
        val inboundTags = mutableSetOf<String>()
        for ((item, config, index) in configs) {
            val inbounds = config.optJSONArray("inbounds")
                ?: throw IllegalArgumentException("Destination Xray config has no inbound.")
            val socksInbound = (0 until inbounds.length())
                .mapNotNull { inbounds.optJSONObject(it) }
                .firstOrNull { it.optString("protocol") == "socks" }
                ?: throw IllegalArgumentException("Destination Xray config has no SOCKS inbound.")
            val inboundsOut = JSONObject(socksInbound.toString())
            val inboundTag = "connecso-rtt-in-$index"
            val proxyTag = "connecso-rtt-proxy-$index"
            val port = socksPort + index
            inboundsOut.put("tag", inboundTag).put("port", port)
            mergedInbounds.put(inboundsOut)
            inboundTags.add(inboundTag)
            proxyTags.add(proxyTag)

            val outbounds = config.optJSONArray("outbounds")
                ?: throw IllegalArgumentException("Destination Xray config has no outbound.")
            val proxy = (0 until outbounds.length())
                .mapNotNull { outbounds.optJSONObject(it) }
                .firstOrNull { it.optString("tag") == PROXY_TAG }
                ?: (0 until outbounds.length()).mapNotNull { outbounds.optJSONObject(it) }.firstOrNull()
                ?: throw IllegalArgumentException("Destination Xray config has no proxy outbound.")
            mergedOutbounds.put(JSONObject(proxy.toString()).put("tag", proxyTag))
            entries.add(BatchEntry(item.optString("nodeId"), item.optString("country"), port))
        }

        val routing = merged.optJSONObject("routing")
            ?: throw IllegalArgumentException("Destination Xray config has no routing rules.")
        val oldRules = routing.optJSONArray("rules") ?: JSONArray()
        val rules = JSONArray()
        for (index in 0 until oldRules.length()) {
            val rule = oldRules.optJSONObject(index) ?: continue
            if (rule.optString("outboundTag") != PROXY_TAG) rules.put(JSONObject(rule.toString()))
        }
        for (index in configs.indices) {
            rules.put(
                JSONObject()
                    .put("type", "field")
                    .put("inboundTag", JSONArray().put("connecso-rtt-in-$index"))
                    .put("outboundTag", "connecso-rtt-proxy-$index"),
            )
        }

        merged.put("inbounds", mergedInbounds)
        merged.put("outbounds", mergedOutbounds)
        routing.put("rules", rules)
        // Main VPN and ping-worker processes share loopback ports. Keep this
        // temporary core's local metrics endpoint away from the live core.
        merged.optJSONObject("metrics")?.put(
            "listen",
            "$HOST:${METRICS_PORT_BASE + (socksPort - DEFAULT_SOCKS_PORT)}",
        )
        return BatchConfig(merged, entries)
    }

    private fun sendFailure(requestId: String, message: String) {
        sendBroadcast(
            Intent(ConnecsoVpnService.ACTION_RESULT)
                .setPackage(packageName)
                .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, requestId)
                .putExtra(ConnecsoVpnService.EXTRA_OPERATION, OPERATION)
                .putExtra(ConnecsoVpnService.EXTRA_SUCCESS, false)
                .putExtra(EXTRA_RESULTS, "[]")
                .putExtra(ConnecsoVpnService.EXTRA_ERROR, message),
        )
    }

    private fun probeThroughInbound(nodeId: String, country: String, port: Int): ProbeResult {
        var last = ProbeResult(false, -1L)
        repeat(PROBE_ATTEMPTS) { attempt ->
            last = probeThroughInboundOnce(nodeId, country, port)
            if (last.success) {
                if (attempt > 0) {
                    Log.i(TAG, "Destination RTT recovered node=$nodeId attempt=${attempt + 1}")
                }
                return last
            }
            if (attempt + 1 < PROBE_ATTEMPTS) Thread.sleep(PROBE_RETRY_DELAY_MS)
        }
        return last
    }

    private fun probeThroughInboundOnce(nodeId: String, country: String, port: Int): ProbeResult {
        val probeStartedAt = SystemClock.elapsedRealtime()
        if (!waitForSocks(port)) {
            Log.w(TAG, "RTT worker SOCKS not ready node=$nodeId elapsedMs=${SystemClock.elapsedRealtime() - probeStartedAt}")
            return ProbeResult(false, -1L)
        }
        val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(HOST, port))
        val raw = Socket(proxy)
        var tls: SSLSocket? = null
        return try {
            // Socket.connect on a proxied Socket performs the SOCKS handshake
            // as part of connect(). Apply SO_TIMEOUT first so a stalled SOCKS
            // reply cannot leave the completion queue waiting until Flutter's
            // much longer aggregate timeout.
            raw.soTimeout = TIMEOUT_MS
            raw.connect(InetSocketAddress.createUnresolved(PING_HOST, PING_PORT), TIMEOUT_MS)
            tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                .createSocket(raw, PING_HOST, PING_PORT, true) as SSLSocket
            tls.soTimeout = TIMEOUT_MS
            tls.startHandshake()
            val input = BufferedInputStream(tls.inputStream)
            val output = BufferedOutputStream(tls.outputStream)

            // First HEAD pays TCP/proxy/TLS setup. The displayed RTT is the
            // second (and, for an outlier, third) HEAD on this same TLS socket.
            sendHead(output)
            val cold = readHttpHead(input)
            if (cold.statusCode !in 100..599 || cold.connectionClose) {
                return ProbeResult(false, -1L)
            }
            val warm = measureWarmHead(input, output)
            if (warm == null) return ProbeResult(false, -1L)
            if (warm >= HIGH_RTT_RETRY_MS) {
                val retry = measureWarmHead(input, output)
                if (retry != null && retry < warm) {
                    Log.i(TAG, "Destination RTT node=$nodeId country=$country result=${retry}ms retry=true")
                    return ProbeResult(true, retry)
                }
            }
            Log.i(TAG, "Destination RTT node=$nodeId country=$country result=${warm}ms totalMs=${SystemClock.elapsedRealtime() - probeStartedAt}")
            ProbeResult(true, warm)
        } catch (failure: Exception) {
            Log.w(
                TAG,
                "Destination RTT failed node=$nodeId country=$country " +
                    "reason=${failure.javaClass.simpleName}: ${failure.message}",
                failure,
            )
            ProbeResult(false, -1L)
        } finally {
            runCatching { tls?.close() }
            if (tls == null) runCatching { raw.close() }
        }
    }

    private fun measureWarmHead(input: BufferedInputStream, output: BufferedOutputStream): Long? {
        val startedAt = SystemClock.elapsedRealtime()
        sendHead(output)
        val response = readHttpHead(input)
        val elapsed = SystemClock.elapsedRealtime() - startedAt
        return elapsed.takeIf { response.statusCode in 100..599 && !response.connectionClose && it > 0L }
    }

    private fun sendHead(output: BufferedOutputStream) {
        val request = "HEAD $PING_PATH HTTP/1.1\r\n" +
            "Host: $PING_HOST\r\n" +
            "User-Agent: Connecso-Mobile-Client\r\n" +
            "Accept: */*\r\n" +
            "Connection: keep-alive\r\n\r\n"
        output.write(request.toByteArray(Charsets.US_ASCII))
        output.flush()
    }

    private data class HttpHead(val statusCode: Int, val connectionClose: Boolean)

    private fun readHttpHead(input: BufferedInputStream): HttpHead {
        var statusCode = -1
        var connectionClose = false
        repeat(MAX_HTTP_INFORMATIONAL_RESPONSES) {
            val statusLine = readHttpLine(input)
            if (!statusLine.startsWith("HTTP/")) throw IllegalStateException("Invalid HTTP status line.")
            statusCode = statusLine.substringAfter(' ').substringBefore(' ').toIntOrNull() ?: -1
            connectionClose = false
            while (true) {
                val line = readHttpLine(input)
                if (line.isEmpty()) break
                val separator = line.indexOf(':')
                if (separator > 0 && line.substring(0, separator).equals("Connection", ignoreCase = true)) {
                    connectionClose = line.substring(separator + 1).trim().equals("close", ignoreCase = true)
                }
            }
            if (statusCode !in 100..199 || statusCode == 101) return HttpHead(statusCode, connectionClose)
        }
        throw IllegalStateException("Too many interim HTTP responses.")
    }

    private fun readHttpLine(input: BufferedInputStream): String {
        val bytes = ByteArrayOutputStream()
        while (bytes.size() <= MAX_HTTP_LINE_BYTES) {
            val value = input.read()
            if (value < 0) throw IllegalStateException("Destination closed the RTT connection.")
            if (value == '\n'.code) {
                val line = bytes.toByteArray()
                val length = if (line.isNotEmpty() && line.last() == '\r'.code.toByte()) line.size - 1 else line.size
                return String(line, 0, length, Charsets.US_ASCII)
            }
            bytes.write(value)
        }
        throw IllegalStateException("Destination returned an oversized HTTP header line.")
    }

    private fun waitForSocks(port: Int): Boolean {
        repeat(SOCKS_READY_ATTEMPTS) {
            try {
                Socket().use { it.connect(InetSocketAddress(HOST, port), SOCKS_READY_TIMEOUT_MS) }
                return true
            } catch (_: Exception) {
                Thread.sleep(SOCKS_READY_POLL_MS)
            }
        }
        return false
    }

    private fun xrayRunning(): Boolean = runCatching {
        invoke("getXrayState").optJSONObject("data")?.optBoolean("running") == true
    }.getOrDefault(false)

    private fun sendProgress(requestId: String, item: JSONObject) {
        sendBroadcast(
            Intent(ConnecsoVpnService.ACTION_RESULT)
                .setPackage(packageName)
                .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, requestId)
                .putExtra(ConnecsoVpnService.EXTRA_OPERATION, OPERATION_PROGRESS)
                .putExtra(EXTRA_PROGRESS_NODE_ID, item.optString("nodeId"))
                .putExtra(ConnecsoVpnService.EXTRA_SUCCESS, item.optBoolean("success"))
                .putExtra(EXTRA_PROGRESS_LATENCY_MS, item.optLong("latencyMs", -1L)),
        )
    }

    private fun invoke(method: String, payload: JSONObject = JSONObject()): JSONObject {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", method)
            .put("payload", payload)
        val response = JSONObject(LibXray.invoke(request.toString()))
        if (!response.optBoolean("success")) throw IllegalStateException("Xray destination probe failed.")
        return response
    }

    private data class ProbeResult(val success: Boolean, val latencyMs: Long)

    companion object {
        const val ACTION_PING = "com.connecso.client.DESTINATION_PING"
        const val OPERATION = "destinationPingBatch"
        const val EXTRA_REQUEST_ID = "destinationPingRequestId"
        const val EXTRA_CONFIGS = "destinationPingConfigs"
        const val EXTRA_RESULTS = "destinationPingResults"
        const val EXTRA_PROGRESS_NODE_ID = "destinationPingProgressNodeId"
        const val EXTRA_PROGRESS_LATENCY_MS = "destinationPingProgressLatencyMs"
        const val OPERATION_PROGRESS = "destinationPingProgress"
        private const val TAG = "CONNECSO_DESTINATION_PING"
        private const val API_VERSION = 3
        private const val HOST = "127.0.0.1"
        private const val PING_HOST = "www.google.com"
        private const val PING_PORT = 443
        private const val PING_PATH = "/generate_204"
        private const val METRICS_PORT_BASE = 49327
        // Keep a stalled node from holding the sequential queue. This is an
        // upper bound for connect/TLS/HTTP setup; it is never reported as RTT.
        private const val TIMEOUT_MS = 1_200
        private const val BATCH_TIMEOUT_MS = 4_000L
        private const val HIGH_RTT_RETRY_MS = 500L
        // Routes are submitted and completed in the same order as the
        // destination list. The merged Xray core keeps initialization shared.
        private const val DESTINATION_PING_CONCURRENCY = 3
        private const val MAX_BATCH_SIZE = 10
        private const val PROBE_ATTEMPTS = 1
        private const val PROBE_RETRY_DELAY_MS = 80L
        private const val PROXY_TAG = "connecso-proxy"
        private const val MAX_HTTP_LINE_BYTES = 16 * 1024
        private const val MAX_HTTP_INFORMATIONAL_RESPONSES = 4
        private const val XRAY_READY_ATTEMPTS = 12
        private const val XRAY_READY_POLL_MS = 100L
        private const val XRAY_STOP_ATTEMPTS = 30
        private const val XRAY_STOP_POLL_MS = 50L
        private const val SOCKS_READY_ATTEMPTS = 8
        private const val SOCKS_READY_TIMEOUT_MS = 100
        private const val SOCKS_READY_POLL_MS = 100L
        private const val PROCESS_RETIRE_DELAY_MS = 350L
        private const val CANCEL_RETIRE_DELAY_MS = 150L
        const val DEFAULT_SOCKS_PORT = 10809
    }
}

/** Second independent worker keeps Ping all responsive without overloading phones. */
class DestinationPingService2 : DestinationPingService() {
    override val socksPort: Int = DEFAULT_SOCKS_PORT + 100
}
