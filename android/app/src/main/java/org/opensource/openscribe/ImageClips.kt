package org.opensource.openscribe

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Color as AndroidColor
import android.net.Uri
import androidx.core.graphics.createBitmap
import org.opensource.openscribe.link.BlobCipher
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Image clips on disk. Received and sent images live in `cacheDir/clips/<mac folder>/`, one folder per Mac
 * ([ClipNames.macFolder]), sealed with AES-256-GCM under a key kept encrypted by the Android Keystore
 * ([PairingStore.clipKey]). Other apps get them through [ClipProvider], which decrypts on the fly, so they can go
 * on the clipboard; thumbnails are decoded in memory. Only the newest [MAX_FILES] per Mac are kept, and
 * forgetting a Mac deletes its folder. Everything here blocks; call it off the main thread.
 */
object ImageClips {
    const val MAX_FILES = 20
    /** Biggest image read from another app before giving up; larger ones are re-encoded down to the blob limit. */
    private const val MAX_READ_BYTES = 64 * 1024 * 1024
    /** Re-encoding starts from at most this many pixels on the long side, to keep memory in check. */
    private const val MAX_EDGE = 4096

    fun root(context: Context) = File(context.cacheDir, "clips")

    private fun macDir(context: Context, macId: String) = File(root(context), ClipNames.macFolder(macId))

    private fun authority(context: Context) = "${context.packageName}.clips"

    private fun key(context: Context): ByteArray {
        val (key, fresh) = PairingStore.clipKey(context)
        // A new key can't open files sealed with a lost one.
        if (fresh) root(context).listFiles()?.forEach { it.deleteRecursively() }
        return key
    }

    /** `content://<app>.clips/<mac folder>/<file>`, served by [ClipProvider]. */
    fun uri(context: Context, file: File): Uri = Uri.Builder().scheme("content").authority(authority(context))
        .appendPath(file.parentFile?.name.orEmpty()).appendPath(file.name).build()

    /** The cached file a [ClipProvider] URI names, or null if the URI isn't one of ours or the file is gone. */
    fun fileFor(context: Context, uri: Uri): File? {
        if (uri.authority != authority(context)) return null
        val segments = uri.pathSegments
        if (segments.size != 2 || !ClipNames.isValid(segments[0], segments[1])) return null
        return File(File(root(context), segments[0]), segments[1]).takeIf { it.isFile }
    }

    /** A clip OpenScribe puts on the clipboard, labelled so the home screen knows where it came from. */
    fun clipData(context: Context, file: File): ClipData =
        ClipData.newUri(context.contentResolver, CLIP_LABEL, uri(context, file))

    /** Saves [bytes] sealed as `<id>.<ext>.enc` in [macId]'s folder and drops that Mac's oldest past [MAX_FILES]. */
    fun save(context: Context, macId: String, id: String, mime: String, bytes: ByteArray): File {
        val folder = macDir(context, macId).apply { mkdirs() }
        val file = File(folder, ClipNames.fileName(id, extension(mime)))
        val partial = File(folder, file.name + ".part")
        partial.writeBytes(BlobCipher.seal(key(context), bytes))
        if (!partial.renameTo(file)) {
            partial.delete()
            throw IOException("Couldn't save the image")
        }
        prune(folder)
        return file
    }

    /** The image bytes of a cached clip. */
    fun open(context: Context, file: File): ByteArray = BlobCipher.open(key(context), file.readBytes())

    /** Plaintext size of a cached clip, without decrypting it. */
    fun plainSize(file: File): Long = (file.length() - BlobCipher.OVERHEAD).coerceAtLeast(0)

    /** Deletes everything cached for [macId]. */
    fun forgetMac(context: Context, macId: String) {
        macDir(context, macId).deleteRecursively()
    }

    /**
     * Startup cleanup: removes unencrypted images earlier builds left in `cacheDir/clips`, half-written files,
     * and the folders of Macs that are no longer paired.
     */
    fun cleanUp(context: Context, pairedMacIds: Collection<String>) {
        val keep = pairedMacIds.map(ClipNames::macFolder).toSet()
        root(context).listFiles()?.forEach { entry ->
            when {
                entry.isFile -> entry.delete()
                entry.name !in keep -> entry.deleteRecursively()
                else -> entry.listFiles()?.forEach { if (!ClipNames.isValid(entry.name, it.name)) it.deleteRecursively() }
            }
        }
    }

    private fun prune(folder: File) {
        val files = folder.listFiles()?.filter { it.isFile && it.name.endsWith(ClipNames.SUFFIX) } ?: return
        files.sortedByDescending { it.lastModified() }.drop(MAX_FILES).forEach { it.delete() }
    }

    fun extension(mime: String): String = when (mime.lowercase()) {
        "image/png" -> "png"
        "image/jpeg", "image/jpg" -> "jpg"
        "image/gif" -> "gif"
        "image/webp" -> "webp"
        "image/heic" -> "heic"
        "image/heif" -> "heif"
        "image/tiff" -> "tiff"
        "image/bmp" -> "bmp"
        else -> "img"
    }

