package com.pixelplot.aircast.camera

import androidx.annotation.Keep

@Keep
object AirCastCameraBridge {
    private fun engine(): AirCastCameraEngine = AirCastCameraEngine.instance

    @Keep @JvmStatic
    fun hasCameraPermission(): Boolean = engine().hasCameraPermission()

    @Keep @JvmStatic
    fun requestCameraPermission() = engine().requestCameraPermission()

    @Keep @JvmStatic
    fun startCamera(width: Int, height: Int, fps: Int, quality: Int, lensIdx: Int): Long =
        engine().startCamera(width, height, fps, quality, lensIdx)

    @Keep @JvmStatic
    fun stopCamera() = engine().stopCamera()

    @Keep @JvmStatic
    fun startStreaming(host: String, port: Int, sessionToken: String): Boolean =
        engine().startStreaming(host, port, sessionToken)

    @Keep @JvmStatic
    fun stopStreaming() = engine().stopStreaming()

    @Keep @JvmStatic
    fun switchLens(index: Int) = engine().switchLens(index)

    @Keep @JvmStatic
    fun applyPreset(width: Int, height: Int, fps: Int, quality: Int) =
        engine().applyPreset(width, height, fps, quality)

    @Keep @JvmStatic
    fun applyJpegQuality(quality: Int) = engine().applyJpegQuality(quality)

    @Keep @JvmStatic
    fun applyMirror(enabled: Boolean) = engine().applyMirror(enabled)

    @Keep @JvmStatic
    fun applyTorch(enabled: Boolean): Boolean = engine().applyTorch(enabled)

    @Keep @JvmStatic
    fun applyZoomRatio(ratio: Float) = engine().applyZoomRatio(ratio)

    @Keep @JvmStatic
    fun focusAt(normX: Float, normY: Float) = engine().focusAt(normX, normY)

    @Keep @JvmStatic
    fun readTextureId(): Long = engine().readTextureId()

    @Keep @JvmStatic
    fun readLensCount(): Int = engine().readLensCount()

    @Keep @JvmStatic
    fun readPreviewRotation(): Int = engine().readPreviewRotation()

    @Keep @JvmStatic
    fun readConvUs(): Long = engine().readConvUs()

    @Keep @JvmStatic
    fun readJpegUs(): Long = engine().readJpegUs()

    @Keep @JvmStatic
    fun readSendUs(): Long = engine().readSendUs()

    @Keep @JvmStatic
    fun readLensLabel(index: Int): String = engine().readLensLabel(index)

    @Keep @JvmStatic
    fun readActiveLensIndex(): Int = engine().readActiveLensIndex()

    @Keep @JvmStatic
    fun hasTorch(): Boolean = engine().hasTorch()

    @Keep @JvmStatic
    fun readMinZoom(): Float = engine().readMinZoom()

    @Keep @JvmStatic
    fun readMaxZoom(): Float = engine().readMaxZoom()

    @Keep @JvmStatic
    fun readEffectiveQuality(): Int = engine().readEffectiveQuality()

    @Keep @JvmStatic
    fun readCapturedTotal(): Int = engine().readCapturedTotal()

    @Keep @JvmStatic
    fun readSentTotal(): Int = engine().readSentTotal()

    @Keep @JvmStatic
    fun readDroppedTotal(): Int = engine().readDroppedTotal()

    @Keep @JvmStatic
    fun readBytesSentTotal(): Long = engine().readBytesSentTotal()

    @Keep @JvmStatic
    fun readStreamingActive(): Boolean = engine().readStreamingActive()

    @Keep @JvmStatic
    fun readLastError(): String = engine().readLastError()
}