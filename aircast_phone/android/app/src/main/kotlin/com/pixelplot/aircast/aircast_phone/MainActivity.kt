package com.pixelplot.aircast.aircast_phone

import android.content.res.Configuration
import com.pixelplot.aircast.camera.AirCastCameraEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AirCastCameraEngine.instance.attach(this, flutterEngine.renderer)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AirCastCameraEngine.instance.onPipModeChanged(isInPictureInPictureMode)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AirCastCameraEngine.instance.onUserLeaveHint()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AirCastCameraEngine.instance.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}