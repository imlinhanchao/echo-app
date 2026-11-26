import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/standalone_config_store.dart';
import '../tts/tts_model_catalog.dart';
import 'update_models.dart';

/// 检查更新核心服务
class UpdateService {
  UpdateService({
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 10),
              ),
            );

  final Dio _dio;

  static const String repo = 'imlinhanchao/echo-app';
  static const String githubApiLatest =
      'https://api.github.com/repos/$repo/releases/latest';
  static const String githubApiList =
      'https://api.github.com/repos/$repo/releases?per_page=10';
  static const String githubReleasesWeb =
      'https://github.com/$repo/releases';

  /// 探测用户 IP 所属国家代码（返回两位大写字母，如 "CN", "US"；探测失败返回 null）
  Future<String?> detectCountryCode() async {
    final apis = <String>[
      'https://api.country.is/',
      'https://ipwho.is/',
    ];

    for (final url in apis) {
      try {
        final res = await _dio.get<dynamic>(url);
        if (res.statusCode == 200 && res.data != null) {
          final data = res.data;
          Map<String, dynamic>? map;
          if (data is Map<String, dynamic>) {
            map = data;
          } else if (data is String) {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) map = decoded;
          }
          if (map != null) {
            final country =
                (map['country'] ?? map['country_code'] ?? '') as String;
            final clean = country.trim().toUpperCase();
            if (clean.length == 2) {
              return clean;
            }
          }
        }
      } catch (_) {
        // 尝试备用 IP 查询端点
      }
    }
    return null;
  }

  /// 获取最新 Release 数据
  Future<Map<String, dynamic>?> fetchLatestReleaseRaw() async {
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'EchoApp-UpdateChecker',
    };

    // 优先通过 API_LATEST 获取
    try {
      final res = await _dio.get<dynamic>(
        githubApiLatest,
        options: Options(headers: headers),
      );
      if (res.statusCode == 200 && res.data != null) {
        if (res.data is Map<String, dynamic>) {
          return res.data as Map<String, dynamic>;
        } else if (res.data is String) {
          final decoded = jsonDecode(res.data as String);
          if (decoded is Map<String, dynamic>) return decoded;
        }
      }
    } catch (e) {
      // 404 或限流时尝试 fallback 列表
    }

    // Fallback: 获取 releases 列表的第一条非草稿
    try {
      final listRes = await _dio.get<dynamic>(
        githubApiList,
        options: Options(headers: headers),
      );
      if (listRes.statusCode == 200 && listRes.data != null) {
        List<dynamic>? list;
        if (listRes.data is List<dynamic>) {
          list = listRes.data as List<dynamic>;
        } else if (listRes.data is String) {
          final decoded = jsonDecode(listRes.data as String);
          if (decoded is List<dynamic>) list = decoded;
        }
        if (list != null && list.isNotEmpty) {
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              final isDraft = item['draft'] as bool? ?? false;
              if (!isDraft) return item;
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// 检查更新核心方法
  Future<AppUpdateInfo> checkForUpdates({
    required String currentVersion,
    required StandaloneConfig config,
    String? explicitCountryCode,
  }) async {
    final raw = await fetchLatestReleaseRaw();
    if (raw == null) {
      throw Exception('无法获取版本信息，请检查网络或稍后重试');
    }

    final tagName = (raw['tag_name'] as String? ?? '').trim();
    final releaseTitle = (raw['name'] as String? ?? tagName).trim();
    final releaseNotes = (raw['body'] as String? ?? '').trim();
    final publishedAt = (raw['published_at'] as String? ?? '').trim();
    final htmlUrl = (raw['html_url'] as String? ?? githubReleasesWeb).trim();

    final rawAssets = raw['assets'] as List<dynamic>? ?? <dynamic>[];
    final allAssets = <ReleaseAssetInfo>[];
    for (final a in rawAssets) {
      if (a is Map<String, dynamic>) {
        allAssets.add(ReleaseAssetInfo.fromJson(a));
      }
    }

    final recommended = pickRecommendedAsset(allAssets);

    // 比较版本：latestVersion > currentVersion
    final latestVersionClean =
        tagName.startsWith('v') || tagName.startsWith('V')
            ? tagName.substring(1)
            : tagName;
    final currentVersionClean =
        currentVersion.startsWith('v') || currentVersion.startsWith('V')
            ? currentVersion.substring(1)
            : currentVersion;

    final hasUpdate =
        compareSemanticVersions(latestVersionClean, currentVersionClean) > 0;

    // 探测 IP 归属地（若配置为 auto 模式）
    final mirrorMode = UpdateMirrorMode.fromId(config.updateMirrorMode);
    String? detectedCountry;
    if (mirrorMode == UpdateMirrorMode.auto) {
      detectedCountry = explicitCountryCode ?? await detectCountryCode();
    }

    final effectiveUrl = resolveDownloadUrl(
      rawUrl: recommended?.browserDownloadUrl ?? htmlUrl,
      mode: mirrorMode,
      detectedCountryCode: detectedCountry,
      customPrefix: config.customUpdateMirrorPrefix,
    );

    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: tagName.isNotEmpty ? tagName : latestVersionClean,
      hasUpdate: hasUpdate,
      releaseTitle: releaseTitle,
      releaseNotes: releaseNotes,
      publishedAt: publishedAt,
      htmlUrl: htmlUrl,
      recommendedAsset: recommended,
      allAssets: allAssets,
      detectedCountryCode: detectedCountry,
      appliedMirrorId: _computeAppliedMirrorId(mirrorMode, detectedCountry),
      effectiveDownloadUrl: effectiveUrl,
    );
  }

  /// 计算实际生效的镜像类型标识
  static String _computeAppliedMirrorId(
    UpdateMirrorMode mode,
    String? detectedCountry,
  ) {
    if (mode == UpdateMirrorMode.auto) {
      final isCn = (detectedCountry ?? '').toUpperCase() == 'CN';
      return isCn ? 'auto_cn (ghfast)' : 'auto_global (github)';
    }
    return mode.id;
  }

  /// 解析最终下载 URL
  static String resolveDownloadUrl({
    required String rawUrl,
    required UpdateMirrorMode mode,
    String? detectedCountryCode,
    String? customPrefix,
  }) {
    if (rawUrl.isEmpty) return githubReleasesWeb;

    // 非 GitHub Release 下载直链，不作前缀替换
    if (!rawUrl.startsWith('https://github.com/') ||
        !rawUrl.contains('/releases/download/')) {
      return rawUrl;
    }

    switch (mode) {
      case UpdateMirrorMode.auto:
        final isCn = (detectedCountryCode ?? '').toUpperCase() == 'CN';
        if (isCn) {
          return 'https://ghfast.top/$rawUrl';
        }
        return rawUrl;
      case UpdateMirrorMode.ghfast:
        return 'https://ghfast.top/$rawUrl';
      case UpdateMirrorMode.ghProxy:
        return 'https://gh-proxy.com/$rawUrl';
      case UpdateMirrorMode.github:
        return rawUrl;
      case UpdateMirrorMode.custom:
        final prefix = (customPrefix ?? '').trim();
        if (prefix.isEmpty) return rawUrl;
        final normalized = prefix.endsWith('/') ? prefix : '$prefix/';
        return '$normalized$rawUrl';
    }
  }
}

final Provider<UpdateService> updateServiceProvider =
    Provider<UpdateService>((ref) => UpdateService());
