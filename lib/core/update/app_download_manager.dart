import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import '../tts/download_keepalive_service.dart';

/// 应用后台静默下载进度状态
enum AppDownloadStatus {
  idle,
  downloading,
  completed,
  failed,
}

@immutable
class AppDownloadState {
  const AppDownloadState({
    this.status = AppDownloadStatus.idle,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.progress = 0.0,
    this.savePath,
    this.error,
    this.downloadingVersion,
  });

  final AppDownloadStatus status;
  final int receivedBytes;
  final int totalBytes;
  final double progress;
  final String? savePath;
  final String? error;
  final String? downloadingVersion;

  AppDownloadState copyWith({
    AppDownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    double? progress,
    String? savePath,
    String? error,
    String? downloadingVersion,
  }) {
    return AppDownloadState(
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      progress: progress ?? this.progress,
      savePath: savePath ?? this.savePath,
      error: error ?? this.error,
      downloadingVersion: downloadingVersion ?? this.downloadingVersion,
    );
  }
}

/// 应用安装包静默后台下载与通知保活管理器
class AppDownloadManager extends StateNotifier<AppDownloadState> {
  AppDownloadManager({
    Dio? dio,
    DownloadKeepAliveService? keepAliveService,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(minutes: 30),
                followRedirects: true,
                maxRedirects: 8,
              ),
            ),
        _keepAlive = keepAliveService ?? const PlatformDownloadKeepAliveService(),
        super(const AppDownloadState());

  final Dio _dio;
  final DownloadKeepAliveService _keepAlive;
  CancelToken? _cancelToken;

  /// 开始静默下载更新包
  Future<void> startDownload({
    required String downloadUrl,
    required String version,
    String? fileName,
  }) async {
    if (state.status == AppDownloadStatus.downloading) return;

    _cancelToken?.cancel();
    _cancelToken = CancelToken();

    final actualFileName = fileName ??
        (downloadUrl.contains('/')
            ? downloadUrl.split('/').last.split('?').first
            : 'echo-$version.apk');

    final dir = await _resolveDownloadDirectory();
    final targetPath = '${dir.path}/$actualFileName';
    final tempPath = '$targetPath.downloading';

    state = AppDownloadState(
      status: AppDownloadStatus.downloading,
      receivedBytes: 0,
      totalBytes: 0,
      progress: 0.0,
      savePath: targetPath,
      downloadingVersion: version,
    );

    // 启动前台消息保活通知（锁屏与切后台不被系统挂起）
    await _keepAlive.startOrUpdate(
      title: '正在下载新版本 $version',
      text: '准备下载更新安装包...',
      progress: 0,
      max: 100,
    );

    int lastReportedPercent = -1;

    try {
      final tempFile = File(tempPath);
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }

      await _dio.download(
        downloadUrl,
        tempPath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final pct = (received / total).clamp(0.0, 1.0);
            final intPct = (pct * 100).toInt();

            state = state.copyWith(
              receivedBytes: received,
              totalBytes: total,
              progress: pct,
            );

            if (intPct != lastReportedPercent) {
              lastReportedPercent = intPct;
              final mbText =
                  '${(received / (1024 * 1024)).toStringAsFixed(1)}MB / ${(total / (1024 * 1024)).toStringAsFixed(1)}MB';
              _keepAlive.startOrUpdate(
                title: '正在下载新版本 $version',
                text: '下载进度 $intPct% ($mbText)',
                progress: intPct,
                max: 100,
              );
            }
          } else {
            state = state.copyWith(
              receivedBytes: received,
              totalBytes: 0,
              progress: 0.0,
            );
          }
        },
      );

      // 下载成功：重命名为最终文件
      final targetFile = File(targetPath);
      if (targetFile.existsSync()) {
        try {
          targetFile.deleteSync();
        } catch (_) {}
      }
      File(tempPath).renameSync(targetPath);

      state = state.copyWith(
        status: AppDownloadStatus.completed,
        progress: 1.0,
      );

      // 通知栏提示完成
      await _keepAlive.startOrUpdate(
        title: '新版本 $version 下载完成',
        text: '点击即可安装',
        progress: 100,
        max: 100,
      );
      // 延时关闭保活前台服务
      Future.delayed(const Duration(seconds: 3), () {
        _keepAlive.stop();
      });

      // 自动唤起安装
      await installApk(targetPath);
    } catch (e) {
      if (_cancelToken?.isCancelled ?? false) {
        state = const AppDownloadState();
      } else {
        state = state.copyWith(
          status: AppDownloadStatus.failed,
          error: e.toString(),
        );
        await _keepAlive.startOrUpdate(
          title: '新版本 $version 下载中断',
          text: '下载失败，请点击重试',
          progress: 0,
          max: 100,
        );
        Future.delayed(const Duration(seconds: 4), () {
          _keepAlive.stop();
        });
      }
    }
  }

  /// 取消当前下载
  Future<void> cancelDownload() async {
    _cancelToken?.cancel();
    _cancelToken = null;
    await _keepAlive.stop();
    state = const AppDownloadState();
  }

  /// 唤起系统安装 APK
  static Future<OpenResult> installApk(String filePath) async {
    return OpenFilex.open(
      filePath,
      type: 'application/vnd.android.package-archive',
    );
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (!kIsWeb && Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    }
    return getApplicationDocumentsDirectory();
  }
}

final StateNotifierProvider<AppDownloadManager, AppDownloadState>
appDownloadManagerProvider =
    StateNotifierProvider<AppDownloadManager, AppDownloadState>(
  (ref) => AppDownloadManager(),
);
