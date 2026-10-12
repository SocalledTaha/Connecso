# CONNECSO Android UI Specification

This document records the approved Android UI behavior and the current implementation. The user-supplied storyboard is the visual reference; compare on a device before claiming visual acceptance.

## Product rules

- Keep networking complexity out of the normal user interface. Do not expose cores, protocols, probes, DNS, raw configuration, or diagnostics.
- Keep the Power control and connection status visually dominant; use restrained cyan/blue accents, rounded geometry, and subtle map detail.
- Split Tunneling is the intentional user-facing network configuration. Other primary settings are language and theme.
- Show a VPN exit location only after connection verification. Never show the user's physical location or request location permission for the map.

## Screen behavior

### Home

Place the transparent theme-matched logo and bold `Connecso` name on the physical left. Keep language then theme icon buttons on the physical right in both locales. With an active profile, show Split Tunneling as a compact card and keep the ConnectionControl, map, state, and verified destination layered in one connection area. Place three equal-height usage tiles (`This Session`, total usage, remaining quota) below it, followed by one full-width Subscription tile showing both the saved profile name and expiry. Keep physical card order stable in RTL while text remains right-to-left. `This Session` shows upload and download separately. Do not trigger subscription refresh by scrolling; refresh runs on app/profile load and through Android background scheduling. Expiry is read from Happ-compatible `subscription-userinfo` HTTP headers or `#subscription-userinfo` body metadata (including base64-encoded subscription bodies) and formatted for the active locale; unknown values remain explicitly unavailable and are never invented.

### Connection states

Represent disconnected, preparing/connecting, verifying, reconnecting, connected, disconnecting, and failed states with the same central control and readable status. Connected is displayed only after the tunnel is verified. A recovery attempt must communicate reconnecting and update the destination only after the replacement is verified. On ultimate failure, show a concise reason and failed state.

### Subscription management

Settings lists saved profiles, marks the active one, allows selecting another saved profile, renaming a profile, adding a subscription, and deactivating the active profile. Deactivation leaves it in the saved list; its confirmation explains this. New subscriptions can be added without replacing or deleting saved profiles. URL imports use the provider's profile title when present, while a user-edited name remains in control. Disable management actions while connection, refresh, or probing work makes switching unsafe. These interactions were added in commit `a173c97` and are present in `HomeScreen` and `SettingsSheet`.

### Settings and split tunneling

Settings contains subscription list/actions and remains free of advanced core controls. Split Tunneling is a separate screen with `OFF`, `Use Proxy`, and `Bypass` modes. It lists installed launcher apps, hides system apps by default, and treats Google apps as user apps. Search filters by app name or package name. Select all, invert, and clear actions appear above the list. Each visible row shows its package name and Android icon when available, with a generic fallback. The complete selection is persisted when toggling system-app visibility and is applied by Android VpnService. Import and export actions back up the selected mode and package list.

## Motion and map

- The connection control uses a stationary power icon/text and a rotating partial arc while busy. The arc is indeterminate, not a percentage. Disconnected is neutral/blue, connected green, and failure restrained red. The target motion is smooth, continuous, and about 1.2–1.6 seconds per revolution.
- The map is a subtle background visualization. It has no active marker before verified connection; a connected exit uses a green marker/pulse and represents only the VPN exit. It must not overpower the control.
- Respect the platform's reduced-motion setting by stopping rotation and pulse while retaining textual status and destination.

## Localization, themes, and accessibility

Support English LTR and Persian RTL as layout directions, not only translated strings. Both dark and light themes must preserve readable contrast and the same semantic state colors. Controls need meaningful accessible names, action hints, and enabled state; textual status must remain available when animation is disabled. Touch targets, text scaling, focus order, contrast, and screen-reader behavior require validation on device before acceptance.

## Current implementation coverage and gaps

| Area | Source evidence | Status / remaining acceptance |
|---|---|---|
| Home/import/usage | `lib/ui/home/home_screen.dart`, `lib/app/connecso_app.dart`, `lib/domain/services/usage_service.dart` | Main states and import paths exist. Session upload/download use Xray traffic stats with an Android UID traffic-counter fallback; expiry metadata is parsed from Happ-compatible HTTPS response headers or subscription-body metadata and displayed in the combined Subscription/Expires tile when supplied. Validate values against a live server/device. |
| Saved subscriptions | `lib/ui/settings/settings_sheet.dart`, `lib/ui/home/home_screen.dart` | Selection, rename, add, and deactivate-with-retention are implemented. Validate full interaction and persistence on Android. |
| Language/theme | `lib/app/connecso_app.dart`, `lib/l10n/app_strings.dart` | English/Persian locales and light/dark themes are configured. Confirm effective RTL direction and check translation completeness/contrast on device. |
| Connection ring | `lib/ui/widgets/connection_control.dart` | Partial rotating arc, reduced-animation handling, complete green connected ring, and 260 ms accent transition are implemented. Motion and visual continuity still need device acceptance review. |
| Dynamic map | `lib/ui/widgets/connection_map.dart` | Bundled custom-painted local map, busy indicator, connected city marker/pulse, 1.15-second regional pan/zoom toward verified destinations, and country-only framing are implemented. Country ISO identifiers are normalized to remove source DBF NUL padding. Verify motion and framing on Android. |
| Split Tunneling | `lib/ui/split_tunneling/split_tunneling_screen.dart`, `android-host/src/main/kotlin/com/connecso/client/MainActivity.kt` | User apps are shown by default; system apps are hidden until enabled from the overflow menu. Google apps are classified as user apps. Search matches app labels and package names. Visible rows load Android icons lazily; a generic icon is the fallback. Selection persists when changing visibility. Verify the app list and search in English/RTL on device. |
| Accessibility | connection control exposes button semantics; animation checks `disableAnimations` | No complete accessibility audit is evidenced. Verify all controls, dialogs, focus, scalable text, contrast, and reduced-motion behavior on Android. |
| Visual reference | User-supplied connection storyboard and latest correction screenshot | Brand text, fixed-position language/theme actions, fixed-size usage tiles, combined subscription/expiry tile, localized Split Tunneling subtitle, ping/stable text, and map-country matching have been corrected in source. Compare every screen state on Android before claiming visual acceptance. |

## Visual acceptance checklist

1. Compare the Android screens against the supplied approved five-state storyboard; complete the home-screen alignment and visual review.
2. Verify no-profile and profile home states, all connection states, active/saved subscription management, and split-tunneling entry.
3. Verify English/LTR and Persian/RTL in both light and dark themes, including dialogs, settings, errors, and long subscription names.
4. Verify animation continuity and reduced-motion behavior, and ensure the map never communicates a destination before verified connectivity.
5. Verify accessibility with screen reader, larger text, keyboard/focus navigation where applicable, and adequate contrast/touch targets.
