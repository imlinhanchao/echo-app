import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 亮/暗模式控制（dark-first：默认深色，听读产品的品牌基准态）。
///
/// ValueNotifier 供 MaterialApp 直接监听（无需 Riverpod 耦合），
/// 偏好持久化到安全存储键 `echo_dark_mode`。
abstract final class ThemeModeController {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _key = 'echo_dark_mode';
  static final ValueNotifier<bool> darkMode = ValueNotifier<bool>(true);

  /// 启动时恢复偏好（存储不可用时静默保持默认深色）。
  static Future<void> init() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == 'false') darkMode.value = false;
    } catch (_) {
      // 保持默认深色。
    }
  }

  static Future<void> toggle() async {
    darkMode.value = !darkMode.value;
    try {
      await _storage.write(key: _key, value: darkMode.value.toString());
    } catch (_) {
      // 持久化失败不影响本次会话切换。
    }
  }
}
