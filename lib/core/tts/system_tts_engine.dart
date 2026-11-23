import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sherpa_tts_engine.dart';
import 'tts_model_catalog.dart';
import 'tts_model_manager.dart';
import 'wav_encoder.dart';

/// 系统 TTS 引擎信息（如 Google TTS、MultiTTS、讯飞等）。
@immutable
class SystemTtsEngineInfo {
  const SystemTtsEngineInfo({
    required this.packageName,
    required this.label,
    this.isDefault = false,
  });

  factory SystemTtsEngineInfo.fromMap(Map<dynamic, dynamic> map) =>
      SystemTtsEngineInfo(
        packageName: (map['packageName'] as String? ?? '').trim(),
        label: (map['label'] as String? ?? '').trim(),
        isDefault: map['isDefault'] as bool? ?? false,
      );

  final String packageName;
  final String label;
  final bool isDefault;
}

/// 系统 TTS 音色信息。
@immutable
class SystemTtsVoiceInfo {
  const SystemTtsVoiceInfo({
    required this.name,
    required this.locale,
    required this.label,
    this.requiresNetwork = false,
  });

  factory SystemTtsVoiceInfo.fromMap(Map<dynamic, dynamic> map) =>
      SystemTtsVoiceInfo(
        name: (map['name'] as String? ?? '').trim(),
        locale: (map['locale'] as String? ?? '').trim(),
        label: (map['label'] as String? ?? '').trim(),
        requiresNetwork: map['requiresNetwork'] as bool? ?? false,
      );

  final String name;
  final String locale;
  final String label;
  final bool requiresNetwork;
}

/// 系统 TTS 平台桥接抽象（生产由 Android 原生 `TextToSpeech` 实现，单测可注入 [FakeSystemTtsBridge]）。
abstract class SystemTtsBridge {
  bool get isSupported;
  Future<List<SystemTtsEngineInfo>> listEngines();
  Future<List<SystemTtsVoiceInfo>> listVoices(String enginePackage);
  Future<File> synthesizeToFile({
    required String enginePackage,
    required String voiceName,
    required String text,
    required double speed,
    required File outputFile,
  });
}

/// 基于 MethodChannel `org.hancel.echo/system_tts` 的 Android 系统 TTS 实现。
class PlatformSystemTtsBridge implements SystemTtsBridge {
  const PlatformSystemTtsBridge();

  static const MethodChannel _channel = MethodChannel(
    'org.hancel.echo/system_tts',
  );

  @override
  bool get isSupported => !kIsWeb && Platform.isAndroid;

  @override
  Future<List<SystemTtsEngineInfo>> listEngines() async {
    if (!isSupported) return const <SystemTtsEngineInfo>[];
    final raw = await _channel.invokeMethod<List<dynamic>>('listEngines');
    if (raw == null) return const <SystemTtsEngineInfo>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(SystemTtsEngineInfo.fromMap)
        .where((e) => e.packageName.isNotEmpty)
        .toList();
  }

  @override
  Future<List<SystemTtsVoiceInfo>> listVoices(String enginePackage) async {
    if (!isSupported) return const <SystemTtsVoiceInfo>[];
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listVoices',
      <String, dynamic>{'enginePackage': enginePackage},
    );
    if (raw == null) return const <SystemTtsVoiceInfo>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(SystemTtsVoiceInfo.fromMap)
        .where((v) => v.name.isNotEmpty)
        .toList();
  }

  @override
  Future<File> synthesizeToFile({
    required String enginePackage,
    required String voiceName,
    required String text,
    required double speed,
    required File outputFile,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('系统 TTS 仅在 Android 真机可用');
    }
    final resultPath = await _channel.invokeMethod<String>(
      'synthesizeToFile',
      <String, dynamic>{
        'enginePackage': enginePackage,
        'voiceName': voiceName,
        'text': text,
        'speed': speed.clamp(0.5, 2.5),
        'outputPath': outputFile.path,
      },
    );
    if (resultPath == null || resultPath.isEmpty) {
      throw StateError('系统 TTS 未返回有效音频路径');
    }
    return File(resultPath);
  }
}

