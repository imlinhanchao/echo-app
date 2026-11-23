import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'system_tts_engine.dart';
import 'tts_model_catalog.dart';
import 'tts_model_manager.dart';
import 'wav_encoder.dart';

/// 单次端侧 TTS 合成输出。
@immutable
class TtsSynthesisResult {
  const TtsSynthesisResult({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;

  double get durationSeconds =>
      sampleRate > 0 ? samples.length / sampleRate : 0.0;

  int get durationMs => (durationSeconds * 1000).round();
}

/// 端侧 TTS 推理引擎抽象（生产由 [SherpaIsolateTtsEngine] 实现，单测可注入 [FakeOnDeviceTtsEngine]）。
abstract class OnDeviceTtsEngine {
  String? get loadedModelId;
  Future<void> loadModel(ResolvedTtsModelPaths paths, {int numThreads});
  Future<TtsSynthesisResult> synthesize(
    String text, {
    int speakerId = 0,
    double speed = 1.0,
  });
  Future<void> dispose();
}

/// 基于 `sherpa_onnx` + 常驻后台 Worker Isolate 的端侧推理引擎。
///
/// 所有模型加载与音频合成都在后台 Isolate 串行执行，不阻塞 Flutter UI 线程。
class SherpaIsolateTtsEngine implements OnDeviceTtsEngine {
  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _responsePort;
  StreamSubscription<dynamic>? _responseSub;
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _nextReqId = 1;
  String? _loadedModelId;
  String? _loadedCacheKey;
  Future<void>? _spawning;

  @override
  String? get loadedModelId => _loadedModelId;

  Future<void> _ensureWorker() async {
    if (_workerPort != null) return;
    if (_spawning != null) return _spawning;

    final completer = Completer<void>();
    _spawning = completer.future;

    final readyPort = ReceivePort();
    _responsePort = ReceivePort();
    _responseSub = _responsePort!.listen(_onWorkerMessage);

    _isolate = await Isolate.spawn<_WorkerBootstrap>(
      _sherpaWorkerEntry,
      _WorkerBootstrap(
        readyPort: readyPort.sendPort,
        responsePort: _responsePort!.sendPort,
      ),
      debugName: 'echo_sherpa_tts_worker',
    );

    _workerPort = await readyPort.first as SendPort;
    readyPort.close();
    completer.complete();
  }

  void _onWorkerMessage(dynamic message) {
    if (message is! Map) return;
    final id = message['id'] as int?;
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = message['error'] as String?;
    if (error != null) {
      completer.completeError(StateError(error));
    } else {
      completer.complete(message['result']);
    }
  }

  Future<dynamic> _send(String cmd, Map<String, dynamic> payload) async {
    await _ensureWorker();
    final id = _nextReqId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _workerPort!.send(<String, dynamic>{
      'id': id,
      'cmd': cmd,
      'payload': payload,
    });
    return completer.future;
  }

  @override
  Future<void> loadModel(
    ResolvedTtsModelPaths paths, {
    int? numThreads,
  }) async {
    if (paths.spec.isSystemTts) {
      throw StateError('Android 系统语音需通过 HybridOnDeviceTtsEngine 加载');
    }
    if (_loadedCacheKey == paths.cacheKey && _workerPort != null) return;
    final threads =
        numThreads ?? math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2));
    await _send('load', <String, dynamic>{
      'modelId': paths.spec.id,
      'kind': paths.spec.kind.name,
      'modelPath': paths.modelPath,
      'decoderPath': paths.decoderPath,
      'tokensPath': paths.tokensPath,
      'voicesPath': paths.voicesPath,
      'vocoderPath': paths.vocoderPath,
      'lexiconPath': paths.lexiconPath,
      'dataDir': paths.dataDir,
      'dictDir': paths.dictDir,
      'ruleFsts': paths.ruleFsts,
      'referenceAudioPath': paths.referenceAudioPath,
      'referenceText': paths.referenceText,
      'numThreads': threads,
    });
    _loadedModelId = paths.spec.id;
    _loadedCacheKey = paths.cacheKey;
  }

