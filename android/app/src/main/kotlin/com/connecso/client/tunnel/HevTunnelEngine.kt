package com.connecso.client.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import hev.htproxy.TProxyService
import java.io.File

class HevTunnelEngine(private val configDir: File) : TunnelEngine {
    override val name: String = "HEV"
    private val configFile = File(configDir, "connecso-hev.yml")
    @Volatile private var started = false
    private var baseline = TunnelEngineStats()

    override fun start(
        service: VpnService,
        tun: ParcelFileDescriptor,
        config: TunnelEngineConfig,
    ): Boolean = synchronized(this) {
        stop()
        configFile.writeText(buildConfig(config))
        started = runCatching { TProxyService.TProxyStartService(configFile.absolutePath, tun.fd) }
            .onFailure { Log.w(TAG, "event=hev.start_failed failureType=${it.javaClass.simpleName}") }
            .getOrDefault(false)
        if (started) {
            repeat(20) { attempt ->
                if (!TProxyService.TProxyIsRunning()) {
                    started = false
                    return@repeat
                }
                if (attempt >= 2) return@repeat
                Thread.sleep(100)
            }
        }
        baseline = rawStats()
        Log.i(TAG, "event=hev.${if (started) "started" else "start_rejected"}")
        started
    }

    override fun stop() {
        synchronized(this) {
            if (started || runCatching { TProxyService.TProxyIsRunning() }.getOrDefault(false)) {
                runCatching { TProxyService.TProxyStopService() }
            }
            started = false
            baseline = TunnelEngineStats()
            runCatching { configFile.delete() }
        }
    }

    override fun isRunning(): Boolean = started && runCatching {
        TProxyService.TProxyIsRunning()
    }.getOrDefault(false)

    override fun stats(): TunnelEngineStats {
        val current = rawStats()
        return TunnelEngineStats(
            rxPackets = (current.rxPackets - baseline.rxPackets).coerceAtLeast(0),
            txPackets = (current.txPackets - baseline.txPackets).coerceAtLeast(0),
        )
    }

    private fun rawStats(): TunnelEngineStats {
        val values = runCatching { TProxyService.TProxyGetStats() }.getOrNull()
            ?: return TunnelEngineStats()
        return TunnelEngineStats(
            rxPackets = values.getOrNull(3)?.coerceAtLeast(0) ?: 0,
            txPackets = values.getOrNull(1)?.coerceAtLeast(0) ?: 0,
        )
    }

    private fun buildConfig(config: TunnelEngineConfig): String = """
tunnel:
  name: connecso0
  mtu: ${config.mtu}
  multi-queue: false
  ipv4: ${config.ipv4}
  ipv6: '${config.ipv6.orEmpty()}'
  icmp: 'off'
socks5:
  address: ${config.socksHost}
  port: ${config.socksPort}
  udp: '${if (config.udpEnabled) "udp" else "off"}'
""".trimIndent()

    companion object {
        private const val TAG = "CONNECSO/HEV"
    }
}