/// 测试用内存假系统 TTS 桥接器：写入合法 16kHz RIFF WAV 文件，跑通端到端链路。
class FakeSystemTtsBridge implements SystemTtsBridge {
  FakeSystemTtsBridge({
    this.isSupported = true,
    this.sampleRate = 16000,
    List<SystemTtsEngineInfo>? engines,
    Map<String, List<SystemTtsVoiceInfo>>? voicesByEngine,
  }) : _engines =
           engines ??
           const <SystemTtsEngineInfo>[
             SystemTtsEngineInfo(
               packageName: 'com.google.android.tts',
               label: 'Google 文字转语音引擎',
               isDefault: true,
             ),
             SystemTtsEngineInfo(
               packageName: 'org.nobody.multitts',
               label: 'MultiTTS',
               isDefault: false,
             ),
           ],
       _voicesByEngine =
           voicesByEngine ??
           const <String, List<SystemTtsVoiceInfo>>{
             '': <SystemTtsVoiceInfo>[
               SystemTtsVoiceInfo(
                 name: 'zh-cn-x-zhe-local',
                 locale: 'zh-CN',
                 label: '中文（中国） · zh-cn-x-zhe-local',
               ),
             ],
             'com.google.android.tts': <SystemTtsVoiceInfo>[
               SystemTtsVoiceInfo(
                 name: 'zh-cn-x-zhe-local',
                 locale: 'zh-CN',
                 label: '中文（中国） · zh-cn-x-zhe-local',
               ),
             ],
             'org.nobody.multitts': <SystemTtsVoiceInfo>[
               SystemTtsVoiceInfo(
                 name: 'multitts-xiaoxiao',
                 locale: 'zh-CN',
                 label: '晓晓（MultiTTS） · multitts-xiaoxiao',
               ),
             ],
           };

  @override
  final bool isSupported;

  final int sampleRate;
  final List<SystemTtsEngineInfo> _engines;
  final Map<String, List<SystemTtsVoiceInfo>> _voicesByEngine;
  final List<({String engine, String voice, String text, double speed})>
  synthesizedCalls =
      <({String engine, String voice, String text, double speed})>[];

  @override
  Future<List<SystemTtsEngineInfo>> listEngines() async =>
      isSupported ? _engines : const <SystemTtsEngineInfo>[];

  @override
  Future<List<SystemTtsVoiceInfo>> listVoices(String enginePackage) async {
    if (!isSupported) return const <SystemTtsVoiceInfo>[];
    return _voicesByEngine[enginePackage] ??
        _voicesByEngine[''] ??
        const <SystemTtsVoiceInfo>[];
  }

  @override
  Future<File> synthesizeToFile({
    required String enginePackage,
    required String voiceName,
    required String text,
    required double speed,
    required File outputFile,
  }) async {
    synthesizedCalls.add((
      engine: enginePackage,
      voice: voiceName,
      text: text,
      speed: speed,
    ));
    await outputFile.parent.create(recursive: true);
    final durationMs = ((text.length * 45) / speed).round().clamp(120, 4000);
    final numSamples = (sampleRate * durationMs) ~/ 1000;
    final samples = Float32List(numSamples);
    final freq = enginePackage == 'org.nobody.multitts' ? 520.0 : 440.0;
    for (var i = 0; i < numSamples; i++) {
      samples[i] = 0.2 * math.sin(2 * math.pi * freq * i / sampleRate);
    }
    await outputFile.writeAsBytes(
      encodeFloat32ToWav(samples, sampleRate: sampleRate),
      flush: true,
    );
    return outputFile;
  }
}

/// 基于 Android 系统 TTS 的 [OnDeviceTtsEngine] 实现：
/// 将系统引擎输出的临时 WAV 解码为统一 PCM Float32，从而复用边听边看与离线 M4A+SRT 全链路。
class AndroidSystemTtsEngine implements OnDeviceTtsEngine {
  AndroidSystemTtsEngine(this._bridge, {Directory? tempDirOverride})
    : _tempDirOverride = tempDirOverride;

