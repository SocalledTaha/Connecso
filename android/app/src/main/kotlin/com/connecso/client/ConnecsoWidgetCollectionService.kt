package com.connecso.client

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray
import org.json.JSONObject

class ConnecsoWidgetCollectionService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        DestinationFactory(applicationContext, intent)
}

private class DestinationFactory(
    private val context: android.content.Context,
    intent: Intent,
) : RemoteViewsService.RemoteViewsFactory {
    private val widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
    private var entries: List<Pair<Int, JSONObject>> = emptyList()

    override fun onCreate() = loadEntries()

    override fun onDataSetChanged() = loadEntries()

    private fun loadEntries() {
        val prefs = context.getSharedPreferences("connecso_widget", android.content.Context.MODE_PRIVATE)
        val json = runCatching {
            JSONArray(prefs.getString("widgetDestinations", "[]") ?: "[]")
        }.getOrDefault(JSONArray())
        val source = (0 until json.length()).mapNotNull { index ->
            json.optJSONObject(index)?.let { index to it }
        }
        if (source.isEmpty()) {
            entries = emptyList()
            return
        }
        val selected = prefs.getInt("selectedDestinationIndex", 0).coerceIn(0, source.lastIndex)
        // StackView shows its first child on top. Put the last selected profile
        // there while preserving the remaining order for vertical flicking.
        entries = source.drop(selected) + source.take(selected)
    }

    override fun getCount(): Int = entries.size

    override fun getViewAt(position: Int): RemoteViews? {
        val (originalIndex, entry) = entries.getOrNull(position) ?: return null
        val views = RemoteViews(
            context.packageName,
            R.layout.connecso_widget_destination_item,
        )
        val country = entry.optString("countryName").ifBlank { "Destination" }
        val endpoint = entry.optString("nodeName").ifBlank { entry.optString("protocol") }
        val protocol = entry.optString("protocol")
        views.setTextViewText(R.id.widget_destination_title, country)
        views.setTextViewText(
            R.id.widget_destination_subtitle,
            listOf(endpoint, protocol).filter(String::isNotBlank).distinct().joinToString(" · "),
        )
        views.setOnClickFillInIntent(
            R.id.widget_destination_card,
            Intent().setAction(ConnecsoWidgetProvider.ACTION_CONNECT_DESTINATION)
                .putExtra(ConnecsoWidgetProvider.EXTRA_POSITION, originalIndex)
                .putExtra(ConnecsoWidgetProvider.EXTRA_NODE_ID, entry.optString("nodeId"))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId),
        )
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = entries.getOrNull(position)?.first?.toLong() ?: position.toLong()

    override fun hasStableIds(): Boolean = true

    override fun onDestroy() = Unit
}
