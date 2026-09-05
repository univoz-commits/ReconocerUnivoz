package com.univoz.senas_app

import android.os.Bundle
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.univoz.senas.LandmarkPlugin

class MainActivity : FlutterActivity() {
    private var plugin: LandmarkPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        plugin = LandmarkPlugin(
            context = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            textureRegistry = flutterEngine.renderer,
            lifecycleOwner = this,
        )
        plugin?.registrar()
    }

    override fun onDestroy() {
        plugin?.destruir()
        plugin = null
        super.onDestroy()
    }
}