  final SystemTtsBridge _bridge;
  final Directory? _tempDirOverride;
  ResolvedTtsModelPaths? _loadedPaths;
  int _seq = 0;

  @override
  String? get loadedModelId => _loadedPaths?.spec.id;

  @override
  Future<void> loadModel(
    ResolvedTtsModelPaths paths, {
    int numThreads = 1,
  }) async {
    if (!_bridge.isSupported) {
      throw UnsupportedError('系统 TTS 仅在 Android 设备可用');
    }
    _loadedPaths = paths;
  }

  Future<Directory> _ensureWorkDir() async {
    if (_tempDirOverride != null) {
      await _tempDirOverride.create(recursive: true);
      return _tempDirOverride;
    }
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'echo_sys_tts_tmp'));
      await dir.create(recursive: true);
      return dir;
    } on MissingPluginException {
      final dir = Directory(p.join(Directory.systemTemp.path, 'echo_sys_tts_tmp'));
      await dir.create(recursive: true);
      return dir;
    }
  }

  @override
  Future<TtsSynthesisResult> synthesize(
    String text, {
    int speakerId = 0,
    double speed = 1.0,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return TtsSynthesisResult(samples: Float32List(0), sampleRate: 16000);
    }
    final active = _loadedPaths;
    if (active == null) {
      throw StateError('系统语音引擎尚未加载');
    }

    final workDir = await _ensureWorkDir();
    final outFile = File(
      p.join(
        workDir.path,
        'sys_${DateTime.now().microsecondsSinceEpoch}_${++_seq}.wav',
      ),
    );
    try {
      final produced = await _bridge.synthesizeToFile(
        enginePackage: active.systemEnginePackage,
        voiceName: active.systemVoiceName,
        text: trimmed,
        speed: speed,
        outputFile: outFile,
      );
      final bytes = await produced.readAsBytes();
      final decoded = decodeWavToFloat32(bytes);
      return TtsSynthesisResult(
        samples: decoded.samples,
        sampleRate: decoded.sampleRate,
      );
    } finally {
      for (final f in <File>[outFile]) {
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
  }

  @override
  Future<void> dispose() async {
    _loadedPaths = null;
  }
}

/// 混合端侧语音引擎：根据所选模型类型动态调度到 sherpa-onnx 或 Android 系统 TTS。
class HybridOnDeviceTtsEngine implements OnDeviceTtsEngine {
  HybridOnDeviceTtsEngine({
    required OnDeviceTtsEngine sherpaEngine,
    required OnDeviceTtsEngine systemEngine,
  }) : _sherpaEngine = sherpaEngine,
       _systemEngine = systemEngine;

  final OnDeviceTtsEngine _sherpaEngine;
  final OnDeviceTtsEngine _systemEngine;
  bool _activeIsSystem = false;
  String? _loadedModelId;

  @override
  String? get loadedModelId => _loadedModelId;

  @override
  Future<void> loadModel(
    ResolvedTtsModelPaths paths, {
    int numThreads = 2,
  }) async {
    if (paths.spec.kind == TtsModelKind.systemTts) {
      await _systemEngine.loadModel(paths, numThreads: numThreads);
      _activeIsSystem = true;
    } else {
      await _sherpaEngine.loadModel(paths, numThreads: numThreads);
      _activeIsSystem = false;
    }
    _loadedModelId = paths.spec.id;
  }

  @override
  Future<TtsSynthesisResult> synthesize(
    String text, {
    int speakerId = 0,
    double speed = 1.0,
  }) {
    final active = _activeIsSystem ? _systemEngine : _sherpaEngine;
    return active.synthesize(text, speakerId: speakerId, speed: speed);
  }

  @override
  Future<void> dispose() async {
    await _sherpaEngine.dispose();
    await _systemEngine.dispose();
    _loadedModelId = null;
  }
}

final Provider<SystemTtsBridge> systemTtsBridgeProvider =
    Provider<SystemTtsBridge>((ref) => const PlatformSystemTtsBridge());
