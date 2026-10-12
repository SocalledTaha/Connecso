# CONNECSO Client — Changelog

Release notes for private Android test builds. Each GitHub Actions run attaches this file as a separate artifact whose name carries the same app version, CI build number, and commit as the APK artifact.

## 0.1.3 — Permanent signing migration build

- Release APKs use the permanent CONNECSO RSA-4096 certificate restored from GitHub Actions secrets.
- CI fails when release signing variables are missing, when APK verification fails, or when an APK is Android-debug-signed.
- `versionCode` continues to use the monotonically increasing GitHub Actions run number.
- This is the one-time migration build for testers moving from the debug-signed `0.1.2`; future builds signed with the same certificate update in place.

## 0.1.2 — Android private test build

### Subscription refresh and import

- Fixed Android subscription responses returned as `bodyBase64`, which previously made URL imports appear empty on Android.
- Normalized Samsung-style clipboard input, including BOM, zero-width/bidi markers, line endings, and matching outer quotes.
- Preserved the Direct-first refresh order, followed by the current VPN/proxy route when Direct fails.

- Added a direct-first subscription fetch path using the underlying non-VPN Android network.
- Added an automatic current-route retry through the active Connecso VPN or another configured VPN/proxy when Direct is filtered or fails.
- Added a native current-route fetcher so the fallback is captured by Android VPN routing.
- Applied the same route sequence to URL import and manual subscription refresh.
- Kept the cached-node recovery proxy slot fail-closed until a signed endpoint and key are supplied.

### Subscription metadata and manager

- Persisted provider support URL, profile URL, administrator announcement, and per-account identity.
- Read metadata from response headers, plain/Base64 bodies, URL query parameters, and provider feed preambles.
- Recognized account labels such as `45ypi555yyuvurjo - Hamin` and display only `Hamin` as the account name.
- Reworked the manager details area to match the subscription sheet surface, with centered Support/Profile actions.
- Support and Profile actions open Telegram or the provider website directly through Android external intents.
- Persian announcements are right-aligned based on the announcement text itself.

### UI and connection stability

- Fixed the Android debug build's generated plugin registration so secure storage and subscription persistence work on device and emulator.
- Replaced legacy VPN include-mode behavior with full-device capture by default; split tunneling now uses an exclusion list only.
- Captured both IPv4 and IPv6 routes and kept the existing HEV TUN-to-Xray bridge, UDP support, and protected upstream sockets.
- Added Android VPN dataplane diagnostics for routing mode, TUN, bridge, TCP/UDP, IPv6 capture, and DNS configuration.

- Kept the approved Globe renderer as the single Home visual system and preserved source/destination connection state separation.
- Kept the dark/light themes, country marker, radar treatment, and responsive connection scene.
- Centralized notices above sheets and menus so import/refresh feedback remains visible.
- Kept the saved subscription list synchronized after import, refresh, edit, pin, and delete operations.

### Validation

- All 82 Flutter tests pass and analysis reports only pre-existing lints.
- Debug ARM64 APK was installed and exercised on a physical Android device; debug x86_64 APK was installed on the Medium_Phone emulator.
- Physical-device and emulator checks covered VPN connection, YouTube, Instagram, and excluded-app routing.
- The tagged workflow builds Universal, armeabi-v7a, arm64-v8a, and x86_64 release APKs.

### Quick Settings tile

