package com.elderlyassistant.services.family

import android.content.Context
import android.content.SharedPreferences

/**
 * Per-event-type caregiver notification preferences (caregiver
 * event-notifications task, 2026-09-13) — the Android mirror of the iOS
 * `CaregiverNotifySettings`. Configure once, events of that type
 * auto-notify; all three default OFF.
 *
 * Stored in plain `SharedPreferences`, NOT the encrypted store: these
 * are UI preferences, not secrets. The settings hold three booleans and
 * nothing else — no contact data, no event titles.
 *
 * Resolved at FIRE TIME, never stored on the event: flipping a toggle
 * changes the behavior of every subsequent fire and of nothing that
 * already fired.
 *
 * **Android has no event fire wiring yet** (this change mirrors the seam
 * only), so nothing reads these values at runtime on this platform —
 * the class exists so the platform stays shaped like iOS and the fire
 * wiring, when it lands, has one place to ask.
 */
class NotifySettings(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Notify caregivers when a medication dose reminder fires. */
    var medicationReminders: Boolean
        get() = prefs.getBoolean(KEY_MEDICATION, false)
        set(value) = prefs.edit().putBoolean(KEY_MEDICATION, value).apply()

    /** Notify caregivers when a routine (walk, meal, …) reminder fires. */
    var routineReminders: Boolean
        get() = prefs.getBoolean(KEY_ROUTINE, false)
        set(value) = prefs.edit().putBoolean(KEY_ROUTINE, value).apply()

    /** Notify caregivers when a calendar event reminder fires. */
    var calendarEvents: Boolean
        get() = prefs.getBoolean(KEY_CALENDAR, false)
        set(value) = prefs.edit().putBoolean(KEY_CALENDAR, value).apply()

    /** The toggle for [kind] — the single lookup a fire site should use. */
    fun isEnabled(kind: EventNotifyKind): Boolean = when (kind) {
        EventNotifyKind.MEDICATION_REMINDER -> medicationReminders
        EventNotifyKind.ROUTINE_REMINDER -> routineReminders
        EventNotifyKind.CALENDAR_EVENT -> calendarEvents
    }

    companion object {
        // Namespaced so a future Settings re-shuffle cannot collide with
        // another preference's key.
        const val PREFS_NAME = "elderly_assistant_notify_settings"
        const val KEY_MEDICATION = "caregiverNotify.medicationReminder"
        const val KEY_ROUTINE = "caregiverNotify.routineReminder"
        const val KEY_CALENDAR = "caregiverNotify.calendarEvent"
    }
}
