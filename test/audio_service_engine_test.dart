import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:echo/core/audio/audio_service_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

class _FakeEchoPlayerAdapter implements EchoPlayerAdapter {
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<ProcessingState> _procStateController =
      StreamController<ProcessingState>.broadcast();
  final StreamController<double> _speedController =
      StreamController<double>.broadcast();

  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;
  Duration _position = Duration.zero;
  final Duration _bufferedPosition = Duration.zero;
  final double _speed = 1.0;
  Completer<void>? _playCompleter;

  final List<Duration?> seekHistory = <Duration?>[];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _procStateController.stream;

  @override
  Stream<double> get speedStream => _speedController.stream;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  Duration get position => _position;

  @override
  Duration get bufferedPosition => _bufferedPosition;

  @override
  double get speed => _speed;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    Duration? initialPosition,
  }) async {
    _position = initialPosition ?? Duration.zero;
    _processingState = ProcessingState.ready;
    _procStateController.add(_processingState);
    _positionController.add(_position);
    return const Duration(seconds: 12);
  }

  @override
  Future<void> play() {
    playCalls++;
    if (_playing) return _playCompleter?.future ?? Future<void>.value();
    _playing = true;
    _playingController.add(true);
    _playCompleter = Completer<void>();
    return _playCompleter!.future;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    if (!_playing) return;
    _playing = false;
    _playingController.add(false);
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    _processingState = ProcessingState.idle;
    _position = Duration.zero;
    _playingController.add(false);
    _procStateController.add(_processingState);
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
  }

  @override
  Future<void> seek(Duration? position) async {
    seekHistory.add(position);
    _position = position ?? Duration.zero;
    if (_processingState == ProcessingState.completed) {
      _processingState = ProcessingState.ready;
      _procStateController.add(_processingState);
    }
    _positionController.add(_position);
  }

  void completePlayback() {
    _processingState = ProcessingState.completed;
    _position = const Duration(seconds: 12);
    _procStateController.add(_processingState);
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  Future<void> dispose() async {
    if (_playCompleter != null && !_playCompleter!.isCompleted) {
      _playCompleter!.complete();
    }
    await _playingController.close();
    await _positionController.close();
    await _procStateController.close();
    await _speedController.close();
  }
}

void main() {
  group('AudioServiceEngine configuration & artwork URI parsing', () {
    test('audioServiceConfig keeps foreground alive on pause for headset resume', () {
      const cfg = AudioServiceEngine.audioServiceConfig;
      expect(cfg.androidResumeOnClick, isTrue);
      expect(cfg.androidStopForegroundOnPause, isFalse);
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

  group('EchoAudioHandler headset click & media controls', () {
    late _FakeEchoPlayerAdapter fakePlayer;
    late int sessionActivateCalls;
    late int stopCallbackCalls;
    late EchoAudioHandler handler;

    setUp(() {
      fakePlayer = _FakeEchoPlayerAdapter();
      sessionActivateCalls = 0;
      stopCallbackCalls = 0;
      handler = EchoAudioHandler(
        player: fakePlayer,
        activateAudioSession: () async {
          sessionActivateCalls++;
          return true;
        },
        onStopped: () async {
          stopCallbackCalls++;
        },
      );
    });

    tearDown(() async {
      await fakePlayer.dispose();
    });

    test('playFromApp completes immediately and exposes play/pause systemActions', () async {
      await handler.setChunkSource(
        Uri.file('/tmp/test.wav'),
        title: 'Test Book',
        artist: 'Chapter 1',
      );
      await handler.playFromApp().timeout(const Duration(seconds: 1));

      expect(fakePlayer.playing, isTrue);
      expect(sessionActivateCalls, 1);
      final state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.controls, contains(MediaControl.pause));
      expect(
        state.systemActions,
        containsAll(const <MediaAction>{
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
        }),
      );
    });

    test('headphone click pauses and resumes cleanly with audio session reactivation', () async {
      var externalPlayCount = 0;
      var externalPauseCount = 0;
      final subPlay = handler.playRequests.listen((_) => externalPlayCount++);
      final subPause = handler.pauseRequests.listen(
        (_) => externalPauseCount++,
      );
      addTearDown(subPlay.cancel);
      addTearDown(subPause.cancel);

      await handler.setChunkSource(Uri.file('/tmp/test.wav'), title: 'Test');
      await handler.playFromApp();
      expect(handler.playbackState.value.playing, isTrue);
      expect(sessionActivateCalls, 1);

      // 第一次耳机单击 -> 暂停
      await handler.click(MediaButton.media);
      await Future<void>.delayed(Duration.zero);
      expect(fakePlayer.playing, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, contains(MediaControl.play));
      expect(externalPauseCount, 1);

      // 第二次耳机单击 -> 重新激活音频焦点并恢复播放
      await handler.click(MediaButton.media);
      await Future<void>.delayed(Duration.zero);
      expect(sessionActivateCalls, 2);
      expect(fakePlayer.playing, isTrue);
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.controls, contains(MediaControl.pause));
      expect(externalPlayCount, 1);
    });

    test('headphone click when completed seeks to zero and resumes playback', () async {
      await handler.setChunkSource(Uri.file('/tmp/test.wav'), title: 'Test');
      await handler.playFromApp();
      fakePlayer.completePlayback();
      await handler.pauseFromApp();

      expect(fakePlayer.processingState, ProcessingState.completed);
      await handler.click(MediaButton.media);

      expect(fakePlayer.seekHistory, contains(Duration.zero));
      expect(fakePlayer.playing, isTrue);
      expect(sessionActivateCalls, 2);
    });

    test('headphone click when idle emits playRequests without setting playing true', () async {
      var externalPlayCount = 0;
      final sub = handler.playRequests.listen((_) => externalPlayCount++);
      addTearDown(sub.cancel);

      await handler.click(MediaButton.media);
      await Future<void>.delayed(Duration.zero);

      expect(externalPlayCount, 1);
      expect(fakePlayer.playCalls, 0);
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('stop resets state to idle and invokes onStopped callback', () async {
      await handler.setChunkSource(Uri.file('/tmp/test.wav'), title: 'Test');
      await handler.playFromApp();
      await handler.stop();

      expect(fakePlayer.stopCalls, 1);
      expect(stopCallbackCalls, 1);
      expect(handler.mediaItem.value, isNull);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, isFalse);
    });
  });
}
