import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'wav_encoder.dart';

/// 实时录音状态快照。
@immutable
class VoiceRecorderStatus {
  const VoiceRecorderStatus({
    this.isRecording = false,
    this.elapsedMs = 0,
    this.level = 0.0,
    this.sampleRate = 24000,
    this.autoStopped = false,
    this.outputPath = '',
  });

  final bool isRecording;
  final int elapsedMs;
  final double level;
  final int sampleRate;
  final bool autoStopped;
  final String outputPath;
}

/// 完成后的 WAV 录音结果。
@immutable
class RecordedVoiceResult {
  const RecordedVoiceResult({
    required this.path,
    required this.durationMs,
    required this.sampleRate,
  });

  final String path;
  final int durationMs;
  final int sampleRate;
}

/// 跨平台单声道 WAV 录音服务抽象（生产由 [PlatformVoiceRecorderService] 提供，单测可注入 [FakeVoiceRecorderService]）。
abstract class VoiceRecorderService {
  bool get isSupported;
  Future<bool> ensurePermission();
  Future<bool> openSettings() async => false;
  Future<void> startRecording(String outputPath, {int sampleRate = 24000});
  Future<VoiceRecorderStatus> getStatus();
  Future<RecordedVoiceResult> stopRecording();
  Future<void> cancelRecording();
}

/// 基于 Android 原生 `AudioRecord` 通道与 Linux `arecord` 的录音服务。
class PlatformVoiceRecorderService implements VoiceRecorderService {
  static const MethodChannel _channel = MethodChannel(
    'org.hancel.echo/voice_recorder',
  );

  bool? _linuxArecordAvailable;
  Process? _linuxProcess;
  String _linuxOutputPath = '';
  int _linuxSampleRate = 24000;
  DateTime? _linuxStartedAt;

  @override
  bool get isSupported {
    if (Platform.isAndroid) return true;
    if (Platform.isLinux) {
      return _linuxArecordAvailable ??= _hasLinuxArecord();
    }
    return false;
  }

  static bool _hasLinuxArecord() {
    try {
      final res = Process.runSync('which', const <String>['arecord']);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> ensurePermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.microphone.request();
      return status.isGranted;
    }
    return isSupported;
  }

  @override
  Future<bool> openSettings() async {
    if (Platform.isAndroid) {
      return openAppSettings();
    }
    return false;
  }

