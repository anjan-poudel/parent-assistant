package com.elderlyassistant.services.medication

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import org.json.JSONObject

/**
 * Encrypted storage implementation using Android EncryptedSharedPreferences.
 * Stub implementation — replace with Room + SQLCipher when T-002-b is completed.
 */
class PreferencesEncryptedStorage(context: Context) : EncryptedLocalStorage {

    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
        EncryptedSharedPreferences.create(
            "elderly_assistant_secure_storage",
            masterKey,
            context,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    override fun <T> write(key: String, value: T): Result<Unit> {
        return try {
            val json = when (value) {
                is String -> value
                is Map<*, *> -> JSONObject(value as Map<String, Any>).toString()
                is List<*> -> value.toString()
                else -> value.toString()
            }
            prefs.edit().putString(key, json).apply()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(StorageError.EncryptedWriteFailed)
        }
    }

    @Suppress("UNCHECKED_CAST")
    override fun <T> read(key: String, type: Class<T>): Result<T> {
        return try {
            val raw = prefs.getString(key, null)
                ?: return Result.failure(StorageError.EncryptedReadFailed)
            val value: Any = when {
                type == String::class.java -> raw
                type == Map::class.java -> raw  // caller must deserialize
                else -> raw
            }
            Result.success(value as T)
        } catch (e: Exception) {
            Result.failure(StorageError.EncryptedReadFailed)
        }
    }

    override fun delete(key: String): Result<Unit> {
        return try {
            prefs.edit().remove(key).apply()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(StorageError.EncryptedWriteFailed)
        }
    }
}

/**
 * Console-based observability bus for development.
 * Replace with production implementation from T-004.
 * All events must pass through LogSanitiser before emission.
 */
class LogcatObservabilityBus : ObservabilityBus {
    override fun emit(event: ObservabilityEvent) {
        android.util.Log.i(
            event.component,
            "${event.eventType} outcome=${event.outcome} metadata=${event.metadata}"
        )
    }
}
