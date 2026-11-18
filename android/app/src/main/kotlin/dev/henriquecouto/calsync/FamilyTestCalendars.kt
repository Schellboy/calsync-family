package dev.henriquecouto.calsync

import android.content.ContentValues
import android.content.Context
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import java.util.TimeZone

internal class FamilyTestCalendars(private val context: Context) {
    companion object {
        private const val account = "de.schellboy.calsyncfamily.test"
        private const val sourceA = "CalSync Family Test - Source A"
        private const val sourceB = "CalSync Family Test - Source B"
        private const val target = "CalSync Family Test - Target"
        private val names = listOf(sourceA, sourceB, target)
        fun isTestBuild(context: Context) = context.packageName == account
    }

    fun list(): Map<String, String> {
        check(isTestBuild(context))
        val projection = arrayOf(Calendars._ID, Calendars.NAME)
        val selection = "${Calendars.ACCOUNT_NAME} = ? AND ${Calendars.ACCOUNT_TYPE} = ? AND ${Calendars.OWNER_ACCOUNT} = ?"
        val args = arrayOf(account, CalendarContract.ACCOUNT_TYPE_LOCAL, account)
        return checkNotNull(context.contentResolver.query(
            Calendars.CONTENT_URI, projection, selection, args, null
        )).use { cursor ->
            buildMap {
                while (cursor.moveToNext()) {
                    val name = cursor.getString(1)
                    if (name !in names) continue
                    check(put(name, cursor.getString(0)) == null)
                }
            }
        }
    }

    fun ids(): Map<String, String> {
        val calendars = list()
        return mapOf("sourceA" to calendars[sourceA], "sourceB" to calendars[sourceB], "target" to calendars[target])
            .mapNotNull { (role, id) -> id?.let { role to it } }.toMap()
    }

    fun allowsEventRead(eventId: String): Boolean {
        val calendars = list().values.toList()
        if (calendars.isEmpty()) return false
        val bound = calendars.joinToString(",") { "?" }
        return checkNotNull(context.contentResolver.query(
            Events.CONTENT_URI, arrayOf(Events._ID),
            "${Events._ID} = ? AND ${Events.CALENDAR_ID} IN ($bound)",
            (listOf(eventId) + calendars).toTypedArray(), null
        )).use { it.moveToFirst() }
    }

    fun requireSource(id: String) {
        if (isTestBuild(context)) {
            val calendars = list()
            check(id == calendars[sourceA] || id == calendars[sourceB])
        }
    }

    fun requireTarget(id: String) {
        if (isTestBuild(context)) check(id == list()[target])
    }

    fun prepare(): Boolean {
        val existing = list()
        val uri = Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(Calendars.ACCOUNT_NAME, account)
            .appendQueryParameter(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            .build()
        for (name in names) {
            if (name in existing) continue
            val values = ContentValues().apply {
                put(Calendars.ACCOUNT_NAME, account)
                put(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
                put(Calendars.OWNER_ACCOUNT, account)
                put(Calendars.NAME, name)
                put(Calendars.CALENDAR_DISPLAY_NAME, name)
                put(Calendars.CALENDAR_ACCESS_LEVEL, Calendars.CAL_ACCESS_OWNER)
                put(Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)
                put(Calendars.CALENDAR_COLOR, 0xff486584.toInt())
                put(Calendars.VISIBLE, 1)
                put(Calendars.SYNC_EVENTS, 0)
            }
            checkNotNull(context.contentResolver.insert(uri, values))
        }
        return true
    }
}
