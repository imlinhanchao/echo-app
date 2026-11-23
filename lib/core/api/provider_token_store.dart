import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// 本地安全存储的书源凭据（来自 ebook-api `/login` 或 `/seal` 的 AES-256-GCM 密封令牌）。
@immutable
class StoredProviderCredential {
  const StoredProviderCredential({
    required this.providerId,
    required this.credentialToken,
    this.account,
    this.savedAt,
  });

  factory StoredProviderCredential.fromJson(Map<String, dynamic> json) {
    final accJson = json['account'];
    return StoredProviderCredential(
      providerId: json['provider_id'] as String? ?? '',
      credentialToken: json['credential_token'] as String? ?? '',
      account: accJson is Map<String, dynamic>
          ? ProviderAccountInfo.fromJson(accJson)
          : null,
      savedAt: DateTime.tryParse(json['saved_at'] as String? ?? ''),
    );
  }

  final String providerId;
  final String credentialToken;
  final ProviderAccountInfo? account;
  final DateTime? savedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_id': providerId,
    'credential_token': credentialToken,
    if (account != null)
      'account': <String, dynamic>{
        'configured': account!.configured,
        'status': account!.status,
        'email': account!.email,
        'daily_used': account!.dailyUsed,
        'daily_limit': account!.dailyLimit,
        'daily_remaining': account!.dailyRemaining,
        'quota_known': account!.quotaKnown,
        if (account!.lastVerifiedAt != null)
          'last_verified_at': account!.lastVerifiedAt!.toUtc().toIso8601String(),
      },
    'saved_at': (savedAt ?? DateTime.now().toUtc()).toIso8601String(),
  };
}

abstract class ProviderTokenStore {
  Future<StoredProviderCredential?> read(String providerId);
  Future<Map<String, StoredProviderCredential>> readAll();
  Future<void> write(StoredProviderCredential credential);
  Future<void> delete(String providerId);
}

class SecureProviderTokenStore implements ProviderTokenStore {
  SecureProviderTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _indexKey = 'echo_ebook_provider_tokens_v1';

  @override
  Future<Map<String, StoredProviderCredential>> readAll() async {
    try {
      final raw = await _storage.read(key: _indexKey);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      final result = <String, StoredProviderCredential>{};
      for (final entry in decoded.entries) {
        if (entry.value is Map<String, dynamic>) {
          result[entry.key] = StoredProviderCredential.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<StoredProviderCredential?> read(String providerId) async {
    final all = await readAll();
    return all[providerId];
  }

  @override
  Future<void> write(StoredProviderCredential credential) async {
    final all = Map<String, StoredProviderCredential>.of(await readAll());
    all[credential.providerId] = credential;
    await _saveAll(all);
  }

  @override
  Future<void> delete(String providerId) async {
    final all = Map<String, StoredProviderCredential>.of(await readAll());
    all.remove(providerId);
    await _saveAll(all);
  }

  Future<void> _saveAll(Map<String, StoredProviderCredential> all) async {
    final encoded = <String, dynamic>{
      for (final entry in all.entries) entry.key: entry.value.toJson(),
    };
    await _storage.write(key: _indexKey, value: jsonEncode(encoded));
  }
}

class MemoryProviderTokenStore implements ProviderTokenStore {
  final Map<String, StoredProviderCredential> _data = {};

  @override
  Future<StoredProviderCredential?> read(String providerId) async =>
      _data[providerId];

  @override
  Future<Map<String, StoredProviderCredential>> readAll() async =>
      Map.unmodifiable(_data);

  @override
  Future<void> write(StoredProviderCredential credential) async {
    _data[credential.providerId] = credential;
  }

  @override
  Future<void> delete(String providerId) async {
    _data.remove(providerId);
  }
}

final Provider<ProviderTokenStore> providerTokenStoreProvider =
    Provider<ProviderTokenStore>((ref) => SecureProviderTokenStore());
