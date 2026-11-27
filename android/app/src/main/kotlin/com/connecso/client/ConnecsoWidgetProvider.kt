package com.connecso.client

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import org.json.JSONArray
import android.widget.RemoteViews
import android.view.View

/** Home-screen shortcut for opening Connecso quickly. */
class ConnecsoWidgetProvider : AppWidgetProvider() {
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        onUpdate(context, manager, intArrayOf(appWidgetId))
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_CONNECT_DESTINATION) {
            val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
            val position = intent.getIntExtra(EXTRA_POSITION, -1)
            val nodeId = intent.getStringExtra(EXTRA_NODE_ID).orEmpty()
            val prefs = context.getSharedPreferences("connecso_widget", Context.MODE_PRIVATE)
            val entries = runCatching {
                JSONArray(prefs.getString("widgetDestinations", "[]"))
            }.getOrDefault(JSONArray())
            val entry = (0 until entries.length())
                .mapNotNull(entries::optJSONObject)
                .firstOrNull { nodeId.isNotBlank() && it.optString("nodeId") == nodeId }
                ?: entries.optJSONObject(position)
            val selectedPosition = (0 until entries.length()).firstOrNull {
                entries.optJSONObject(it)?.optString("nodeId") == entry?.optString("nodeId")
            } ?: position
            if (entry != null) {
                val packages = entry.optJSONArray("packages") ?: JSONArray()
                QuickTileStore.saveConfiguration(
                    context = context,
                    config = entry.optString("config"),
                    mode = entry.optString("mode", "off"),
                    packages = List(packages.length()) { index -> packages.optString(index) },
                    nodeId = entry.optString("nodeId"),
                    countryName = entry.optString("countryName"),
                    countryCode = entry.optString("countryCode"),
                )
                prefs.edit()
                    .putInt("selectedDestinationIndex", selectedPosition)
                    .putString("country", entry.optString("countryName"))
                    .apply()
                if (VpnService.prepare(context) != null) {
                    context.startActivity(
                        Intent(context, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                } else {
                    val serviceIntent = Intent(context, ConnecsoVpnService::class.java)
                        .setAction(ConnecsoVpnService.ACTION_START)
                        .putExtra(ConnecsoVpnService.EXTRA_CONFIG, entry.optString("config"))
                        .putExtra(ConnecsoVpnService.EXTRA_SPLIT_MODE, entry.optString("mode", "off"))
                        .putExtra(ConnecsoVpnService.EXTRA_NODE_ID, entry.optString("nodeId"))
                        .putExtra(ConnecsoVpnService.EXTRA_COUNTRY_NAME, entry.optString("countryName"))
                        .putExtra(ConnecsoVpnService.EXTRA_COUNTRY_CODE, entry.optString("countryCode"))
                        .putStringArrayListExtra(
                            ConnecsoVpnService.EXTRA_SPLIT_PACKAGES,
                            ArrayList<String>(packages.length()).apply {
                                for (index in 0 until packages.length()) add(packages.optString(index))
                            },
                        )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                }
                if (appWidgetId >= 0) onUpdate(
                    context,
                    AppWidgetManager.getInstance(context),
                    intArrayOf(appWidgetId),
                )
            }
            return
        }
        if (intent.action == ACTION_TOGGLE) {
            if (QuickTileStore.isActive(context)) {
                context.startService(Intent(context, ConnecsoVpnService::class.java).setAction(ConnecsoVpnService.ACTION_STOP))
            } else {
                val config = QuickTileStore.readConfiguration(context)
                if (config == null || VpnService.prepare(context) != null) {
                    context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } else {
                    val packages = config.optJSONArray("packages") ?: JSONArray()
                    val serviceIntent = Intent(context, ConnecsoVpnService::class.java)
                        .setAction(ConnecsoVpnService.ACTION_START)
                        .putExtra(ConnecsoVpnService.EXTRA_CONFIG, config.getString("config"))
                        .putExtra(ConnecsoVpnService.EXTRA_SPLIT_MODE, config.optString("mode", "off"))
                        .putExtra(ConnecsoVpnService.EXTRA_NODE_ID, config.optString("nodeId"))
                        .putExtra(ConnecsoVpnService.EXTRA_COUNTRY_NAME, config.optString("countryName"))
                        .putExtra(ConnecsoVpnService.EXTRA_COUNTRY_CODE, config.optString("countryCode"))
                        .putStringArrayListExtra(ConnecsoVpnService.EXTRA_SPLIT_PACKAGES,
                            ArrayList<String>().apply { for (i in 0 until packages.length()) add(packages.optString(i)) })
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(serviceIntent)
                    else context.startService(serviceIntent)
                }
            }
        }
        super.onReceive(context, intent)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val toggle = PendingIntent.getBroadcast(
            context, 702,
            Intent(context, ConnecsoWidgetProvider::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        ids.forEach { id ->
            val options = manager.getAppWidgetOptions(id)
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
            // One-row compact widgets use a centered power control, wide one-row
            // widgets reserve an inline quota meter, and every 2+ row widget
            // switches to the vertically spacious layout.
            val large = width >= 330 && height >= 155
            val oneRow = height < 105
            val buttonOnly = oneRow && width < 210
            val tall = !large && height >= 105
            val wideDestinations = oneRow && width >= 240
            val mediumDestinations = !oneRow && width in 240..329 && height >= 105
            // Some launchers report a one-cell width even after the widget is
            // resized horizontally. Keep the action visible at every height
            // for those narrow widgets, without affecting other widths.
            val narrowTall = width < 100 && height >= 105
            val narrowThreeRows = narrowTall && height >= 155
            val wideThree = oneRow && width in 210..279
            val wide = oneRow && width >= 210 && !wideThree
            val medium = !large && !tall && !wide && !wideThree && width >= 210
            val views = RemoteViews(
                context.packageName,
                when {
                    buttonOnly -> R.layout.connecso_widget_button_only
                    wideDestinations -> R.layout.connecso_widget_destinations_wide
                    mediumDestinations -> R.layout.connecso_widget_destinations_medium
                    large -> R.layout.connecso_widget_large
                    narrowTall -> R.layout.connecso_widget_narrow_tall
                    wideThree -> R.layout.connecso_widget_wide_three
                    tall -> R.layout.connecso_widget_tall
                    wide -> R.layout.connecso_widget_wide
                    medium -> R.layout.connecso_widget_medium
                    else -> R.layout.connecso_widget_compact
                },
            )
            val prefs = context.getSharedPreferences("connecso_widget", Context.MODE_PRIVATE)
            // Destination switching needs enough height to make each swipe
            // target readable. Keep it only in the spacious multi-row layout.
            val hasDestinationStack = large || wideDestinations || mediumDestinations
            val active = QuickTileStore.isActive(context)
            val isFa = prefs.getString("language", "en") == "fa"
            val dark = prefs.getBoolean("darkTheme", false)
            val failed = prefs.getBoolean("connectionFailed", false)
            val layoutHasDetails = !buttonOnly
            val actionBackground = when {
                failed -> R.drawable.connecso_widget_power_error
                active -> R.drawable.connecso_widget_power_active
                else -> R.drawable.connecso_widget_power_idle
            }
            views.setInt(
                R.id.widget_root,
                "setBackgroundResource",
                if (dark) R.drawable.connecso_widget_background_dark
                else R.drawable.connecso_widget_background,
            )
            views.setInt(
                R.id.widget_action,
                "setBackgroundResource",
                actionBackground,
            )
            views.setImageViewResource(R.id.widget_action, R.drawable.ic_widget_power)
            val country = prefs.getString("country", "").orEmpty()
                .ifBlank { QuickTileStore.readConfiguration(context)?.optString("countryName").orEmpty() }
            val usageAvailable = prefs.getBoolean("quotaAvailable", false)
            val used = prefs.getLong("usedBytes", -1L)
            val total = prefs.getLong("totalBytes", -1L)
            val remaining = prefs.getLong("remainingBytes", -1L)
            val unlimited = prefs.getBoolean("unlimited", false)
            val usageText = when {
                !usageAvailable || used < 0 -> if (isFa) "مصرف اشتراک در دسترس نیست" else "Subscription usage unavailable"
                unlimited -> if (isFa) "مصرف ${formatBytes(used)} · نامحدود" else "Used ${formatBytes(used)} · Unlimited"
                large -> if (isFa) "مصرف ${formatBytes(used)} · باقیمانده ${if (remaining >= 0) formatBytes(remaining) else "—"}" else "Used ${formatBytes(used)} · Remaining ${if (remaining >= 0) formatBytes(remaining) else "—"}"
                total > 0 -> if (isFa) "${formatBytes(used)} از ${formatBytes(total)}" else "${formatBytes(used)} / ${formatBytes(total)}"
                else -> if (isFa) "مصرف ${formatBytes(used)}" else "Used ${formatBytes(used)}"
            }
            if (layoutHasDetails) {
                views.setTextViewText(R.id.widget_state, when {
                    isFa && active -> "متصل"
                    isFa -> "آمادهٔ اتصال"
                    active -> "Connected"
                    else -> "Ready to connect"
                })
                if (!hasDestinationStack) {
                    views.setTextViewText(R.id.widget_detail, country.ifBlank { "Connecso" })
                }
                val mainText = if (dark) android.graphics.Color.rgb(238, 244, 248)
                    else android.graphics.Color.rgb(16, 33, 44)
                val secondaryText = if (dark) android.graphics.Color.rgb(172, 188, 198)
                    else android.graphics.Color.rgb(82, 102, 115)
                views.setTextColor(R.id.widget_state, mainText)
                views.setTextColor(R.id.widget_detail, secondaryText)
                if (layoutHasDetails) {
                    views.setTextViewText(R.id.widget_usage, usageText)
                    views.setTextColor(
                        R.id.widget_usage,
                        if (dark) android.graphics.Color.rgb(75, 192, 226)
                        else android.graphics.Color.rgb(33, 141, 184),
                    )
                }
            }
            views.setContentDescription(
                R.id.widget_action,
                when {
                    isFa && active -> "قطع اتصال"
                    isFa -> "اتصال"
                    active -> "Disconnect"
                    else -> "Connect"
                },
            )
            if (layoutHasDetails) {
                views.setImageViewResource(
                    R.id.widget_logo,
                    if (dark) R.drawable.connecso_widget_logo_dark
                    else R.drawable.connecso_widget_logo_light,
                )
            }
            if (hasDestinationStack) {
                views.setTextViewText(
                    R.id.widget_destinations_label,
                    when {
                        isFa && prefs.getBoolean("widgetHasFavorites", false) -> "علاقه‌مندی‌ها"
                        isFa -> "همهٔ سرورها"
                        prefs.getBoolean("widgetHasFavorites", false) -> "Favorites"
                        else -> "All servers"
                    },
                )
                views.setTextViewText(
                    R.id.widget_destinations_empty,
                    if (isFa) "مقصدی برای انتخاب نیست" else "No destinations available",
                )
                val stackIntent = Intent(context, ConnecsoWidgetCollectionService::class.java).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    data = android.net.Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
                }
                views.setRemoteAdapter(R.id.widget_destinations, stackIntent)
                views.setEmptyView(R.id.widget_destinations, R.id.widget_destinations_empty)
                val destinationTemplate = PendingIntent.getBroadcast(
                    context,
                    720 + id,
                    Intent(context, ConnecsoWidgetProvider::class.java)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
                views.setPendingIntentTemplate(R.id.widget_destinations, destinationTemplate)
            }
            if (large || tall || wide || wideDestinations || mediumDestinations || narrowThreeRows) {
                val progressVisible = usageAvailable && total > 0 && used >= 0
                views.setViewVisibility(R.id.widget_quota, if (progressVisible) View.VISIBLE else View.GONE)
                if (progressVisible) {
                    val percent = ((used.toDouble() / total.toDouble()) * 100.0).toInt().coerceIn(0, 100)
                    views.setProgressBar(R.id.widget_quota, 100, percent, false)
                }
            }
            if (tall) {
                val scale = when {
                    height >= 220 -> 1.22f
                    height >= 155 -> 1.12f
                    else -> 1.0f
                }
                views.setTextViewTextSize(R.id.widget_state, android.util.TypedValue.COMPLEX_UNIT_SP, 15f * scale)
                views.setTextViewTextSize(R.id.widget_detail, android.util.TypedValue.COMPLEX_UNIT_SP, 12f * scale)
                views.setTextViewTextSize(R.id.widget_usage, android.util.TypedValue.COMPLEX_UNIT_SP, 12f * scale)
            }
            views.setOnClickPendingIntent(R.id.widget_action, toggle)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                android.app.PendingIntent.getActivity(context, 703,
                    Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE),
            )
            manager.updateAppWidget(id, views)
            if (hasDestinationStack) {
                manager.notifyAppWidgetViewDataChanged(id, R.id.widget_destinations)
            }
        }
    }

    companion object {
        private const val ACTION_TOGGLE = "com.connecso.client.WIDGET_TOGGLE"
        internal const val ACTION_CONNECT_DESTINATION = "com.connecso.client.WIDGET_CONNECT_DESTINATION"
        internal const val EXTRA_POSITION = "destinationPosition"
        internal const val EXTRA_NODE_ID = "destinationNodeId"
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ConnecsoWidgetProvider::class.java))
            if (ids.isNotEmpty()) ConnecsoWidgetProvider().onUpdate(context, manager, ids)
        }

        private fun formatBytes(bytes: Long): String {
            if (bytes < 1024L) return "$bytes B"
            val units = arrayOf("KB", "MB", "GB", "TB")
            var value = bytes.toDouble()
            var index = -1
            do {
                value /= 1024.0
                index++
            } while (value >= 1024.0 && index < units.lastIndex)
            return String.format(java.util.Locale.US, "%.2f %s", value, units[index])
        }
    }
}
