package com.connecso.client.tunnel

object VpnDataplaneConfig {
    const val XRAY_SOCKS_HOST = "127.0.0.1"
    const val XRAY_SOCKS_PORT = 10808
    const val DEFAULT_MTU = 1400
    const val IPV4_ADDRESS = "10.111.0.1"
    const val IPV4_PREFIX = 30
    const val IPV6_ADDRESS = "fd00::1"
    const val IPV6_PREFIX = 126
    // Capture IPv6 as well as IPv4. Leaving this disabled lets Android route
    // IPv6 traffic directly over cellular networks, which appears as a leak
    // on carriers that provide IPv6 even when Wi-Fi is IPv4-only.
    const val IPV6_ENABLED = true
    const val DNS_SERVER = "1.1.1.1"
    const val TRAFFIC_PROOF_WINDOW_MS = 6_000L
}
