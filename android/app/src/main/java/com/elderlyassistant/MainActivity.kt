package com.elderlyassistant

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity

/**
 * Minimal UI activity — this is a voice-first app.
 * The main interface is voice interaction via the assistant.
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
    }
}
