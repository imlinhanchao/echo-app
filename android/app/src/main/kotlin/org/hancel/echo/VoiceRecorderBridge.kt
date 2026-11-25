package org.hancel.echo

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.sqrt

/**
 * 原生单声道 16-bit PCM WAV 录音桥接：
 * 通过 Android SDK [AudioRecord] 实时采集 24kHz（降级 16kHz/44.1kHz）音频，
 * 计算实时音量电平与录制约 20s 上限控制，结束时写入标准 44 字节 RIFF 头。
 */
class VoiceRecorderBridge(private val context: Context) {
    companion object {
        private const val MAX_DURATION_MS = 20_000L
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private val lock = Any()
    private val recordingFlag = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val autoStoppedFlag = AtomicBoolean(false)
    private val levelBits = AtomicInteger(java.lang.Float.floatToIntBits(0f))
    private val pcmBytesWritten = AtomicLong(0L)

    @Volatile
    private var activeSampleRate: Int = 24_000

    @Volatile
    private var startedAtMs: Long = 0L

    @Volatile
    private var currentOutputPath: String = ""

    private var workerThread: Thread? = null

    fun start(outputPath: String, requestedSampleRate: Int = 24_000): Map<String, Any> {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("缺少麦克风录音权限（RECORD_AUDIO）")
        }

        // 停止先前未结束的会话
        cancel()

        val outFile = File(outputPath)
        outFile.parentFile?.mkdirs()
        if (outFile.exists()) {
            outFile.delete()
        }

        val candidates = listOf(requestedSampleRate, 24_000, 16_000, 44_100).distinct()
        var chosenRecord: AudioRecord? = null
        var chosenSampleRate = 0
        var chosenBufBytes = 0

        for (rate in candidates) {
            if (rate <= 0) continue
            val minBuf = AudioRecord.getMinBufferSize(rate, CHANNEL_CONFIG, AUDIO_FORMAT)
            if (minBuf <= 0) continue
            val bufBytes = maxOf(minBuf * 2, rate / 10 * 2) // 至少 100ms 缓冲

            for (source in intArrayOf(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                MediaRecorder.AudioSource.MIC,
            )) {
                val rec = createAudioRecord(source, rate, bufBytes) ?: continue
                if (rec.state == AudioRecord.STATE_INITIALIZED) {
                    chosenRecord = rec
                    chosenSampleRate = rate
                    chosenBufBytes = bufBytes
                    break
                }
                try {
                    rec.release()
                } catch (_: Exception) {
                }
            }
            if (chosenRecord != null) break
        }

        val record = chosenRecord
            ?: throw IllegalStateException("无法初始化设备麦克风，请检查系统录音占用情况")

        synchronized(lock) {
            currentOutputPath = outFile.absolutePath
            activeSampleRate = chosenSampleRate
            pcmBytesWritten.set(0L)
            levelBits.set(java.lang.Float.floatToIntBits(0f))
            stopRequested.set(false)
            autoStoppedFlag.set(false)
            startedAtMs = System.currentTimeMillis()
            recordingFlag.set(true)

            val thread = Thread({
                recordLoop(record, outFile, chosenSampleRate, chosenBufBytes)
            }, "echo-voice-recorder")
            workerThread = thread
            thread.start()
        }

        return mapOf(
            "sampleRate" to chosenSampleRate,
            "outputPath" to outFile.absolutePath,
        )
    }

    @SuppressLint("MissingPermission")
    private fun createAudioRecord(source: Int, sampleRate: Int, bufferBytes: Int): AudioRecord? {
        return try {
            AudioRecord(source, sampleRate, CHANNEL_CONFIG, AUDIO_FORMAT, bufferBytes)
        } catch (_: Exception) {
            null
        }
    }

