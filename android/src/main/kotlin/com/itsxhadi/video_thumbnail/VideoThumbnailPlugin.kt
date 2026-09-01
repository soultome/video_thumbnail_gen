package com.itsxhadi.video_thumbnail

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LruCache
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * VideoThumbnailPlugin — Android native implementation.
 *
 * Author : Hadi <hadi7786x@gmail.com>
 * GitHub : https://github.com/Itsxhadi
 * License: MIT
 *
 * Supports: thumbnailData, thumbnailFile, thumbnailDataList, getVideoMetadata, clearCache.
 */
class VideoThumbnailPlugin : FlutterPlugin, MethodCallHandler {

    private var context: Context? = null
    private var executor: ExecutorService? = null
    private var channel: MethodChannel? = null
    private var memoryCache: LruCache<String, ByteArray>? = null

    // ─── FlutterPlugin lifecycle ──────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        val numCores = Runtime.getRuntime().availableProcessors()
        val threadCount = max(2, min(4, numCores))
        executor = Executors.newFixedThreadPool(threadCount)

        val maxMemory = (Runtime.getRuntime().maxMemory() / 1024).toInt()
        val cacheSize = maxMemory / 8
        memoryCache = object : LruCache<String, ByteArray>(cacheSize) {
            override fun sizeOf(key: String, value: ByteArray): Int = value.size / 1024
        }

        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        executor?.shutdown()
        executor = null
        memoryCache?.evictAll()
        memoryCache = null
    }

    // ─── Method dispatch ──────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        val method = call.method

        if (method == "clearCache") {
            memoryCache?.evictAll()
            runOnUiThread { result.success(null) }
            return
        }

        val args = call.arguments<Map<String, Any?>>()!!
        val video = args["video"] as String

        @Suppress("UNCHECKED_CAST")
        val headers = args["headers"] as? HashMap<String, String>
        val format = args["format"] as Int
        val maxh = args["maxh"] as Int
        val maxw = args["maxw"] as Int
        val timeMs = args["timeMs"] as Int
        val quality = args["quality"] as Int

        executor?.execute {
            var thumbnail: Any? = null
            var handled = false
            var errCode: String? = null
            var exc: Exception? = null

            try {
                when (method) {
                    "file" -> {
                        val path = args["path"] as? String
                        thumbnail = buildThumbnailFile(video, headers, path, format, maxh, maxw, timeMs, quality)
                        handled = true
                    }
                    "data" -> {
                        thumbnail = buildThumbnailData(video, headers, format, maxh, maxw, timeMs, quality)
                        handled = true
                    }
                    "dataList" -> {
                        @Suppress("UNCHECKED_CAST")
                        val timesMs = args["timesMs"] as? List<Int>
                        thumbnail = buildThumbnailDataList(video, headers, timesMs, format, maxh, maxw, quality)
                        handled = true
                    }
                    "metadata" -> {
                        thumbnail = getVideoMetadata(video, headers)
                        handled = true
                    }
                }
            } catch (e: FileNotFoundException) {
                exc = e; errCode = ERR_FILE_NOT_FOUND
            } catch (e: NullPointerException) {
                exc = e; errCode = ERR_UNSUPPORTED
            } catch (e: IOException) {
                exc = e; errCode = ERR_IO
            } catch (e: Exception) {
                exc = e; errCode = ERR_UNKNOWN
            }

            runOnUiThread {
                if (!handled) {
                    result.notImplemented()
                    return@runOnUiThread
                }
                if (exc != null) {
                    exc.printStackTrace()
                    result.error(errCode ?: ERR_UNKNOWN, exc.message, null)
                    return@runOnUiThread
                }
                result.success(thumbnail)
            }
        }
    }

    // ─── Thumbnail data (single frame → memory) ───────────────────────────────

    @Throws(IOException::class)
    private fun buildThumbnailData(
        vidPath: String,
        headers: HashMap<String, String>?,
        format: Int,
        maxh: Int,
        maxw: Int,
        timeMs: Int,
        quality: Int,
    ): ByteArray {
        val cacheKey = "${vidPath}_${timeMs}_${format}_${maxh}_${maxw}_$quality"
        memoryCache?.get(cacheKey)?.let {
            Log.d(TAG, "Cache hit: $cacheKey")
            return it
        }
        val bitmap = createVideoThumbnail(vidPath, headers, maxh, maxw, timeMs)
            ?: throw NullPointerException("Could not decode frame")
        val stream = ByteArrayOutputStream()
        bitmap.compress(intToFormat(format), quality, stream)
        bitmap.recycle()
        val bytes = stream.toByteArray()
        memoryCache?.put(cacheKey, bytes)
        return bytes
    }

    // ─── Thumbnail file (single frame → disk) ─────────────────────────────────

    @Throws(IOException::class)
    private fun buildThumbnailFile(
        vidPath: String,
        headers: HashMap<String, String>?,
        path: String?,
        format: Int,
        maxh: Int,
        maxw: Int,
        timeMs: Int,
        quality: Int,
    ): String {
        val bytes = buildThumbnailData(vidPath, headers, format, maxh, maxw, timeMs, quality)
        val ext = formatExt(format)

        // Derive the base filename safely — handles both local paths and remote URLs.
        val baseName = try {
            val lastSegment = Uri.parse(vidPath).lastPathSegment.takeUnless { it.isNullOrEmpty() } ?: "thumbnail"
            val dotIdx = lastSegment.lastIndexOf('.')
            (if (dotIdx >= 0) lastSegment.substring(0, dotIdx) else lastSegment) + "." + ext
        } catch (e: Exception) {
            "thumbnail.$ext"
        }
        var fullpath = baseName

        val isLocalFile = vidPath.startsWith("/") || vidPath.startsWith("file://")
        var targetPath = path
        if (targetPath == null && !isLocalFile) targetPath = context?.cacheDir?.absolutePath

        if (targetPath != null) {
            val check = File(targetPath)
            fullpath = if (check.isDirectory || targetPath.endsWith("/")) {
                if (targetPath.endsWith("/")) targetPath + baseName else "$targetPath/$baseName"
            } else {
                targetPath
            }
        }
        FileOutputStream(fullpath).use { it.write(bytes) }
        Log.d(TAG, String.format("Wrote %d bytes → %s", bytes.size, fullpath))
        return fullpath
    }

    // ─── Batch frame extraction ───────────────────────────────────────────────

    @Throws(IOException::class)
    private fun buildThumbnailDataList(
        vidPath: String,
        headers: HashMap<String, String>?,
        timesMs: List<Int>?,
        format: Int,
        maxh: Int,
        maxw: Int,
        quality: Int,
    ): List<ByteArray?> {
        val results = mutableListOf<ByteArray?>()
        if (timesMs.isNullOrEmpty()) return results
        val cf = intToFormat(format)
        val retriever = MediaMetadataRetriever()
        try {
            openRetriever(vidPath, headers, retriever)
            for (ms in timesMs) {
                var frame: Bitmap? = null
                try {
                    frame = if (maxh != 0 || maxw != 0) {
                        if (Build.VERSION.SDK_INT >= 27 && maxh != 0 && maxw != 0) {
                            retriever.getScaledFrameAtTime(
                                ms.toLong() * 1000,
                                MediaMetadataRetriever.OPTION_CLOSEST,
                                maxw,
                                maxh,
                            )
                        } else {
                            retriever.getFrameAtTime(
                                ms.toLong() * 1000,
                                MediaMetadataRetriever.OPTION_CLOSEST,
                            )?.let { scaleAndRecycle(it, maxh, maxw) }
                        }
                    } else {
                        retriever.getFrameAtTime(ms.toLong() * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                    }
                    if (frame != null) {
                        val s = ByteArrayOutputStream()
                        frame.compress(cf, quality, s)
                        results.add(s.toByteArray())
                    } else {
                        results.add(null)
                    }
                } finally {
                    frame?.recycle()
                }
            }
        } finally {
            try {
                retriever.release()
            } catch (ignored: Exception) {
            }
        }
        return results
    }

    // ─── Video metadata ───────────────────────────────────────────────────────

    @Throws(IOException::class)
    private fun getVideoMetadata(
        vidPath: String,
        headers: HashMap<String, String>?,
    ): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            openRetriever(vidPath, headers, retriever)
            val dMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rot = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val mime = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)
            return mapOf(
                "durationMs" to (dMs?.toLong() ?: 0L),
                "width" to (w?.toInt() ?: 0),
                "height" to (h?.toInt() ?: 0),
                "rotation" to (rot?.toInt() ?: 0),
                "mimeType" to mime,
            )
        } finally {
            try {
                retriever.release()
            } catch (ignored: Exception) {
            }
        }
    }

    // ─── Core frame extraction ────────────────────────────────────────────────

    private fun createVideoThumbnail(
        video: String,
        headers: HashMap<String, String>?,
        targetH: Int,
        targetW: Int,
        timeMs: Int,
    ): Bitmap? {
        var bitmap: Bitmap? = null
        val retriever = MediaMetadataRetriever()
        try {
            openRetriever(video, headers, retriever)
            bitmap = if (targetH != 0 || targetW != 0) {
                if (Build.VERSION.SDK_INT >= 27 && targetH != 0 && targetW != 0) {
                    retriever.getScaledFrameAtTime(
                        timeMs.toLong() * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                        targetW,
                        targetH,
                    )
                } else {
                    retriever.getFrameAtTime(
                        timeMs.toLong() * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    )?.let { scaleAndRecycle(it, targetH, targetW) }
                }
            } else {
                retriever.getFrameAtTime(timeMs.toLong() * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
            }
        } catch (ex: RuntimeException) {
            ex.printStackTrace()
        } catch (ex: IOException) {
            ex.printStackTrace()
        } finally {
            try {
                retriever.release()
            } catch (ex: RuntimeException) {
                ex.printStackTrace()
            } catch (ex: IOException) {
                ex.printStackTrace()
            }
        }
        return bitmap
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    @Throws(IOException::class)
    private fun openRetriever(
        video: String,
        headers: HashMap<String, String>?,
        retriever: MediaMetadataRetriever,
    ) {
        when {
            video.startsWith("content://") -> retriever.setDataSource(context, Uri.parse(video))
            video.startsWith("/") -> setDataSource(video, retriever)
            video.startsWith("file://") -> setDataSource(video.substring(7), retriever)
            else -> retriever.setDataSource(video, headers ?: HashMap())
        }
    }

    companion object {
        private const val TAG = "VideoThumbnailPlugin"

        // ─── MethodChannel identifier ─────────────────────────────────────────
        private const val CHANNEL = "plugins.itsxhadi.com/video_thumbnail_gen"

        // ─── Error code constants ─────────────────────────────────────────────
        private const val ERR_FILE_NOT_FOUND = "FILE_NOT_FOUND"
        private const val ERR_UNSUPPORTED = "UNSUPPORTED_FORMAT"
        private const val ERR_IO = "IO_ERROR"
        private const val ERR_UNKNOWN = "UNKNOWN"

        // ─── Image format indices ─────────────────────────────────────────────
        private const val FORMAT_JPEG = 0
        private const val FORMAT_PNG = 1
        private const val FORMAT_WEBP = 2
        private const val FORMAT_HEIC = 3

        @Suppress("DEPRECATION")
        private fun intToFormat(format: Int): Bitmap.CompressFormat = when (format) {
            FORMAT_PNG -> Bitmap.CompressFormat.PNG
            FORMAT_WEBP ->
                if (Build.VERSION.SDK_INT >= 30) {
                    Bitmap.CompressFormat.WEBP_LOSSY
                } else {
                    Bitmap.CompressFormat.WEBP
                }
            // HEIC is not a Bitmap.CompressFormat — fall back to JPEG on all APIs.
            // Actual HEIC encoding is not supported via Bitmap.compress on Android.
            FORMAT_HEIC -> Bitmap.CompressFormat.JPEG
            FORMAT_JPEG -> Bitmap.CompressFormat.JPEG
            else -> Bitmap.CompressFormat.JPEG
        }

        private fun formatExt(format: Int): String = when (format) {
            FORMAT_PNG -> "png"
            FORMAT_WEBP -> "webp"
            FORMAT_HEIC -> "heic"
            FORMAT_JPEG -> "jpg"
            else -> "jpg"
        }

        private fun scaleAndRecycle(original: Bitmap, targetH: Int, targetW: Int): Bitmap {
            val w = original.width
            val h = original.height
            var outW = targetW
            var outH = targetH
            if (outW == 0) outW = (outH.toFloat() / h * w).roundToInt()
            if (outH == 0) outH = (outW.toFloat() / w * h).roundToInt()
            Log.d(TAG, String.format("Scaling %dx%d → %dx%d", w, h, outW, outH))
            val scaled = Bitmap.createScaledBitmap(original, outW, outH, true)
            if (scaled != original) original.recycle()
            return scaled
        }

        @Throws(IOException::class)
        private fun setDataSource(video: String, retriever: MediaMetadataRetriever) {
            val videoFile = File(video)
            FileInputStream(videoFile.absolutePath).use { retriever.setDataSource(it.fd) }
        }

        private fun runOnUiThread(runnable: Runnable) {
            Handler(Looper.getMainLooper()).post(runnable)
        }
    }
}
