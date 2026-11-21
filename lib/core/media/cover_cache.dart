import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 封面本地缓存。
///
/// 系统通知/锁屏的媒体卡片需要的是 **MediaSession 里的封面位图**，
/// 而系统取图依赖 MediaItem.artUri。若直接把远端 URL（书源 CDN）给系统，
/// 在部分网络（如国内手机访问境外 CDN）或华为/HarmonyOS 上会取不到图，
/// 表现为「只有展开通知才有封面、锁屏没有封面」。
///
/// 这里先用应用自己的网络栈把封面下载到本地缓存，再把本地文件 URI 交给
/// audio_service，由它在本地读取并写入 MediaSession 元数据（Android 原生
/// 侧会解码成 METADATA_KEY_ALBUM_ART），锁屏与通知栏都能拿到封面。
class CoverCache {
  CoverCache({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Map<String, String> _memory = <String, String>{};

  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/echo_covers');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// 返回本地封面文件的 URI 字符串；失败返回 null（调用方回退远端 URL）。
  Future<String?> resolve(String? url) async {
    if (url == null || url.isEmpty) return null;
    final memo = _memory[url];
    if (memo != null) return memo;

    try {
      final dir = await _cacheDir();
      final name = url.hashCode.toRadixString(16);
      final file = File('${dir.path}/$name.img');
      if (file.existsSync() && await file.length() > 0) {
        final uri = file.uri.toString();
        _memory[url] = uri;
        return uri;
      }
      final response = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
          followRedirects: true,
          validateStatus: (code) => code != null && code >= 200 && code < 400,
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      await file.writeAsBytes(bytes, flush: true);
      final uri = file.uri.toString();
      _memory[url] = uri;
      return uri;
    } catch (e) {
      debugPrint('封面缓存失败（回退远端 URL）：$e');
      return null;
    }
  }
}