  @override
  Future<void> startRecording(
    String outputPath, {
    int sampleRate = 24000,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('当前平台暂不支持应用内录制，请导入本地 .wav 文件');
    }

    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<dynamic>('start', <String, dynamic>{
          'outputPath': outputPath,
          'sampleRate': sampleRate,
        });
        return;
      } on PlatformException catch (e) {
        throw StateError(e.message ?? e.code);
      }
    }

    // Linux 桌面端通过 arecord 采集单声道 16-bit WAV
    await cancelRecording();
    final outFile = File(outputPath);
    await outFile.parent.create(recursive: true);
    if (await outFile.exists()) {
      await outFile.delete();
    }
    _linuxOutputPath = outFile.path;
    _linuxSampleRate = sampleRate;
    _linuxStartedAt = DateTime.now();
    _linuxProcess = await Process.start('arecord', <String>[
      '-q',
      '-f',
      'S16_LE',
      '-r',
      '$sampleRate',
      '-c',
      '1',
      '-t',
      'wav',
      outFile.path,
    ]);
  }

  @override
  Future<VoiceRecorderStatus> getStatus() async {
    if (Platform.isAndroid) {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (raw == null) return const VoiceRecorderStatus();
      return VoiceRecorderStatus(
        isRecording: raw['isRecording'] as bool? ?? false,
        elapsedMs: (raw['elapsedMs'] as num?)?.toInt() ?? 0,
        level: ((raw['level'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
        sampleRate: (raw['sampleRate'] as num?)?.toInt() ?? 24000,
        autoStopped: raw['autoStopped'] as bool? ?? false,
        outputPath: raw['outputPath'] as String? ?? '',
      );
    }

    if (Platform.isLinux && _linuxProcess != null) {
      final elapsed = _linuxStartedAt != null
          ? DateTime.now().difference(_linuxStartedAt!).inMilliseconds
          : 0;
      final level = _estimateLinuxLevel(_linuxOutputPath);
      final autoStopped = elapsed >= 20000;
      return VoiceRecorderStatus(
        isRecording: true,
        elapsedMs: elapsed,
        level: level,
        sampleRate: _linuxSampleRate,
        autoStopped: autoStopped,
        outputPath: _linuxOutputPath,
      );
    }

    return const VoiceRecorderStatus();
  }

  double _estimateLinuxLevel(String path) {
    if (path.isEmpty) return 0.0;
    try {
      final f = File(path);
      if (!f.existsSync()) return 0.0;
      final len = f.lengthSync();
      if (len <= 44 + 64) return 0.0;
      const tailBytes = 960; // ~20ms at 24kHz 16-bit
      final start = math.max(44, len - tailBytes);
      final raf = f.openSync(mode: FileMode.read);
      try {
        raf.setPositionSync(start);
        final chunk = raf.readSync(len - start);
        final bd = ByteData.sublistView(chunk);
        final samples = chunk.length ~/ 2;
        if (samples == 0) return 0.0;
        var sumSq = 0.0;
        for (var i = 0; i < samples; i++) {
          final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
          sumSq += v * v;
        }
        final rms = math.sqrt(sumSq / samples);
        return (rms * 4.5).clamp(0.0, 1.0);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return 0.0;
    }
  }

  @override
  Future<RecordedVoiceResult> stopRecording() async {
    if (Platform.isAndroid) {
      final raw = await _channel.invokeMapMethod<String, dynamic>('stop');
      if (raw == null) {
        throw StateError('录音停止返回空结果');
      }
      return RecordedVoiceResult(
        path: raw['path'] as String? ?? '',
        durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
        sampleRate: (raw['sampleRate'] as num?)?.toInt() ?? 24000,
      );
    }

    if (Platform.isLinux) {
      final proc = _linuxProcess;
      final outPath = _linuxOutputPath;
      _linuxProcess = null;
      _linuxOutputPath = '';
      if (proc != null) {
        proc.kill(ProcessSignal.sigint);
        try {
          await proc.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          proc.kill(ProcessSignal.sigkill);
        }
      }
      if (outPath.isEmpty || !File(outPath).existsSync()) {
        throw StateError('未能生成录音文件：$outPath');
      }
      final bytes = await File(outPath).readAsBytes();
      final decoded = decodeWavToFloat32(bytes);
      final durationMs = decoded.sampleRate > 0
          ? ((decoded.samples.length * 1000) / decoded.sampleRate).round()
          : 0;
      return RecordedVoiceResult(
        path: outPath,
        durationMs: durationMs,
        sampleRate: decoded.sampleRate,
      );
    }

    throw UnsupportedError('当前平台不支持停止录制');
  }

  @override
  Future<void> cancelRecording() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<dynamic>('cancel');
      } catch (_) {}
      return;
    }

    if (Platform.isLinux) {
      final proc = _linuxProcess;
      final outPath = _linuxOutputPath;
      _linuxProcess = null;
      _linuxOutputPath = '';
      if (proc != null) {
        proc.kill(ProcessSignal.sigterm);
      }
      if (outPath.isNotEmpty) {
        try {
          final f = File(outPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }
}

/// 纯内存/临时文件假录音服务，供 Widget 与单元测试覆盖完整录制流程。
class FakeVoiceRecorderService implements VoiceRecorderService {
  FakeVoiceRecorderService({
    this.supported = true,
    this.permissionGranted = true,
    this.simulatedDurationMs = 3600,
    this.simulatedSampleRate = 24000,
    this.simulatedLevel = 0.45,
    this.elapsedStepMs = 300,
  });

  bool supported;
  bool permissionGranted;
  int simulatedDurationMs;
  int simulatedSampleRate;
  double simulatedLevel;
  int elapsedStepMs;

  int startCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  int openSettingsCount = 0;

  bool _isRecording = false;
  int _elapsedMs = 0;
  String _outputPath = '';

  @override
  bool get isSupported => supported;

  @override
  Future<bool> ensurePermission() async => permissionGranted;

  @override
  Future<bool> openSettings() async {
    openSettingsCount += 1;
    return true;
  }

  @override
  Future<void> startRecording(
    String outputPath, {
    int sampleRate = 24000,
  }) async {
    if (!supported) {
      throw UnsupportedError('当前平台暂不支持应用内录制，请导入本地 .wav 文件');
    }
    if (!permissionGranted) {
      throw StateError('未获得麦克风录音权限');
    }
    startCount += 1;
    _isRecording = true;
    _elapsedMs = 0;
    _outputPath = outputPath;
    simulatedSampleRate = sampleRate;
  }

  @override
  Future<VoiceRecorderStatus> getStatus() async {
    if (_isRecording) {
      _elapsedMs += elapsedStepMs;
    }
    return VoiceRecorderStatus(
      isRecording: _isRecording,
      elapsedMs: _elapsedMs,
      level: _isRecording ? simulatedLevel : 0.0,
      sampleRate: simulatedSampleRate,
      autoStopped: false,
      outputPath: _outputPath,
    );
  }

  @override
  Future<RecordedVoiceResult> stopRecording() async {
    stopCount += 1;
    _isRecording = false;
    final outFile = File(_outputPath);
    outFile.parent.createSync(recursive: true);

    final numSamples = ((simulatedSampleRate * simulatedDurationMs) / 1000)
        .round()
        .clamp(1, simulatedSampleRate * 30);
    final samples = Float32List(numSamples);
    for (var i = 0; i < numSamples; i++) {
      samples[i] = 0.25 * math.sin(2 * math.pi * 220.0 * i / simulatedSampleRate);
    }
    final wav = encodeFloat32ToWav(samples, sampleRate: simulatedSampleRate);
    outFile.writeAsBytesSync(wav, flush: true);

    return RecordedVoiceResult(
      path: outFile.path,
      durationMs: simulatedDurationMs,
      sampleRate: simulatedSampleRate,
    );
  }

  @override
  Future<void> cancelRecording() async {
    cancelCount += 1;
    _isRecording = false;
    if (_outputPath.isNotEmpty) {
      final f = File(_outputPath);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    _outputPath = '';
  }
}

/// 轻量参考录音试听播放器抽象（懒初始化 `just_audio`，方便单测替换无原生通道实现）。
abstract class VoicePreviewAudioPlayer {
  Stream<bool> get playingStream;
  Future<void> playFile(String path);
  Future<void> stop();
  Future<void> dispose();
}

class JustAudioVoicePreviewPlayer implements VoicePreviewAudioPlayer {
  AudioPlayer? _player;
  final StreamController<bool> _playingCtrl =
      StreamController<bool>.broadcast();
  StreamSubscription<PlayerState>? _sub;

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final created = AudioPlayer();
    _player = created;
    _sub = created.playerStateStream.listen((state) {
      if (_playingCtrl.isClosed) return;
      final playing =
          state.playing && state.processingState != ProcessingState.completed;
      _playingCtrl.add(playing);
      if (state.processingState == ProcessingState.completed) {
        unawaited(created.stop());
      }
    });
    return created;
  }

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Future<void> playFile(String path) async {
    final p = _ensurePlayer();
    await p.stop();
    await p.setFilePath(path);
    await p.play();
  }

  @override
  Future<void> stop() async {
    final existing = _player;
    if (existing != null) {
      await existing.stop();
    }
    if (!_playingCtrl.isClosed) {
      _playingCtrl.add(false);
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _player?.dispose();
    _player = null;
    await _playingCtrl.close();
  }
}

class FakeVoicePreviewAudioPlayer implements VoicePreviewAudioPlayer {
  final StreamController<bool> _ctrl = StreamController<bool>.broadcast();
  final List<String> playedPaths = <String>[];
  int stopCount = 0;

  @override
  Stream<bool> get playingStream => _ctrl.stream;

  @override
  Future<void> playFile(String path) async {
    playedPaths.add(path);
    if (!_ctrl.isClosed) _ctrl.add(true);
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
    if (!_ctrl.isClosed) _ctrl.add(false);
  }

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}

final Provider<VoiceRecorderService> voiceRecorderServiceProvider =
    Provider<VoiceRecorderService>((_) => PlatformVoiceRecorderService());

final Provider<VoicePreviewAudioPlayer Function()> voicePreviewPlayerFactoryProvider =
    Provider<VoicePreviewAudioPlayer Function()>(
      (_) => () => JustAudioVoicePreviewPlayer(),
    );

final Provider<Future<Directory> Function()> voiceRecorderTempDirProvider =
    Provider<Future<Directory> Function()>((_) => getTemporaryDirectory);

/// 构造唯一临时录音文件路径。
String buildTempVoiceRecordingPath(Directory dir, {int? nowMs}) {
  final ts = nowMs ?? DateTime.now().microsecondsSinceEpoch;
  return p.join(dir.path, 'zipvoice_rec_$ts.wav');
}
