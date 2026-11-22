import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/core/reader/reading_store.dart';
import 'package:echo/core/storage/progress_store.dart';
import 'package:echo/core/sync/progress_sync_service.dart';

import 'stub_adapter.dart';

void main() {
  group('ProgressSyncService 云端进度与笔记同步', () {
    test('全量同步：云端较新时覆盖本地，本地较新时上报云端', () async {
      final tCloud = DateTime.utc(2026, 11, 21, 12, 0, 0);
      final tLocalOld = DateTime.utc(2026, 11, 21, 11, 0, 0);
      final tLocalNew = DateTime.utc(2026, 11, 21, 13, 0, 0);

      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/sync/progress': () => okResponse(<String, dynamic>{
          'progresses': [
            <String, dynamic>{
              'item_type': 'audiobook',
              'item_id': 101,
              'chapter_index': 3,
              'chunk_n': 3,
              'offset_ms': 50000,
              'updated_at': tCloud.toIso8601String(),
            },
            <String, dynamic>{
              'item_type': 'book',
              'item_id': 202,
              'chapter_index': 1,
              'char_offset': 100,
              'updated_at': tCloud.toIso8601String(),
            },
          ],
        }),
        '/api/sync/notes': () =>
            okResponse(<String, dynamic>{'notes': <dynamic>[]}),
      });

      final progressStore = MemoryProgressStore();
      final readingStore = MemoryReadingStore();

      // audiobook 101 本地较旧 (11:00 < 12:00) -> 应被云端覆盖为 50000
      await progressStore.write(
        PlaybackProgress(
          audiobookId: 101,
          chapterIndex: 1,
          chunkN: 1,
          offsetMs: 10000,
          updatedAt: tLocalOld,
        ),
      );

      // book 202 本地较新 (13:00 > 12:00) -> 应保留本地，并上报云端
      await readingStore.write(
        ReadingPosition(
          bookId: 202,
          chapterIndex: 5,
          charOffset: 800,
          updatedAt: tLocalNew,
        ),
      );

      final service = ProgressSyncService(
        api: EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        progressStore: progressStore,
        readingStore: readingStore,
      );

      await service.syncAll();

      expect(service.state.status, SyncStatus.success);
      expect(service.state.lastSyncTime, isNotNull);

      // 验证 audiobook 101 被更新为云端数据
      final updatedAudio = await progressStore.read(101);
      expect(updatedAudio?.offsetMs, 50000);
      expect(updatedAudio?.chapterIndex, 3);

      // 验证 book 202 保持本地最新数据
      final updatedBook = await readingStore.read(202);
      expect(updatedBook?.chapterIndex, 5);
      expect(updatedBook?.charOffset, 800);

      // 验证向云端发起了上报请求
      final postRequests = adapter.requestsTo('/api/sync/progress');
      expect(postRequests.length, greaterThanOrEqualTo(1));
    });

    test('防抖上报：reportAudioProgress 放入队列并在 flushPending 立即提交', () async {
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/sync/progress': () =>
            okResponse(<String, dynamic>{'status': 'ok'}),
      });

      final service = ProgressSyncService(
        api: EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        progressStore: MemoryProgressStore(),
        readingStore: MemoryReadingStore(),
      );

      service.reportAudioProgress(
        const PlaybackProgress(
          audiobookId: 99,
          chapterIndex: 2,
          chunkN: 2,
          offsetMs: 25000,
        ),
      );

      // 尚未 flush 前不发网络请求
      expect(adapter.requestsTo('/api/sync/progress'), isEmpty);

      // 触发 flush
      await service.flushPending();
      expect(adapter.requestsTo('/api/sync/progress'), hasLength(1));
      final body = adapter.requestBodyAt('/api/sync/progress')!;
      final progresses = body['progresses'] as List<dynamic>;
      expect(progresses.first['item_id'], 99);
      expect(progresses.first['offset_ms'], 25000);
    });

    test('网络异常：syncAll 失败时置为 error 态且不崩溃', () async {
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/sync/progress': () => errorResponse(500, 'FAIL', '服务器异常'),
      });

      final service = ProgressSyncService(
        api: EchoApi(dio: stubDio(adapter), tokenStore: MemoryTokenStore()),
        progressStore: MemoryProgressStore(),
        readingStore: MemoryReadingStore(),
      );

      await service.syncAll();
      expect(service.state.status, SyncStatus.error);
      expect(service.state.errorMessage, contains('服务器异常'));
    });
  });
}