    private fun recordLoop(
        record: AudioRecord,
        outFile: File,
        sampleRate: Int,
        bufferBytes: Int,
    ) {
        var raf: RandomAccessFile? = null
        try {
            raf = RandomAccessFile(outFile, "rw")
            raf.setLength(0L)
            raf.write(ByteArray(44))

            record.startRecording()
            val sampleCount = maxOf(256, bufferBytes / 2)
            val shortBuf = ShortArray(sampleCount)
            val byteBuf = ByteArray(sampleCount * 2)

            while (!stopRequested.get()) {
                val read = record.read(shortBuf, 0, shortBuf.size)
                if (read > 0) {
                    var sumSq = 0.0
                    var byteIdx = 0
                    for (i in 0 until read) {
                        val s = shortBuf[i]
                        val normalized = s / 32768.0
                        sumSq += normalized * normalized
                        val v = s.toInt()
                        byteBuf[byteIdx++] = (v and 0xFF).toByte()
                        byteBuf[byteIdx++] = ((v ushr 8) and 0xFF).toByte()
                    }
                    raf.write(byteBuf, 0, byteIdx)
                    pcmBytesWritten.addAndGet(byteIdx.toLong())

                    val rms = sqrt(sumSq / read)
                    val displayLevel = (rms.toFloat() * 4.5f).coerceIn(0f, 1f)
                    levelBits.set(java.lang.Float.floatToIntBits(displayLevel))
                } else if (read < 0) {
                    break
                }

                val elapsed = System.currentTimeMillis() - startedAtMs
                if (elapsed >= MAX_DURATION_MS) {
                    autoStoppedFlag.set(true)
                    break
                }
            }
        } catch (_: Exception) {
        } finally {
            try {
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    record.stop()
                }
            } catch (_: Exception) {
            }
            try {
                record.release()
            } catch (_: Exception) {
            }
            try {
                val dataBytes = pcmBytesWritten.get()
                raf?.let { file ->
                    writeWavHeader(file, dataBytes, sampleRate)
                    file.fd.sync()
                    file.close()
                }
            } catch (_: Exception) {
                try {
                    raf?.close()
                } catch (_: Exception) {
                }
            }
            levelBits.set(java.lang.Float.floatToIntBits(0f))
            recordingFlag.set(false)
        }
    }

    private fun writeWavHeader(raf: RandomAccessFile, dataSize: Long, sampleRate: Int) {
        val channels = 1
        val bitsPerSample = 16
        val byteRate = sampleRate * channels * (bitsPerSample / 8)
        val blockAlign = channels * (bitsPerSample / 8)
        val clampedData = dataSize.coerceAtLeast(0L)
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put('R'.code.toByte())
            put('I'.code.toByte())
            put('F'.code.toByte())
            put('F'.code.toByte())
            putInt((36L + clampedData).toInt())
            put('W'.code.toByte())
            put('A'.code.toByte())
            put('V'.code.toByte())
            put('E'.code.toByte())
            put('f'.code.toByte())
            put('m'.code.toByte())
            put('t'.code.toByte())
            put(' '.code.toByte())
            putInt(16)
            putShort(1.toShort())
            putShort(channels.toShort())
            putInt(sampleRate)
            putInt(byteRate)
            putShort(blockAlign.toShort())
            putShort(bitsPerSample.toShort())
            put('d'.code.toByte())
            put('a'.code.toByte())
            put('t'.code.toByte())
            put('a'.code.toByte())
            putInt(clampedData.toInt())
        }.array()

        raf.seek(0L)
        raf.write(header)
    }

    private fun currentElapsedMs(): Long {
        val sr = activeSampleRate
        val bytes = pcmBytesWritten.get()
        if (sr > 0 && bytes > 0) {
            return (bytes * 1000L) / (sr * 2L)
        }
        return if (recordingFlag.get() && startedAtMs > 0L) {
            (System.currentTimeMillis() - startedAtMs).coerceAtLeast(0L)
        } else {
            0L
        }
    }

    fun getStatus(): Map<String, Any> {
        val level = java.lang.Float.intBitsToFloat(levelBits.get()).toDouble()
        return mapOf(
            "isRecording" to recordingFlag.get(),
            "elapsedMs" to currentElapsedMs().toInt(),
            "level" to level,
            "sampleRate" to activeSampleRate,
            "autoStopped" to autoStoppedFlag.get(),
            "outputPath" to currentOutputPath,
        )
    }

    fun stop(): Map<String, Any> {
        val thread: Thread?
        val path: String
        val sr: Int
        synchronized(lock) {
            stopRequested.set(true)
            thread = workerThread
            workerThread = null
            path = currentOutputPath
            sr = activeSampleRate
        }
        try {
            thread?.join(1500L)
        } catch (_: InterruptedException) {
        }

        val durationMs = if (sr > 0) {
            ((pcmBytesWritten.get() * 1000L) / (sr * 2L)).toInt()
        } else {
            0
        }
        return mapOf(
            "path" to path,
            "durationMs" to durationMs,
            "sampleRate" to sr,
        )
    }

    fun cancel() {
        val thread: Thread?
        val path: String
        synchronized(lock) {
            stopRequested.set(true)
            thread = workerThread
            workerThread = null
            path = currentOutputPath
            currentOutputPath = ""
        }
        try {
            thread?.join(1500L)
        } catch (_: InterruptedException) {
        }
        if (path.isNotEmpty()) {
            try {
                File(path).delete()
            } catch (_: Exception) {
            }
        }
        pcmBytesWritten.set(0L)
        levelBits.set(java.lang.Float.floatToIntBits(0f))
        autoStoppedFlag.set(false)
    }

    fun dispose() {
        cancel()
    }
}
