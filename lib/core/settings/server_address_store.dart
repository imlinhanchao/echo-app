import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 构建期默认服务地址（`--dart-define=ECHO_BASE_URL=...`）。
///
/// 用户可在登录页 / 我的页的「服务地址」里覆盖它；覆盖值持久化到安全存储，
/// 启动时经 [ServerAddressStore.init] 恢复。
const String kEchoDefaultBaseUrl = String.fromEnvironment(
  'ECHO_BASE_URL',
  defaultValue: 'http://127.0.0.1:8090',
);

/// 服务地址设置与历史记录。
///
/// - 当前地址：安全存储 `echo_server_url`；未设置时回落到 [kEchoDefaultBaseUrl]；
/// - 历史地址：安全存储 `echo_server_history`（JSON 数组，最近使用优先，最多
///   [maxHistory] 条，自动去重）；
/// - 存储不可用（widget 测试 / 桌面等）时静默使用默认值，不阻塞启动。
///
/// 地址一律经 [normalize] 规范化：省略 scheme 时补 `http://`、去掉尾部斜杠。
abstract final class ServerAddressStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _currentKey = 'echo_server_url';
  static const String _historyKey = 'echo_server_history';

  /// 历史地址上限。
  static const int maxHistory = 8;

  /// 当前服务地址（规范化后）。UI 用 ValueListenableBuilder 监听。
  static final ValueNotifier<String> current = ValueNotifier<String>(
    kEchoDefaultBaseUrl,
  );

  /// 历史地址，最近使用在前。
  static final ValueNotifier<List<String>> history =
      ValueNotifier<List<String>>(const <String>[]);

  /// 启动时恢复当前地址与历史记录。
  static Future<void> init() async {
    try {
      final rawCurrent = await _storage.read(key: _currentKey);
      final restored = normalize(rawCurrent);
      if (restored != null) current.value = restored;
      final rawHistory = await _storage.read(key: _historyKey);
      var restoredHistory = parseHistory(rawHistory);
      // 老版本（无历史记录）升级后，把当前地址补进历史。
      if (restoredHistory.isEmpty || !restoredHistory.contains(current.value)) {
        restoredHistory = upsert(restoredHistory, current.value);
      }
      history.value = restoredHistory;
    } catch (_) {
      // 存储不可用：使用构建期默认地址。
    }
  }

  /// 切换当前服务地址；返回是否真的发生了变化。
  ///
  /// 内存状态同步生效，持久化在后台完成（不阻塞 UI；无安全存储插件的
  /// 测试环境里也不会挂起调用方）。
  static Future<bool> setCurrent(String raw) async {
    final normalized = normalize(raw);
    if (normalized == null) return false;
    final changed = normalized != current.value;
    current.value = normalized;
    history.value = upsert(history.value, normalized);
    unawaited(_persist(normalized, history.value));
    return changed;
  }

  static Future<void> _persist(String address, List<String> addresses) async {
    try {
      await _storage.write(key: _currentKey, value: address);
      await _storage.write(key: _historyKey, value: jsonEncode(addresses));
    } catch (_) {
      // 持久化失败不影响本次会话使用新地址。
    }
  }

  /// 从历史记录里移除一条（不影响当前地址）。
  static Future<void> removeHistory(String raw) async {
    final normalized = normalize(raw) ?? raw;
    final next = history.value
        .where((address) => address != normalized)
        .toList();
    if (next.length == history.value.length) return;
    history.value = next;
    try {
      await _storage.write(key: _historyKey, value: jsonEncode(next));
    } catch (_) {
      // 持久化失败不影响本次会话。
    }
  }

  /// 规范化服务地址；非法返回 null。
  ///
  /// 允许 `192.168.50.200:8090`、`http://host:8090/`、`https://host/echo`
  /// 等形式；返回 `http://192.168.50.200:8090`、`http://host:8090`、
  /// `https://host/echo`。
  static String? normalize(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) return null;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://$host$port$path';
  }

  /// 把 [address] 放到历史最前（去重、截断到 [maxHistory]）。
  static List<String> upsert(List<String> addresses, String address) {
    final next = <String>[
      address,
      ...addresses.where((existing) => existing != address),
    ];
    return next.length > maxHistory ? next.sublist(0, maxHistory) : next;
  }

  /// 解析持久化的历史 JSON；坏数据一律忽略。
  static List<String> parseHistory(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .whereType<String>()
          .map<String?>((value) => normalize(value))
          .whereType<String>()
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }
}
