import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/main.dart';

import 'tokens_fixtures.dart';

class _LibraryStubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    final path = options.uri.path;
    if (path == '/api/audiobooks') {
      return _json(<String, dynamic>{
        'audiobooks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 101,
            'book_id': 42,
            'book_title': '三体 · 地球往事',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'status': 'done',
            'progress': 100,
            'duration_s': 60.0,
            'chapters_url': '/api/audiobooks/101/chapters',
          },
        ],
      });
    }
    if (path == '/api/library') {
      return _json(<String, dynamic>{
        'books': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 42,
            'title': '三体 · 地球往事',
            'authors': <String>['刘慈欣'],
            'format': 'epub',
            'status': 'ready',
          },
        ],
      });
    }
    if (path == '/api/audiobooks/101/chapters') {
      return _json(<String, dynamic>{
        'audiobook_id': 101,
        'format': 'mp3',
        'duration_s': 60.0,
        'chunk_seconds': 60,
        'chunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'n': 0,
            'chapter_index': 0,
            'title': '第一章 科学边界',
            'start_s': 0.0,
            'end_s': 60.0,
            'duration_s': 60.0,
            'audio_url': '/api/files/audiobooks/101?variant=chapter&n=0',
            'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=0',
          },
        ],
      });
    }
    if (path == '/api/files/audiobooks/101') {
      return ResponseBody.fromString(
        '1\n00:00:00,000 --> 00:00:10,000\n叶文洁凝视着雷达峰。\n',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/plain; charset=utf-8'],
        },
      );
    }
    return _json(<String, dynamic>{});
  }

  static ResponseBody _json(Map<String, dynamic> body) =>
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);
  const user = EchoUser(id: 7, email: 'hancel@example.com');

  testWidgets('书架加载有声书 → 点击播放浮现迷你播放条 → 展开 v3 跟读播放器',
      (WidgetTester tester) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_test');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _LibraryStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final engine = FakeAudioEngine();
    final progressStore = MemoryProgressStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          tokenStoreProvider.overrideWithValue(tokenStore),
          echoApiProvider.overrideWithValue(api),
          audioEngineProvider.overrideWithValue(engine),
          progressStoreProvider.overrideWithValue(progressStore),
        ],
        child: EchoApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const EchoHome(user: user),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 有声书卡片已渲染
    expect(find.byKey(const Key('audiobook_card_101')), findsOneWidget);
    expect(find.text('三体 · 地球往事'), findsOneWidget);

    // 2. 点击播放按钮 -> 底部浮现 MiniPlayerBar 并展示首句跟读字幕
    await tester.tap(find.byKey(const Key('audiobook_play_101')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mini_player_bar')), findsOneWidget);
    // 「正在收听」hero 卡与迷你播放条都应展示当前跟读句。
    expect(find.text('叶文洁凝视着雷达峰。'), findsWidgets);
    expect(find.byKey(const Key('now_playing_hero_card')), findsOneWidget);

    // 3. 点击 MiniPlayerBar 展开全屏 v3 播放器
    await tester.tap(find.byKey(const Key('mini_player_bar')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('player_sheet')), findsOneWidget);
    expect(find.byKey(const Key('player_srt_list')), findsOneWidget);
    expect(find.byKey(const Key('player_toggle_play')), findsOneWidget);
    expect(find.byKey(const Key('player_back_15')), findsOneWidget);
    expect(find.byKey(const Key('player_forward_15')), findsOneWidget);
  });
}
