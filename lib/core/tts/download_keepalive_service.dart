import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 端侧模型下载前台保活抽象（Android 通过前台通知 + WakeLock/WifiLock 防止锁屏断流）。
abstract class DownloadKeepAliveService {
  Future<void> startOrUpdate({
    required String title,
    required String text,
    int progress = 0,
    int max = 100,
  });

  Future<void> stop();
}

/// 基于 Android MethodChannel `org.hancel.echo/download_keepalive` 的生产保活实现。
class PlatformDownloadKeepAliveService implements DownloadKeepAliveService {
  const PlatformDownloadKeepAliveService();

  static const MethodChannel _channel = MethodChannel(
    'org.hancel.echo/download_keepalive',
  );

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
    int progress = 0,
    int max = 100,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startOrUpdate', <String, dynamic>{
        'title': title,
        'text': text,
        'progress': progress,
        'max': max,
      });
    } catch (_) {
      // 测试环境或系统受限时静默忽略，不阻塞下载流程
    }
  }

  @override
  Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

/// 空实现：用于纯单元测试或无平台通道场景。
class NoopDownloadKeepAliveService implements DownloadKeepAliveService {
  const NoopDownloadKeepAliveService();

  @override
  Future<void> startOrUpdate({
    required String title,
    required String text,
    int progress = 0,
    int max = 100,
  }) async {}

  @override
  Future<void> stop() async {}
}
