import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/audio/chunked_player_controller.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/storage/progress_store.dart';

class _ManifestStubAdapter implements HttpClientAdapter {
  static const String chunk0Srt = '''
1
00:00:00,000 --> 00:00:10,000
第一章第一句：红岸之巅。

2
00:00:10,500 --> 00:00:25,000
第一章第二句：信号发射。
''';

  static const String chunk1Srt = '''
1
00:00:00,000 --> 00:00:15,000
第二章第一句：寂静的森林。
''';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    final uri = options.uri;
    if (uri.path == '/api/audiobooks/101/chapters') {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{
          'audiobook_id': 101,
          'format': 'mp3',
          'duration_s': 120.0,
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
            <String, dynamic>{
              'n': 1,
              'chapter_index': 1,
              'title': '第二章 台球',
              'start_s': 60.0,
              'end_s': 120.0,
              'duration_s': 60.0,
              'audio_url': '/api/files/audiobooks/101?variant=chapter&n=1',
              'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=1',
            },
          ],
        }),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    }

    if (uri.path == '/api/files/audiobooks/101' &&
        uri.queryParameters['variant'] == 'chapter_srt') {
      final n = uri.queryParameters['n'];
      final text = n == '1' ? chunk1Srt : chunk0Srt;
      return ResponseBody.fromString(
        text,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/plain; charset=utf-8'],
        },
      );
    }

    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const sampleBook = AudiobookInfo(
    id: 101,
    bookId: 42,
    bookTitle: '三体',
    model: 'kokoro-82m',
    voice: 'zf_xiaoxiao',
    status: 'done',
    progress: 100,
    durationS: 120.0,
    chaptersUrl: '/api/audiobooks/101/chapters',
  );

  Future<
      ({
        ChunkedPlayerController controller,
        FakeAudioEngine engine,
        MemoryProgressStore progress,
      })> createHarness({PlaybackProgress? initialProgress}) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_media_token');
    final progressStore = MemoryProgressStore();
    if (initialProgress != null) {
      await progressStore.write(initialProgress);
    }
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
      ..httpClientAdapter = _ManifestStubAdapter();
    final api = EchoApi(dio: dio, tokenStore: tokenStore);
    final engine = FakeAudioEngine();
    final controller = ChunkedPlayerController(api, engine, progressStore);
    return (
      controller: controller,
      engine: engine,
      progress: progressStore,
    );
  }

  group('ChunkedPlayerController 分块播放引擎', () {
    test('载入分章清单、注入 Bearer 头、解析 SRT 并随播放位置切换高亮句', () async {
      final h = await createHarness();
      await h.controller.loadAudiobook(sampleBook);

      expect(h.controller.state.hasBook, isTrue);
      expect(h.controller.state.chunks.length, 2);
      expect(h.controller.state.currentChunkIndex, 0);
      expect(
        h.engine.lastUri.toString(),
        'http://127.0.0.1:8090/api/files/audiobooks/101?variant=chapter&n=0',
      );
      expect(
        h.engine.lastHeaders['Authorization'],
        'Bearer echo_pat_media_token',
      );
      expect(h.controller.state.cues.length, 2);
      expect(h.controller.state.activeCue?.text, '第一章第一句：红岸之巅。');

      // 推进播放到 12 秒，高亮句应切换到第 2 句，并自动持久化进度
      h.engine.emitPosition(const Duration(seconds: 12));
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.state.activeCueIndex, 1);
      expect(h.controller.state.activeCue?.text, '第一章第二句：信号发射。');

      final saved = await h.progress.read(101);
      expect(saved?.chunkN, 0);
      expect(saved?.offsetMs, 12000);
    });

    test('断点续听：存在历史进度时直接恢复到对应分块与毫秒偏移', () async {
      final h = await createHarness(
        initialProgress: const PlaybackProgress(
          audiobookId: 101,
          chapterIndex: 1,
          chunkN: 1,
          offsetMs: 8000,
        ),
      );
      await h.controller.loadAudiobook(sampleBook);

      expect(h.controller.state.currentChunkIndex, 1);
      expect(h.controller.state.positionMs, 8000);
      expect(
        h.engine.lastUri.toString(),
        'http://127.0.0.1:8090/api/files/audiobooks/101?variant=chapter&n=1',
      );
      expect(h.controller.state.activeCue?.text, '第二章第一句：寂静的森林。');
    });

    test('块间无缝续播：当前分块播完自动切入下一分块', () async {
      final h = await createHarness();
      await h.controller.loadAudiobook(sampleBook);
      expect(h.controller.state.currentChunkIndex, 0);

      h.engine.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(h.controller.state.currentChunkIndex, 1);
      expect(
        h.engine.lastUri.toString(),
        'http://127.0.0.1:8090/api/files/audiobooks/101?variant=chapter&n=1',
      );
    });

    test('±15s 跨块跳转：块尾前进跨入下一块，块首后退跨回上一块', () async {
      final h = await createHarness();
      await h.controller.loadAudiobook(sampleBook);

      // 跳到第 0 块 50s（总 60s），再前进 15s -> 应进入第 1 块 5s (5000ms)
      await h.controller.seekToMs(50000);
      await h.controller.skipBy(const Duration(seconds: 15));
      expect(h.controller.state.currentChunkIndex, 1);
      expect(h.controller.state.positionMs, 5000);

      // 在第 1 块 5s 处后退 15s -> 应回到第 0 块 50s (50000ms)
      await h.controller.skipBy(const Duration(seconds: -15));
      expect(h.controller.state.currentChunkIndex, 0);
      expect(h.controller.state.positionMs, 50000);
    });
  });
}
