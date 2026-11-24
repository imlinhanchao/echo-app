import 'package:echo/core/audio/audio_service_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioServiceEngine configuration & artwork URI parsing', () {
    test('audioServiceConfig keeps media buttons and custom icon active', () {
      const cfg = AudioServiceEngine.audioServiceConfig;
      expect(cfg.androidResumeOnClick, isTrue);
      expect(cfg.androidStopForegroundOnPause, isTrue);
      expect(cfg.androidNotificationOngoing, isFalse);
      expect(cfg.androidNotificationIcon, 'drawable/ic_stat_echo');
    });

    test('parseArtUri normalizes local paths and filters invalid URIs', () {
      expect(AudioServiceEngine.parseArtUri(null), isNull);
      expect(AudioServiceEngine.parseArtUri(''), isNull);
      expect(AudioServiceEngine.parseArtUri('   '), isNull);
      expect(AudioServiceEngine.parseArtUri('relative/cover.jpg'), isNull);

      final localPath = AudioServiceEngine.parseArtUri(
        '/data/user/0/org.hancel.echo/app_flutter/books/1/cover.jpg',
      );
      expect(localPath, isNotNull);
      expect(localPath!.scheme, 'file');
      expect(
        localPath.toFilePath(),
        '/data/user/0/org.hancel.echo/app_flutter/books/1/cover.jpg',
      );

      final fileUri = AudioServiceEngine.parseArtUri('file:///tmp/cover.png');
      expect(fileUri, isNotNull);
      expect(fileUri!.scheme, 'file');

      final httpsUri = AudioServiceEngine.parseArtUri(
        'https://example.com/c.jpg',
      );
      expect(httpsUri, isNotNull);
      expect(httpsUri!.scheme, 'https');

      final contentUri = AudioServiceEngine.parseArtUri(
        'content://media/external/images/1',
      );
      expect(contentUri, isNotNull);
      expect(contentUri!.scheme, 'content');
    });
  });
}