- Added a CONNECSO Android Quick Settings tile for one-tap connect/disconnect.
- The tile uses the last profile started in the app; its Xray configuration and Split Tunneling policy are saved in an Android Keystore AES-GCM encrypted file that is excluded from backup.
- If the app has no previously started profile or VPN permission is missing, the tile opens CONNECSO for setup.
- GitHub Actions run [36895229438](https://github.com/SocalledTaha/connecso-client/actions/runs/36895229438) passed analysis, all tests, and the universal APK build; matching APK and changelog artifacts are available from that run. Physical-device installation/validation remains pending because Wireless Debugging is disconnected.

## 0.1.1 — Android private test build

- Removed the disconnected-state arc beside the Connect control; the neutral outline remains, while the animated arc is reserved for active connection attempts.
- Resized the map scene using the available phone height so it expands and contracts with common screen sizes.
- Fixed latency reporting: while connected, Google `generate_204` is measured through the active local SOCKS tunnel; while disconnected, Xray's probe result supplies the measured delay instead of timing the full method-channel call.
- Switched the ping target to `https://www.google.com/generate_204` and reject timeout/sentinel delays as unavailable.
- Persist Split Tunneling edits after each selection, mode change, bulk operation, or list import so abrupt app closure does not discard the latest saved policy.
- Disabled Android app-data backup to avoid restoring encrypted preferences without their device-bound secure-storage key.
- Bumped the app version so this APK can update an existing 0.1.0 installation.

## 0.1.0 — Android private test builds

### Current working tree batch — network baseline and anchored connection control

- Set Android and Xray's default DNS to `1.1.1.1`; Xray now handles routed DNS port 53 and prefers IPv4 answers.
- Kept the IPv6 default route inside the VPN and added an Xray blackhole rule for IPv6 destinations, preventing direct fallback outside the tunnel.
- Disabled Xray Mux by default and allowed UDP/443 through the proxy so QUIC can be tested.
- Kept the existing MTU at 1500 and did not add speculative Xray/HEV buffer overrides.
- Anchored Connect, connection status, and ping/health immediately above the This Session card; the map remains full width and independently scrollable at a large size.
- Made the Ping/health row tappable to re-probe the active node, with a progress indicator and persisted health-history update.
- Added regression assertions for Xray DNS/IP routing, Mux/QUIC policy, and the map/control/usage layout relationship.
- Device testing is still needed to compare Chrome/YouTube and other browsing with the prior configuration; if QUIC fails on the tested server, restore UDP/443 blocking and compare as a compatibility fallback.

### Current working tree batch — local universal APK built

- Added equally sized edit, refresh, delete, and pin controls to every saved subscription; pinned rows sort first and show a filled pin.
- The editor now updates the subscription name and HTTPS link together and can copy the current link.
- Selecting a saved profile updates its check immediately and persists the selection without dropping an active VPN session. The new profile's node list applies after a manual disconnect; reconnect then uses the selected profile.
- Added a backup copy and serialized persistence writes for saved subscription metadata, including pin state and provider server/account labels.
- Added clipboard and QR import actions directly to the subscription manager and enabled profile management before the first VPN connection.
- Kept the session/quota card and subscription tile visually unchanged while anchoring them at the bottom; connected control height now adapts to the remaining screen space.
- Added the locale transition to the subscription label and kept the header controls fixed across LTR/RTL changes.
- Expiry uses Gregorian English dates and Jalali Persian dates. Provider account email is read only from explicit account metadata and displayed alongside the server title.
- Expanded the map across the full screen width, restored its larger integrated scene, and added horizontal edge fades; the map still has no framed card/container.
- Kept the Connect control and larger status/health text below the map and immediately above the bottom-anchored This Session card. Tapping while Connecting cancels the attempt.
- Moved the pin beside the subscription name, reduced the action icon size, and set the English trailing order to Delete, Refresh, Edit, Copy Link.
- Displayed the provider account label with the saved subscription and taught metadata parsing to read Email fields from base64-encoded JSON responses.
- Replaced Android's direct Xray TUN path with Android VpnService TUN → HEV tun2socks → Xray's local SOCKS5 inbound. HEV is built from pinned source for API 24 and four ABIs, retaining Android 7.0+ compatibility. Release APK build passes; verify Chrome and VPN behavior on a physical Android device.
- Flutter analysis passed and 17 targeted Home/subscription/metadata/connection tests passed. Dependency refresh via pub.dev returned HTTP 403, so checks used the packages already present locally.
- Built and installed the local universal APK (`0.1.0`) at `build/app/outputs/flutter-apk/app-release.apk` on the connected Android phone. A subsequent technical follow-up adds Android's unmetered-VPN flag; that newer APK built successfully (183,150,965 bytes), but the phone disconnected from Wireless Debugging before the update could be installed. The working tree has not been pushed to GitHub, so no GitHub Actions APK exists for it yet.

The Android APK version is `0.1.0`. GitHub Actions assigns each workflow run a unique increasing build number; use the artifact name and commit suffix to distinguish downloads. The source version remains stable across CI runs.

### Current source changes since the last confirmed APK build (`f4e1e0e`)

- Rebuilt the Home connection area as one map/control scene with faded map edges, uniform geographic scaling, country framing from the connection name, and a destination label anchored to the resolved city or country center.
- Removed Antarctic geometry and latitude/longitude grid lines from the home scene; compacted the power control and retained its stationary glyph with a rotating connecting arc.
- Replaced the three usage dashboard tiles with one bilingual session/quota card, including a session total, inline download/upload values, finite-quota progress, and explicit unlimited/unavailable states.
- Simplified the subscription entry and Split Tunneling entry into secondary rows; subscription expiry now reads No expiry, Expires <date>, or Expired.
- Suppressed stale connection health data and only label a recent, low-latency node with sufficient healthy history as Stable.
- Added tests for the single-card hierarchy, quota states, Persian/light presentation, country resolution from a connection name, and unlimited quota metadata.

### Prior confirmed batch (`f4e1e0e`)

- Corrected Natural Earth DBF NUL padding that prevented ISO country matching; verified countries can now highlight and the camera can zoom to their region.
- Reworked the home header brand to show only bold “Connecso”; styled theme/language icon actions and fixed their physical positions across LTR/RTL.
- Made usage tiles equal-height, combined saved subscription name and expiry into one full-width tile, and replaced stability percentages with localized Stable/Unstable text beside Ping.
- Corrected the English Split Tunneling subtitle and stabilized its physical row layout across language changes.
- Removed pull-to-refresh from the home scroll; subscription data continues to refresh on app/profile load and through Android background scheduling.
- Treats the real 3x-ui `expire=0` subscription metadata as an explicit no-expiry state instead of showing Unavailable.
- Uses one shared destination zoom scale for the map and marker, keeping the city marker geographically aligned through the transition.
- Added regression coverage for country identifiers, base64 subscription-userinfo metadata, connected Ping/Stability and matching usage-tile dimensions.

- Added scheduled background refresh for saved HTTPS subscriptions using Android WorkManager, subject to Android network and battery scheduling policies.
- Added Android VPN service tracking for underlying network changes and service intent redelivery after process recreation.
- Added the combined session usage total alongside download and upload counters.
- Added connected-state ping and stability presentation.
- Persisted connection establishment duration and included it in SmartSelector scoring.
- Kept country-only server metadata honest: the app no longer fabricates a city when one cannot be resolved.
- Improved localized connection failure messages and corrected the Persian Split Tunneling title.
- Added the supplied transparent CONNECSO logo variants for dark/light themes. The brand stays on the left and language/theme buttons stay on the right when switching between English and Persian.
- Removed the general header menu. Saved subscription selection, rename, add, and sign-out remain in a subscription manager opened from the home subscription card.
- Replaced the approximate continent illustration with a local Natural Earth country map, typed location resolution, country-only framing, verified connection transitions, reconnect/failover camera movement, reduced-motion behavior, and a restrained destination pulse.
- Kept Xray as the only VPN core; no Sing-box runtime or core switching is included.

### Validation status

These notes describe the source included in a matching Actions run. This UI batch still requires a successful analyze/test/APK workflow and Android device visual validation before an APK is offered for download.

## Build identification

Each APK artifact is named in this format:

`connecso-client-v<app-version>-build-<CI-run-number>-android-universal-<commit>`

The matching changelog artifact uses the same version, build number, and commit suffix. Compare all three values before downloading so the notes and APK come from the same workflow run.
