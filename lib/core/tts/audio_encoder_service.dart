import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'wav_encoder.dart';

/// 音频编码输出（Android 优先编码为 M4A，其他平台或单测自动降级为 WAV）。
@immutable
class EncodedAudioResult {
  const EncodedAudioResult({
    required this.outputPath,
    required this.format,
    required this.sizeBytes,
  });

  final String outputPath;
  final String format; // 'm4a' | 'wav'
  final int sizeBytes;
}

/// 将 16-bit PCM 原始文件编码为最终离线音频文件。
abstract class AudioEncoderService {
  Future<EncodedAudioResult> encodePcm16File({
    required File pcmFile,
    required String targetPathWithoutExt,
    required int sampleRate,
    int channels = 1,
    int bitRate = 64000,
  });
}

class PlatformAudioEncoderService implements AudioEncoderService {
  const PlatformAudioEncoderService();

  static const MethodChannel _channel = MethodChannel(
    'org.hancel.echo/audio_encoder',
  );

  @override
  Future<EncodedAudioResult> encodePcm16File({
    required File pcmFile,
    required String targetPathWithoutExt,
    required int sampleRate,
    int channels = 1,
    int bitRate = 64000,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      final m4aPath = '$targetPathWithoutExt.m4a';
      try {
        await _channel.invokeMethod<String>('encodePcmToM4a', <String, dynamic>{
          'pcmPath': pcmFile.path,
          'm4aPath': m4aPath,
          'sampleRate': sampleRate,
          'channels': channels,
          'bitRate': bitRate,
        });
        final outFile = File(m4aPath);
        if (await outFile.exists() && await outFile.length() > 0) {
          return EncodedAudioResult(
            outputPath: m4aPath,
            format: 'm4a',
            sizeBytes: await outFile.length(),
          );
        }
      } catch (_) {
        // 原生通道不可用或编码失败时平滑降级为 WAV，确保任务不中断。
      }
    }

    final wavPath = '$targetPathWithoutExt.wav';
    final pcmBytes = await pcmFile.readAsBytes();
    final wavBytes = wrapPcm16AsWav(
      pcmBytes,
      sampleRate: sampleRate,
      numChannels: channels,
    );
    final wavFile = File(wavPath);
    await wavFile.parent.create(recursive: true);
    await wavFile.writeAsBytes(wavBytes, flush: true);
    return EncodedAudioResult(
      outputPath: wavPath,
      format: 'wav',
      sizeBytes: wavBytes.length,
    );
  }
}

final Provider<AudioEncoderService> audioEncoderServiceProvider =
    Provider<AudioEncoderService>((ref) => const PlatformAudioEncoderService());
