# Current Implementation Scope

The original 15-block specification is retained in [MASTER_BUILD_SPECIFICATION_SOURCE.txt](MASTER_BUILD_SPECIFICATION_SOURCE.txt) as historical input. The owner-approved architecture amendment makes the current product Android-only and Xray-core-only. Do not build Windows or iOS deliverables.

## Android delivery

- Flutter/Dart owns the UI, subscription retrieval and parsing, normalized node model, probing, node selection, Xray configuration generation, persistence, and localization.
- Kotlin owns Android VPN permission, `VpnService`, TUN lifecycle, DNS, per-app split tunneling, platform connectivity verification, and the Xray service bridge.
- `ProxyCore` is retained as an application boundary; `XrayProxyCore` is its only implementation.
- A connection is reported as connected only after Xray starts, Android establishes the VPN, and HTTPS reachability through that tunnel succeeds.
- Subscription parsers remain independent of runtime. JSON proxy-outbound and Clash inputs are kept when their data can be normalized and represented by the Xray builder.
- Mux is enabled by default in generated Xray outbounds and has no UI control.
- Signed subscription recovery remains fail-closed until the owner supplies a production endpoint and trust configuration. Signing a production APK requires the owner-managed release keystore.

## Preserved services and validation

The core migration preserves Subscription Engine, atomic cache replacement, ProbeEngine, SmartSelector, health/stability history, hysteresis, node cooldown and failover, Android VpnService, split tunneling, usage/quota, map and connection animation, English/Persian localization, RTL/LTR, light/dark themes, redacted structured logging, and schema migrations.

GitHub Actions is the Android validation path. A previously successful CI run `36721819764` built the earlier dual-runtime APK, so it does not validate this Xray-only batch. Run CI after these changes to validate current analysis, tests, Android Kotlin/Gradle packaging, and the universal APK. VPN routing and traffic counters still require physical-device verification.
