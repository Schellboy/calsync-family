package dev.henriquecouto.calsync

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.CalendarContract.Events
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

class SoftDeletePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(
            binding.binaryMessenger, "calsync/calendar", StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue()
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val value = when (call.method) {
                "sourceChange" -> sourceChange(call)
                "sourceExceptionKeys" -> sourceExceptionKeys(call)
                "canDeleteEvents" -> canDeleteEvents()
                "updateOwnedEvent" -> mutateOwnedEvent(call, delete = false)
                "deleteOwnedEvent" -> mutateOwnedEvent(call, delete = true)
                else -> {
                    result.notImplemented()
                    return
                }
            }
            result.success(value)
        } catch (_: Exception) {
            result.error("CALENDAR_OPERATION_FAILED", "Could not safely verify or modify the calendar event.", null)
        }
    }

    private fun canDeleteEvents(): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        return context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
    }

    private fun sourceExceptionKeys(call: MethodCall): Map<String, List<String>> {
        val calendarId = requireNotNull(call.argument<String>("calendarId"))
        val ids = requireNotNull(call.argument<List<String>>("eventIds"))
        val result = mutableMapOf<String, List<String>>()
        val projection = arrayOf(Events._ID, Events.ORIGINAL_ID, Events.ORIGINAL_INSTANCE_TIME)
        for (chunk in ids.chunked(250)) {
            val placeholders = chunk.joinToString(",") { "?" }
            val selection = "${Events.CALENDAR_ID} = ? AND ${Events._ID} IN ($placeholders)"
            checkNotNull(context.contentResolver.query(
                Events.CONTENT_URI, projection, selection, (listOf(calendarId) + chunk).toTypedArray(), null
            )).use { cursor ->
                check(cursor.count == chunk.size)
                while (cursor.moveToNext()) {
                    if (cursor.isNull(1) || cursor.isNull(2)) continue
                    val originalId = cursor.getString(1)
                    result[cursor.getString(0)] = listOf(originalId, "$originalId@${cursor.getLong(2)}")
                }
            }
        }
        return result
    }

    private fun sourceChange(call: MethodCall): Map<String, Any> {
        val calendarId = requireNotNull(call.argument<String>("calendarId"))
        val eventId = requireNotNull(call.argument<String>("eventId"))
        val instanceId = call.argument<String>("instanceId")
        val projection = arrayOf(Events._ID, Events.DELETED, Events.STATUS)
        val resolver = context.contentResolver
        val master = checkNotNull(resolver.query(
            Events.CONTENT_URI, projection,
            "${Events.CALENDAR_ID} = ? AND ${Events._ID} = ?", arrayOf(calendarId, eventId), null
        )).use { cursor ->
            if (!cursor.moveToFirst()) return emptyMap()
            cursor.getInt(1) != 0 || cursor.getInt(2) == Events.STATUS_CANCELED
        }
        if (master) return mapOf("removed" to true)
        if (instanceId == null) return emptyMap()
        val originalStart = instanceId.removePrefix("$eventId@").toLongOrNull() ?: return emptyMap()
        if (!instanceId.startsWith("$eventId@")) return emptyMap()

        return checkNotNull(resolver.query(
            Events.CONTENT_URI, projection,
            "${Events.CALENDAR_ID} = ? AND ${Events.ORIGINAL_ID} = ? AND ${Events.ORIGINAL_INSTANCE_TIME} = ?",
            arrayOf(calendarId, eventId, originalStart.toString()), null
        )).use { cursor ->
            // Absence (including hard deletes) is not proof of removal.
            if (cursor.count != 1 || !cursor.moveToFirst()) return@use emptyMap()
            if (cursor.getInt(1) != 0 || cursor.getInt(2) == Events.STATUS_CANCELED) {
                mapOf("removed" to true)
            } else {
                mapOf("movedId" to cursor.getString(0))
            }
        }
    }

    private fun calendarMillis(millis: Long, allDay: Boolean): Long {
        if (!allDay) return millis
        return Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).toLocalDate()
            .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    }

    private fun mutateOwnedEvent(call: MethodCall, delete: Boolean): Boolean {
        if (delete && !canDeleteEvents()) return false
        val allDay = requireNotNull(call.argument<Boolean>("oldAllDay"))
        val description = requireNotNull(call.argument<String>("oldDescription"))
        val location = call.argument<String>("oldLocation")
        val selection = """${Events._ID} = ? AND ${Events.CALENDAR_ID} = ? AND ${Events.DELETED} = 0
            AND (${Events.STATUS} IS NULL OR ${Events.STATUS} <> ${Events.STATUS_CANCELED})
            AND ${Events.DESCRIPTION} = ? AND COALESCE(${Events.TITLE}, '') = ? AND ${Events.DTSTART} = ?
            AND ${Events.DTEND} = ? AND ${Events.ALL_DAY} = ? AND COALESCE(${Events.EVENT_LOCATION}, '') = ?
            AND COALESCE(${Events.RRULE}, '') = '' AND COALESCE(${Events.RDATE}, '') = ''
            AND ${Events.ORIGINAL_ID} IS NULL AND COALESCE(${Events.ORIGINAL_SYNC_ID}, '') = ''""".trimIndent()
        val args = arrayOf(
            requireNotNull(call.argument<String>("eventId")),
            requireNotNull(call.argument<String>("calendarId")),
            description,
            requireNotNull(call.argument<String>("oldTitle")),
            calendarMillis(number(call, "oldStart"), allDay).toString(),
            calendarMillis(number(call, "oldEnd"), allDay).toString(),
            if (allDay) "1" else "0",
            location.orEmpty(),
        )
        val resolver = context.contentResolver
        if (delete) return resolver.delete(Events.CONTENT_URI, selection, args) == 1
        val newAllDay = requireNotNull(call.argument<Boolean>("allDay"))
        val values = ContentValues().apply {
            put(Events.TITLE, call.argument<String>("title"))
            put(Events.DESCRIPTION, call.argument<String>("description"))
            put(Events.EVENT_LOCATION, call.argument<String>("location"))
            put(Events.ALL_DAY, if (newAllDay) 1 else 0)
            put(Events.DTSTART, calendarMillis(number(call, "start"), newAllDay))
            put(Events.DTEND, calendarMillis(number(call, "end"), newAllDay))
            put(Events.EVENT_TIMEZONE, if (newAllDay) "UTC" else ZoneId.systemDefault().id)
            put(Events.EVENT_END_TIMEZONE, if (newAllDay) "UTC" else ZoneId.systemDefault().id)
        }
        return resolver.update(Events.CONTENT_URI, values, selection, args) == 1
    }

    private fun number(call: MethodCall, name: String): Long =
        requireNotNull(call.argument<Number>(name)).toLong()
}
