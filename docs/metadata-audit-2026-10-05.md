# Android metadata audit — experimental checkout only

## Status

This is a reviewable experimental build, **not a demonstrated full-device fix**.
Taha reports that Netherlands Hysteria2 supplies Internet to some applications but not the whole device. That report remains unresolved. A successful endpoint probe or the app's current verification through SOCKS is not proof of full-device Internet.

Backup before changes: `D:/Coding/backups/connecso-metadata-20261005-151934`.
No GitHub upload. Home, country menu, subscription UI, and the production checkout were not modified by this work.

## Actual flow

Subscription fetch → SubscriptionParser → VpnNode → existing encrypted SubscriptionCache → AndroidVpnAdapter → XrayConfigBuilder → native ConnecsoVpnService → Xray.
Both probing and connecting call the same configuration encoder. Country/method selection still chooses an endpoint before the common VPN pipeline.

Device applications → Android VPN routes → TUN FD → HEV SOCKS5/UDP → `127.0.0.1:10808` SOCKS inbound → selected Xray outbound. IPv4 `10.111.0.1/30`, IPv6 `fd00::1/126`, MTU 1500 and default routes remain unchanged.

## Findings and changes

| File | Problem / change | Reason / risk / validation |
| --- | --- | --- |
| `lib/domain/models/vpn_node.dart` | Added structured outbound, original source fields and redacted diagnostics to persisted nodes. | String credentials alone cannot retain nested arrays/objects. Additive cache fields; old caches cannot recover already discarded fields. Cache round-trip audit passed. |
| `lib/data/parsers/subscription_parser.dart` | Retains original native outbound, URI/map metadata, encryption/flow/Reality spiderX; supports JSON profile arrays; reports rejected entries. | Prevent flattening loss. Unsupported combinations may now fail explicitly instead of connecting with incomplete settings. Existing tests passed. |
| `lib/data/parsers/xray_subscription_metadata.dart` | Own typed conversion for TLS/Reality, WS headers/options, XHTTP extra/xmux, gRPC and source fields. | Supplied false, empty and nested values survive. Unknown URI/map fields are reported and prevent silent connection alteration. Not a universal converter for every foreign-client option. |
| `lib/domain/services/xray_config_builder.dart` | Recursively fills absent fields only; preserves native settings objects; validates protocol/dependent-outbound chains. | Provider settings take precedence. Native multi-outbound dependency graphs are deliberately rejected. All 45 audited nodes keep identical local inbound/DNS/routing infrastructure. |
| `lib/data/repositories/subscription_repository.dart` | Logs import counts and warning reasons. | No credential values logged. Diagnostics are developer logs rather than new UI. |
| `lib/platform/android/android_vpn_adapter.dart` | One encoding path for probe/start with redacted metadata-source diagnostics. | Keeps per-node configuration independent. |
| `android/app/src/main/kotlin/com/connecso/client/ConnecsoVpnService.kt` | Replaced default-network callback with INTERNET + NOT_VPN request; physical-network selection excludes VPN transport. | Runtime showed VPN 102 using itself as underlying network 102. After repair VPN 103 uses Wi-Fi 100. No HEV/TUN address, route, protocol or inbound-port change. Physical-network preference still needs Wi-Fi/mobile transition testing. |
| `tool/audit_subscription_metadata.dart` | Local audit of cache round-trip, typed native fields and shared infrastructure. | Private generated configs are exported only to the supplied private output directory. Does not test Internet transport. |

## Evidence

- Supplied subscription: 45 nodes; 27 VLESS/WS, 13 VLESS/XHTTP, 5 Hysteria2.
- Audit: 45 structured configurations; cache round-trip, typed native metadata and fixed local infrastructure passed.
- Existing tests: 15 passed across xray_config_builder_test, subscription_metadata_test and saved_subscriptions_test.
- Dart analysis: no errors/warnings in inspected files; style infos remain.
- Emulator selected USA XHTTP/Reality; core/inbound/HEV started; warm ping measured 254 ms in the final native build. This does not establish Google/YouTube usability.
- HEV statistics increased from `11,2082,4,212` to `40,6461,29,11911` during connection verification. The verification request itself uses SOCKS, so this increase is supporting evidence only, not per-application proof.
- Emulator routing table contains IPv4/IPv6 default routes on tun0; final underlying network is physical Wi-Fi 100, not VPN 103.
- Arm64 debug build 2099 installed with `adb install -r`; earlier update 2098 retained original firstInstallTime. No uninstall/data reset.
- Emulator native build 2100 runs with a Flutter Hot Reload session.
- Automatic approval review rejected the command to open Google in emulator Chrome; no reason was supplied. That browser test was not performed.

## References inspected

- v2rayNG: CoreConfigManager, CoreOutboundBuilder, VlessFmt, Hysteria2Fmt (shared config building, typed transport settings, Hysteria auth/finalmask).
- Nekoray: TrojanVLESSBean and V2RayStreamSettings (explicit transport/TLS/Reality fields).
- Hiddify: profile_parser.dart (subscription acquisition/profile-header processing; not evidence of complete transport conversion).
- Karing: server_manager.dart subscription traffic acquisition. Referenced proxy_conf_utils.dart is absent from the inspected public tree, so transport-parser comparison is limited.
- AetherGUI: VpnService/HEV lifecycle and capture architecture only. No code copied. The separate Aether Rust repository is a different transport architecture, not a drop-in Xray parser.
- Xray v26.9.9 configuration source: Hysteria outbound/stream/finalmask schema.

## Remaining validation

Need the exact successful/failed application pair from the Hysteria2 phone test and effective split-tunnel settings, then a contemporaneous phone trace. Full TCP/UDP/QUIC, Private DNS, IPv6 egress and Wi-Fi/mobile transition tests are not completed. Do not call the original Internet issue fixed.

Old subscriptions must be refreshed once: additive cache changes preserve old data but cannot reconstruct metadata previously discarded.

## Local commands

```powershell
Set-Location D:\Coding\connecso-client-vpn-dataplane
& D:\Android\Flutter\bin\flutter.bat test --no-pub test/xray_config_builder_test.dart test/subscription_metadata_test.dart test/saved_subscriptions_test.dart
& D:\Android\Flutter\bin\flutter.bat build apk --debug --target-platform android-arm64 --build-number 2101 --build-name 0.1.3 --no-pub
& D:\Android\Sdk\platform-tools\adb.exe -s '<current-wireless-device-id>' install -r build\app\outputs\flutter-apk\app-debug.apk
```

Use a higher build number for the next phone update; do not overwrite the saved arm64 artifact with an emulator build. Saved phone artifact: `D:/Coding/backups/connecso-metadata-arm64-2099.apk`.
