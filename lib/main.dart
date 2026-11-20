import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api/models.dart';
import 'core/audio/audio_service_engine.dart';
import 'core/settings/theme_mode_controller.dart';
import 'design/echo_theme.dart';
import 'design/echo_tokens.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_page.dart';
import 'features/shell/echo_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 后台媒体会话（锁屏/通知栏播控）；桌面/测试等平台自动回退 just_audio。
  await AudioServiceEngine.tryInit();
  // 恢复亮/暗偏好（dark-first，默认深色）。
  await ThemeModeController.init();
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
    return MaterialApp(
      title: 'Echo · 回声',
      debugShowCheckedModeBanner: false,
      theme: lightTheme ?? theme,
      darkTheme: theme,
      themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
      home: home ?? const AuthGate(),
    );
  }
}

/// 根据认证状态切换：启动恢复中 / 登录 / 已登录书架主界面。
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return switch (auth) {
      AuthLoading() => const _Splash(),
      AuthLoggedOut(:final reason) => LoginPage(initialError: reason),
      AuthLoggedIn(:final user) => EchoHome(user: user),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Echo',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: tokens.primary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),
            CircularProgressIndicator(color: tokens.primary),
          ],
        ),
      ),
    );
  }
}

/// 已登录根视图：委托给 [EchoShell]（4-Tab：书架/发现/任务/我的 + 迷你播放条）。
class EchoHome extends StatelessWidget {
  const EchoHome({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context) => EchoShell(key: EchoShell.shellKey, user: user);
}
