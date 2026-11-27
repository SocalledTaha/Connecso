package com.connecso.client

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

class AndroidUpdateFileProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun resolve(uri: Uri): File? {
        if (uri.authority != "${context?.packageName}.fileprovider" || uri.pathSegments.size != 2 || uri.pathSegments[0] != "update") {
            return null
        }
        val name = uri.pathSegments[1]
        if (name.isBlank() || name.contains("..") || name.contains('/') || name.contains('\\')) return null
        val root = context?.getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS)
            ?.let { File(it, "Update Downloads") }
            ?: context?.filesDir?.let { File(it, "Update Downloads") }
            ?: return null
        val file = File(root, name).canonicalFile
        if (!file.path.startsWith(root.canonicalPath + File.separator)) return null
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") throw IllegalArgumentException("Update APKs are read-only.")
        val file = resolve(uri)?.takeIf { it.isFile }
            ?: throw IllegalArgumentException("Update APK does not exist.")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? =
        if (resolve(uri)?.isFile == true) "application/vnd.android.package-archive" else null

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val file = resolve(uri)?.takeIf { it.isFile } ?: return null
        val columns = projection?.toList() ?: listOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns.toTypedArray()).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> file.name
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
