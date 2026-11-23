package org.hancel.echo

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.io.File
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 原生 Android System TTS 桥接器（支持系统默认、MultiTTS、讯飞等已安装引擎）：
 * - 通过单线程 Executor 串行管理 `TextToSpeech` 实例切换与离线文件合成；
 * - 使用 `synthesizeToFile` 输出标准 WAV 文件供 Dart 端统一播放与转码。
 */
class SystemTtsBridge(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val utteranceSeq = AtomicInteger(1)

    private var tts: TextToSpeech? = null
    private var activeEnginePackage: String? = null

    fun listEngines(onSuccess: (List<Map<String, Any>>) -> Unit, onError: (String) -> Unit) {
        executor.execute {
            try {
                val engine = ensureEngineLocked(activeEnginePackage ?: "")
                val defaultPkg = try {
                    engine.defaultEngine ?: ""
                } catch (_: Exception) {
                    ""
                }
                val items = try {
                    engine.engines.map { info ->
                        val pkg = info.name ?: ""
                        val lbl = if (!info.label.isNullOrBlank()) info.label else pkg
                        mapOf<String, Any>(
                            "packageName" to pkg,
                            "label" to lbl,
                            "isDefault" to (pkg == defaultPkg)
                        )
                    }.sortedWith(
                        compareByDescending<Map<String, Any>> { it["isDefault"] as Boolean }
                            .thenBy { it["label"] as String }
                    )
                } catch (_: Exception) {
                    emptyList()
                }
                mainHandler.post { onSuccess(items) }
            } catch (e: Exception) {
                mainHandler.post { onError(e.message ?: "读取系统语音引擎失败") }
            }
        }
    }

    fun listVoices(
        enginePackage: String,
        onSuccess: (List<Map<String, Any>>) -> Unit,
        onError: (String) -> Unit
    ) {
        executor.execute {
            try {
                val engine = ensureEngineLocked(enginePackage)
                val voices = try {
                    engine.voices?.toList().orEmpty()
                } catch (_: Exception) {
                    emptyList<Voice>()
                }

                val mapped = voices
                    .filter { !it.name.isNullOrBlank() }
                    .map { voice ->
                        val tag = voice.locale?.toLanguageTag() ?: ""
                        val lang = voice.locale?.language?.lowercase(Locale.ROOT) ?: ""
                        val score = when (lang) {
                            "zh" -> 0
                            "en" -> 1
                            else -> 2
                        }
                        val netFlag = voice.isNetworkConnectionRequired
                        val localeDisplay = voice.locale?.displayName?.takeIf { it.isNotBlank() } ?: tag
                        val label = buildString {
                            append(if (localeDisplay.isNotEmpty()) localeDisplay else "默认")
                            append(" · ")
                            append(voice.name)
                            if (netFlag) append("（联网）")
                        }
                        Triple(
                            score,
                            if (netFlag) 1 else 0,
                            mapOf<String, Any>(
                                "name" to voice.name,
                                "locale" to tag,
                                "label" to label,
                                "requiresNetwork" to netFlag
                            )
                        )
                    }
                    .sortedWith(
                        compareBy<Triple<Int, Int, Map<String, Any>>> { it.first }
                            .thenBy { it.second }
                            .thenBy { it.third["label"] as String }
                    )
                    .map { it.third }

                mainHandler.post { onSuccess(mapped) }
            } catch (e: Exception) {
                mainHandler.post { onError(e.message ?: "读取引擎音色列表失败") }
            }
        }
    }

    fun synthesizeToFile(
        enginePackage: String,
        voiceName: String,
        text: String,
        speed: Double,
        outputPath: String,
        onSuccess: (String) -> Unit,
        onError: (String) -> Unit
    ) {
        executor.execute {
            try {
                val engine = ensureEngineLocked(enginePackage)
                if (voiceName.isNotEmpty()) {
                    val targetVoice = try {
                        engine.voices?.firstOrNull { it.name == voiceName }
                    } catch (_: Exception) {
                        null
                    }
                    if (targetVoice != null) {
                        engine.voice = targetVoice
                    }
                }
                engine.setSpeechRate(speed.toFloat().coerceIn(0.5f, 2.5f))

                val outFile = File(outputPath)
                outFile.parentFile?.mkdirs()
                if (outFile.exists()) {
                    outFile.delete()
                }

                val utteranceId = "echo_sys_tts_${utteranceSeq.incrementAndGet()}"
                val doneLatch = CountDownLatch(1)
                var synthErr: String? = null

                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(uid: String?) {}

                    override fun onDone(uid: String?) {
                        if (uid == utteranceId) {
                            doneLatch.countDown()
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(uid: String?) {
                        if (uid == utteranceId) {
                            synthErr = "系统语音合成失败"
                            doneLatch.countDown()
                        }
                    }

                    override fun onError(uid: String?, errorCode: Int) {
                        if (uid == utteranceId) {
                            synthErr = "系统语音合成失败（错误码 $errorCode）"
                            doneLatch.countDown()
                        }
                    }
                })

                val params = Bundle()
                val callStatus = engine.synthesizeToFile(text, params, outFile, utteranceId)
                if (callStatus != TextToSpeech.SUCCESS) {
                    throw IllegalStateException("调用系统 TTS 合成失败（code=$callStatus）")
                }

                val finished = doneLatch.await(30, TimeUnit.SECONDS)
                if (!finished) {
                    try {
                        engine.stop()
                    } catch (_: Exception) {
                    }
                    throw IllegalStateException("系统 TTS 合成超时（超过 30 秒）")
                }
                if (synthErr != null) {
                    throw IllegalStateException(synthErr)
                }
                if (!outFile.exists() || outFile.length() <= 12) {
                    throw IllegalStateException("系统 TTS 未生成有效音频输出")
                }

                mainHandler.post { onSuccess(outFile.absolutePath) }
            } catch (e: Exception) {
                mainHandler.post { onError(e.message ?: "系统 TTS 合成异常") }
            }
        }
    }

    private fun ensureEngineLocked(enginePackage: String): TextToSpeech {
        val current = tts
        if (current != null && activeEnginePackage == enginePackage) {
            return current
        }

        if (current != null) {
            val shutdownLatch = CountDownLatch(1)
            mainHandler.post {
                try {
                    current.stop()
                    current.shutdown()
                } catch (_: Exception) {
                } finally {
                    shutdownLatch.countDown()
                }
            }
            shutdownLatch.await(2, TimeUnit.SECONDS)
            tts = null
            activeEnginePackage = null
        }

        val initLatch = CountDownLatch(1)
        var initStatus = TextToSpeech.ERROR
        var created: TextToSpeech? = null
        mainHandler.post {
            try {
                val listener = TextToSpeech.OnInitListener { status ->
                    initStatus = status
                    initLatch.countDown()
                }
                created = if (enginePackage.isEmpty()) {
                    TextToSpeech(context.applicationContext, listener)
                } else {
                    TextToSpeech(context.applicationContext, listener, enginePackage)
                }
            } catch (_: Exception) {
                initStatus = TextToSpeech.ERROR
                initLatch.countDown()
            }
        }

        val ready = initLatch.await(8, TimeUnit.SECONDS)
        val instance = created
        if (!ready || instance == null || initStatus != TextToSpeech.SUCCESS) {
            if (instance != null) {
                mainHandler.post {
                    try {
                        instance.shutdown()
                    } catch (_: Exception) {
                    }
                }
            }
            val pkgHint = if (enginePackage.isEmpty()) "系统默认引擎" else enginePackage
            throw IllegalStateException("无法初始化语音引擎 $pkgHint（status=$initStatus）")
        }

        tts = instance
        activeEnginePackage = enginePackage
        return instance
    }

    fun dispose() {
        val current = tts
        tts = null
        activeEnginePackage = null
        mainHandler.post {
            try {
                current?.stop()
                current?.shutdown()
            } catch (_: Exception) {
            }
        }
        executor.shutdown()
    }
}
