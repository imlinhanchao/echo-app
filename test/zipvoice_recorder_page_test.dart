import 'dart:io';

import 'package:echo/core/settings/standalone_config_store.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/tts/system_tts_engine.dart';
import 'package:echo/core/tts/tts_model_catalog.dart';
import 'package:echo/core/tts/tts_model_manager.dart';
import 'package:echo/core/tts/voice_recorder_service.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/tts/tts_model_manager_page.dart';
import 'package:echo/features/tts/zipvoice_reference_recorder_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'tokens_fixtures.dart';

Future<void> _seedFakeZipVoiceDir(Directory rootDir) async {
  final zvDir = Directory(
    p.join(rootDir.path, TtsModelCatalog.zipvoiceZhEnInt8.id),
  );
  await zvDir.create(recursive: true);
  for (final f in const <String>[
    'encoder.int8.onnx',
    'decoder.int8.onnx',
    'vocos_24khz.onnx',
    'tokens.txt',
    'lexicon.txt',
  ]) {
    await File(p.join(zvDir.path, f)).writeAsBytes(const <int>[1, 2, 3]);
  }
  final espeakDir = Directory(p.join(zvDir.path, 'espeak-ng-data'));
  await espeakDir.create(recursive: true);
  for (final f in kRequiredEspeakDataFiles) {
    await File(p.join(espeakDir.path, f)).writeAsBytes(const <int>[4, 5]);
  }
  final wavFile = File(p.join(zvDir.path, 'test_wavs', 'leijun-1.wav'));
  await wavFile.parent.create(recursive: true);
  await wavFile.writeAsBytes(const <int>[82, 73, 70, 70]);
}

