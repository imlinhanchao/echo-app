import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'chunked_player_controller.dart' show AudioEngine, LockScreenControls;

/// audio_service 后台处理器：把 just_audio 会话桥接到系统媒体控制
/// （锁屏/通知栏：书名 + 章节名 + 进度条 + 上一章/下一章）。
class EchoAudioHandler extends BaseAudioHandler {
  EchoAudioHandler() {
    _player.playingStream.listen((_) => _broadcast());
    _player.positionStream.listen((_) => _broadcast());
    _player.processingStateStream.listen((_) => _broadcast());
    _player.speedStream.listen((_) => _broadcast());
  }

  final AudioPlayer _player = AudioPlayer();
  final StreamController<void> _skipNext = StreamController<void>.broadcast();
  final StreamController<void> _skipPrev = StreamController<void>.broadcast();

  AudioPlayer get player => _player;
  Stream<void> get skipNextRequests => _skipNext.stream;
  Stream<void> get skipPrevRequests => _skipPrev.stream;

  /// 载入一个分块音源并广播媒体元数据（锁屏显示书名/章节/时长）。
  Future<void> setChunkSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    Duration? duration,
    String title = '',
    String artist = '',
    Uri? artUri,
  }) async {
    mediaItem.add(
      MediaItem(
        id: uri.toString(),
        album: 'Echo · 回声',
        title: title.isEmpty ? 'Echo · 回声' : title,
        artist: artist,
        duration: duration,
        // 锁屏 / 通知栏上部"小组件"的封面图
        artUri: artUri,
      ),
    );
    await _player.setAudioSource(
      AudioSource.uri(uri, headers: headers.isEmpty ? null : headers),
      initialPosition: initialPosition,
    );
    _broadcast();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  /// 锁屏"上一首/下一首"按设计映射为章节切换请求，
  /// 由 [EchoAudioHandler] 持有的流交由 ChunkedPlayerController 消费。
  @override
  Future<void> skipToNext() async => _skipNext.add(null);

  @override
  Future<void> skipToPrevious() async => _skipPrev.add(null);

  static const _processingStateMap = <ProcessingState, AudioProcessingState>{
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _broadcast() {
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (_player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState:
            _processingStateMap[_player.processingState] ??
                AudioProcessingState.idle,
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ),
    );
  }
}

/// 经 audio_service 驱动的生产引擎（Android/iOS）。
/// 单例由 [tryInit] 在 main() 初始化；dispose 为空操作（会话与 App 同生命周期）。
class AudioServiceEngine implements AudioEngine, LockScreenControls {
  AudioServiceEngine._(this._handler);

  static bool initialized = false;
  static AudioServiceEngine? _instance;

  /// 已初始化的单例；未初始化时不应访问（引擎选择在 provider 中先行判断）。
  static AudioServiceEngine get instance => _instance!;

  final EchoAudioHandler _handler;

  /// 在 main() 中初始化后台媒体会话；
  /// 非 Android/iOS 平台（桌面/测试）自动跳过并回退 just_audio。
  static Future<void> tryInit() async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      final handler = await AudioService.init(
        builder: () => EchoAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'org.hancel.echo.playback',
          androidNotificationChannelName: 'Echo 播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      _instance = AudioServiceEngine._(handler);
      initialized = true;
    } catch (e) {
      debugPrint('AudioService 初始化失败，回退 just_audio：$e');
    }
  }

  @override
  Stream<Duration> get positionStream => _handler.player.positionStream;

  @override
  Stream<bool> get playingStream => _handler.player.playingStream;

  @override
  Stream<void> get completedStream => _handler.player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Future<void> setSource(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Duration initialPosition = Duration.zero,
    String? mediaTitle,
    String? mediaArtist,
    Duration? mediaDuration,
    String? mediaArtUrl,
  }) =>
      _handler.setChunkSource(
        uri,
        headers: headers,
        initialPosition: initialPosition,
        duration: mediaDuration,
        title: mediaTitle ?? '',
        artist: mediaArtist ?? '',
        artUri: (mediaArtUrl != null && mediaArtUrl.startsWith('http'))
            ? Uri.tryParse(mediaArtUrl)
            : null,
      );

  @override
  Future<void> play() => _handler.play();

  @override
  Future<void> pause() => _handler.pause();

  @override
  Future<void> stop() => _handler.stop();

  @override
  Future<void> seek(Duration position) => _handler.seek(position);

  @override
  Future<void> setSpeed(double speed) => _handler.setSpeed(speed);

  /// 空操作：后台媒体会话与 App 同生命周期，由系统管理释放。
  @override
  Future<void> dispose() async {}

  @override
  Stream<void> get skipToNextRequests => _handler.skipNextRequests;

  @override
  Stream<void> get skipToPreviousRequests => _handler.skipPrevRequests;
}
