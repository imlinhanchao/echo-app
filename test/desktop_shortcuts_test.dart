import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/features/shell/desktop_shortcuts.dart';

import 'stub_adapter.dart';

class _MockPlayerController extends ChunkedPlayerController {
  _MockPlayerController(super.api, super.engine, super.progressStore);

  bool togglePlayCalled = false;
  int seekOffset = 0;
  bool nextChunkCalled = false;
  bool prevChunkCalled = false;

  @override
  Future<void> togglePlay() async {
    togglePlayCalled = true;
  }

  @override
  Future<void> seekByRelativeMs(int offsetMs) async {
    seekOffset = offsetMs;
  }

  @override
  Future<void> nextChunk() async {
    nextChunkCalled = true;
  }

  @override
  Future<void> previousChunk() async {
    prevChunkCalled = true;
  }
}

void main() {
  late StubAdapter adapter;
  late EchoApi api;
  late MemoryTokenStore tokenStore;
  late MemoryProgressStore progressStore;
  late FakeAudioEngine engine;
  late _MockPlayerController mockController;

  setUp(() async {
    tokenStore = MemoryTokenStore();
    adapter = StubAdapter(<String, Responder Function()>{});
    api = EchoApi(dio: stubDio(adapter), tokenStore: tokenStore);
    progressStore = MemoryProgressStore();
    engine = FakeAudioEngine();
    mockController = _MockPlayerController(api, engine, progressStore);
  });

  testWidgets('桌面快捷键映射与文本框焦点防护', (WidgetTester tester) async {
    var notePromptCalled = false;
    final textController = TextEditingController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          chunkedPlayerProvider.overrideWith((ref) => mockController),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DesktopShortcutsWrapper(
              onAddNotePrompt: () => notePromptCalled = true,
              child: Column(
                children: [
                  const Text('主界面内容'),
                  TextField(
                    key: const Key('test_input'),
                    controller: textController,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 1. 空格键播放/暂停
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(mockController.togglePlayCalled, isTrue);

    // 2. 快退 [ (-15s) 与快进 ] (+15s)
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await tester.pump();
    expect(mockController.seekOffset, -15000);

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect(mockController.seekOffset, 15000);

    // 3. Alt+ArrowRight / Alt+ArrowLeft 切章节
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(mockController.nextChunkCalled, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(mockController.prevChunkCalled, isTrue);

    // 4. Ctrl+M 触发打点记录笔记
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(notePromptCalled, isTrue);

    // 5. 聚焦输入框后，快捷键均不应触发播放器动作（焦点防护）
    mockController.togglePlayCalled = false;
    await tester.tap(find.byKey(const Key('test_input')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(mockController.togglePlayCalled, isFalse);
  });
}
