package com.elderlyassistant.services.medication

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.UUID

// MARK: - Platform Alarm Scheduler Protocol

interface PlatformAlarmScheduler {
    fun scheduleReminder(reminderId: UUID, entryId: UUID, medicationName: String, at: Long)
    fun scheduleAckDeadlineCheck(reminderId: UUID, entryId: UUID, deadline: Long)
    fun cancelReminder(reminderId: UUID)
    fun cancelAllReminders()
}

// MARK: - Android Implementation (AlarmManager)

class AlarmManagerScheduler(
    private val context: Context
) : PlatformAlarmScheduler {

    private val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    override fun scheduleReminder(
        reminderId: UUID,
        entryId: UUID,
        medicationName: String,
        at: Long
    ) {
        val intent = Intent(context, MedicationAlarmReceiver::class.java).apply {
            putExtra("reminder_id", reminderId.toString())
            putExtra("entry_id", entryId.toString())
            putExtra("medication_name", medicationName)
            putExtra("type", "medication_reminder")
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            reminderId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    at,
                    pendingIntent
                )
            }
        } else {
            @Suppress("DEPRECATION")
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                at,
                pendingIntent
            )
        }
    }

    override fun scheduleAckDeadlineCheck(
        reminderId: UUID,
        entryId: UUID,
        deadline: Long
    ) {
        val intent = Intent(context, MedicationAlarmReceiver::class.java).apply {
            putExtra("reminder_id", reminderId.toString())
            putExtra("entry_id", entryId.toString())
            putExtra("type", "ack_deadline_check")
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            "ack_check_${reminderId}".hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        alarmManager.setExact(AlarmManager.RTC_WAKEUP, deadline, pendingIntent)
    }

    override fun cancelReminder(reminderId: UUID) {
        val intent = Intent(context, MedicationAlarmReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            reminderId.hashCode(),
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        )
        pendingIntent?.cancel()
        alarmManager.cancel(pendingIntent)
    }

    override fun cancelAllReminders() {
        // In production: track all pending intent IDs and cancel them individually
    }
}

// MARK: - BroadcastReceiver for medication alarms

class MedicationAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val type = intent.getStringExtra("type") ?: return
        val reminderId = intent.getStringExtra("reminder_id")?.let { UUID.fromString(it) } ?: return

        // In production: obtain MedicationScheduler from service locator / DI
        // and call triggerReminder() or handleAckDeadlineExpired() accordingly
        when (type) {
            "medication_reminder" -> {
                // medicationScheduler.triggerReminder(reminderId)
            }
            "ack_deadline_check" -> {
                // medicationScheduler.handleAckDeadlineExpired(reminderId)
            }
        }
    }
}
