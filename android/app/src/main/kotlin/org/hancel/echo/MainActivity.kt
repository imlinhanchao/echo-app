package org.hancel.echo

import android.os.Handler
import android.os.Looper
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
    }

    override fun onDestroy() {
        encoderExecutor.shutdown()
        super.onDestroy()
    }
}
