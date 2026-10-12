# UI Specification

The home screen stays sparse: the transparent CONNECSO logo with the single bold name `Connecso`, one large stateful power control, connection status, exit location after verification, session/total/remaining quota, subscription name and expiry, and a subtle bundled world map. Without a profile, only clipboard import and QR import are prominent. With a profile, the only network setting is Split Tunneling. Language and theme controls sit in fixed physical header positions; there is no general menu. `This Session` shows upload and download separately, as in the supplied storyboard.

Do not refresh subscription data from scroll gestures. Refresh on app/profile load and through Android background scheduling. Read Happ-compatible `Subscription-Userinfo` response headers or body metadata, including base64-encoded feeds. For 3x-ui, `expire=0` means no expiry date is configured; show a localized “No expiry” state rather than “Unavailable.” A missing or malformed expiry remains “Unavailable.”

Persian is RTL, English is LTR. Dark mode uses navy, low-contrast cyan geography, blue connecting, green verified exit, and restrained red failure. Light mode uses a quiet gray/blue map with identical semantic states. Reduced-motion preferences reduce or disable rotation, zoom, and pulse without hiding textual state.

The approved home storyboard defines the header, Split Tunneling card, map/control layering, and session traffic layout. Validate all states on Android before claiming visual acceptance.
