import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';

import 'core/api/models.dart';
import 'core/audio/audio_service_engine.dart';
import 'core/notes/note_store.dart';
import 'core/offline/offline_store.dart';
import 'core/stats/stats_store.dart';
import 'core/settings/server_address_store.dart';
import 'core/settings/standalone_config_store.dart';
import 'core/settings/theme_mode_controller.dart';
import 'core/tts/tts_model_manager.dart';
import 'design/echo_splash_screen.dart';
import 'design/echo_theme.dart';
import 'design/echo_tokens.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_page.dart';
import 'features/onboarding/onboarding_page.dart';
import 'features/shell/echo_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 后台媒体会话（锁屏/通知栏播控）；桌面/测试等平台自动回退 just_audio。
  await AudioServiceEngine.tryInit();
  // Android 13+ 需要运行时通知权限，否则媒体通知与锁屏控件不显示。
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (_) {
      // 权限申请失败不阻塞启动。
    }
  }
  // 离线目录初始化（播放路径只读缓存值，不触发插件调用）。
  await OfflineFiles.init();
  // 本地收听统计
  await StatsStore.instance.load();
  await NoteStore.instance.load();
  // 恢复亮/暗偏好（dark-first，默认深色）。
  await ThemeModeController.init();
  // 恢复单机版全局配置（ebook-api 地址、引导完成状态、默认 TTS 模型）
  await StandaloneConfigStore.init();
  // 恢复旧服务地址缓存（保留兼容）
  await ServerAddressStore.init();
  // 深色为品牌基准态；亮色为同一 Token 体系的双态对偶。
  final darkTokens = await EchoTokens.load(Brightness.dark);
  final lightTokens = await EchoTokens.load(Brightness.light);
  runApp(
    ProviderScope(
      child: EchoApp(
        theme: buildEchoTheme(Brightness.dark, darkTokens),
        lightTheme: buildEchoTheme(Brightness.light, lightTokens),
        darkModeListenable: ThemeModeController.darkMode,
      ),
    ),
  );
}

class EchoApp extends StatelessWidget {
  const EchoApp({
    super.key,
    required this.theme,
    this.lightTheme,
    this.darkModeListenable,
    this.home,
  });

  /// 深色基准主题（darkTheme）。
  final ThemeData theme;

  /// 亮色对偶主题；提供后经 [darkModeListenable] 切换，仅深色亦可运行。
  final ThemeData? lightTheme;

  final ValueNotifier<bool>? darkModeListenable;

  /// 测试可注入确定性首页；缺省走 [AuthGate]。
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    final listenable = darkModeListenable;
    if (listenable == null) {
      return _materialApp(true);
    }
    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) => _materialApp(listenable.value),
    );
  }

  Widget _materialApp(bool darkMode) {
    return _AppLifecycleBridge(
      child: MaterialApp(
        title: '回声',
        debugShowCheckedModeBanner: false,
        theme: lightTheme ?? theme,
        darkTheme: theme,
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        home: home ?? const StandaloneGate(),
      ),
    );
  }
}

/// 监听应用前后台切换：回到前台时自动继续此前因锁屏/断网中断的模型下载。
class _AppLifecycleBridge extends StatefulWidget {
  const _AppLifecycleBridge({required this.child});

  final Widget child;

  @override
  State<_AppLifecycleBridge> createState() => _AppLifecycleBridgeState();
}

class _AppLifecycleBridgeState extends State<_AppLifecycleBridge>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      try {
        ProviderScope.containerOf(
          context,
          listen: false,
        ).read(ttsModelManagerProvider.notifier).onAppResumed();
      } catch (_) {
        // 无 ProviderScope 的独立外观测试忽略
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 单机版入口网关：首次启动进入两步引导页（配置 ebook-api + 语音模型，均可跳过），
/// 完成后直达书架主界面（无账号登录）。
class StandaloneGate extends ConsumerWidget {
  const StandaloneGate({super.key});

  static const EchoUser localUser = EchoUser(
    id: 0,
    email: '本地书库',
    name: '单机模式',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(standaloneConfigProvider);
    if (!config.onboardingCompleted) {
      return const OnboardingPage();
    }
    return const EchoHome(user: localUser);
  }
}

/// 兼容旧测试的认证网关符号。
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return switch (auth) {
      AuthLoading() => const EchoSplashScreen(),
      AuthLoggedOut(:final reason) => LoginPage(initialError: reason),
      AuthLoggedIn(:final user) => EchoHome(user: user),
    };
  }
}

/// 已登录根视图：委托给 [EchoShell]（4-Tab：书架/发现/任务/我的 + 迷你播放条）。
class EchoHome extends StatelessWidget {
  const EchoHome({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context) =>
      EchoShell(key: EchoShell.shellKey, user: user);
}
