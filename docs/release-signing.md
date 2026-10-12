# CONNECSO release signing

The distributed Android `release` variant is signed with the permanent
`connecso-release.jks` certificate. The keystore and passwords are never stored
in this repository.

## Local PowerShell build

Set the four environment variables in a local PowerShell session, then build:

```powershell
$env:CONNECSO_KEYSTORE_FILE="D:\CONNECSO-Secrets\connecso-release.jks"
$env:CONNECSO_KEYSTORE_PASSWORD="<keystore-password>"
$env:CONNECSO_KEY_ALIAS="<key-alias>"
$env:CONNECSO_KEY_PASSWORD="<key-password>"

flutter build apk --release
```

The release build fails when these variables are absent. Debug builds do not
need them and remain separate from distributed release signing.

## GitHub Actions

The Android workflow restores the keystore from the repository secrets
`CONNECSO_KEYSTORE_BASE64`, `CONNECSO_KEYSTORE_PASSWORD`,
`CONNECSO_KEY_ALIAS`, and `CONNECSO_KEY_PASSWORD` into the ephemeral runner
directory. It verifies every Universal and ABI APK with `apksigner` before the
GitHub Release upload.

The workflow uses the GitHub Actions run number as `versionCode`, so each later
release has a higher update version. The production application ID remains
`com.connecso.client`.
