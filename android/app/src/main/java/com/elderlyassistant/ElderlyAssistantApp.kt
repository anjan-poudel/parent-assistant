package com.elderlyassistant

import android.app.Application
import android.util.Log
import com.elderlyassistant.services.medication.AlarmManagerScheduler
import com.elderlyassistant.services.medication.MedicationScheduler
import com.elderlyassistant.services.family.FCMFamilyNotifier
import com.elderlyassistant.services.family.NotifySettings

/**
 * Application class that initializes all services.
 * Safety-critical services (medication scheduler) are started first,
 * before voice pipeline and LLM.
 */
class ElderlyAssistantApp : Application() {

    lateinit var medicationScheduler: MedicationScheduler
        private set

    /**
     * Per-event-type caregiver notification preferences (caregiver
     * event-notifications task, 2026-09-13) — the Android mirror of the
     * iOS `AppCoordinator.caregiverNotifySettings`. Created here so the
     * composition root owns the one instance; Android has no event fire
     * wiring yet, so nothing reads it at runtime.
     */
    val notifySettings: NotifySettings by lazy { NotifySettings(this) }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(TAG, "Elderly AI Assistant starting...")

        initializeServices()
    }

    private fun initializeServices() {
        // Storage and observability (replace with T-002, T-004 real implementations)
        val storage = PreferencesEncryptedStorage(this)
        val observabilityBus = LogcatObservabilityBus()
        val alarmScheduler = AlarmManagerScheduler(this)
        val familyNotifier = FCMFamilyNotifier(emptyList())

        // Safety-critical: medication scheduler (no LLM dependency)
        medicationScheduler = MedicationScheduler(
            storage = storage,
            alarmScheduler = alarmScheduler,
            observabilityBus = observabilityBus,
            familyNotifier = familyNotifier
        )

        // Restore and re-arm any outstanding reminders
        medicationScheduler.scheduleAll()

        Log.i(TAG, "Services initialized. Medication scheduler ready.")
    }

    companion object {
        private const val TAG = "ElderlyAssistant"

        lateinit var instance: ElderlyAssistantApp
            private set
    }
}
