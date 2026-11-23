import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 单机版全局配置（无内置写死服务地址，由首次启动引导或设置页配置）。
@immutable
class StandaloneConfig {
  const StandaloneConfig({
    this.ebookApiBaseUrl = '',
    this.ebookApiKey = '',
    this.onboardingCompleted = false,
    this.activeTtsModelId = '',
    this.activeTtsSpeakerId = 0,
    this.defaultTtsSpeed = 1.0,
    this.ttsDownloadMirror = 'ghfast',
    this.customTtsMirrorPrefix = '',
    this.zipvoiceRefAudioPath = '',
    this.zipvoiceRefText = '',
    this.systemTtsEngine = '',
    this.systemTtsVoice = '',
    this.keepScreenOnWhileReading = true,
  });

  factory StandaloneConfig.fromJson(Map<String, dynamic> json) {
    final legacyPreferCn = json['prefer_cn_mirror'] as bool? ?? true;
    final rawMirror = (json['tts_download_mirror'] as String? ?? '').trim();
    final mirrorId = rawMirror.isNotEmpty
        ? rawMirror
        : (legacyPreferCn ? 'ghfast' : 'github');
    return StandaloneConfig(
      ebookApiBaseUrl: (json['ebook_api_base_url'] as String? ?? '').trim(),
      ebookApiKey: (json['ebook_api_key'] as String? ?? '').trim(),
      onboardingCompleted: json['onboarding_completed'] as bool? ?? false,
      activeTtsModelId: (json['active_tts_model_id'] as String? ?? '').trim(),
      activeTtsSpeakerId:
          (json['active_tts_speaker_id'] as num?)?.toInt() ?? 0,
      defaultTtsSpeed:
          ((json['default_tts_speed'] as num?)?.toDouble() ?? 1.0).clamp(
            0.5,
            2.5,
          ),
      ttsDownloadMirror: mirrorId,
      customTtsMirrorPrefix:
          (json['custom_tts_mirror_prefix'] as String? ?? '').trim(),
      zipvoiceRefAudioPath:
          (json['zipvoice_ref_audio_path'] as String? ?? '').trim(),
      zipvoiceRefText: (json['zipvoice_ref_text'] as String? ?? '').trim(),
      systemTtsEngine: (json['system_tts_engine'] as String? ?? '').trim(),
      systemTtsVoice: (json['system_tts_voice'] as String? ?? '').trim(),
      keepScreenOnWhileReading:
          json['keep_screen_on_while_reading'] as bool? ?? true,
    );
  }

  final String ebookApiBaseUrl;
  final String ebookApiKey;
  final bool onboardingCompleted;
  final String activeTtsModelId;
  final int activeTtsSpeakerId;
  final double defaultTtsSpeed;
  final String ttsDownloadMirror;
  final String customTtsMirrorPrefix;
  final String zipvoiceRefAudioPath;
  final String zipvoiceRefText;
  final String systemTtsEngine;
  final String systemTtsVoice;
  final bool keepScreenOnWhileReading;

  bool get preferCnMirror => ttsDownloadMirror != 'github';

  bool get hasEbookApi => ebookApiBaseUrl.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ebook_api_base_url': ebookApiBaseUrl,
    'ebook_api_key': ebookApiKey,
    'onboarding_completed': onboardingCompleted,
    'active_tts_model_id': activeTtsModelId,
    'active_tts_speaker_id': activeTtsSpeakerId,
    'default_tts_speed': defaultTtsSpeed,
    'tts_download_mirror': ttsDownloadMirror,
    'custom_tts_mirror_prefix': customTtsMirrorPrefix,
    'zipvoice_ref_audio_path': zipvoiceRefAudioPath,
    'zipvoice_ref_text': zipvoiceRefText,
    'system_tts_engine': systemTtsEngine,
    'system_tts_voice': systemTtsVoice,
    'prefer_cn_mirror': preferCnMirror,
    'keep_screen_on_while_reading': keepScreenOnWhileReading,
  };

  StandaloneConfig copyWith({
    String? ebookApiBaseUrl,
    String? ebookApiKey,
    bool? onboardingCompleted,
    String? activeTtsModelId,
    int? activeTtsSpeakerId,
    double? defaultTtsSpeed,
    String? ttsDownloadMirror,
    String? customTtsMirrorPrefix,
    String? zipvoiceRefAudioPath,
    String? zipvoiceRefText,
    String? systemTtsEngine,
    String? systemTtsVoice,
    bool? keepScreenOnWhileReading,
  }) {
    return StandaloneConfig(
      ebookApiBaseUrl: ebookApiBaseUrl ?? this.ebookApiBaseUrl,
      ebookApiKey: ebookApiKey ?? this.ebookApiKey,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      activeTtsModelId: activeTtsModelId ?? this.activeTtsModelId,
      activeTtsSpeakerId: activeTtsSpeakerId ?? this.activeTtsSpeakerId,
      defaultTtsSpeed: defaultTtsSpeed ?? this.defaultTtsSpeed,
      ttsDownloadMirror: ttsDownloadMirror ?? this.ttsDownloadMirror,
      customTtsMirrorPrefix:
          customTtsMirrorPrefix ?? this.customTtsMirrorPrefix,
      zipvoiceRefAudioPath: zipvoiceRefAudioPath ?? this.zipvoiceRefAudioPath,
      zipvoiceRefText: zipvoiceRefText ?? this.zipvoiceRefText,
      systemTtsEngine: systemTtsEngine ?? this.systemTtsEngine,
      systemTtsVoice: systemTtsVoice ?? this.systemTtsVoice,
      keepScreenOnWhileReading:
          keepScreenOnWhileReading ?? this.keepScreenOnWhileReading,
    );
  }
}

