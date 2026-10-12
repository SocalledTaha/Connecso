# Android Split Tunneling

The user-facing control is labelled **مسیریابی جداگانهٔ برنامه‌ها** in Persian. It supports two policies: route only selected packages through the VPN, or exclude selected packages from the VPN. Persist package identifiers and policy mode in secure storage. On Android, validate the packages against the installed-app list and map the selected mode to `VpnService.Builder.addAllowedApplication` or `addDisallowedApplication` while constructing the VPN interface.

The Flutter screen persists the policy and passes it through `ConnectionManager`, `ProxyCore`, and the Android adapter. The Android Xray `VpnService` now applies selections with `VpnService.Builder.addAllowedApplication` or `addDisallowedApplication` before creating the TUN interface.

The CONNECSO app package is always included in include-selected mode and is not offered in the exclusion list. The app uses its own HTTPS request after tunnel startup to verify that the selected route is usable. Other applications follow the user's saved policy.
