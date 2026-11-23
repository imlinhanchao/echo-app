package org.hancel.echo

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val encoderExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.hancel.echo/audio_encoder"
        ).setMethodCallHandler { call, result ->
            if (call.method == "encodePcmToM4a") {
                val pcmPath = call.argument<String>("pcmPath")
                val m4aPath = call.argument<String>("m4aPath")
                val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                val channels = call.argument<Int>("channels") ?: 1
                val bitRate = call.argument<Int>("bitRate") ?: 64000

                if (pcmPath.isNullOrEmpty() || m4aPath.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "pcmPath 和 m4aPath 不能为空", null)
                    return@setMethodCallHandler
                }

                encoderExecutor.execute {
                    try {
                        M4aEncoder.encodePcmToM4a(
                            pcmPath = pcmPath,
                            m4aPath = m4aPath,
                            sampleRate = sampleRate,
                            channels = channels,
                            bitRate = bitRate
                        )
                        mainHandler.post { result.success(m4aPath) }
                    } catch (e: Exception) {
                        mainHandler.post {
                            result.error("ENCODE_FAILED", e.message ?: "M4A 编码失败", null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.hancel.echo/download_keepalive"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startOrUpdate" -> {
                    val title = call.argument<String>("title") ?: "正在下载离线语音模型"
                    val text = call.argument<String>("text") ?: "下载中..."
                    val progress = call.argument<Int>("progress") ?: 0
                    val max = call.argument<Int>("max") ?: 100
                    try {
                        val intent = Intent(this, ModelDownloadForegroundService::class.java).apply {
                            action = ModelDownloadForegroundService.ACTION_START_OR_UPDATE
                            putExtra(ModelDownloadForegroundService.EXTRA_TITLE, title)
                            putExtra(ModelDownloadForegroundService.EXTRA_TEXT, text)
                            putExtra(ModelDownloadForegroundService.EXTRA_PROGRESS, progress)
                            putExtra(ModelDownloadForegroundService.EXTRA_MAX, max)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                    } catch (_: Exception) {
                        // 某些国产 ROM 若限制后台拉起前台服务，降级为无保活下载，避免崩溃
                    }
                    result.success(null)
                }
                "stop" -> {
                    try {
                        stopService(Intent(this, ModelDownloadForegroundService::class.java))
                    } catch (_: Exception) {
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.hancel.echo/wakelock"
        ).setMethodCallHandler { call, result ->
            if (call.method == "setKeepScreenOn") {
                val enabled = call.argument<Boolean>("enabled") ?: false
                mainHandler.post {
                    try {
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_FAILED", e.message, null)
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        encoderExecutor.shutdown()
        super.onDestroy()
    }
}