  @override
  Future<TtsSynthesisResult> synthesize(
    String text, {
    int speakerId = 0,
    double speed = 1.0,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return TtsSynthesisResult(samples: Float32List(0), sampleRate: 24000);
    }
    final res =
        await _send('generate', <String, dynamic>{
              'text': trimmed,
              'sid': speakerId,
              'speed': speed.clamp(0.5, 2.5),
            })
            as Map<dynamic, dynamic>;

    final transferable = res['samples'] as TransferableTypedData;
    final byteBuffer = transferable.materialize();
    final samples = byteBuffer.asFloat32List();
    final sampleRate = res['sampleRate'] as int;
    return TtsSynthesisResult(samples: samples, sampleRate: sampleRate);
  }

  @override
  Future<void> dispose() async {
    if (_workerPort != null) {
      try {
        await _send('dispose', const <String, dynamic>{});
      } catch (_) {}
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('TTS engine disposed'));
      }
    }
    _pending.clear();
    await _responseSub?.cancel();
    _responsePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
    _loadedModelId = null;
    _loadedCacheKey = null;
    _spawning = null;
  }
}

class _WorkerBootstrap {
  const _WorkerBootstrap({required this.readyPort, required this.responsePort});

  final SendPort readyPort;
  final SendPort responsePort;
}

void _sherpaWorkerEntry(_WorkerBootstrap bootstrap) {
  final inbox = ReceivePort();
  bootstrap.readyPort.send(inbox.sendPort);

  var bindingsReady = false;
  sherpa_onnx.OfflineTts? tts;
  var activeKind = '';
  Float32List? refSamples;
  var refSampleRate = 0;
  var refText = '';

  inbox.listen((dynamic message) {
    if (message is! Map) return;
    final id = message['id'] as int;
    final cmd = message['cmd'] as String;
    final payload = (message['payload'] as Map?)?.cast<String, dynamic>() ?? {};

    try {
      if (cmd == 'load') {
        if (!bindingsReady) {
          sherpa_onnx.initBindings();
          bindingsReady = true;
        }
        tts?.free();
        tts = null;
        refSamples = null;
        refSampleRate = 0;
        refText = '';

        final kindName = payload['kind'] as String;
        final modelPath = payload['modelPath'] as String;
        final decoderPath = payload['decoderPath'] as String? ?? '';
        final tokensPath = payload['tokensPath'] as String;
        final vocoderPath = payload['vocoderPath'] as String? ?? '';
        final lexiconPath = payload['lexiconPath'] as String? ?? '';
        final dataDir = payload['dataDir'] as String? ?? '';
        final dictDir = payload['dictDir'] as String? ?? '';
        final ruleFsts = payload['ruleFsts'] as String? ?? '';
        final referenceAudioPath =
            payload['referenceAudioPath'] as String? ?? '';
        final referenceText = payload['referenceText'] as String? ?? '';
        final numThreads = payload['numThreads'] as int? ?? 2;

        final sherpa_onnx.OfflineTtsModelConfig modelConfig;
        if (kindName == TtsModelKind.zipvoice.name) {
          if (referenceAudioPath.isEmpty ||
              !File(referenceAudioPath).existsSync()) {
            throw StateError('ZipVoice 缺少参考音频文件：$referenceAudioPath');
          }
          if (referenceText.trim().isEmpty) {
            throw StateError('ZipVoice 缺少参考音频对应的文本内容');
          }
          final bytes = File(referenceAudioPath).readAsBytesSync();
          final decoded = decodeWavToFloat32(bytes);
          if (decoded.samples.isEmpty || decoded.sampleRate <= 0) {
            throw StateError('无法解码 ZipVoice 参考音频：$referenceAudioPath');
          }
          refSamples = decoded.samples;
          refSampleRate = decoded.sampleRate;
          refText = referenceText.trim();

          modelConfig = sherpa_onnx.OfflineTtsModelConfig(
            zipvoice: sherpa_onnx.OfflineTtsZipVoiceModelConfig(
              tokens: tokensPath,
              encoder: modelPath,
              decoder: decoderPath,
              vocoder: vocoderPath,
              lexicon: lexiconPath,
              dataDir: dataDir,
            ),
            numThreads: numThreads,
            debug: false,
          );
        } else if (kindName == TtsModelKind.matcha.name) {
          modelConfig = sherpa_onnx.OfflineTtsModelConfig(
            matcha: sherpa_onnx.OfflineTtsMatchaModelConfig(
              acousticModel: modelPath,
              vocoder: vocoderPath,
              tokens: tokensPath,
              lexicon: lexiconPath,
              dataDir: dataDir,
              dictDir: dictDir,
            ),
            numThreads: numThreads,
            debug: false,
          );
        } else {
          modelConfig = sherpa_onnx.OfflineTtsModelConfig(
            vits: sherpa_onnx.OfflineTtsVitsModelConfig(
              model: modelPath,
              tokens: tokensPath,
              lexicon: lexiconPath,
              dataDir: dataDir,
              dictDir: dictDir,
            ),
            numThreads: numThreads,
            debug: false,
          );
        }

        activeKind = kindName;
        tts = sherpa_onnx.OfflineTts(
          sherpa_onnx.OfflineTtsConfig(
            model: modelConfig,
            ruleFsts: ruleFsts,
          ),
        );
        bootstrap.responsePort.send(<String, dynamic>{
          'id': id,
          'result': true,
        });
      } else if (cmd == 'generate') {
        final active = tts;
        if (active == null) {
          throw StateError('TTS 模型尚未加载');
        }
        final text = payload['text'] as String;
        final sid = payload['sid'] as int? ?? 0;
        final speed = (payload['speed'] as num?)?.toDouble() ?? 1.0;

        final sherpa_onnx.GeneratedAudio generated;
        if (activeKind == TtsModelKind.zipvoice.name) {
          generated = active.generateWithConfig(
            text: text,
            config: sherpa_onnx.OfflineTtsGenerationConfig(
              sid: sid,
              speed: speed,
              referenceAudio: refSamples,
              referenceSampleRate: refSampleRate,
              referenceText: refText,
              numSteps: 4,
              extra: const <String, Object>{'min_char_in_sentence': 10},
            ),
          );
        } else {
          generated = active.generate(text: text, sid: sid, speed: speed);
        }
        final copied = Float32List.fromList(generated.samples);
        final transferable = TransferableTypedData.fromList(<TypedData>[
          copied,
        ]);
        bootstrap.responsePort.send(<String, dynamic>{
          'id': id,
          'result': <String, dynamic>{
            'samples': transferable,
            'sampleRate': generated.sampleRate,
          },
        });
      } else if (cmd == 'dispose') {
        tts?.free();
        tts = null;
        bootstrap.responsePort.send(<String, dynamic>{
          'id': id,
          'result': true,
        });
        inbox.close();
      }
    } catch (e) {
      bootstrap.responsePort.send(<String, dynamic>{
        'id': id,
        'error': e.toString(),
      });
    }
  });
}

