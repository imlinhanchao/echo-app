import 'dart:io';

import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/offline/offline_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/profile/offline_manager_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('echo_offline_test_');
    OfflineFiles.setRootForTest(tempRoot);
  });

  tearDown(() async {
    OfflineFiles.setRootForTest(null);
    if (tempRoot.existsSync()) {
      await tempRoot.delete(recursive: true);
    }
  });

  void seedOfflineBook(
    int audiobookId, {
    int chunks = 2,
    int bytesPerChunk = 1024,
  }) {
    final dir = Directory('${tempRoot.path}/$audiobookId');
    dir.createSync(recursive: true);
    for (var i = 0; i < chunks; i++) {
      File(
        '${dir.path}/$i.audio',
      ).writeAsBytesSync(List<int>.filled(bytesPerChunk, 1));
      File(
        '${dir.path}/$i.srt',
      ).writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHi\n');
    }
  }

  test('OfflineFiles.scanAll / removeAudiobook / clearAll 与 formatBytes', () async {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatBytes(2 * 1024 * 1024), '2.0 MB');

    seedOfflineBook(101, chunks: 2, bytesPerChunk: 2048);
    seedOfflineBook(102, chunks: 1, bytesPerChunk: 512);

    final summary = await OfflineFiles.scanAll();
    expect(summary.entries.length, 2);
    expect(summary.totalChunks, 3);
    // 按体积倒序：101 在前
    expect(summary.entries.first.audiobookId, 101);
    expect(summary.entries.last.audiobookId, 102);

    await OfflineFiles.removeAudiobook(101);
    final afterOne = await OfflineFiles.scanAll();
    expect(afterOne.entries.length, 1);
    expect(afterOne.entries.first.audiobookId, 102);

    await OfflineFiles.clearAll();
    final afterClear = await OfflineFiles.scanAll();
    expect(afterClear.isEmpty, isTrue);
  });

  testWidgets('OfflineManagerPage 展示汇总并支持单本删除与清空全部', (
    WidgetTester tester,
  ) async {
    seedOfflineBook(101, chunks: 2, bytesPerChunk: 2048);
    seedOfflineBook(102, chunks: 1, bytesPerChunk: 1024);

    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_offline');
    final adapter = StubAdapter(<String, Responder Function()>{
      '/api/library': () => okResponse(<String, dynamic>{
        'books': <Map<String, dynamic>>[
          <String, dynamic>{'id': 42, 'title': '三体', 'format': 'epub'},
        ],
      }),
      '/api/audiobooks': () => okResponse(<String, dynamic>{
        'audiobooks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 101,
            'book_id': 42,
            'book_title': '三体',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'status': 'done',
            'progress': 100,
          },
        ],
      }),
    });
    final api = EchoApi(dio: stubDio(adapter), tokenStore: tokenStore);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[echoApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const OfflineManagerPage(),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('offline_summary_card')), findsOneWidget);
    expect(find.byKey(const Key('offline_item_101')), findsOneWidget);
    expect(find.byKey(const Key('offline_item_102')), findsOneWidget);
    expect(find.text('三体'), findsOneWidget);

    // 删除单本 102
    await tester.tap(find.byKey(const Key('offline_delete_102')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('offline_item_102')), findsNothing);
    expect(find.byKey(const Key('offline_item_101')), findsOneWidget);

    // 清空全部
    await tester.tap(find.byKey(const Key('offline_clear_all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('offline_empty')), findsOneWidget);
  });
}