void main() {
  group('ZipVoiceReferenceRecorderPage 录制参考音色交互与边界条件', () {
    late Directory rootDir;
    late MemoryStandaloneConfigStorage storage;
    late StandaloneConfigController configCtrl;
    late TtsModelManager manager;

    setUp(() async {
      rootDir = Directory.systemTemp.createTempSync('echo_zv_rec_test_');
      await _seedFakeZipVoiceDir(rootDir);
      storage = MemoryStandaloneConfigStorage(
        const StandaloneConfig(onboardingCompleted: true),
      );
      StandaloneConfigStore.setForTest(
        const StandaloneConfig(onboardingCompleted: true),
        storage: storage,
      );
      configCtrl = StandaloneConfigController(
        storage,
        const StandaloneConfig(onboardingCompleted: true),
      );
      manager = TtsModelManager(
        configCtrl,
        rootDirOverride: rootDir,
        keepAliveService: const NoopDownloadKeepAliveService(),
        systemTtsBridge: FakeSystemTtsBridge(isSupported: false),
      );
      await manager.refresh();
    });

    tearDown(() {
      if (rootDir.existsSync()) {
        rootDir.deleteSync(recursive: true);
      }
    });

    Future<void> pumpApp(
      WidgetTester tester, {
      required Widget home,
      required FakeVoiceRecorderService recorder,
      FakeVoicePreviewAudioPlayer? previewPlayer,
    }) async {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final theme = buildEchoTheme(
        Brightness.dark,
        EchoTokens.fromColors(darkColors, Brightness.dark),
      );
      final player = previewPlayer ?? FakeVoicePreviewAudioPlayer();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            standaloneConfigStorageProvider.overrideWithValue(storage),
            standaloneConfigProvider.overrideWith((_) => configCtrl),
            systemTtsBridgeProvider.overrideWithValue(
              FakeSystemTtsBridge(isSupported: false),
            ),
            ttsModelManagerProvider.overrideWith((_) => manager),
            voiceRecorderServiceProvider.overrideWithValue(recorder),
            voicePreviewPlayerFactoryProvider.overrideWithValue(() => player),
            voiceRecorderTempDirProvider.overrideWithValue(() async => rootDir),
          ],
          child: MaterialApp(theme: theme, home: home),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      '可从模型管理页进入录制页，切换台词、录制、试听并保存设为自定义参考音色',
      (tester) async {
        final recorder = FakeVoiceRecorderService(simulatedDurationMs: 3600);
        final player = FakeVoicePreviewAudioPlayer();

        await pumpApp(
          tester,
          home: const TtsModelManagerPage(),
          recorder: recorder,
          previewPlayer: player,
        );

        final recordEntry = find.byKey(const Key('tts_zipvoice_record_ref'));
        await tester.dragUntilVisible(
          recordEntry,
          find.byType(ListView),
          const Offset(0, -180),
        );
        await tester.pumpAndSettle();
        await tester.tap(recordEntry);
        await tester.pumpAndSettle();

        expect(find.byType(ZipVoiceReferenceRecorderPage), findsOneWidget);

        // 切换预置朗读台词
        await tester.tap(find.byKey(const Key('zipvoice_recorder_next_prompt')));
        await tester.pumpAndSettle();
        final textField = tester.widget<TextField>(
          find.byKey(const Key('zipvoice_recorder_text_field')),
        );
        final chosenPrompt = textField.controller!.text;
        expect(chosenPrompt, zipvoiceSamplePrompts[1]);

        // 开始录制并轮询电平
        final toggleBtn = find.byKey(const Key('zipvoice_recorder_toggle_btn'));
        await tester.ensureVisible(toggleBtn);
        await tester.pumpAndSettle();
        await tester.tap(toggleBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 140));
        expect(recorder.startCount, 1);

        // 停止录制，生成本地 WAV
        await tester.ensureVisible(toggleBtn);
        await tester.pumpAndSettle();
        await tester.tap(toggleBtn);
        for (var i = 0; i < 20; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          if (find
              .byKey(const Key('zipvoice_recorder_play_btn'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(recorder.stopCount, 1);
        final playBtn = find.byKey(const Key('zipvoice_recorder_play_btn'));
        expect(playBtn, findsOneWidget);
        expect(
          find.byKey(const Key('zipvoice_recorder_rerecord_btn')),
          findsOneWidget,
        );

        // 试听录音与停止试听
        await tester.ensureVisible(playBtn);
        await tester.pumpAndSettle();
        await tester.tap(playBtn);
        await tester.pumpAndSettle();
        expect(player.playedPaths, hasLength(1));
        await tester.tap(playBtn);
        await tester.pumpAndSettle();
        expect(player.stopCount, greaterThanOrEqualTo(1));

        // 保存并设为参考音色，返回模型管理页
        final applyBtn = find.byKey(const Key('zipvoice_recorder_apply_btn'));
        await tester.ensureVisible(applyBtn);
        await tester.pumpAndSettle();
        await tester.tap(applyBtn);
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (find.byType(ZipVoiceReferenceRecorderPage).evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();

        expect(find.byType(ZipVoiceReferenceRecorderPage), findsNothing);
        expect(
          configCtrl.state.zipvoiceRefAudioPath,
          matches(RegExp(r'zipvoice_custom_ref_\d+_\d+\.wav$')),
        );
        expect(File(configCtrl.state.zipvoiceRefAudioPath).existsSync(), isTrue);
        expect(configCtrl.state.zipvoiceRefText, chosenPrompt);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('拒绝麦克风权限时展示友好错误提示与前往系统设置入口', (tester) async {
      final recorder = FakeVoiceRecorderService(permissionGranted: false);

      await pumpApp(
        tester,
        home: const ZipVoiceReferenceRecorderPage(),
        recorder: recorder,
      );

      final toggleBtn = find.byKey(const Key('zipvoice_recorder_toggle_btn'));
      await tester.ensureVisible(toggleBtn);
      await tester.pumpAndSettle();
      await tester.tap(toggleBtn);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('zipvoice_recorder_error_banner')),
        findsOneWidget,
      );
      expect(find.text('前往系统设置'), findsOneWidget);
      await tester.tap(find.text('前往系统设置'));
      await tester.pumpAndSettle();
      expect(recorder.openSettingsCount, 1);
      expect(recorder.startCount, 0);
    });

    testWidgets('录制不足 1 秒时保存校验报错且不覆盖已有配置', (tester) async {
      final recorder = FakeVoiceRecorderService(simulatedDurationMs: 500);

      await pumpApp(
        tester,
        home: const ZipVoiceReferenceRecorderPage(),
        recorder: recorder,
      );

      final toggleBtn = find.byKey(const Key('zipvoice_recorder_toggle_btn'));
      await tester.ensureVisible(toggleBtn);
      await tester.pumpAndSettle();
      await tester.tap(toggleBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.ensureVisible(toggleBtn);
      await tester.pumpAndSettle();
      await tester.tap(toggleBtn);
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        if (find
            .byKey(const Key('zipvoice_recorder_play_btn'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();

      final applyBtn = find.byKey(const Key('zipvoice_recorder_apply_btn'));
      await tester.ensureVisible(applyBtn);
      await tester.pumpAndSettle();
      await tester.tap(applyBtn);
      for (var i = 0; i < 30; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (find
            .byKey(const Key('zipvoice_recorder_error_banner'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('zipvoice_recorder_error_banner')),
        findsOneWidget,
      );
      expect(find.textContaining('不足 1 秒'), findsAtLeastNWidgets(1));
      expect(configCtrl.state.zipvoiceRefAudioPath, isEmpty);
      expect(find.byType(ZipVoiceReferenceRecorderPage), findsOneWidget);
    });

    testWidgets('不支持录音平台在 360x720 小屏优雅降级提示且无溢出', (tester) async {
      final recorder = FakeVoiceRecorderService(supported: false);

      await pumpApp(
        tester,
        home: const ZipVoiceReferenceRecorderPage(),
        recorder: recorder,
      );

      expect(
        find.byKey(const Key('zipvoice_recorder_unsupported_banner')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
