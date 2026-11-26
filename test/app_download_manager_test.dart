import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/tts/download_keepalive_service.dart';
import 'package:echo/core/update/app_download_manager.dart';

class _MockDownloadKeepAliveService implements DownloadKeepAliveService {
  final List<String> records = [];

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
    int progress = 0,
    int max = 100,
  }) async {
    records.add('$title | $text | $progress/$max');
  }

  @override
  Future<void> stop() async {
    records.add('stop');
  }
}

void main() {
  group('AppDownloadManager Tests', () {
    test('Initial state is idle', () {
      final mockKeepAlive = _MockDownloadKeepAliveService();
      final manager = AppDownloadManager(keepAliveService: mockKeepAlive);
      expect(manager.state.status, AppDownloadStatus.idle);
      expect(manager.state.progress, 0.0);
      expect(manager.state.receivedBytes, 0);
    });

    test('Cancel download stops keep alive and resets state', () async {
      final mockKeepAlive = _MockDownloadKeepAliveService();
      final manager = AppDownloadManager(keepAliveService: mockKeepAlive);

      await manager.cancelDownload();
      expect(manager.state.status, AppDownloadStatus.idle);
      expect(mockKeepAlive.records, contains('stop'));
    });
  });
}
