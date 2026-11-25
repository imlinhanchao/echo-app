import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/core/tts/wav_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _buildStereoWavWithListChunk({
  required int sampleRate,
  required int frames,
}) {
  final fmtPayload = ByteData(16)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, 2, Endian.little) // stereo
    ..setUint32(4, sampleRate, Endian.little)
    ..setUint32(8, sampleRate * 4, Endian.little)
    ..setUint16(12, 4, Endian.little)
    ..setUint16(14, 16, Endian.little);

  // Junk / LIST metadata chunk between fmt and data
  final listData = Uint8List.fromList(List<int>.filled(10, 0x41));

  final pcm = ByteData(frames * 4);
  for (var i = 0; i < frames; i++) {
    // left = +0.5, right = -0.1 => mono avg = +0.2
    pcm.setInt16(i * 4, 16384, Endian.little);
    pcm.setInt16(i * 4 + 2, -3277, Endian.little);
  }

  final totalPayload =
      4 + (8 + fmtPayload.lengthInBytes) + (8 + listData.length) + (8 + pcm.lengthInBytes);
  final out = BytesBuilder();
  out.add('RIFF'.codeUnits);
  final fileSizeBd = ByteData(4)..setUint32(0, totalPayload, Endian.little);
  out.add(fileSizeBd.buffer.asUint8List());
  out.add('WAVE'.codeUnits);

  out.add('fmt '.codeUnits);
  out.add((ByteData(4)..setUint32(0, 16, Endian.little)).buffer.asUint8List());
  out.add(fmtPayload.buffer.asUint8List());

  out.add('LIST'.codeUnits);
  out.add(
    (ByteData(4)..setUint32(0, listData.length, Endian.little))
        .buffer
        .asUint8List(),
  );
  out.add(listData);

  out.add('data'.codeUnits);
  out.add(
    (ByteData(4)..setUint32(0, pcm.lengthInBytes, Endian.little))
        .buffer
        .asUint8List(),
  );
  out.add(pcm.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  group('TtsModelCatalog 镜像与新模型目录', () {
    test('已彻底移除 Kokoro 与 Piper，并包含系统语音/ZipVoice/Melo/Matcha', () {
      expect(TtsModelCatalog.byId('kokoro-int8-multi-lang-v1_1'), isNull);
      expect(TtsModelCatalog.byId('vits-piper-zh_CN-huayan-medium'), isNull);
      expect(TtsModelCatalog.byId('android-system-tts'), isNotNull);
      final zvSpec =
          TtsModelCatalog.byId('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(zvSpec.dataDirName, 'espeak-ng-data');
      expect(TtsModelCatalog.byId('vits-melo-tts-zh_en'), isNotNull);
      expect(TtsModelCatalog.byId('matcha-icefall-zh-baker'), isNotNull);
      expect(TtsModelCatalog.byId('matcha-icefall-zh-en'), isNotNull);
    });

    test('严格按所选单一镜像生成 URL，不跨镜像静默回退', () {
      final asset = TtsModelCatalog.meloTtsZhEn.assets.first;

      final ghfastUrls = asset.urlsForMirror(mirrorId: TtsModelCatalog.mirrorGhFast);
      expect(ghfastUrls, hasLength(1));
      expect(ghfastUrls.single, startsWith('https://ghfast.top/https://github.com/'));

      final githubUrls = asset.urlsForMirror(mirrorId: TtsModelCatalog.mirrorGithub);
      expect(githubUrls, hasLength(1));
      expect(githubUrls.single, startsWith('https://github.com/k2-fsa/sherpa-onnx/'));

      final customUrls = asset.urlsForMirror(
        mirrorId: TtsModelCatalog.mirrorCustom,
        customPrefix: 'https://my-proxy.example.com',
      );
      expect(customUrls, hasLength(1));
      expect(
        customUrls.single,
        startsWith('https://my-proxy.example.com/https://github.com/'),
      );

      expect(TtsModelCatalog.validateCustomMirrorPrefix(''), isNotNull);
      expect(TtsModelCatalog.validateCustomMirrorPrefix('ftp://bad'), isNotNull);
      expect(
        TtsModelCatalog.validateCustomMirrorPrefix('https://mirror.example.com/'),
        isNull,
      );
    });

    test('旧版 StandaloneConfig prefer_cn_mirror 自动迁移到 tts_download_mirror', () {
      final legacyGithub = StandaloneConfig.fromJson(const <String, dynamic>{
        'prefer_cn_mirror': false,
      });
      expect(legacyGithub.ttsDownloadMirror, 'github');
      expect(legacyGithub.preferCnMirror, isFalse);

      final legacyCn = StandaloneConfig.fromJson(const <String, dynamic>{
        'prefer_cn_mirror': true,
      });
      expect(legacyCn.ttsDownloadMirror, 'ghfast');
      expect(legacyCn.preferCnMirror, isTrue);
    });
  });

  group('WAV 解码与 ZipVoice / 旧模型清理', () {
    test('decodeWavToFloat32 支持非 44 字节头部（LIST 块）及立体声混音', () {
      final bytes = _buildStereoWavWithListChunk(sampleRate: 24000, frames: 2400);
      final decoded = decodeWavToFloat32(bytes);
      expect(decoded.sampleRate, 24000);
      expect(decoded.channels, 2);
      expect(decoded.samples.length, 2400);
      // ~ (0.5 - 0.1) / 2 = 0.2
      expect((decoded.samples.first - 0.2).abs(), lessThan(0.01));
    });

    test('检测到磁盘残留旧 Kokoro/Piper 模型可统计体积并一键清理，ZipVoice 支持自定义参考音频', () async {
      final rootDir = await Directory.systemTemp.createTemp('echo_legacy_tts_');
      addTearDown(() async {
        if (await rootDir.exists()) await rootDir.delete(recursive: true);
      });

      // 创建旧模型残留
      final oldKokoro = File(
        p.join(rootDir.path, 'kokoro-int8-multi-lang-v1_1', 'model.onnx'),
      );
      await oldKokoro.parent.create(recursive: true);
      await oldKokoro.writeAsBytes(List<int>.filled(4096, 1));

      // 安装好一个伪造 ZipVoice 目录（含完整 espeak-ng-data）
      final zvDir = Directory(
        p.join(rootDir.path, 'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia'),
      );
      await zvDir.create(recursive: true);
      for (final f in <String>[
        'encoder.int8.onnx',
        'decoder.int8.onnx',
        'vocos_24khz.onnx',
        'tokens.txt',
        'lexicon.txt',
      ]) {
        await File(p.join(zvDir.path, f)).writeAsBytes(<int>[1, 2, 3]);
      }
      final espeakDir = Directory(p.join(zvDir.path, 'espeak-ng-data'));
      await espeakDir.create(recursive: true);
      for (final f in kRequiredEspeakDataFiles) {
        await File(p.join(espeakDir.path, f)).writeAsBytes(<int>[4, 5]);
      }
      final defaultWav = File(p.join(zvDir.path, 'test_wavs', 'leijun-1.wav'));
      await defaultWav.parent.create(recursive: true);
      await defaultWav.writeAsBytes(
        encodeFloat32ToWav(
          Float32List.fromList(List<double>.generate(24000, (i) => 0.1 * math.sin(i))),
          sampleRate: 24000,
        ),
      );

      final storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(
          onboardingCompleted: true,
          activeTtsModelId: 'kokoro-int8-multi-lang-v1_1',
        ),
      );
      final configCtrl = StandaloneConfigController(
        storage,
        const StandaloneConfig(
          onboardingCompleted: true,
          activeTtsModelId: 'kokoro-int8-multi-lang-v1_1',
        ),
      );

      final manager = TtsModelManager(
        configCtrl,
        rootDirOverride: rootDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
      );
      addTearDown(manager.dispose);
      await manager.refresh();

      expect(manager.currentState.legacyModelsSizeBytes, greaterThanOrEqualTo(4096));
      expect(
        configCtrl.state.activeTtsModelId,
        'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia',
      );
      final zvEntry = manager.currentState
          .entryOf('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(zvEntry.isInstalled, isTrue);
      expect(zvEntry.resolvedPaths!.referenceAudioPath, defaultWav.path);
      expect(zvEntry.resolvedPaths!.dataDir, endsWith('espeak-ng-data'));

      // 一键清理旧模型
      final freed = await manager.cleanupLegacyModels();
      expect(freed, greaterThanOrEqualTo(4096));
      expect(manager.currentState.legacyModelsSizeBytes, 0);

      // 导入自定义 ZipVoice 参考音频（2 秒 WAV）
      final customSrc = File(p.join(rootDir.path, 'my_voice.wav'));
      await customSrc.writeAsBytes(
        _buildStereoWavWithListChunk(sampleRate: 24000, frames: 48000),
      );
      final importErr = await manager.importZipVoiceReferenceAudio(
        customSrc,
        '这是一段自定义克隆参考文字。',
      );
      expect(importErr, isNull);
      final afterCustom = manager.currentState
          .entryOf('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(
        afterCustom.resolvedPaths!.referenceAudioPath,
        matches(RegExp(r'zipvoice_custom_ref_\d+_\d+\.wav$')),
      );
      expect(
        afterCustom.resolvedPaths!.referenceText,
        '这是一段自定义克隆参考文字。',
      );
      expect(
        afterCustom.resolvedPaths!.cacheKey,
        isNot(zvEntry.resolvedPaths!.cacheKey),
      );

      // 使用相同参考文本再次导入，应产生新路径、删除旧自定义文件并更新 cacheKey
      final firstCustomPath = afterCustom.resolvedPaths!.referenceAudioPath;
      final importErr2 = await manager.importZipVoiceReferenceAudio(
        customSrc,
        '这是一段自定义克隆参考文字。',
      );
      expect(importErr2, isNull);
      final afterCustom2 = manager.currentState
          .entryOf('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(
        afterCustom2.resolvedPaths!.referenceAudioPath,
        isNot(firstCustomPath),
      );
      expect(File(firstCustomPath).existsSync(), isFalse);
      expect(
        afterCustom2.resolvedPaths!.cacheKey,
        isNot(afterCustom.resolvedPaths!.cacheKey),
      );

      // 重置回内置参考音频并清理所有自定义 WAV
      await manager.resetZipVoiceReferenceAudio();
      final afterReset = manager.currentState
          .entryOf('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(afterReset.resolvedPaths!.referenceAudioPath, defaultWav.path);
      expect(
        File(afterCustom2.resolvedPaths!.referenceAudioPath).existsSync(),
        isFalse,
      );
    });

    test('ZipVoice 缺少 espeak-ng-data 时不判定为已安装且加载抛出可恢复 StateError', () async {
      final rootDir = await Directory.systemTemp.createTemp('echo_zv_missing_espeak_');
      addTearDown(() async {
        if (await rootDir.exists()) await rootDir.delete(recursive: true);
      });

      final zvDir = Directory(
        p.join(rootDir.path, 'sherpa-onnx-zipvoice-distill-int8-zh-en-emilia'),
      );
      await zvDir.create(recursive: true);
      for (final f in <String>[
        'encoder.int8.onnx',
        'decoder.int8.onnx',
        'vocos_24khz.onnx',
        'tokens.txt',
        'lexicon.txt',
      ]) {
        await File(p.join(zvDir.path, f)).writeAsBytes(<int>[1, 2, 3]);
      }
      final defaultWav = File(p.join(zvDir.path, 'test_wavs', 'leijun-1.wav'));
      await defaultWav.parent.create(recursive: true);
      await defaultWav.writeAsBytes(
        encodeFloat32ToWav(
          Float32List.fromList(List<double>.generate(24000, (i) => 0.1 * math.sin(i))),
          sampleRate: 24000,
        ),
      );

      final storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      final configCtrl = StandaloneConfigController(
        storage,
        const StandaloneConfig(onboardingCompleted: true),
      );
      final manager = TtsModelManager(
        configCtrl,
        rootDirOverride: rootDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
      );
      addTearDown(manager.dispose);
      await manager.refresh();

      final zvEntry = manager.currentState
          .entryOf('sherpa-onnx-zipvoice-distill-int8-zh-en-emilia')!;
      expect(zvEntry.isInstalled, isFalse);

      final invalidPaths = ResolvedTtsModelPaths(
        spec: TtsModelCatalog.zipvoiceZhEnInt8,
        rootDir: zvDir.path,
        modelPath: p.join(zvDir.path, 'encoder.int8.onnx'),
        decoderPath: p.join(zvDir.path, 'decoder.int8.onnx'),
        tokensPath: p.join(zvDir.path, 'tokens.txt'),
        vocoderPath: p.join(zvDir.path, 'vocos_24khz.onnx'),
        lexiconPath: p.join(zvDir.path, 'lexicon.txt'),
        dataDir: '',
        referenceAudioPath: defaultWav.path,
        referenceText: '参考文本',
      );

      final engine = SherpaIsolateTtsEngine();
      addTearDown(engine.dispose);
      await expectLater(
        engine.loadModel(invalidPaths),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('espeak-ng-data'),
          ),
        ),
      );
    });
  });
}
