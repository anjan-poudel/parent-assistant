package com.elderlyassistant.services.medication

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.elderlyassistant.ElderlyAssistantApp

/**
 * Re-arms medication reminders after device reboot.
 * Safety-critical: ensures missed reminders are restored even after a full power cycle.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val app = context.applicationContext as? ElderlyAssistantApp ?: return
            app.medicationScheduler.scheduleAll()
        }
    }
}
