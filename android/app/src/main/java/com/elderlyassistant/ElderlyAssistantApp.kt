package com.elderlyassistant

import android.app.Application
import android.util.Log
import com.elderlyassistant.services.medication.AlarmManagerScheduler
import com.elderlyassistant.services.medication.MedicationScheduler
import com.elderlyassistant.services.family.FCMFamilyNotifier

/**
 * Application class that initializes all services.
 * Safety-critical services (medication scheduler) are started first,
 * before voice pipeline and LLM.
 */
class ElderlyAssistantApp : Application() {

    lateinit var medicationScheduler: MedicationScheduler
        private set

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
