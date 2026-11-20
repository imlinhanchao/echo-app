import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/api/models.dart';
import 'design/echo_theme.dart';
import 'design/echo_tokens.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_page.dart';
import 'features/library/library_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 深色优先（dark-first）：听读产品的主场景是夜间与沉浸。
  final tokens = await EchoTokens.load(Brightness.dark);
  runApp(
    ProviderScope(
      child: EchoApp(theme: buildEchoTheme(Brightness.dark, tokens)),
    ),
  );
}

class EchoApp extends StatelessWidget {
  const EchoApp({super.key, required this.theme, this.home});

  final ThemeData theme;

  /// 测试可注入确定性首页；缺省走 [AuthGate]。
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Echo · 回声',
      debugShowCheckedModeBanner: false,
      theme: theme,
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

/// 已登录根视图：委托给 [LibraryShell]（书架 + 有声书 + 分块播放器）。
class EchoHome extends StatelessWidget {
  const EchoHome({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context) => LibraryShell(user: user);
}