/// 纯内存假 TTS 引擎：供单元测试验证流式预合成与本地转有声书全链路。
class FakeOnDeviceTtsEngine implements OnDeviceTtsEngine {
  FakeOnDeviceTtsEngine({
    this.sampleRate = 16000,
    this.msPerChar = 50,
    this.syntheticDelay = Duration.zero,
  });

  final int sampleRate;
  final int msPerChar;
  final Duration syntheticDelay;

  final List<String> synthesizedTexts = <String>[];
  String? _loadedModelId;

  @override
  String? get loadedModelId => _loadedModelId;

  @override
  Future<void> loadModel(
    ResolvedTtsModelPaths paths, {
    int numThreads = 2,
  }) async {
    _loadedModelId = paths.spec.id;
  }

  @override
  Future<TtsSynthesisResult> synthesize(
    String text, {
    int speakerId = 0,
    double speed = 1.0,
  }) async {
    if (syntheticDelay > Duration.zero) {
      await Future<void>.delayed(syntheticDelay);
    }
    synthesizedTexts.add(text);
    final durationMs = ((text.length * msPerChar) / speed).round().clamp(
      120,
      5000,
    );
    final numSamples = (sampleRate * durationMs) ~/ 1000;
    final samples = Float32List(numSamples);
    for (var i = 0; i < numSamples; i++) {
      samples[i] = 0.15 * math.sin(2 * math.pi * 440.0 * i / sampleRate);
    }
    return TtsSynthesisResult(samples: samples, sampleRate: sampleRate);
  }

  @override
  Future<void> dispose() async {
    _loadedModelId = null;
  }
}

final Provider<OnDeviceTtsEngine> onDeviceTtsEngineProvider =
    Provider<OnDeviceTtsEngine>((ref) {
      final sherpa = SherpaIsolateTtsEngine();
      final system = AndroidSystemTtsEngine(ref.watch(systemTtsBridgeProvider));
      final hybrid = HybridOnDeviceTtsEngine(
        sherpaEngine: sherpa,
        systemEngine: system,
      );
      ref.onDispose(hybrid.dispose);
      return hybrid;
    });
