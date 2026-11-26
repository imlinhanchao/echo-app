import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// 升级镜像模式
enum UpdateMirrorMode {
  /// 自动：根据 IP 所属国家/地区自动决定是否走国内加速镜像
  auto('auto', '自动探测（根据 IP 地区）'),

  /// 国内镜像加速
  ghfast('ghfast', 'ghfast.top（国内加速）'),

  /// 国内备用镜像
  ghProxy('ghproxy_com', 'gh-proxy.com（国内加速）'),

  /// GitHub 官方直连
  github('github', 'GitHub 官方直连'),

  /// 自定义加速前缀
  custom('custom', '自定义加速前缀');

  const UpdateMirrorMode(this.id, this.label);
  final String id;
  final String label;

  static UpdateMirrorMode fromId(String? id) {
    for (final mode in UpdateMirrorMode.values) {
      if (mode.id == id) return mode;
    }
    return UpdateMirrorMode.auto;
  }
}

/// 发布版本 Assets 信息
@immutable
class ReleaseAssetInfo {
  const ReleaseAssetInfo({
    required this.name,
    required this.size,
    required this.browserDownloadUrl,
  });

  final String name;
  final int size;
  final String browserDownloadUrl;

  factory ReleaseAssetInfo.fromJson(Map<String, dynamic> json) {
    return ReleaseAssetInfo(
      name: json['name'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      browserDownloadUrl: json['browser_download_url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'browser_download_url': browserDownloadUrl,
  };
}

/// 版本检测结果
@immutable
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseTitle,
    required this.releaseNotes,
    required this.publishedAt,
    required this.htmlUrl,
    required this.recommendedAsset,
    required this.allAssets,
    this.detectedCountryCode,
    this.appliedMirrorId,
    this.effectiveDownloadUrl,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseTitle;
  final String releaseNotes;
  final String publishedAt;
  final String htmlUrl;
  final ReleaseAssetInfo? recommendedAsset;
  final List<ReleaseAssetInfo> allAssets;

  /// 探测到的国家/地区代码（如 "CN"）
  final String? detectedCountryCode;

  /// 实际生效的镜像 ID
  final String? appliedMirrorId;

  /// 根据镜像模式与 IP 决定的最终下载 URL
  final String? effectiveDownloadUrl;

  AppUpdateInfo copyWith({
    String? currentVersion,
    String? latestVersion,
    bool? hasUpdate,
    String? releaseTitle,
    String? releaseNotes,
    String? publishedAt,
    String? htmlUrl,
    ReleaseAssetInfo? recommendedAsset,
    List<ReleaseAssetInfo>? allAssets,
    String? detectedCountryCode,
    String? appliedMirrorId,
    String? effectiveDownloadUrl,
  }) {
    return AppUpdateInfo(
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      hasUpdate: hasUpdate ?? this.hasUpdate,
      releaseTitle: releaseTitle ?? this.releaseTitle,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      publishedAt: publishedAt ?? this.publishedAt,
      htmlUrl: htmlUrl ?? this.htmlUrl,
      recommendedAsset: recommendedAsset ?? this.recommendedAsset,
      allAssets: allAssets ?? this.allAssets,
      detectedCountryCode: detectedCountryCode ?? this.detectedCountryCode,
      appliedMirrorId: appliedMirrorId ?? this.appliedMirrorId,
      effectiveDownloadUrl: effectiveDownloadUrl ?? this.effectiveDownloadUrl,
    );
  }
}

/// 语义化版本对比：返回 1 (v1 > v2), -1 (v1 < v2), 0 (相等)
int compareSemanticVersions(String v1, String v2) {
  List<int> parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    // 截掉 +build 或 -prerelease
    final plusIdx = s.indexOf('+');
    if (plusIdx != -1) s = s.substring(0, plusIdx);
    final dashIdx = s.indexOf('-');
    if (dashIdx != -1) s = s.substring(0, dashIdx);

    final parts = s.split('.');
    final result = <int>[];
    for (final p in parts) {
      result.add(int.tryParse(p) ?? 0);
    }
    while (result.length < 3) {
      result.add(0);
    }
    return result;
  }

  final p1 = parse(v1);
  final p2 = parse(v2);
  final len = p1.length > p2.length ? p1.length : p2.length;
  for (var i = 0; i < len; i++) {
    final num1 = i < p1.length ? p1[i] : 0;
    final num2 = i < p2.length ? p2[i] : 0;
    if (num1 > num2) return 1;
    if (num1 < num2) return -1;
  }
  return 0;
}

/// 根据平台匹配最佳安装包
ReleaseAssetInfo? pickRecommendedAsset(
  List<ReleaseAssetInfo> assets, {
  bool? isAndroid,
  bool? isWindows,
  bool? isMacos,
  bool? isLinux,
}) {
  if (assets.isEmpty) return null;

  final android = isAndroid ?? (!kIsWeb && Platform.isAndroid);
  final windows = isWindows ?? (!kIsWeb && Platform.isWindows);
  final macos = isMacos ?? (!kIsWeb && Platform.isMacOS);
  final linux = isLinux ?? (!kIsWeb && Platform.isLinux);

  ReleaseAssetInfo? pick(List<RegExp> patterns, [ReleaseAssetInfo? exclude]) {
    for (final reg in patterns) {
      for (final a in assets) {
        if (a == exclude) continue;
        if (reg.hasMatch(a.name)) return a;
      }
    }
    return null;
  }

  if (android) {
    final arm64 = pick([RegExp(r'arm64.*\.apk$', caseSensitive: false)]);
    if (arm64 != null) return arm64;
    return pick([
      RegExp(r'universal.*\.apk$', caseSensitive: false),
      RegExp(r'\.apk$', caseSensitive: false),
    ]);
  } else if (windows) {
    return pick([
      RegExp(r'windows.*\.zip$', caseSensitive: false),
      RegExp(r'win.*\.zip$', caseSensitive: false),
      RegExp(r'\.exe$', caseSensitive: false),
    ]);
  } else if (macos) {
    return pick([
      RegExp(r'macos.*\.dmg$', caseSensitive: false),
      RegExp(r'\.dmg$', caseSensitive: false),
    ]);
  } else if (linux) {
    final linuxAsset = pick([
      RegExp(r'linux.*\.tar\.gz$', caseSensitive: false),
      RegExp(r'\.AppImage$', caseSensitive: false),
      RegExp(r'\.deb$', caseSensitive: false),
    ]);
    if (linuxAsset != null) return linuxAsset;
  }

  // 兜底优先选 apk 或第一个可用文件
  return pick([
    RegExp(r'\.apk$', caseSensitive: false),
    RegExp(r'\.(zip|tar\.gz|dmg|exe)$', caseSensitive: false),
  ]) ?? (assets.isNotEmpty ? assets.first : null);
}
