package com.itsxhadi.video_thumbnail

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import android.util.LruCache
import android.webkit.MimeTypeMap
import androidx.exifinterface.media.ExifInterface
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
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
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
                // A failure inside a known method must surface as its typed error
                // code. `handled` is only set once the work succeeds, so checking
                // it first would report every failure as notImplemented — which
                // reaches Dart as MissingPluginException instead of, say,
                // FILE_NOT_FOUND.
                if (exc != null) {
                    exc.printStackTrace()
                    result.error(errCode ?: ERR_UNKNOWN, exc.message, null)
                    return@runOnUiThread
                }
                if (!handled) {
                    result.notImplemented()
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

    // ─── Media metadata ───────────────────────────────────────────────────────

    /**
     * Metadata for a video *or* an image.
     *
     * Every field is resolved independently and defensively: a tag the source
     * file does not carry comes back as null rather than failing the call.
     */
    private fun getVideoMetadata(
        vidPath: String,
        headers: HashMap<String, String>?,
    ): Map<String, Any?> {
        val mimeType = runCatching { resolveMimeType(vidPath) }.getOrNull()
        return if (mimeType != null && mimeType.startsWith("image/")) {
            imageMetadata(vidPath, mimeType)
        } else {
            videoMetadata(vidPath, headers, mimeType)
        }
    }

    private fun videoMetadata(
        vidPath: String,
        headers: HashMap<String, String>?,
        fallbackMime: String?,
    ): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        try {
            openRetriever(vidPath, headers, retriever)

            fun key(id: Int): String? =
                runCatching { retriever.extractMetadata(id) }.getOrNull()?.takeIf { it.isNotEmpty() }

            val rotation = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val storedWidth = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val storedHeight = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0

            return mapOf(
                "durationMs" to key(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
                "width" to storedWidth,
                "height" to storedHeight,
                "rotation" to rotation,
                "mimeType" to (key(MediaMetadataRetriever.METADATA_KEY_MIMETYPE) ?: fallbackMime),
                "capturedAt" to parseVideoDate(key(MediaMetadataRetriever.METADATA_KEY_DATE)),
                "modifiedAt" to lastModifiedMs(vidPath),
                // MediaMetadataRetriever exposes no camera make/model keys, so these
                // stay null for videos on Android.
                "cameraMake" to null,
                "cameraModel" to null,
                "gps" to parseIso6709(key(MediaMetadataRetriever.METADATA_KEY_LOCATION)),
            )
        } finally {
            try {
                retriever.release()
            } catch (ignored: Exception) {
            }
        }
    }

    private fun imageMetadata(vidPath: String, mimeType: String): Map<String, Any?> {
        // Stored pixel dimensions. BitmapFactory does not apply EXIF orientation,
        // so these are pre-rotation and get transposed below when needed.
        var storedWidth = 0
        var storedHeight = 0
        runCatching {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            openStream(vidPath)?.use { BitmapFactory.decodeStream(it, null, options) }
            if (options.outWidth > 0) storedWidth = options.outWidth
            if (options.outHeight > 0) storedHeight = options.outHeight
        }

        val exif = runCatching { openStream(vidPath)?.use { ExifInterface(it) } }.getOrNull()

        val orientation = exif?.let {
            runCatching {
                it.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }.getOrNull()
        } ?: ExifInterface.ORIENTATION_NORMAL

        val rotation = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_180, ExifInterface.ORIENTATION_FLIP_VERTICAL -> 180
            ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE -> 90
            ExifInterface.ORIENTATION_ROTATE_270, ExifInterface.ORIENTATION_TRANSVERSE -> 270
            else -> 0
        }
        // Orientations 5–8 are quarter turns: the stored pixels are transposed
        // relative to how the image displays.
        val quarterTurn = orientation in 5..8
        val width = if (quarterTurn) storedHeight else storedWidth
        val height = if (quarterTurn) storedWidth else storedHeight

        fun tag(name: String): String? = exif?.let {
            runCatching { it.getAttribute(name) }.getOrNull()?.takeIf { v -> v.isNotEmpty() }
        }

        val captured = parseExifDate(
            tag(ExifInterface.TAG_DATETIME_ORIGINAL)
                ?: tag(ExifInterface.TAG_DATETIME_DIGITIZED)
                ?: tag(ExifInterface.TAG_DATETIME),
            tag(ExifInterface.TAG_OFFSET_TIME_ORIGINAL) ?: tag(ExifInterface.TAG_OFFSET_TIME),
        )

        return mapOf(
            // Images have no duration; null is what distinguishes them from a
            // zero-length video.
            "durationMs" to null,
            "width" to width,
            "height" to height,
            "rotation" to rotation,
            "mimeType" to mimeType,
            "capturedAt" to captured,
            "modifiedAt" to lastModifiedMs(vidPath),
            "cameraMake" to tag(ExifInterface.TAG_MAKE),
            "cameraModel" to tag(ExifInterface.TAG_MODEL),
            "gps" to exifGps(exif),
        )
    }

    private fun exifGps(exif: ExifInterface?): Map<String, Any?>? {
        if (exif == null) return null
        // latLong() is null unless a usable fix is present, which is exactly the
        // "null as a group" semantics we want — never default to 0, 0.
        val latLong = runCatching { exif.latLong }.getOrNull() ?: return null
        if (latLong.size < 2) return null

        val payload = mutableMapOf<String, Any?>("lat" to latLong[0], "lon" to latLong[1])
        val altitude = runCatching { exif.getAltitude(Double.NaN) }.getOrNull()
        if (altitude != null && !altitude.isNaN()) payload["alt"] = altitude
        return payload
    }

    // ─── Metadata helpers ─────────────────────────────────────────────────────

    /** Opens a stream for a `content://`, `file://`, or plain filesystem path. */
    private fun openStream(path: String): InputStream? = when {
        path.startsWith("content://") ->
            context?.contentResolver?.openInputStream(Uri.parse(path))
        path.startsWith("file://") -> FileInputStream(path.substring(7))
        path.startsWith("/") -> FileInputStream(path)
        else -> null
    }

    private fun resolveMimeType(path: String): String? {
        if (path.startsWith("content://")) {
            context?.contentResolver?.getType(Uri.parse(path))?.let { return it }
        }
        val extension = MimeTypeMap.getFileExtensionFromUrl(path)
            .ifEmpty { path.substringAfterLast('.', "") }
            .lowercase()
        if (extension.isEmpty()) return null
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
    }

    private fun lastModifiedMs(path: String): Long? = runCatching {
        when {
            path.startsWith("content://") -> contentLastModifiedMs(Uri.parse(path))
            path.startsWith("file://") -> File(path.substring(7)).lastModified().takeIf { it > 0 }
            path.startsWith("/") -> File(path).lastModified().takeIf { it > 0 }
            else -> null
        }
    }.getOrNull()

    private fun contentLastModifiedMs(uri: Uri): Long? {
        val resolver = context?.contentResolver ?: return null
        val columns = arrayOf(
            MediaStore.MediaColumns.DATE_MODIFIED,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        for (column in columns) {
            val value = runCatching {
                resolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
                }
            }.getOrNull() ?: continue
            if (value <= 0) continue
            // MediaStore reports seconds; DocumentsContract reports milliseconds.
            return if (column == MediaStore.MediaColumns.DATE_MODIFIED) value * 1000 else value
        }
        return null
    }

    /** Parses an ISO-6709 location such as `+37.7749-122.4194+010.500/`. */
    private fun parseIso6709(raw: String?): Map<String, Any?>? {
        if (raw.isNullOrEmpty()) return null
        val match = ISO_6709.find(raw) ?: return null
        val lat = match.groupValues[1].toDoubleOrNull() ?: return null
        val lon = match.groupValues[2].toDoubleOrNull() ?: return null
        val payload = mutableMapOf<String, Any?>("lat" to lat, "lon" to lon)
        match.groupValues[3].takeIf { it.isNotEmpty() }?.toDoubleOrNull()
            ?.let { payload["alt"] = it }
        return payload
    }

    /** `METADATA_KEY_DATE` is UTC, formatted `yyyyMMdd'T'HHmmss[.SSS]'Z'`. */
    private fun parseVideoDate(raw: String?): Long? {
        if (raw.isNullOrEmpty()) return null
        for (pattern in arrayOf("yyyyMMdd'T'HHmmss.SSS'Z'", "yyyyMMdd'T'HHmmss'Z'")) {
            val parsed = runCatching {
                SimpleDateFormat(pattern, Locale.US)
                    .apply { timeZone = TimeZone.getTimeZone("UTC") }
                    .parse(raw)
            }.getOrNull()
            if (parsed != null) return parsed.time
        }
        return null
    }

    /**
     * Parses an EXIF timestamp (`yyyy:MM:dd HH:mm:ss`). EXIF carries no time zone,
     * so without an explicit offset the device's zone is assumed.
     */
    private fun parseExifDate(raw: String?, utcOffset: String?): Long? {
        if (raw.isNullOrEmpty()) return null
        if (!utcOffset.isNullOrEmpty()) {
            runCatching {
                SimpleDateFormat("yyyy:MM:dd HH:mm:ssXXX", Locale.US).parse(raw + utcOffset)
            }.getOrNull()?.let { return it.time }
        }
        return runCatching {
            SimpleDateFormat("yyyy:MM:dd HH:mm:ss", Locale.US)
                .apply { timeZone = TimeZone.getDefault() }
                .parse(raw)
        }.getOrNull()?.time
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

        /** ISO-6709 latitude/longitude/optional-altitude, e.g. `+37.77-122.41+010.5/`. */
        private val ISO_6709 =
            Regex("""([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?""")

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
