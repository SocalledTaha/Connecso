# Platform Capabilities

The current build target is Android. Android may advertise system VPN, per-app routing, QR camera/image import, and whichever core runtimes are actually bundled. A capability must remain false until its implementation can perform the operation.

Windows and iOS are not being implemented now. Future adapters should expose only verified platform behavior; do not scatter platform checks across widgets.