    /** The image type from its first bytes, which is more trustworthy than a label. */
    fun sniffMime(bytes: ByteArray): String? {
        fun at(offset: Int, vararg expected: Int) =
            bytes.size >= offset + expected.size && expected.indices.all { (bytes[offset + it].toInt() and 0xff) == expected[it] }
        fun ascii(offset: Int, text: String) = at(offset, *text.map { it.code }.toIntArray())
        return when {
            at(0, 0x89, 0x50, 0x4e, 0x47) -> "image/png"
            at(0, 0xff, 0xd8, 0xff) -> "image/jpeg"
            ascii(0, "GIF8") -> "image/gif"
            ascii(0, "RIFF") && ascii(8, "WEBP") -> "image/webp"
            ascii(4, "ftypheic") || ascii(4, "ftypheix") || ascii(4, "ftypmif1") || ascii(4, "ftyphevc") -> "image/heic"
            at(0, 0x49, 0x49, 0x2a, 0x00) || at(0, 0x4d, 0x4d, 0x00, 0x2a) -> "image/tiff"
            ascii(0, "BM") -> "image/bmp"
            else -> null
        }
    }

    /** Reads an image another app shared or copied. Call while our app is in the foreground. */
    fun read(context: Context, uri: Uri): ByteArray {
        val input = context.contentResolver.openInputStream(uri) ?: throw IOException("Couldn't open the image")
        input.use {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = it.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_READ_BYTES) throw IOException("That image is too large to send")
            }
            if (out.size() == 0) throw IOException("The image is empty")
            return out.toByteArray()
        }
    }

    /** Whether a clipboard description or share type is an image. */
    fun isImage(description: ClipDescription?): Boolean = description?.hasMimeType("image/*") == true

    /**
     * Returns bytes that fit in one blob, with their type. Images over the limit are re-encoded as JPEG and
     * scaled down until they fit (ImageDecoder also applies the EXIF rotation, so photos stay upright).
     */
    fun fitForSending(bytes: ByteArray, mime: String): Pair<ByteArray, String> {
        if (bytes.size <= BlobCipher.MAX_PLAINTEXT) return bytes to mime
        var scale = 1.0
        repeat(8) {
            val encoded = encodeJpeg(bytes, scale)
            if (encoded.size <= BlobCipher.MAX_PLAINTEXT) return encoded to "image/jpeg"
            scale *= 0.75
        }
        throw IOException("That image is too large to send")
    }

    private fun encodeJpeg(bytes: ByteArray, scale: Double): ByteArray {
        val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width
            val h = info.size.height
            val fit = minOf(1.0, MAX_EDGE.toDouble() / max(w, h)) * scale
            decoder.setTargetSize(max(1, (w * fit).roundToInt()), max(1, (h * fit).roundToInt()))
        }
        // JPEG has no transparency: put see-through images on white, not black.
        val opaque = if (bitmap.hasAlpha()) {
            createBitmap(bitmap.width, bitmap.height).also {
                Canvas(it).apply { drawColor(AndroidColor.WHITE); drawBitmap(bitmap, 0f, 0f, null) }
                bitmap.recycle()
            }
        } else bitmap
        val out = ByteArrayOutputStream()
        opaque.compress(Bitmap.CompressFormat.JPEG, 88, out)
        opaque.recycle()
        return out.toByteArray()
    }

    /** A small bitmap of [file] for the Recent list, decoded in memory, or null if it can't be. */
    fun thumbnail(context: Context, file: File, sizePx: Int): Bitmap? = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(open(context, file)))) { decoder, info, _ ->
            val shortSide = minOf(info.size.width, info.size.height)
            decoder.setTargetSampleSize(max(1, shortSide / sizePx))
        }
    } catch (e: Exception) {
        null
    }
}

/** Names inside `cacheDir/clips`, kept strict so [ClipProvider] can't be pointed anywhere else. Pure JVM. */
object ClipNames {
    const val SUFFIX = ".enc"
    private val FOLDER = Regex("^[0-9a-f]{16}$")
    private val FILE = Regex("^[A-Za-z0-9_-]{1,64}\\.[a-z]{2,4}\\.enc$")

    /** A Mac's folder: the first 8 bytes of SHA-256 of its id, in hex, so ids never become paths. */
    fun macFolder(macId: String): String =
        MessageDigest.getInstance("SHA-256").digest(macId.toByteArray(Charsets.UTF_8)).take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun fileName(id: String, extension: String): String {
        val safeId = id.filter { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }.take(64).ifEmpty { "clip" }
        return "$safeId.$extension$SUFFIX"
    }

    fun isValid(folder: String, file: String) = FOLDER.matches(folder) && FILE.matches(file)

    /** The image type from a cached file's name. */
    fun mime(file: String): String = when (file.removeSuffix(SUFFIX).substringAfterLast('.')) {
        "png" -> "image/png"
        "jpg" -> "image/jpeg"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic" -> "image/heic"
        "heif" -> "image/heif"
        "tiff" -> "image/tiff"
        "bmp" -> "image/bmp"
        else -> "application/octet-stream"
    }

    /** The name pasting apps see: the file name without [SUFFIX]. */
    fun displayName(file: String) = file.removeSuffix(SUFFIX)
}
