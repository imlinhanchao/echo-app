import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_source_models.dart';

// ---------------------------------------------------------------------------
// Tier 1: Pure Rule Definitions & Subscriptions Registry
// ---------------------------------------------------------------------------

abstract class BookSourceRegistryStore {
  Future<BookSourceRegistryData> read();
  Future<void> write(BookSourceRegistryData data);
  Future<void> clear();
}

class MemoryBookSourceRegistryStore implements BookSourceRegistryStore {
  MemoryBookSourceRegistryStore([BookSourceRegistryData? initial])
    : _data = initial ?? const BookSourceRegistryData();

  BookSourceRegistryData _data;

  @override
  Future<BookSourceRegistryData> read() async => _data;

  @override
  Future<void> write(BookSourceRegistryData data) async {
    _data = data;
  }

  @override
  Future<void> clear() async {
    _data = const BookSourceRegistryData();
  }
}

class FileBookSourceRegistryStore implements BookSourceRegistryStore {
  FileBookSourceRegistryStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  BookSourceRegistryData? _memoryFallback;

  Future<File?> _resolveFile() async {
    try {
      final root = await _directoryProvider();
      final dir = Directory(p.join(root.path, 'book_sources'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File(p.join(dir.path, 'registry.json'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<BookSourceRegistryData> read() async {
    final file = await _resolveFile();
    if (file == null) return _memoryFallback ?? const BookSourceRegistryData();
    try {
      if (!await file.exists()) {
        return _memoryFallback ?? const BookSourceRegistryData();
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return _memoryFallback ?? const BookSourceRegistryData();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _memoryFallback ?? const BookSourceRegistryData();
      }
      final parsed = BookSourceRegistryData.fromJson(
        decoded.cast<String, dynamic>(),
      );
      _memoryFallback = parsed;
      return parsed;
    } catch (_) {
      return _memoryFallback ?? const BookSourceRegistryData();
    }
  }

  @override
  Future<void> write(BookSourceRegistryData data) async {
    _memoryFallback = data;
    final file = await _resolveFile();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(data.toJson()));
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    _memoryFallback = const BookSourceRegistryData();
    final file = await _resolveFile();
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Tier 2: User Overlays (enabled, preferred/custom domains, proxy prefix, active)
// ---------------------------------------------------------------------------

abstract class BookSourceUserStateStore {
  Future<BookSourceUserState> read();
  Future<void> write(BookSourceUserState state);
  Future<void> clear();
}

class MemoryBookSourceUserStateStore implements BookSourceUserStateStore {
  MemoryBookSourceUserStateStore([BookSourceUserState? initial])
    : _state = initial ?? const BookSourceUserState();

  BookSourceUserState _state;

  @override
  Future<BookSourceUserState> read() async => _state;

  @override
  Future<void> write(BookSourceUserState state) async {
    _state = state;
  }

  @override
  Future<void> clear() async {
    _state = const BookSourceUserState();
  }
}

class FileBookSourceUserStateStore implements BookSourceUserStateStore {
  FileBookSourceUserStateStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  BookSourceUserState? _memoryFallback;

  Future<File?> _resolveFile() async {
    try {
      final root = await _directoryProvider();
      final dir = Directory(p.join(root.path, 'book_sources'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return File(p.join(dir.path, 'overlays.json'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<BookSourceUserState> read() async {
    final file = await _resolveFile();
    if (file == null) return _memoryFallback ?? const BookSourceUserState();
    try {
      if (!await file.exists()) {
        return _memoryFallback ?? const BookSourceUserState();
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return _memoryFallback ?? const BookSourceUserState();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _memoryFallback ?? const BookSourceUserState();
      }
      final parsed = BookSourceUserState.fromJson(
        decoded.cast<String, dynamic>(),
      );
      _memoryFallback = parsed;
      return parsed;
    } catch (_) {
      return _memoryFallback ?? const BookSourceUserState();
    }
  }

  @override
  Future<void> write(BookSourceUserState state) async {
    _memoryFallback = state;
    final file = await _resolveFile();
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(state.toJson()));
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    _memoryFallback = const BookSourceUserState();
    final file = await _resolveFile();
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Tier 3: Secure Credential Storage (Isolated per source_id)
// ---------------------------------------------------------------------------

abstract class BookSourceCredentialStore {
  Future<BookSourceCredentials?> read(String sourceId);
  Future<Map<String, BookSourceCredentials>> readAll();
  Future<void> write(BookSourceCredentials credentials);
  Future<void> delete(String sourceId);
}

class MemoryBookSourceCredentialStore implements BookSourceCredentialStore {
  MemoryBookSourceCredentialStore([
    Map<String, BookSourceCredentials>? initial,
  ]) : _data = Map<String, BookSourceCredentials>.of(initial ?? const {});

  final Map<String, BookSourceCredentials> _data;

  @override
  Future<BookSourceCredentials?> read(String sourceId) async => _data[sourceId];

  @override
  Future<Map<String, BookSourceCredentials>> readAll() async =>
      Map<String, BookSourceCredentials>.unmodifiable(_data);

  @override
  Future<void> write(BookSourceCredentials credentials) async {
    _data[credentials.sourceId] = credentials;
  }

  @override
  Future<void> delete(String sourceId) async {
    _data.remove(sourceId);
  }
}

class SecureBookSourceCredentialStore implements BookSourceCredentialStore {
  SecureBookSourceCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _storageKey = 'echo_book_source_creds_v1';
  Map<String, BookSourceCredentials>? _memoryFallback;

  @override
  Future<Map<String, BookSourceCredentials>> readAll() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null || raw.isEmpty) {
        return _memoryFallback ?? const <String, BookSourceCredentials>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _memoryFallback ?? const <String, BookSourceCredentials>{};
      }
      final result = <String, BookSourceCredentials>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty || entry.value is! Map) continue;
        result[key] = BookSourceCredentials.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
      }
      _memoryFallback = result;
      return Map<String, BookSourceCredentials>.unmodifiable(result);
    } catch (_) {
      return _memoryFallback ?? const <String, BookSourceCredentials>{};
    }
  }

  @override
  Future<BookSourceCredentials?> read(String sourceId) async {
    final all = await readAll();
    return all[sourceId];
  }

  @override
  Future<void> write(BookSourceCredentials credentials) async {
    final all = Map<String, BookSourceCredentials>.of(await readAll());
    all[credentials.sourceId] = credentials;
    _memoryFallback = all;
    await _saveAll(all);
  }

  @override
  Future<void> delete(String sourceId) async {
    final all = Map<String, BookSourceCredentials>.of(await readAll());
    all.remove(sourceId);
    _memoryFallback = all;
    await _saveAll(all);
  }

  Future<void> _saveAll(Map<String, BookSourceCredentials> all) async {
    try {
      final encoded = <String, dynamic>{
        for (final entry in all.entries) entry.key: entry.value.toJson(),
      };
      await _storage.write(key: _storageKey, value: jsonEncode(encoded));
    } catch (_) {}
  }
}

final Provider<BookSourceRegistryStore> bookSourceRegistryStoreProvider =
    Provider<BookSourceRegistryStore>((ref) => FileBookSourceRegistryStore());

final Provider<BookSourceUserStateStore> bookSourceUserStateStoreProvider =
    Provider<BookSourceUserStateStore>((ref) => FileBookSourceUserStateStore());

final Provider<BookSourceCredentialStore> bookSourceCredentialStoreProvider =
    Provider<BookSourceCredentialStore>(
      (ref) => SecureBookSourceCredentialStore(),
    );
