package com.yskj0864.oo_music

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private var pendingExport: MethodChannel.Result? = null
    private var pendingNotificationPermission: MethodChannel.Result? = null
    private var sourceFile: File? = null
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var audioManager: AudioManager
    private var desktopLyricsChannel: MethodChannel? = null
    private var overlayWindowManager: WindowManager? = null
    private var overlayView: View? = null
    private var overlayLyric: TextView? = null
    private var overlayTranslation: TextView? = null
    private var overlayPlayPause: ImageButton? = null
    private var overlayControls: View? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var overlayLocked = false
    private var overlayLockHandle: View? = null
    private var overlayLockHandleParams: WindowManager.LayoutParams? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        configureAndroidPermissionsChannel(flutterEngine)
        configureDesktopLyricsChannel(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oo_music/system_volume")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "get" -> {
                            val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                            val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            result.success(if (maximum > 0) current.toDouble() / maximum else 0.0)
                        }
                        "set" -> {
                            val normalized =
                                (call.argument<Number>("value")?.toDouble() ?: 0.0)
                                    .coerceIn(0.0, 1.0)
                            val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            val target = Math.round(normalized * maximum).toInt()
                            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: SecurityException) {
                    result.error("volume_denied", "Cannot change system media volume", null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oo_music/file_export")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveAs") {
                    result.notImplemented()
                } else if (pendingExport != null) {
                    result.error("busy", "A file export is already active", null)
                } else {
                    try {
                        val path = call.argument<String>("path") ?: ""
                        val file = File(path).canonicalFile
                        // Restrict reads to the two download locations created
                        // by DownloadService, excluding account DB/cache files.
                        val roots = listOfNotNull(
                            File(filesDir, "downloads/oo music"),
                            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                                ?.let { File(it, "oo music") }
                        )
                        val allowed = roots.any {
                            file.path.startsWith(it.canonicalPath + File.separator)
                        }
                        if (!allowed || !file.isFile) {
                            result.error("invalid_file", "Not an application download", null)
                        } else {
                            sourceFile = file
                            pendingExport = result
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = call.argument<String>("mimeType") ?: "audio/mpeg"
                                putExtra(Intent.EXTRA_TITLE, file.name)
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, EXPORT_REQUEST)
                        }
                    } catch (_: Exception) {
                        pendingExport = null
                        sourceFile = null
                        result.error("export_failed", "Cannot open save dialog", null)
                    }
                }
            }
    }

    private fun configureAndroidPermissionsChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oo_music/android_permissions")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "notificationsEnabled" -> {
                        val manager =
                            getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                        result.success(manager.areNotificationsEnabled())
                    }
                    "openNotificationSettings" -> {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        if (
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        if (pendingNotificationPermission != null) {
                            result.error(
                                "permission_busy",
                                "Notification permission is already pending",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        pendingNotificationPermission = result
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIFICATION_PERMISSION_REQUEST,
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun configureDesktopLyricsChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oo_music/desktop_lyrics")
        desktopLyricsChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            requestOverlayPermission()
                            Toast.makeText(
                                this,
                                "请允许悬浮窗权限后再次打开桌面歌词",
                                Toast.LENGTH_LONG,
                            ).show()
                            result.error(
                                "overlay_permission_required",
                                "Overlay permission is required",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        showDesktopLyrics(
                            lyric = call.argument<String>("lyric").orEmpty(),
                            translation = call.argument<String>("translation").orEmpty(),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                        )
                        result.success(true)
                    }
                    "update" -> {
                        updateDesktopLyrics(
                            lyric = call.argument<String>("lyric").orEmpty(),
                            translation = call.argument<String>("translation").orEmpty(),
                            isPlaying = call.argument<Boolean>("isPlaying") ?: false,
                        )
                        result.success(null)
                    }
                    "hide" -> {
                        hideDesktopLyrics()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                hideDesktopLyrics()
                result.error("overlay_failed", "Cannot display desktop lyrics", null)
            }
        }
    }

    private fun requestOverlayPermission() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName"),
        )
        startActivity(intent)
    }

    private fun showDesktopLyrics(lyric: String, translation: String, isPlaying: Boolean) {
        if (overlayView != null) {
            updateDesktopLyrics(lyric, translation, isPlaying)
            return
        }

        val windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(7), dp(8), dp(7))
            elevation = dp(14).toFloat()
            background = GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                intArrayOf(
                    Color.argb(238, 10, 14, 20),
                    Color.argb(228, 22, 31, 29),
                    Color.argb(238, 8, 12, 17),
                ),
            ).apply {
                cornerRadius = dp(27).toFloat()
                setStroke(dp(1), Color.argb(128, 105, 223, 160))
            }
        }

        val textColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(2), dp(10), dp(2))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val lyricView = TextView(this).apply {
            textSize = 20f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setShadowLayer(dp(2).toFloat(), 0f, dp(1).toFloat(), Color.argb(220, 0, 0, 0))
        }
        val translationView = TextView(this).apply {
            textSize = 12f
            setTextColor(Color.argb(210, 205, 210, 225))
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            setShadowLayer(dp(1).toFloat(), 0f, dp(1).toFloat(), Color.argb(210, 0, 0, 0))
        }
        textColumn.addView(lyricView)
        textColumn.addView(translationView)

        val playPauseButton = overlayIconButton(
            R.drawable.ic_lyrics_play,
            "播放",
        ) {
            desktopLyricsChannel?.invokeMethod("togglePlayback", null)
        }
        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        controls.addView(
            overlayIconButton(R.drawable.ic_lyrics_previous, "上一首") {
                desktopLyricsChannel?.invokeMethod("previous", null)
            },
        )
        controls.addView(playPauseButton)
        controls.addView(
            overlayIconButton(R.drawable.ic_lyrics_next, "下一首") {
                desktopLyricsChannel?.invokeMethod("next", null)
            },
        )
        controls.addView(
            overlayIconButton(R.drawable.ic_lyrics_lock, "锁定桌面歌词") {
                setOverlayLocked(true)
            },
        )
        controls.addView(
            overlayIconButton(R.drawable.ic_lyrics_close, "关闭桌面歌词") {
                hideDesktopLyrics()
                desktopLyricsChannel?.invokeMethod("closed", null)
            },
        )

        root.addView(textColumn)
        root.addView(controls)

        val params = WindowManager.LayoutParams(
            (resources.displayMetrics.widthPixels * 0.92f).toInt(),
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayWindowType(),
            overlayWindowFlags(locked = false),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(16)
            y = dp(140)
        }
        attachDrag(textColumn, root, params, windowManager)

        windowManager.addView(root, params)
        overlayWindowManager = windowManager
        overlayView = root
        overlayLyric = lyricView
        overlayTranslation = translationView
        overlayPlayPause = playPauseButton
        overlayControls = controls
        overlayParams = params
        overlayLocked = false
        updateDesktopLyrics(lyric, translation, isPlaying)
    }

    private fun overlayIconButton(
        iconResource: Int,
        description: String,
        onClick: () -> Unit,
    ): ImageButton {
        return ImageButton(this).apply {
            setImageResource(iconResource)
            contentDescription = description
            setColorFilter(Color.WHITE)
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(34, 255, 255, 255))
            }
            isClickable = true
            isFocusable = true
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(36)).apply {
                marginStart = dp(3)
                marginEnd = dp(3)
            }
            setOnClickListener { onClick() }
        }
    }

    private fun overlayWindowType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }

    private fun overlayWindowFlags(locked: Boolean): Int {
        var flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
        if (locked) flags = flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        return flags
    }

    private fun attachDrag(
        view: View,
        root: View,
        params: WindowManager.LayoutParams,
        windowManager: WindowManager,
        onTap: (() -> Unit)? = null,
    ) {
        var startX = 0
        var startY = 0
        var touchStartX = 0f
        var touchStartY = 0f
        var dragged = false
        val touchSlop = dp(5)
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startX = params.x
                    startY = params.y
                    touchStartX = event.rawX
                    touchStartY = event.rawY
                    dragged = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchStartX).toInt()
                    val dy = (event.rawY - touchStartY).toInt()
                    if (kotlin.math.abs(dx) > touchSlop || kotlin.math.abs(dy) > touchSlop) {
                        dragged = true
                    }
                    params.x = (startX + dx).coerceIn(
                        0,
                        (resources.displayMetrics.widthPixels - params.width).coerceAtLeast(0),
                    )
                    params.y = (startY + dy).coerceIn(
                        0,
                        (resources.displayMetrics.heightPixels - dp(80)).coerceAtLeast(0),
                    )
                    windowManager.updateViewLayout(root, params)
                    updateLockHandlePosition()
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!dragged) onTap?.invoke()
                    true
                }
                MotionEvent.ACTION_CANCEL -> true
                else -> false
            }
        }
    }

    private fun setOverlayLocked(locked: Boolean) {
        val root = overlayView ?: return
        val params = overlayParams ?: return
        val windowManager = overlayWindowManager ?: return
        overlayLocked = locked
        overlayControls?.visibility = if (locked) View.GONE else View.VISIBLE
        params.flags = overlayWindowFlags(locked)
        windowManager.updateViewLayout(root, params)
        if (locked) {
            showLockHandle()
        } else {
            hideLockHandle()
        }
    }

    private fun showLockHandle() {
        if (overlayLockHandle != null || !overlayLocked) return
        val windowManager = overlayWindowManager ?: return
        val handle = ImageButton(this).apply {
            setImageResource(R.drawable.ic_lyrics_unlock)
            contentDescription = "解锁桌面歌词"
            setColorFilter(Color.WHITE)
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.argb(225, 15, 20, 25))
                setStroke(dp(1), Color.argb(180, 105, 223, 160))
            }
            elevation = dp(10).toFloat()
        }
        val handleParams = WindowManager.LayoutParams(
            dp(38),
            dp(38),
            overlayWindowType(),
            overlayWindowFlags(locked = false),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }
        attachDrag(handle, overlayView ?: return, overlayParams ?: return, windowManager) {
            setOverlayLocked(false)
        }
        windowManager.addView(handle, handleParams)
        overlayLockHandle = handle
        overlayLockHandleParams = handleParams
        updateLockHandlePosition()
    }

    private fun hideLockHandle() {
        val handle = overlayLockHandle ?: return
        try {
            overlayWindowManager?.removeView(handle)
        } catch (_: IllegalArgumentException) {
            // The activity may already have detached the unlock handle.
        }
        overlayLockHandle = null
        overlayLockHandleParams = null
    }

    private fun updateLockHandlePosition() {
        val handle = overlayLockHandle ?: return
        val handleParams = overlayLockHandleParams ?: return
        val mainParams = overlayParams ?: return
        val windowManager = overlayWindowManager ?: return
        handleParams.x = (mainParams.x + mainParams.width - dp(46)).coerceAtLeast(0)
        handleParams.y = (mainParams.y + dp(8)).coerceAtLeast(0)
        windowManager.updateViewLayout(handle, handleParams)
    }

    private fun updateDesktopLyrics(lyric: String, translation: String, isPlaying: Boolean) {
        overlayLyric?.text = lyric.trim().ifEmpty { "♪" }
        overlayTranslation?.apply {
            text = translation.trim()
            visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
        }
        overlayPlayPause?.apply {
            setImageResource(
                if (isPlaying) R.drawable.ic_lyrics_pause else R.drawable.ic_lyrics_play,
            )
            contentDescription = if (isPlaying) "暂停" else "播放"
        }
    }

    private fun hideDesktopLyrics() {
        hideLockHandle()
        val view = overlayView ?: return
        try {
            overlayWindowManager?.removeView(view)
        } catch (_: IllegalArgumentException) {
            // The activity may already have detached the overlay.
        }
        overlayView = null
        overlayWindowManager = null
        overlayLyric = null
        overlayTranslation = null
        overlayPlayPause = null
        overlayControls = null
        overlayParams = null
        overlayLocked = false
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotificationPermission?.success(granted)
            pendingNotificationPermission = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    @Deprecated("Activity result bridge for Storage Access Framework")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST) return
        val result = pendingExport ?: return
        val file = sourceFile
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null || file == null) {
            pendingExport = null
            sourceFile = null
            result.success(false)
            return
        }
        exportExecutor.execute {
            var succeeded = false
            try {
                contentResolver.openOutputStream(destination, "w")?.use { output ->
                    file.inputStream().use { input -> input.copyTo(output) }
                    succeeded = true
                }
            } catch (_: Exception) {
                // No signed URL, provider URI or local path in logs/errors.
            }
            mainHandler.post {
                if (pendingExport !== result) return@post
                pendingExport = null
                sourceFile = null
                if (succeeded) result.success(true)
                else result.error("export_failed", "Cannot write the selected document", null)
            }
        }
    }

    override fun onDestroy() {
        hideDesktopLyrics()
        desktopLyricsChannel?.setMethodCallHandler(null)
        desktopLyricsChannel = null
        pendingNotificationPermission?.error(
            "cancelled",
            "Activity closed while requesting notification permission",
            null,
        )
        pendingNotificationPermission = null
        pendingExport?.error("cancelled", "Activity closed during export", null)
        pendingExport = null
        sourceFile = null
        exportExecutor.shutdown()
        super.onDestroy()
    }

    companion object {
        private const val EXPORT_REQUEST = 4101
        private const val NOTIFICATION_PERMISSION_REQUEST = 4102
    }
}
