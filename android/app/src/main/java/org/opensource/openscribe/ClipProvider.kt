package org.opensource.openscribe

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Serves cached clipboard images ([ImageClips]) to the apps they are pasted into. Files are encrypted at rest,
 * so [openFile] decrypts into a pipe instead of handing out the file. Not exported: apps can read a URI only
 * while the clipboard (or a share) grants it.
 */
class ClipProvider : ContentProvider() {
    override fun onCreate() = true

    override fun getType(uri: Uri): String? = uri.lastPathSegment?.let(ClipNames::mime)

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Clipboard images are read-only")
        val context = context ?: throw FileNotFoundException()
        val file = ImageClips.fileFor(context, uri) ?: throw FileNotFoundException("No such image")
        val plain = try {
            ImageClips.open(context, file)
        } catch (e: Exception) {
            throw FileNotFoundException("The image can't be read")
        }
        val (read, write) = ParcelFileDescriptor.createPipe()
        Thread({
            try {
                ParcelFileDescriptor.AutoCloseOutputStream(write).use { it.write(plain) }
            } catch (e: IOException) {
                // The reader went away early; nothing to do.
                Log.d("OpenScribe", "clip pipe closed early")
            }
        }, "openscribe-clip-pipe").apply { isDaemon = true; start() }
        return read
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val context = context ?: return null
        val file = ImageClips.fileFor(context, uri) ?: return null
        val columns = projection?.filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }?.toTypedArray()
            ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { if (it == OpenableColumns.SIZE) ImageClips.plainSize(file) else ClipNames.displayName(file.name) })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
