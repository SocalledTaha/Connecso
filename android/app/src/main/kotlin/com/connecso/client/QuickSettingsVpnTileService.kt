package com.connecso.client

import android.app.ActivityManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/** Quick Settings toggle for the last successfully selected Xray profile. */
class QuickSettingsVpnTileService : TileService() {
    private val stateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == QuickTileStore.ACTION_STATE_CHANGED) {
                updateTileState()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = android.content.IntentFilter(QuickTileStore.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(stateReceiver, filter)
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(stateReceiver) }
        super.onDestroy()
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()
        val intent = if (QuickTileStore.isActive(this)) {
            Intent(this, ConnecsoVpnService::class.java)
                .setAction(ConnecsoVpnService.ACTION_STOP)
                .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, UUID.randomUUID().toString())
        } else {
            val configuration = QuickTileStore.readConfiguration(this)
            if (configuration == null || VpnService.prepare(this) != null) {
                openApplication()
                return
            }
            val packages = configuration.optJSONArray("packages") ?: JSONArray()
            Intent(this, ConnecsoVpnService::class.java)
                .setAction(ConnecsoVpnService.ACTION_START)
                .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, UUID.randomUUID().toString())
                .putExtra(ConnecsoVpnService.EXTRA_CONFIG, configuration.getString("config"))
                .putExtra(ConnecsoVpnService.EXTRA_SPLIT_MODE, configuration.optString("mode", "off"))
                .putExtra(ConnecsoVpnService.EXTRA_NODE_ID, configuration.optString("nodeId"))
                .putStringArrayListExtra(
                    ConnecsoVpnService.EXTRA_SPLIT_PACKAGES,
                    ArrayList<String>(packages.length()).apply {
                        for (index in 0 until packages.length()) add(packages.optString(index))
                    },
                )
        }
        try {
            if (intent.action == ConnecsoVpnService.ACTION_START && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Exception) {
            openApplication()
        } finally {
            updateTileState()
        }
    }

    private fun updateTileState() {
        // The status file is written by the VPN service only after a successful
        // dataplane transition (and cleared on every stop/failure).  Checking
        // ActivityManager here introduced a race: the service process can be
        // alive before the TUN is ready, or remain visible briefly after stop,
        // leaving the tile one state behind.  Use the authoritative state file
        // and let requestListeningState refresh the tile immediately.
        val active = QuickTileStore.isActive(this)
        qsTile?.let { tile ->
            tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            tile.label = "CONNECSO"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                tile.subtitle = if (resources.configuration.locales[0].language == "fa") {
                    if (active) "قطع اتصال" else "اتصال"
                } else if (active) {
                    "Disconnect"
                } else {
                    "Connect"
                }
            }
            tile.updateTile()
        }
    }

    private fun openApplication() {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= 34) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}

/** Cross-process status plus an encrypted last-used profile for the tile. */
internal object QuickTileStore {
    const val ACTION_STATE_CHANGED = "com.connecso.client.QUICK_TILE_STATE_CHANGED"
    private const val KEY_ALIAS = "connecso.quick-settings.v1"
    private const val ACTIVE = "active"
    private const val IDLE = "idle"

    private fun configurationFile(context: Context) =
        AtomicFile(File(context.noBackupFilesDir, "quick_settings_profile.enc"))

    private fun statusFile(context: Context) =
        AtomicFile(File(context.noBackupFilesDir, "quick_settings_status"))

    fun saveConfiguration(
        context: Context,
        config: String,
        mode: String,
        packages: List<String>,
        nodeId: String,
    ) {
        val plainText = JSONObject()
            .put("config", config)
            .put("mode", mode)
            .put("packages", JSONArray(packages))
            .put("nodeId", nodeId)
            .toString()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val encrypted = cipher.iv + cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
        writeAtomically(configurationFile(context), Base64.encode(encrypted, Base64.NO_WRAP))
    }

    fun readConfiguration(context: Context): JSONObject? = runCatching {
        val encoded = configurationFile(context).openRead().use { it.readBytes() }
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        require(combined.size > 12)
        val iv = combined.copyOfRange(0, 12)
        val encrypted = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        JSONObject(String(cipher.doFinal(encrypted), StandardCharsets.UTF_8))
    }.getOrNull()

    fun readConnection(context: Context): Map<String, Any?> {
        val config = readConfiguration(context)
        val serviceRunning = isTunnelServiceRunning(context)
        return mapOf(
            // This state is written by ConnecsoVpnService only after the
            // dataplane is ready and cleared on every stop/failure.
            "active" to isActive(context),
            // Activity recreation/lock-screen transitions can briefly leave
            // the persisted tile flag stale while the VPN service is still
            // holding the TUN and Xray session.
            "serviceRunning" to serviceRunning,
            "nodeId" to config?.optString("nodeId").orEmpty().ifBlank { null },
        )
    }

    fun isTunnelServiceRunning(context: Context): Boolean = runCatching {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        manager.getRunningServices(Int.MAX_VALUE).any {
            it.service.className == ConnecsoVpnService::class.java.name
        }
    }.getOrDefault(false)


    fun setActive(context: Context, active: Boolean) {
        writeAtomically(statusFile(context), (if (active) ACTIVE else IDLE).toByteArray())
        context.sendBroadcast(
            Intent(ACTION_STATE_CHANGED).setPackage(context.packageName),
        )
        requestTileRefresh(context)
    }

    fun isActive(context: Context): Boolean = runCatching {
        statusFile(context).openRead().bufferedReader().use { it.readText() == ACTIVE }
    }.getOrDefault(false)

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun writeAtomically(file: AtomicFile, data: ByteArray) {
        var output: FileOutputStream? = null
        try {
            output = file.startWrite()
            output.write(data)
            file.finishWrite(output)
        } catch (error: Exception) {
            if (output != null) file.failWrite(output)
            throw error
        }
    }

    private fun requestTileRefresh(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val component = ComponentName(context, QuickSettingsVpnTileService::class.java)
            fun request() = runCatching {
                TileService.requestListeningState(context, component)
            }
            request()
            // The tile service may be between listening callbacks when the
            // VPN result arrives. Retry briefly so the icon converges without
            // reintroducing foreground polling.
            val handler = Handler(Looper.getMainLooper())
            handler.postDelayed({ request() }, 120L)
            handler.postDelayed({ request() }, 320L)
        }
    }
}
