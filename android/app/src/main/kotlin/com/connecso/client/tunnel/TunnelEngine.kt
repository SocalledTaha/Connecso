package com.connecso.client.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor

data class TunnelEngineConfig(
    val socksHost: String,
    val socksPort: Int,
    val mtu: Int,
    val ipv4: String,
    val ipv6: String?,
    val udpEnabled: Boolean,
    val pipeline: Boolean,
)

data class TunnelEngineStats(
    val rxPackets: Long = 0,
    val txPackets: Long = 0,
    val tcpOpened: Long = 0,
    val tcpFailed: Long = 0,
    val udpSessions: Long = 0,
)

enum class TunnelEngineChoice { AUTO, CONTUN, HEV }

enum class DataplaneState {
    IDLE,
    XRAY_STARTING,
    XRAY_READY,
    TUN_ESTABLISHING,
    TUN_READY,
    TUNNEL_ENGINE_STARTING,
    CONTUN_ACTIVE,
    HEV_ACTIVE,
    DATAPLANE_VERIFYING,
    CONNECTED,
    FAILED,
}

interface TunnelEngine {
    val name: String
    fun start(service: VpnService, tun: ParcelFileDescriptor, config: TunnelEngineConfig): Boolean
    fun stop()
    fun isRunning(): Boolean
    fun stats(): TunnelEngineStats
}
