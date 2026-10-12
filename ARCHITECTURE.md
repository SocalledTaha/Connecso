# Architecture

## Current product scope

This repository is a new Android-only Flutter application. Windows and iOS are excluded from current implementation work. Their future support can be added behind platform capability and adapter contracts without adding platform-specific code to product UI.

## Runtime boundaries

```text
Flutter UI
  └── application state and typed connection state machine
       ├── Subscription Engine / cache / control-plane recovery
       ├── ProbeEngine / SmartSelector / ConnectionManager
       ├── Usage and quota / subscription management / location resolution
       ├── local Dynamic Connection Map
       └── ProxyCore boundary
            └── XrayCore ↔ local SOCKS5 ↔ HEV tun2socks ↔ Android VpnService TUN
```

The UI receives presentation state and capability data. It does not form core configurations, choose proxies, or call `VpnService` directly.

## Android state and persistence

Import, parse, validate, and normalize candidates before replacing the encrypted last-known-good node cache. A failed refresh leaves the previous cache untouched. Startup reads cached data before starting remote requests. SQLite stores usage, probe, and connection history with versioned migrations; credential-bearing nodes, saved subscription URLs, and sensitive settings remain in Android secure storage.

## Security boundary

Node credentials are data and must never be logged. Recovery infrastructure is separate from user VPN routing. No physical device location is requested or rendered.

The home header uses theme-specific transparent CONNECSO marks and fixed physical positions for brand and language/theme actions. Subscription switching, renaming, adding, and sign-out remain available from the home subscription card; there is no general settings menu in the header.

Android's `VpnService` owns the TUN descriptor. HEV consumes that descriptor and forwards TCP/UDP traffic to Xray's loopback SOCKS5 inbound. Xray remains the only proxy core; HEV supplies the TUN-to-SOCKS transport layer. On profile switching, the selected profile is persisted immediately while an already-running VPN session continues with its existing node set until the user manually disconnects.

The Android Quick Settings tile sends start/stop requests directly to the same VPN service. The service saves the last started Xray configuration and Split Tunneling policy for that tile, encrypted with an Android Keystore AES-GCM key in the no-backup files directory. The tile reflects whether the VPN service is active; if the saved profile or VPN consent is missing, it opens the app for setup.

The current connection baseline uses Xray's built-in DNS with `1.1.1.1` and IPv4 query preference. Android keeps the IPv6 default route within the TUN, while Xray blocks IPv6 destinations to avoid a direct-network fallback. DNS port 53 is routed through Xray's DNS outbound; UDP/443 is allowed for QUIC evaluation, and Mux is disabled by default. See [CORE_ARCHITECTURE.md](CORE_ARCHITECTURE.md) for the complete packet and DNS routing policy.

## Connection truth

Only a started tunnel followed by a successful real connectivity check may produce `connected`. Missing core artifacts, tunnel-start failure, or verification failure stay visible as failure states.

The map consumes normalized exit-location data through `LocationResolver` and derives its presentation from this same typed connection state. It has no independent network state and uses no online map provider. See [DYNAMIC_CONNECTION_MAP.md](DYNAMIC_CONNECTION_MAP.md).
