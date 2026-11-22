import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/notes/note_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/shell/echo_shell.dart';
import 'package:echo/main.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final iconBytes = await File(
      '/home/hancel/fvm/versions/3.38.9/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    final iconLoader = FontLoader('MaterialIcons');
    iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
    await iconLoader.load();

    final cjkBytes = await File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytes();
    final cjkLoader = FontLoader('Roboto');
    cjkLoader.addFont(Future.value(ByteData.view(cjkBytes.buffer)));
    await cjkLoader.load();
  });

  testWidgets('Render Desktop Preview', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);
    const user = EchoUser(id: 7, email: 'hancel@echo.reader');

    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_test');
    final progressStore = MemoryProgressStore();
    final readingStore = MemoryReadingStore();
    final engine = FakeAudioEngine();

    final adapter = StubAdapter(<String, Responder Function()>{
      '/api/audiobooks': () => okResponse(<String, dynamic>{
        'audiobooks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 101,
            'book_id': 42,
            'book_title': '呐喊',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'status': 'done',
            'progress': 100,
            'duration_s': 120.0,
            'chapters_url': '/api/audiobooks/101/chapters',
          },
          <String, dynamic>{
            'id': 102,
            'book_id': 43,
            'book_title': '一地鸡毛',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'status': 'done',
            'progress': 100,
            'duration_s': 300.0,
            'chapters_url': '/api/audiobooks/102/chapters',
          },
        ],
      }),
      '/api/library': () => okResponse(<String, dynamic>{
        'books': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 42,
            'title': '呐喊',
            'authors': <String>['鲁迅'],
            'format': 'epub',
            'status': 'ready',
            'cover_url': '/tmp/echo_covers/nahan.jpg',
          },
          <String, dynamic>{
            'id': 43,
            'title': '一地鸡毛',
            'authors': <String>['刘震云'],
            'format': 'epub',
            'status': 'ready',
            'cover_url': '/tmp/echo_covers/yidijimao.jpg',
          },
          <String, dynamic>{
            'id': 44,
            'title': 'Kafka - Tutti i romanzi',
            'authors': <String>['Franz Kafka'],
            'format': 'epub',
            'status': 'ready',
            'cover_url': '/tmp/echo_covers/kafka.jpg',
          },
        ],
      }),
      '/api/audiobooks/101/chapters': () => okResponse(<String, dynamic>{
        'audiobook_id': 101,
        'format': 'mp3',
        'duration_s': 120.0,
        'chunk_seconds': 60,
        'chunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'n': 0,
            'chapter_index': 0,
            'title': '第一章 狂人日记',
            'start_s': 0.0,
            'end_s': 60.0,
            'duration_s': 60.0,
            'audio_url': '/api/files/audiobooks/101?variant=chapter&n=0',
            'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=0',
          },
        ],
      }),
      '/api/files/audiobooks/101': () => okResponse(<String, dynamic>{}),
      '/api/sync/progress': () =>
          okResponse(<String, dynamic>{'progresses': []}),
      '/api/sync/notes': () => okResponse(<String, dynamic>{'notes': []}),
    });

    final api = EchoApi(dio: stubDio(adapter), tokenStore: tokenStore);

    // 预注入两条时间戳笔记
    await NoteStore.instance.add(
      audiobookId: 101,
      positionMs: 14500,
      text: '物理学从来没有存在过，将来也不会存在。汪淼在台球桌旁沉思。',
      chapterTitle: '第一章 科学边界',
    );
    await NoteStore.instance.add(
      audiobookId: 101,
      positionMs: 38200,
      text: '射手与农场主假说：对经验主义认知边界的深刻质询。',
      chapterTitle: '第一章 科学边界',
    );

    final repaintKey = GlobalKey();

    // 在 pumpWidget 前预加载解码封面图片，确保帧绘制时位图已被缓存并在截图呈现
    await tester.runAsync(() async {
      for (final path in [
        '/tmp/echo_covers/nahan.jpg',
        '/tmp/echo_covers/yidijimao.jpg',
        '/tmp/echo_covers/kafka.jpg',
      ]) {
        await precacheImage(FileImage(File(path)), tester.binding.rootElement!);
      }
    });

    await tester.pumpWidget(
      RepaintBoundary(
        key: repaintKey,
        child: ProviderScope(
          overrides: <Override>[
            tokenStoreProvider.overrideWithValue(tokenStore),
            echoApiProvider.overrideWithValue(api),
            audioEngineProvider.overrideWithValue(engine),
            progressStoreProvider.overrideWithValue(progressStore),
            readingStoreProvider.overrideWithValue(readingStore),
          ],
          child: EchoApp(
            theme: buildEchoTheme(Brightness.dark, darkTokens),
            home: const EchoHome(user: user),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 模拟点击播放「呐喊」，激活底部桌面专业播控台
    await tester.tap(find.byKey(const Key('audiobook_play_101')));
    await tester.pumpAndSettle();

    // 截图 1：桌面主界面（左侧完整导航栏 + 顶栏书架双列卡片 + 底部全宽专业播控台）
    await tester.runAsync(() async {
      final boundary =
          repaintKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();
      final outDir = Directory(
        '/home/hancel/.gemini/antigravity/brain/fc494477-2c47-47b7-b79f-28cbf61eafe0',
      );
      await File('${outDir.path}/desktop_main.png').writeAsBytes(pngBytes);
    });

    // 2. 打开右侧时间戳笔记抽屉
    EchoShell.shellKey.currentState?.toggleNotes();
    await tester.pumpAndSettle();

    // 截图 2：桌面主界面 + 右侧滑出时间戳笔记抽屉
    await tester.runAsync(() async {
      final boundary =
          repaintKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();
      final outDir = Directory(
        '/home/hancel/.gemini/antigravity/brain/fc494477-2c47-47b7-b79f-28cbf61eafe0',
      );
      await File('${outDir.path}/desktop_notes.png').writeAsBytes(pngBytes);
    });

    // 3. 平板中屏模式 (800x900)
    tester.view.physicalSize = const Size(800, 900);
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final boundary =
          repaintKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();
      final outDir = Directory(
        '/home/hancel/.gemini/antigravity/brain/fc494477-2c47-47b7-b79f-28cbf61eafe0',
      );
      await File('${outDir.path}/tablet_main.png').writeAsBytes(pngBytes);
    });
  });
}
