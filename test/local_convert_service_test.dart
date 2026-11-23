import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echo/core/audio/srt_parser.dart';
import 'package:echo/core/books/local_library_store.dart';
import 'package:echo/core/offline/offline_store.dart';
import 'package:echo/core/tts/audio_encoder_service.dart';
import 'package:echo/core/tts/local_convert_service.dart';
import 'package:echo/core/tts/sherpa_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalConvertService', () {
    late Directory libDir;
    late Directory offlineDir;
    late Directory workDir;

    setUp(() async {
      libDir = await Directory.systemTemp.createTemp('echo_conv_lib_');
      offlineDir = await Directory.systemTemp.createTemp('echo_conv_offline_');
      workDir = await Directory.systemTemp.createTemp('echo_conv_work_');
      OfflineFiles.setRootForTest(offlineDir);
    });

    tearDown(() async {
      OfflineFiles.setRootForTest(null);
      for (final d in <Directory>[libDir, offlineDir, workDir]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });

    test('converts book chapters into local audio chunks, SRT and manifest', () async {
      final libraryStore = LocalLibraryStore(rootDir: libDir);
      final book = await libraryStore.importBytes(
        Uint8List.fromList(
          utf8.encode(
            '第一章 晨光\n\n第一句清晨的阳光照进房间。第二句鸟儿在窗外歌唱。\n\n第二章 黄昏\n\n夕阳西下，微风徐徐吹过。',
          ),
        ),
        filename: 'seasons.txt',
      );

      final service = LocalConvertService(
        libraryStore: libraryStore,
        ttsEngine: FakeOnDeviceTtsEngine(),
        encoderService: const PlatformAudioEncoderService(),
        workDirOverride: workDir,
      );

      final progressEvents = <int>[];
      final info = await service.convertBook(
        book: book,
        modelPaths: const ResolvedTtsModelPaths(
          spec: TtsModelCatalog.meloTtsZhEn,
          rootDir: '/tmp/fake',
          modelPath: '/tmp/fake/model.onnx',
          tokensPath: '/tmp/fake/tokens.txt',
        ),
        speakerId: 0,
        voiceLabel: 'Melo 标准女声',
        onProgress: (pct, _) => progressEvents.add(pct),
      );

      expect(info.status, 'done');
      expect(info.progress, 100);
      expect(info.durationS, greaterThan(0));
      expect(info.sizeBytes, greaterThan(0));
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last, 100);

      final manifest = await libraryStore.readChaptersManifest(info.id);
      expect(manifest, isNotNull);
      expect(manifest!.chunks, hasLength(2));

      // 验证 OfflineFiles 音频与 SRT 文件均可读且字幕有效
      final audio0 = await OfflineFiles.audioFile(info.id, 0);
      final srt0 = await OfflineFiles.srtFile(info.id, 0);
      expect(audio0, isNotNull);
      expect(srt0, isNotNull);

      final cues = SrtParser.parse(await srt0!.readAsString());
      expect(cues, isNotEmpty);
      expect(cues.first.text, contains('晨光'));
    });
  });
}