/// 标准化 ebook-api URL（去尾部斜杠，缺协议时补 http://）。
String normalizeEbookApiUrl(String raw) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 校验 ebook-api URL 格式合法性，返回 null 表示合法。
String? validateEbookApiUrl(String raw) {
  final normalized = normalizeEbookApiUrl(raw);
  if (normalized.isEmpty) return '请输入 ebook-api 服务地址';
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '请输入合法的 http(s) 地址，例如 http://192.168.1.10:8091';
  }
  return null;
}

abstract class StandaloneConfigStorage {
  Future<StandaloneConfig> read();
  Future<void> write(StandaloneConfig config);
}

class SecureStandaloneConfigStorage implements StandaloneConfigStorage {
  SecureStandaloneConfigStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _key = 'echo_standalone_config_v1';

  @override
  Future<StandaloneConfig> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return const StandaloneConfig();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return StandaloneConfig.fromJson(decoded);
      }
    } catch (_) {
      // 忽略损坏配置，回退默认值。
    }
    return const StandaloneConfig();
  }

  @override
  Future<void> write(StandaloneConfig config) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(config.toJson()));
    } catch (_) {
      // 持久化失败不崩溃。
    }
  }
}

class MemoryStandaloneConfigStorage implements StandaloneConfigStorage {
  MemoryStandaloneConfigStorage([
    StandaloneConfig initial = const StandaloneConfig(),
  ]) : _value = initial;

  StandaloneConfig _value;

  @override
  Future<StandaloneConfig> read() async => _value;

  @override
  Future<void> write(StandaloneConfig config) async {
    _value = config;
  }
}

/// 启动预加载缓存，确保首帧即可决定是否进入引导页。
abstract final class StandaloneConfigStore {
  static StandaloneConfig _cached = const StandaloneConfig();
  static StandaloneConfigStorage _storage = SecureStandaloneConfigStorage();

  static StandaloneConfig get cached => _cached;
  static StandaloneConfigStorage get storage => _storage;

  static Future<void> init({StandaloneConfigStorage? storage}) async {
    if (storage != null) _storage = storage;
    _cached = await _storage.read();
  }

  @visibleForTesting
  static void setForTest(
    StandaloneConfig config, {
    StandaloneConfigStorage? storage,
  }) {
    _cached = config;
    if (storage != null) _storage = storage;
  }
}

class StandaloneConfigController extends StateNotifier<StandaloneConfig> {
  StandaloneConfigController(this._storage, StandaloneConfig initial)
    : super(initial);

  final StandaloneConfigStorage _storage;

  Future<void> _commit(StandaloneConfig next) async {
    state = next;
    StandaloneConfigStore.setForTest(next);
    await _storage.write(next);
  }

  Future<void> setEbookApi({required String baseUrl, String apiKey = ''}) =>
      _commit(
        state.copyWith(
          ebookApiBaseUrl: normalizeEbookApiUrl(baseUrl),
          ebookApiKey: apiKey.trim(),
        ),
      );

  Future<void> clearEbookApi() =>
      _commit(state.copyWith(ebookApiBaseUrl: '', ebookApiKey: ''));

  Future<void> completeOnboarding() =>
      _commit(state.copyWith(onboardingCompleted: true));

  Future<void> setActiveTtsModel(String modelId, {int? speakerId}) => _commit(
    state.copyWith(
      activeTtsModelId: modelId,
      activeTtsSpeakerId: speakerId ?? state.activeTtsSpeakerId,
    ),
  );

  Future<void> setActiveTtsSpeaker(int speakerId) =>
      _commit(state.copyWith(activeTtsSpeakerId: speakerId));

  Future<void> setDefaultTtsSpeed(double speed) =>
      _commit(state.copyWith(defaultTtsSpeed: speed.clamp(0.5, 2.5)));

  Future<void> setTtsDownloadMirror(String mirrorId) =>
      _commit(state.copyWith(ttsDownloadMirror: mirrorId.trim()));

  Future<void> setCustomTtsMirrorPrefix(String prefix) =>
      _commit(state.copyWith(customTtsMirrorPrefix: prefix.trim()));

  Future<void> setZipvoiceReference({
    required String audioPath,
    required String text,
  }) => _commit(
    state.copyWith(
      zipvoiceRefAudioPath: audioPath.trim(),
      zipvoiceRefText: text.trim(),
    ),
  );

  Future<void> setSystemTtsSelection({
    required String enginePackage,
    String? voiceName,
  }) => _commit(
    state.copyWith(
      systemTtsEngine: enginePackage.trim(),
      systemTtsVoice: voiceName?.trim() ?? state.systemTtsVoice,
    ),
  );

  Future<void> setPreferCnMirror(bool prefer) =>
      setTtsDownloadMirror(prefer ? 'ghfast' : 'github');

  Future<void> setKeepScreenOnWhileReading(bool enabled) =>
      _commit(state.copyWith(keepScreenOnWhileReading: enabled));
}

final Provider<StandaloneConfigStorage> standaloneConfigStorageProvider =
    Provider<StandaloneConfigStorage>((ref) => StandaloneConfigStore.storage);

final StateNotifierProvider<StandaloneConfigController, StandaloneConfig>
standaloneConfigProvider =
    StateNotifierProvider<StandaloneConfigController, StandaloneConfig>((ref) {
      return StandaloneConfigController(
        ref.watch(standaloneConfigStorageProvider),
        StandaloneConfigStore.cached,
      );
    });
