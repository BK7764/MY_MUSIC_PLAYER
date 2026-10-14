package com.example.my_music_player

import android.content.ContentUris
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private val channelName = "my_music_player/media"
    private var pendingDeleteResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 9001) {
            val pending = pendingDeleteResult
            pendingDeleteResult = null
            pending?.success(resultCode == RESULT_OK)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSongs" -> result.success(getSongs())
                    "getArtwork" -> getArtwork(call.argument<String>("uri"), call.argument<String>("path"), result)
                    "getVideos" -> result.success(getVideos())
                    "deleteSong" -> deleteSong(call.argument<Number>("id")?.toLong(), call.argument<String>("uri"), call.argument<String>("path"), result)
                    "shareFile" -> shareFile(call.argument<String>("uri"), call.argument<String>("path"), result)
                    "setRingtone" -> setRingtone(call.argument<String>("uri"), call.argument<String>("name"), result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun getSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.MIME_TYPE
        )

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"

        contentResolver.query(collection, projection, selection, null, "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC")?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val pathColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val folderColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.BUCKET_DISPLAY_NAME)
            val dateAddedColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED)
            val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val path = cursor.getString(pathColumn) ?: ""
                val lowerPath = path.lowercase()
                val isCallRecording = lowerPath.contains("call recording") ||
                    lowerPath.contains("call_recording") ||
                    lowerPath.contains("callrecording") ||
                    lowerPath.contains("/call recordings/") ||
                    lowerPath.contains("/call_recordings/") ||
                    lowerPath.contains("/callrecordings/") ||
                    lowerPath.contains("/record/call/")
                if (isCallRecording) continue

                val uri = ContentUris.withAppendedId(collection, id)
                songs.add(
                    mapOf(
                        "id" to id,
                        "title" to (cursor.getString(titleColumn) ?: "Unknown Song"),
                        "artist" to (cursor.getString(artistColumn) ?: "Unknown Artist"),
                        "album" to (cursor.getString(albumColumn) ?: "Unknown Album"),
                        "path" to path,
                        "uri" to uri.toString(),
                        "duration" to cursor.getLong(durationColumn),
                        "folder" to (cursor.getString(folderColumn) ?: "Unknown Folder"),
                        "dateAdded" to cursor.getLong(dateAddedColumn),
                        "mimeType" to (cursor.getString(mimeColumn) ?: "audio/mpeg")
                    )
                )
            }
        }
        return songs
    }

    private fun getArtwork(uriString: String?, path: String?, result: MethodChannel.Result) {
        var retriever: android.media.MediaMetadataRetriever? = null
        try {
            retriever = android.media.MediaMetadataRetriever()
            if (!uriString.isNullOrBlank()) {
                retriever.setDataSource(this, Uri.parse(uriString))
            } else if (!path.isNullOrBlank()) {
                retriever.setDataSource(path)
            } else {
                result.success(null)
                return
            }
            result.success(retriever.embeddedPicture)
        } catch (_: Exception) {
            result.success(null)
        } finally {
            try { retriever?.release() } catch (_: Exception) {}
        }
    }

    private fun getVideos(): List<Map<String, Any?>> {
        val videos = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DURATION
        )

        contentResolver.query(collection, projection, null, null, "${MediaStore.Video.Media.DISPLAY_NAME} COLLATE NOCASE ASC")?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val pathColumn = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
            val durationColumn = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val uri = ContentUris.withAppendedId(collection, id)
                videos.add(
                    mapOf(
                        "id" to id,
                        "name" to (cursor.getString(nameColumn) ?: "Unknown Video"),
                        "path" to (cursor.getString(pathColumn) ?: ""),
                        "uri" to uri.toString(),
                        "duration" to cursor.getLong(durationColumn)
                    )
                )
            }
        }
        return videos
    }

    private fun deleteSong(id: Long?, uriString: String?, path: String?, result: MethodChannel.Result) {
        val uri = if (!uriString.isNullOrBlank() && uriString != "null") {
            Uri.parse(uriString)
        } else if (id != null) {
            ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        } else null

        if (uri == null) {
            result.success(false)
            return
        }

        try {
            val deleted = contentResolver.delete(uri, null, null)
            result.success(deleted > 0)
        } catch (security: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    val pendingIntent = MediaStore.createDeleteRequest(contentResolver, listOf(uri))
                    pendingDeleteResult = result
                    startIntentSenderForResult(pendingIntent.intentSender, 9001, null, 0, 0, 0)
                } catch (e: Exception) {
                    result.error("DELETE_REQUEST_FAILED", e.message, null)
                }
            } else {
                result.error("DELETE_PERMISSION", security.message, null)
            }
        } catch (e: Exception) {
            result.error("DELETE_FAILED", e.message, null)
        }
    }

    private fun shareFile(uriString: String?, path: String?, result: MethodChannel.Result) {
        try {
            val uri = if (!uriString.isNullOrBlank() && uriString != "null") Uri.parse(uriString) else Uri.fromFile(java.io.File(path ?: ""))
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = contentResolver.getType(uri) ?: "audio/*"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share song"))
            result.success(true)
        } catch (e: Exception) {
            result.error("SHARE_FAILED", e.message, null)
        }
    }

    private fun setRingtone(uriString: String?, name: String?, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.System.canWrite(this)) {
                val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
                result.success(false)
                return
            }
            val uri = if (!uriString.isNullOrBlank() && uriString != "null") Uri.parse(uriString) else null
            if (uri == null) {
                result.success(false)
                return
            }
            RingtoneManager.setActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE, uri)
            result.success(true)
        } catch (e: Exception) {
            result.error("RINGTONE_FAILED", e.message, null)
        }
    }
}
