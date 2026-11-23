package org.hancel.echo

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * 基于 Android 原生 MediaCodec (AAC-LC) + MediaMuxer 的 16-bit PCM -> M4A 编码器。
 * 零 FFmpeg 依赖，可将 TTS 产出的原始 PCM 压缩为约 1/6 体积的标准 M4A 音频。
 */
object M4aEncoder {
    private const val TIMEOUT_US = 10_000L

    fun encodePcmToM4a(
        pcmPath: String,
        m4aPath: String,
        sampleRate: Int,
        channels: Int = 1,
        bitRate: Int = 64_000
    ) {
        val inputFile = File(pcmPath)
        require(inputFile.exists() && inputFile.length() > 0) {
            "PCM 输入文件不存在或为空: $pcmPath"
        }
        val outputFile = File(m4aPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            sampleRate,
            channels
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val muxer = MediaMuxer(m4aPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var muxerStarted = false
        var trackIndex = -1

        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            FileInputStream(inputFile).use { fis ->
                val bufferInfo = MediaCodec.BufferInfo()
                val readBuf = ByteArray(4096)
                var inputDone = false
                var outputDone = false
                var totalSamplesFed = 0L
                val bytesPerSampleFrame = channels * 2 // 16-bit PCM

                while (!outputDone) {
                    if (!inputDone) {
                        val inIdx = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (inIdx >= 0) {
                            val inBuf: ByteBuffer? = codec.getInputBuffer(inIdx)
                            inBuf?.clear()
                            val maxRead = minOf(readBuf.size, inBuf?.capacity() ?: readBuf.size)
                            val readBytes = fis.read(readBuf, 0, maxRead)
                            if (readBytes <= 0) {
                                codec.queueInputBuffer(
                                    inIdx,
                                    0,
                                    0,
                                    (totalSamplesFed * 1_000_000L) / sampleRate,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                inputDone = true
                            } else {
                                inBuf?.put(readBuf, 0, readBytes)
                                val ptsUs = (totalSamplesFed * 1_000_000L) / sampleRate
                                totalSamplesFed += (readBytes / bytesPerSampleFrame)
                                codec.queueInputBuffer(inIdx, 0, readBytes, ptsUs, 0)
                            }
                        }
                    }

                    val outIdx = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                    when {
                        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            // 继续下一轮
                        }
                        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (!muxerStarted) {
                                trackIndex = muxer.addTrack(codec.outputFormat)
                                muxer.start()
                                muxerStarted = true
                            }
                        }
                        outIdx >= 0 -> {
                            val outBuf = codec.getOutputBuffer(outIdx)
                            if (outBuf != null &&
                                bufferInfo.size > 0 &&
                                (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 &&
                                muxerStarted
                            ) {
                                outBuf.position(bufferInfo.offset)
                                outBuf.limit(bufferInfo.offset + bufferInfo.size)
                                muxer.writeSampleData(trackIndex, outBuf, bufferInfo)
                            }
                            codec.releaseOutputBuffer(outIdx, false)
                            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                outputDone = true
                            }
                        }
                    }
                }
            }
        } finally {
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            try {
                codec.release()
            } catch (_: Exception) {
            }
            try {
                if (muxerStarted) {
                    muxer.stop()
                }
            } catch (_: Exception) {
            }
            try {
                muxer.release()
            } catch (_: Exception) {
            }
        }
    }
}
