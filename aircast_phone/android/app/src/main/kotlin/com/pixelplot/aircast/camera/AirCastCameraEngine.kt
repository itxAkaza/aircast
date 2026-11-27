package com.pixelplot.aircast.camera

import android.Manifest
import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Range
import android.util.Rational
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.view.TextureRegistry
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class AirCastCameraEngine {

    companion object {
        private const val PROTOCOL_VERSION: Byte = 1
        private const val TYPE_AUTH: Byte = 0x01
        private const val TYPE_JPEG_FRAME: Byte = 0x02
        private const val HEADER_SIZE = 26
        private const val FLAG_FRONT_CAMERA = 1 shl 0
        private const val FLAG_MIRROR_HORIZONTAL = 1 shl 1
        private const val MAX_FRAME_BYTES = 4 * 1024 * 1024
        private const val REQ_CAMERA_PERM = 4821

        @Volatile
        var instance: AirCastCameraEngine = AirCastCameraEngine()
    }

    private data class LensEntry(
        val cameraId: String,
        val label: String,
        val isFront: Boolean,
        val selector: CameraSelector,
        val fpsRanges: Array<Range<Int>>
    )

    private data class EncodedFrame(
        val sequence: Int,
        val timestampMs: Long,
        val width: Int,
        val height: Int,
        val rotation: Int,
        val flags: Int,
        val jpegBytes: ByteArray
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "AirCast-Analysis").apply { priority = Thread.NORM_PRIORITY + 1 }
    }
    private val encodeExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "AirCast-Encode").apply { priority = Thread.NORM_PRIORITY + 1 }
    }

    @Volatile private var activityRef: Activity? = null
    @Volatile private var textureRegistry: TextureRegistry? = null
    @Volatile private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    @Volatile private var cameraProvider: ProcessCameraProvider? = null
    @Volatile private var activeCamera: Camera? = null

    private val lenses = mutableListOf<LensEntry>()
    @Volatile private var activeLensIndex = 0
    @Volatile private var targetWidth = 1280
    @Volatile private var targetHeight = 720
    @Volatile private var targetFps = 30
    @Volatile private var baseJpegQuality = 75
    private val effectiveJpegQuality = AtomicInteger(75)
    private val mirrorHorizontal = AtomicBoolean(false)
    private val torchEnabled = AtomicBoolean(false)
    private val previewRunning = AtomicBoolean(false)
    private val streamingActive = AtomicBoolean(false)
    private val inPipMode = AtomicBoolean(false)
    private val previewRotation = AtomicInteger(90)

    // Ping-pong NV21 buffers (thread-safe handoff between analysisExecutor & encodeExecutor)
    private val encBusy = AtomicBoolean(false)
    private val nv21Bufs = arrayOf(ByteArray(0), ByteArray(0))
    private var nv21Idx = 0 // accessed exclusively on analysisExecutor
    private var uRow = ByteArray(0) // accessed exclusively on analysisExecutor
    private var vRow = ByteArray(0) // accessed exclusively on analysisExecutor
    private val jpegStream = ByteArrayOutputStream(256 * 1024) // accessed exclusively on encodeExecutor

    // 1-slot latest-frame-wins queue for Port 4821 TCP sender
    private val latestPendingFrame = AtomicReference<EncodedFrame?>(null)
    private val senderSignal = Object()
    private val senderRunning = AtomicBoolean(false)
    private val senderGen = AtomicInteger(0)
    @Volatile private var senderThread: Thread? = null
    @Volatile private var videoSocket: Socket? = null
    @Volatile private var currentHost: String = ""
    @Volatile private var currentPort: Int = 4821
    @Volatile private var currentSessionToken: String = ""

    // Telemetry counters & stage EMA timings (microseconds)
    private val seqCounter = AtomicInteger(0)
    private val capturedCount = AtomicInteger(0)
    private val sentCount = AtomicInteger(0)
    private val droppedCount = AtomicInteger(0)
    private val totalBytesSent = AtomicLong(0)
    private val convUs = AtomicLong(0)
    private val jpegUs = AtomicLong(0)
    private val sendUs = AtomicLong(0)
    private val lastError = AtomicReference("")
    private val textureId = AtomicLong(-1L)

    private fun updateEma(target: AtomicLong, sampleUs: Long) {
        val prev = target.get()
        target.set(if (prev == 0L) sampleUs else (prev * 7 + sampleUs) / 8)
    }

    fun attach(activity: Activity, registry: TextureRegistry) {
        activityRef = activity
        textureRegistry = registry
    }

    fun detach() {
        stopStreaming()
        stopCamera()
        activityRef = null
        textureRegistry = null
    }

    fun hasCameraPermission(): Boolean {
        val act = activityRef ?: return false
        return ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
    }

    fun requestCameraPermission() {
        val act = activityRef ?: return
        mainHandler.post {
            ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.CAMERA), REQ_CAMERA_PERM)
        }
    }

    fun startCamera(width: Int, height: Int, fps: Int, quality: Int, lensIdx: Int): Long {
        val act = activityRef ?: run {
            lastError.set("Activity not attached")
            return -1L
        }
        if (!hasCameraPermission()) {
            requestCameraPermission()
            lastError.set("Camera permission required")
            return -1L
        }

        targetWidth = width.coerceIn(320, 1920)
        targetHeight = height.coerceIn(240, 1080)
        targetFps = fps.coerceIn(15, 60)
        baseJpegQuality = quality.coerceIn(40, 95)
        effectiveJpegQuality.set(baseJpegQuality)
        activeLensIndex = lensIdx.coerceAtLeast(0)
        lastError.set("")

        var producer = surfaceProducer
        if (producer == null) {
            val reg = textureRegistry ?: return -1L
            val createProducer = {
                val created = reg.createSurfaceProducer()
                created.setSize(minOf(targetWidth, 1280), minOf(targetHeight, 720))
                created.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        if (previewRunning.get()) bindCameraUseCases()
                    }
                    override fun onSurfaceCleanup() {}
                })
                surfaceProducer = created
                textureId.set(created.id())
            }

            if (Looper.myLooper() == Looper.getMainLooper()) {
                createProducer()
            } else {
                val latch = java.util.concurrent.CountDownLatch(1)
                mainHandler.post {
                    try {
                        createProducer()
                    } finally {
                        latch.countDown()
                    }
                }
                latch.await(2, TimeUnit.SECONDS)
            }
            producer = surfaceProducer
        } else {
            val pw = minOf(targetWidth, 1280)
            val ph = minOf(targetHeight, 720)
            if (Looper.myLooper() == Looper.getMainLooper()) {
                producer.setSize(pw, ph)
            } else {
                mainHandler.post { producer.setSize(pw, ph) }
            }
        }

        val id = textureId.get()
        if (id < 0L) {
            lastError.set("Failed to create Flutter SurfaceProducer")
            return -1L
        }

        previewRunning.set(true)
        setKeepScreenOn(true)

        val providerFuture = ProcessCameraProvider.getInstance(act)
        providerFuture.addListener({
            try {
                cameraProvider = providerFuture.get()
                discoverLenses()
                bindCameraUseCases()
            } catch (e: Exception) {
                lastError.set("CameraX init failed: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(act))

        return id
    }

    fun stopCamera() {
        stopStreaming()
        previewRunning.set(false)
        torchEnabled.set(false)
        setKeepScreenOn(false)

        mainHandler.post {
            try {
                cameraProvider?.unbindAll()
            } catch (_: Exception) {}
            activeCamera = null
            surfaceProducer?.release()
            surfaceProducer = null
            textureId.set(-1L)
        }
    }

    fun startStreaming(host: String, port: Int, sessionToken: String): Boolean {
        if (host.isBlank() || sessionToken.isBlank()) {
            lastError.set("Missing host or session token")
            return false
        }
        stopStreaming()
        currentHost = host.trim()
        currentPort = port
        currentSessionToken = sessionToken.trim()
        seqCounter.set(0)
        capturedCount.set(0)
        sentCount.set(0)
        droppedCount.set(0)
        totalBytesSent.set(0)
        convUs.set(0)
        jpegUs.set(0)
        sendUs.set(0)
        effectiveJpegQuality.set(baseJpegQuality)
        lastError.set("")

        streamingActive.set(true)
        syncPipParams()
        senderRunning.set(true)
        val gen = senderGen.incrementAndGet()
        senderThread = Thread({ senderLoop(gen) }, "AirCast-VideoSender-$gen").apply {
            priority = Thread.NORM_PRIORITY + 1
            start()
        }
        return true
    }

    fun stopStreaming() {
        streamingActive.set(false)
        syncPipParams()
        senderGen.incrementAndGet()
        senderRunning.set(false)
        synchronized(senderSignal) {
            latestPendingFrame.set(null)
            senderSignal.notifyAll()
        }
        try {
            videoSocket?.close()
        } catch (_: Exception) {}
        videoSocket = null
        try {
            senderThread?.join(500)
        } catch (_: Exception) {}
        senderThread = null
    }

    fun switchLens(index: Int) {
        if (lenses.isEmpty()) return
        activeLensIndex = index.coerceIn(0, lenses.lastIndex)
        val entry = lenses[activeLensIndex]
        mirrorHorizontal.set(entry.isFront)
        if (entry.isFront) torchEnabled.set(false)
        if (previewRunning.get()) {
            mainHandler.post { bindCameraUseCases() }
        }
    }

    fun applyPreset(width: Int, height: Int, fps: Int, quality: Int) {
        targetWidth = width.coerceIn(320, 1920)
        targetHeight = height.coerceIn(240, 1080)
        targetFps = fps.coerceIn(15, 60)
        baseJpegQuality = quality.coerceIn(40, 95)
        effectiveJpegQuality.set(baseJpegQuality)
        if (previewRunning.get()) {
            mainHandler.post {
                surfaceProducer?.setSize(minOf(targetWidth, 1280), minOf(targetHeight, 720))
                bindCameraUseCases()
            }
        }
    }

    fun applyJpegQuality(quality: Int) {
        baseJpegQuality = quality.coerceIn(40, 95)
        effectiveJpegQuality.set(baseJpegQuality)
    }

    fun applyMirror(enabled: Boolean) {
        mirrorHorizontal.set(enabled)
    }

    fun applyTorch(enabled: Boolean): Boolean {
        val cam = activeCamera ?: return false
        if (!cam.cameraInfo.hasFlashUnit()) {
            torchEnabled.set(false)
            return false
        }
        torchEnabled.set(enabled)
        mainHandler.post {
            try {
                cam.cameraControl.enableTorch(enabled)
            } catch (_: Exception) {}
        }
        return true
    }

    fun applyZoomRatio(ratio: Float) {
        val cam = activeCamera ?: return
        val zoomState = cam.cameraInfo.zoomState.value
        val minZ = zoomState?.minZoomRatio ?: 1.0f
        val maxZ = zoomState?.maxZoomRatio ?: 4.0f
        val clamped = ratio.coerceIn(minZ, maxZ)
        mainHandler.post {
            try {
                cam.cameraControl.setZoomRatio(clamped)
            } catch (_: Exception) {}
        }
    }

    fun focusAt(normX: Float, normY: Float) {
        val cam = activeCamera ?: return
        val x = normX.coerceIn(0f, 1f)
        val y = normY.coerceIn(0f, 1f)
        mainHandler.post {
            try {
                val factory = SurfaceOrientedMeteringPointFactory(1.0f, 1.0f)
                val point = factory.createPoint(x, y)
                val action = FocusMeteringAction.Builder(point)
                    .setAutoCancelDuration(3, TimeUnit.SECONDS)
                    .build()
                cam.cameraControl.startFocusAndMetering(action)
            } catch (_: Exception) {}
        }
    }

    // Picture-in-Picture (Android 8.0+ / Android 12+ Auto-Enter)
    fun syncPipParams() {
        val act = activityRef ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        mainHandler.post {
            try {
                val builder = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    builder.setAutoEnterEnabled(streamingActive.get())
                    builder.setSeamlessResizeEnabled(true)
                }
                act.setPictureInPictureParams(builder.build())
            } catch (_: Exception) {}
        }
    }

    fun enterPipMode(): Boolean {
        val act = activityRef ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!act.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
            return false
        }
        mainHandler.post {
            try {
                val builder = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    builder.setAutoEnterEnabled(streamingActive.get())
                    builder.setSeamlessResizeEnabled(true)
                }
                act.enterPictureInPictureMode(builder.build())
            } catch (_: Exception) {}
        }
        return true
    }

    fun onPipModeChanged(isInPip: Boolean) {
        inPipMode.set(isInPip)
    }

    fun onUserLeaveHint() {
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S) {
            if (streamingActive.get()) {
                enterPipMode()
            }
        }
    }

    fun readIsInPipMode(): Boolean = inPipMode.get()

    // Telemetry & capability readers
    fun readTextureId(): Long = textureId.get()
    fun readPreviewRotation(): Int = previewRotation.get()
    fun readLensCount(): Int = lenses.size
    fun readLensLabel(index: Int): String = lenses.getOrNull(index)?.label ?: "Camera"
    fun readActiveLensIndex(): Int = activeLensIndex
    fun hasTorch(): Boolean = activeCamera?.cameraInfo?.hasFlashUnit() == true
    fun readMinZoom(): Float = activeCamera?.cameraInfo?.zoomState?.value?.minZoomRatio ?: 1.0f
    fun readMaxZoom(): Float = activeCamera?.cameraInfo?.zoomState?.value?.maxZoomRatio ?: 4.0f
    fun readEffectiveQuality(): Int = effectiveJpegQuality.get()
    fun readCapturedTotal(): Int = capturedCount.get()
    fun readSentTotal(): Int = sentCount.get()
    fun readDroppedTotal(): Int = droppedCount.get()
    fun readBytesSentTotal(): Long = totalBytesSent.get()
    fun readConvUs(): Long = convUs.get()
    fun readJpegUs(): Long = jpegUs.get()
    fun readSendUs(): Long = sendUs.get()
    fun readStreamingActive(): Boolean = streamingActive.get()
    fun readLastError(): String = lastError.get() ?: ""

    @OptIn(ExperimentalCamera2Interop::class)
    private fun discoverLenses() {
        val provider = cameraProvider ?: return
        lenses.clear()

        var backIndex = 0
        var frontIndex = 0
        for (info in provider.availableCameraInfos) {
            val c2 = Camera2CameraInfo.from(info)
            val camId = c2.cameraId
            val facing = c2.getCameraCharacteristic(CameraCharacteristics.LENS_FACING)
            val focalLengths = c2.getCameraCharacteristic(
                CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
            )
            val ranges = c2.getCameraCharacteristic(
                CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
            ) ?: emptyArray()
            val minFocal = focalLengths?.minOrNull() ?: 0f

            val isFront = (facing == CameraCharacteristics.LENS_FACING_FRONT)
            val label = if (isFront) {
                frontIndex++
                if (frontIndex == 1) "Front" else "Front $frontIndex"
            } else {
                backIndex++
                when {
                    backIndex == 1 -> "Back Main"
                    minFocal in 0.5f..2.5f -> "Back Ultrawide"
                    else -> "Back Lens $backIndex"
                }
            }

            val selector = CameraSelector.Builder()
                .addCameraFilter { infos ->
                    infos.filter { Camera2CameraInfo.from(it).cameraId == camId }
                }
                .build()

            lenses.add(LensEntry(camId, label, isFront, selector, ranges))
        }

        if (lenses.isEmpty()) {
            lenses.add(LensEntry("0", "Back Main", false, CameraSelector.DEFAULT_BACK_CAMERA, emptyArray()))
        }
        activeLensIndex = activeLensIndex.coerceIn(0, lenses.lastIndex)
    }

    private fun pickFpsRange(ranges: Array<Range<Int>>, fps: Int): Range<Int> {
        val ok = ranges.filter { it.upper >= fps }
        val bestUpper = ok.minOfOrNull { it.upper } ?: return Range(fps, fps)
        return ok.filter { it.upper == bestUpper }.maxByOrNull { it.lower } ?: Range(fps, fps)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindCameraUseCases() {
        val act = activityRef ?: return
        val lifecycleOwner = act as? LifecycleOwner ?: return
        val provider = cameraProvider ?: return
        val producer = surfaceProducer ?: return
        if (lenses.isEmpty()) return

        val entry = lenses[activeLensIndex.coerceIn(0, lenses.lastIndex)]
        val fpsRange = pickFpsRange(entry.fpsRanges, targetFps)
        val mainExec = ContextCompat.getMainExecutor(act)

        // Cap local preview at 720p so ISP doesn't throttle when streaming 1080p
        val previewSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(minOf(targetWidth, 1280), minOf(targetHeight, 720)),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                )
            )
            .build()

        val previewBuilder = Preview.Builder()
            .setResolutionSelector(previewSelector)
        Camera2Interop.Extender(previewBuilder)
            .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
        val preview = previewBuilder.build()
        preview.setSurfaceProvider { request ->
            val res = request.resolution
            producer.setSize(res.width, res.height)
            request.setTransformationInfoListener(mainExec) { info ->
                previewRotation.set(info.rotationDegrees)
            }
            val surface: Surface = producer.surface
            request.provideSurface(surface, mainExec) {}
        }

        val analysisSelector = ResolutionSelector.Builder()
            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(targetWidth, targetHeight),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER
                )
            )
            .build()

        val analysisBuilder = ImageAnalysis.Builder()
            .setResolutionSelector(analysisSelector)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
        Camera2Interop.Extender(analysisBuilder)
            .setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
        val analysis = analysisBuilder.build()
        analysis.setAnalyzer(analysisExecutor) { image ->
            processImageProxy(image, entry.isFront)
        }

        try {
            provider.unbindAll()
            val cam = provider.bindToLifecycle(lifecycleOwner, entry.selector, preview, analysis)
            activeCamera = cam
            previewRotation.set(cam.cameraInfo.sensorRotationDegrees)
            if (torchEnabled.get() && cam.cameraInfo.hasFlashUnit()) {
                cam.cameraControl.enableTorch(true)
            } else {
                torchEnabled.set(false)
            }
        } catch (e: Exception) {
            lastError.set("Bind failed: ${e.message}")
        }
    }

    private fun processImageProxy(image: ImageProxy, isFront: Boolean) {
        try {
            if (!streamingActive.get()) return

            val w = image.width
            val h = image.height
            val rotation = image.imageInfo.rotationDegrees
            val timestampMs = SystemClock.elapsedRealtime()

            val t0 = System.nanoTime()
            val needed = w * h * 3 / 2
            if (nv21Bufs[nv21Idx].size < needed) {
                nv21Bufs[nv21Idx] = ByteArray(needed)
            }
            val nv21 = nv21Bufs[nv21Idx]
            fillNv21(image, nv21)
            updateEma(convUs, (System.nanoTime() - t0) / 1000L)

            // If encoder thread is still compressing the previous frame, drop this one immediately
            if (!encBusy.compareAndSet(false, true)) {
                droppedCount.incrementAndGet()
                return
            }
            // Hand nv21Bufs[nv21Idx] exclusively to encodeExecutor; next frame writes to the other slot
            nv21Idx = nv21Idx xor 1

            val q = effectiveJpegQuality.get().coerceIn(40, 95)
            var flags = 0
            if (isFront) flags = flags or FLAG_FRONT_CAMERA
            if (mirrorHorizontal.get()) flags = flags or FLAG_MIRROR_HORIZONTAL
            val seq = seqCounter.incrementAndGet()

            encodeExecutor.execute {
                try {
                    val t1 = System.nanoTime()
                    jpegStream.reset()
                    YuvImage(nv21, ImageFormat.NV21, w, h, null)
                        .compressToJpeg(Rect(0, 0, w, h), q, jpegStream)
                    val jpegBytes = jpegStream.toByteArray()
                    updateEma(jpegUs, (System.nanoTime() - t1) / 1000L)

                    if (jpegBytes.isEmpty() || jpegBytes.size > MAX_FRAME_BYTES) return@execute

                    capturedCount.incrementAndGet()
                    val prev = latestPendingFrame.getAndSet(
                        EncodedFrame(seq, timestampMs, w, h, rotation, flags, jpegBytes)
                    )
                    if (prev != null) {
                        droppedCount.incrementAndGet()
                    }
                    synchronized(senderSignal) {
                        senderSignal.notify()
                    }
                } catch (e: Exception) {
                    lastError.set("Encode error: ${e.message}")
                } finally {
                    encBusy.set(false)
                }
            }
        } catch (e: Exception) {
            lastError.set("Capture error: ${e.message}")
        } finally {
            image.close()
        }
    }

    /**
     * Bulk-row YUV_420_888 -> NV21 conversion with verified semi-planar NV21 fast path.
     */
    private fun fillNv21(image: ImageProxy, out: ByteArray) {
        val w = image.width
        val h = image.height
        val ySize = w * h

        val yp = image.planes[0]
        val yb = yp.buffer
        if (yp.pixelStride == 1 && yp.rowStride == w) {
            yb.position(0)
            yb.get(out, 0, ySize)
        } else {
            for (r in 0 until h) {
                yb.position(r * yp.rowStride)
                yb.get(out, r * w, w)
            }
        }

        val up = image.planes[1]
        val vp = image.planes[2]
        val ub = up.buffer
        val vb = vp.buffer
        var dst = ySize
        val halfH = h / 2

        if (vp.pixelStride == 2 && up.pixelStride == 2 && looksLikeNv21(ub, vb)) {
            for (r in 0 until halfH) {
                val start = r * vp.rowStride
                val len = minOf(w, vb.limit() - start)
                vb.position(start)
                vb.get(out, dst, len)
                if (len < w) {
                    out[dst + w - 1] = ub.get(ub.limit() - 1)
                }
                dst += w
            }
        } else {
            val halfW = w / 2
            if (uRow.size < up.rowStride) uRow = ByteArray(up.rowStride)
            if (vRow.size < vp.rowStride) vRow = ByteArray(vp.rowStride)
            for (r in 0 until halfH) {
                val us = r * up.rowStride
                val vs = r * vp.rowStride
                ub.position(us)
                ub.get(uRow, 0, minOf(up.rowStride, ub.limit() - us))
                vb.position(vs)
                vb.get(vRow, 0, minOf(vp.rowStride, vb.limit() - vs))
                for (c in 0 until halfW) {
                    out[dst++] = vRow[c * vp.pixelStride]
                    out[dst++] = uRow[c * up.pixelStride]
                }
            }
        }
    }

    private fun looksLikeNv21(ub: ByteBuffer, vb: ByteBuffer): Boolean {
        val n = minOf(ub.limit(), vb.limit() - 1)
        if (n < 64) return false
        for (i in 0 until 16) {
            val k = ((n / 16) * i) and 1.inv()
            if (ub.get(k) != vb.get(k + 1)) return false
        }
        return true
    }

    private fun senderLoop(gen: Int) {
        val headerBuf = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)

        while (senderRunning.get() && senderGen.get() == gen) {
            var socket: Socket? = null
            try {
                socket = Socket()
                socket.tcpNoDelay = true
                socket.sendBufferSize = 96 * 1024
                socket.trafficClass = 0x28
                socket.connect(InetSocketAddress(currentHost, currentPort), 4000)
                videoSocket = socket

                val out = BufferedOutputStream(socket.getOutputStream(), 96 * 1024)

                // Step 1: Authenticate Port 4821 with active sessionToken
                val tokenBytes = currentSessionToken.toByteArray(Charsets.UTF_8)
                writePacket(
                    out, headerBuf,
                    type = TYPE_AUTH,
                    seq = 0,
                    timestampMs = SystemClock.elapsedRealtime(),
                    width = 0, height = 0, rotation = 0, flags = 0,
                    payload = tokenBytes
                )
                out.flush()
                lastError.set("")

                // Step 2: Pump latest JPEG frames with adaptive quality backoff
                while (senderRunning.get() && senderGen.get() == gen) {
                    var frame = latestPendingFrame.getAndSet(null)
                    if (frame == null) {
                        synchronized(senderSignal) {
                            frame = latestPendingFrame.getAndSet(null)
                            if (frame == null && senderRunning.get() && senderGen.get() == gen) {
                                senderSignal.wait(100)
                                frame = latestPendingFrame.getAndSet(null)
                            }
                        }
                    }
                    val f = frame ?: continue

                    val t0 = System.nanoTime()
                    writePacket(
                        out, headerBuf,
                        type = TYPE_JPEG_FRAME,
                        seq = f.sequence,
                        timestampMs = f.timestampMs,
                        width = f.width,
                        height = f.height,
                        rotation = f.rotation,
                        flags = f.flags,
                        payload = f.jpegBytes
                    )
                    out.flush()
                    val writeUs = (System.nanoTime() - t0) / 1000L
                    updateEma(sendUs, writeUs)

                    sentCount.incrementAndGet()
                    totalBytesSent.addAndGet((HEADER_SIZE + f.jpegBytes.size).toLong())

                    val writeMs = writeUs / 1000L
                    val curQ = effectiveJpegQuality.get()
                    if (writeMs > 35 && curQ > 45) {
                        effectiveJpegQuality.set((curQ - 5).coerceAtLeast(45))
                    } else if (writeMs < 12 && curQ < baseJpegQuality) {
                        effectiveJpegQuality.set((curQ + 2).coerceAtMost(baseJpegQuality))
                    }
                }
            } catch (e: Exception) {
                if (senderRunning.get() && senderGen.get() == gen) {
                    lastError.set("Video socket error: ${e.message}")
                    try {
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) {}
                }
            } finally {
                try {
                    socket?.close()
                } catch (_: Exception) {}
                if (videoSocket === socket) videoSocket = null
            }
        }
    }

    private fun writePacket(
        out: BufferedOutputStream,
        headerBuf: ByteBuffer,
        type: Byte,
        seq: Int,
        timestampMs: Long,
        width: Int,
        height: Int,
        rotation: Int,
        flags: Int,
        payload: ByteArray
    ) {
        headerBuf.clear()
        headerBuf.put(PROTOCOL_VERSION)
        headerBuf.put(type)
        headerBuf.putInt(seq)
        headerBuf.putLong(timestampMs)
        headerBuf.putShort(width.toShort())
        headerBuf.putShort(height.toShort())
        headerBuf.putShort(rotation.toShort())
        headerBuf.putShort(flags.toShort())
        headerBuf.putInt(payload.size)
        out.write(headerBuf.array(), 0, HEADER_SIZE)
        out.write(payload)
    }

    private fun setKeepScreenOn(enable: Boolean) {
        val act = activityRef ?: return
        mainHandler.post {
            if (enable) {
                act.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                act.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }
}