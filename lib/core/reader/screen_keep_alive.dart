import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 屏幕防锁屏/常亮服务抽象（阅读页进入时启用，退出时务必释放）。
abstract class ScreenKeepAliveService {
  Future<void> setEnabled(bool enabled);
}

/// 通过 Android 原生 `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON` 控制屏幕常亮。
class PlatformScreenKeepAliveService implements ScreenKeepAliveService {
  const PlatformScreenKeepAliveService();

  static const MethodChannel _channel = MethodChannel('org.hancel.echo/wakelock');

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', <String, dynamic>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // 单元测试或非 Android 桌面环境无此通道时静默忽略。
    } catch (_) {}
  }
}

final Provider<ScreenKeepAliveService> screenKeepAliveServiceProvider =
    Provider<ScreenKeepAliveService>(
      (ref) => const PlatformScreenKeepAliveService(),
    );
