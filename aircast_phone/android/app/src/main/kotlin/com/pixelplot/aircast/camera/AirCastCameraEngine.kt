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
        val selector: CameraSelector
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
    private val analysisExecutor = Executors.newSingleThreadExecutor()

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

    // Reusable per-frame buffers (zero per-frame GC churn on analysisExecutor)
    private var nv21Scratch = ByteArray(0)
    private val jpegStream = ByteArrayOutputStream(128 * 1024)

    // 1-slot latest-frame-wins queue for Port 4821 TCP sender
    private val latestPendingFrame = AtomicReference<EncodedFrame?>(null)
    private val senderSignal = Object()
    private val senderRunning = AtomicBoolean(false)
    @Volatile private var senderThread: Thread? = null
    @Volatile private var videoSocket: Socket? = null
    @Volatile private var currentHost: String = ""
    @Volatile private var currentPort: Int = 4821
    @Volatile private var currentSessionToken: String = ""

    // Telemetry counters
    private val seqCounter = AtomicInteger(0)
    private val capturedCount = AtomicInteger(0)
    private val sentCount = AtomicInteger(0)
    private val droppedCount = AtomicInteger(0)
    private val totalBytesSent = AtomicLong(0)
    private val lastError = AtomicReference("")
    private val textureId = AtomicLong(-1L)

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
        targetFps = fps.coerceIn(15, 30)
        baseJpegQuality = quality.coerceIn(40, 95)
        effectiveJpegQuality.set(baseJpegQuality)
        activeLensIndex = lensIdx.coerceAtLeast(0)
        lastError.set("")

        // Create Flutter SurfaceProducer safely on the main thread (supports Flutter 3.50 merged UI/Platform thread)
        var producer = surfaceProducer
        if (producer == null) {
            val reg = textureRegistry ?: return -1L
            val createProducer = {
                val created = reg.createSurfaceProducer()
                created.setSize(targetWidth, targetHeight)
                created.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        if (previewRunning.get()) bindCameraUseCases()
                    }
                    override fun onSurfaceCleanup() {
                        // CameraX Preview cleanly releases surface when unbound/rebound
                    }
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
            if (Looper.myLooper() == Looper.getMainLooper()) {
                producer.setSize(targetWidth, targetHeight)
            } else {
                mainHandler.post { producer.setSize(targetWidth, targetHeight) }
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
        effectiveJpegQuality.set(baseJpegQuality)
        lastError.set("")

        streamingActive.set(true)
        syncPipParams()
        senderRunning.set(true)
        senderThread = Thread({ senderLoop() }, "AirCast-VideoSender").apply {
            priority = Thread.NORM_PRIORITY + 1
            start()
        }
        return true
    }

    fun stopStreaming() {
        streamingActive.set(false)
        syncPipParams()
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
        // Default mirror ON for front camera, OFF for rear camera
        mirrorHorizontal.set(entry.isFront)
        if (entry.isFront) torchEnabled.set(false)
        if (previewRunning.get()) {
            mainHandler.post { bindCameraUseCases() }
        }
    }

    fun applyPreset(width: Int, height: Int, fps: Int, quality: Int) {
        targetWidth = width.coerceIn(320, 1920)
        targetHeight = height.coerceIn(240, 1080)
        targetFps = fps.coerceIn(15, 30)
        baseJpegQuality = quality.coerceIn(40, 95)
        effectiveJpegQuality.set(baseJpegQuality)
        if (previewRunning.get()) {
            mainHandler.post {
                surfaceProducer?.setSize(targetWidth, targetHeight)
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

    // Telemetry & capability readers (no get/is/set prefix -> clean JNIgen methods)
    fun readTextureId(): Long = textureId.get()
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

            lenses.add(LensEntry(camId, label, isFront, selector))
        }

        if (lenses.isEmpty()) {
            lenses.add(LensEntry("0", "Back Main", false, CameraSelector.DEFAULT_BACK_CAMERA))
        }
        activeLensIndex = activeLensIndex.coerceIn(0, lenses.lastIndex)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindCameraUseCases() {
        val act = activityRef as? LifecycleOwner ?: return
        val provider = cameraProvider ?: return
        val producer = surfaceProducer ?: return
        if (lenses.isEmpty()) return

        val entry = lenses[activeLensIndex.coerceIn(0, lenses.lastIndex)]
        val resSelector = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(targetWidth, targetHeight),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                )
            )
            .build()

        // Preview bound directly to Flutter SurfaceProducer (zero-copy GPU)
        val previewBuilder = Preview.Builder()
            .setResolutionSelector(resSelector)
        Camera2Interop.Extender(previewBuilder)
            .setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                Range(targetFps, targetFps)
            )
        val preview = previewBuilder.build()
        preview.setSurfaceProvider { request ->
            val res = request.resolution
            producer.setSize(res.width, res.height)
            val surface: Surface = producer.surface
            request.provideSurface(surface, ContextCompat.getMainExecutor(activityRef!!)) {}
        }

        // ImageAnalysis with STRATEGY_KEEP_ONLY_LATEST & locked FPS range
        val analysisBuilder = ImageAnalysis.Builder()
            .setResolutionSelector(resSelector)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
        Camera2Interop.Extender(analysisBuilder)
            .setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                Range(targetFps, targetFps)
            )
        val analysis = analysisBuilder.build()
        analysis.setAnalyzer(analysisExecutor) { image ->
            processImageProxy(image, entry.isFront)
        }

        try {
            provider.unbindAll()
            val cam = provider.bindToLifecycle(act, entry.selector, preview, analysis)
            activeCamera = cam
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

            val width = image.width
            val height = image.height
            val rotation = image.imageInfo.rotationDegrees
            val timestampMs = SystemClock.elapsedRealtime()

            val nv21 = yuv420888ToNv21(image)
            jpegStream.reset()
            val yuvImage = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val q = effectiveJpegQuality.get().coerceIn(40, 95)
            yuvImage.compressToJpeg(Rect(0, 0, width, height), q, jpegStream)

            val jpegBytes = jpegStream.toByteArray()
            if (jpegBytes.isEmpty() || jpegBytes.size > MAX_FRAME_BYTES) return

            capturedCount.incrementAndGet()

            var flags = 0
            if (isFront) flags = flags or FLAG_FRONT_CAMERA
            if (mirrorHorizontal.get()) flags = flags or FLAG_MIRROR_HORIZONTAL

            val frame = EncodedFrame(
                sequence = seqCounter.incrementAndGet(),
                timestampMs = timestampMs,
                width = width,
                height = height,
                rotation = rotation,
                flags = flags,
                jpegBytes = jpegBytes
            )

            // 1-slot latest-frame-wins queue: overwrite stale unsent frame immediately
            val prev = latestPendingFrame.getAndSet(frame)
            if (prev != null) {
                droppedCount.incrementAndGet()
            }
            synchronized(senderSignal) {
                senderSignal.notify()
            }
        } catch (e: Exception) {
            lastError.set("Encode error: ${e.message}")
        } finally {
            image.close()
        }
    }

    /**
     * Stride-safe YUV_420_888 -> NV21 conversion (handles arbitrary rowStride & pixelStride).
     */
    private fun yuv420888ToNv21(image: ImageProxy): ByteArray {
        val width = image.width
        val height = image.height
        val ySize = width * height
        val uvSize = ySize / 2
        val required = ySize + uvSize
        if (nv21Scratch.size < required) {
            nv21Scratch = ByteArray(required)
        }
        val out = nv21Scratch

        // Copy Y plane row by row
        val yPlane = image.planes[0]
        val yBuf = yPlane.buffer
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        var dstPos = 0
        if (yPixelStride == 1 && yRowStride == width) {
            yBuf.position(0)
            yBuf.get(out, 0, ySize)
            dstPos = ySize
        } else {
            for (row in 0 until height) {
                val rowStart = row * yRowStride
                if (yPixelStride == 1) {
                    yBuf.position(rowStart)
                    yBuf.get(out, dstPos, width)
                    dstPos += width
                } else {
                    for (col in 0 until width) {
                        out[dstPos++] = yBuf.get(rowStart + col * yPixelStride)
                    }
                }
            }
        }

        // Interleave V then U (NV21) respecting both rowStride & pixelStride
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixelStride = vPlane.pixelStride
        val halfH = height / 2
        val halfW = width / 2

        for (row in 0 until halfH) {
            val uRowStart = row * uvRowStride
            val vRowStart = row * vRowStride
            for (col in 0 until halfW) {
                out[dstPos++] = vBuf.get(vRowStart + col * vPixelStride)
                out[dstPos++] = uBuf.get(uRowStart + col * uvPixelStride)
            }
        }
        return out
    }

    private fun senderLoop() {
        val headerBuf = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)

        while (senderRunning.get()) {
            var socket: Socket? = null
            try {
                socket = Socket()
                socket.tcpNoDelay = true
                socket.sendBufferSize = 256 * 1024
                socket.connect(InetSocketAddress(currentHost, currentPort), 4000)
                videoSocket = socket

                val out = BufferedOutputStream(socket.getOutputStream(), 128 * 1024)

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
                while (senderRunning.get()) {
                    var frame = latestPendingFrame.getAndSet(null)
                    if (frame == null) {
                        synchronized(senderSignal) {
                            frame = latestPendingFrame.getAndSet(null)
                            if (frame == null && senderRunning.get()) {
                                senderSignal.wait(100)
                                frame = latestPendingFrame.getAndSet(null)
                            }
                        }
                    }
                    val f = frame ?: continue

                    val t0 = SystemClock.elapsedRealtime()
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
                    val writeMs = SystemClock.elapsedRealtime() - t0

                    sentCount.incrementAndGet()
                    totalBytesSent.addAndGet((HEADER_SIZE + f.jpegBytes.size).toLong())

                    // Adaptive Wi-Fi quality backoff so video never starves Port 4820 audio
                    val curQ = effectiveJpegQuality.get()
                    if (writeMs > 40 && curQ > 45) {
                        effectiveJpegQuality.set((curQ - 5).coerceAtLeast(45))
                    } else if (writeMs < 15 && curQ < baseJpegQuality) {
                        effectiveJpegQuality.set((curQ + 2).coerceAtMost(baseJpegQuality))
                    }
                }
            } catch (e: Exception) {
                if (senderRunning.get()) {
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