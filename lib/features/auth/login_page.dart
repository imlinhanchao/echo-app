import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/server_address_store.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../settings/server_address_page.dart';
import 'auth_controller.dart';
import 'register_page.dart';

/// 登录页展示用：去掉 scheme，让「服务器：host:port」保持一行。
String _shortAddress(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return address;
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.host}$port${uri.path}';
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.initialError});

  /// 服务端原因（如会话过期），展示在表单顶部。
  final String? initialError;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref
        .read(authControllerProvider.notifier)
        .login(_emailController.text.trim(), _passwordController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: const Key('login_page'),
      backgroundColor: tokens.surfaceBase,
      body: EchoAmbientBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: EchoMetrics.space3,
                vertical: EchoMetrics.space4,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部品牌声纹徽章（与启动加载页视觉一脉相承）
                      Center(
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                tokens.primary,
                                const Color(0xFF8B5CF6),
                              ],
                            ),
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: isDark ? 0.28 : 0.45,
                              ),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: tokens.primary.withValues(
                                  alpha: isDark ? 0.42 : 0.28,
                                ),
                                blurRadius: 28,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.graphic_eq_rounded,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),
                      const SizedBox(height: EchoMetrics.space2),
                      ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: isDark
                              ? [Colors.white, const Color(0xFFC7D2FE)]
                              : [const Color(0xFF0F172A), tokens.primary],
                        ).createShader(bounds),
                        child: Text(
                          '回声',
                          key: const Key('login_title'),
                          textAlign: TextAlign.center,
                          style: textTheme.displaySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '听书 · 看书 · 转有声书',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: tokens.textSecondary,
                          letterSpacing: 1.8,
                        ),
                      ),
                      const SizedBox(height: EchoMetrics.space2),

                      // 服务地址设置胶囊：登录前即可切换服务器
                      ValueListenableBuilder<String>(
                        valueListenable: ServerAddressStore.current,
                        builder: (context, address, _) => Center(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: const Key('login_server_settings'),
                              borderRadius: BorderRadius.circular(999),
                              onTap: _busy
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const ServerAddressPage(),
                                      ),
                                    ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: tokens.surfaceElevated.withValues(
                                    alpha: isDark ? 0.72 : 0.9,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.10)
                                        : tokens.surfaceSubtle,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.dns_outlined,
                                      size: 15,
                                      color: tokens.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        '服务器：${_shortAddress(address)} · 设置',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodySmall?.copyWith(
                                          color: tokens.textSecondary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 15,
                                      color: tokens.textDisabled,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: EchoMetrics.space3),

                      // 玻璃拟态高光描边登录卡片
                      Container(
                        padding: const EdgeInsets.all(EchoMetrics.space3),
                        decoration: echoElevatedCardDecoration(
                          context,
                          radius: 22,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              key: const Key('login_email'),
                              controller: _emailController,
                              decoration: const InputDecoration(
                                labelText: '邮箱',
                                hintText: 'you@example.com',
                                prefixIcon: Icon(Icons.mail_outline),
                              ),
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.email],
                              textInputAction: TextInputAction.next,
                              validator: (v) {
                                final value = v?.trim() ?? '';
                                if (value.isEmpty) return '请输入邮箱';
                                if (!value.contains('@')) return '邮箱格式不正确';
                                return null;
                              },
                            ),
                            const SizedBox(height: EchoMetrics.space2),
                            TextFormField(
                              key: const Key('login_password'),
                              controller: _passwordController,
                              decoration: InputDecoration(
                                labelText: '密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                              obscureText: _obscurePassword,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) {
                                if (!_busy) _submit();
                              },
                              validator: (v) =>
                                  (v == null || v.isEmpty) ? '请输入密码' : null,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: EchoMetrics.space2),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: tokens.error.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: tokens.error.withValues(alpha: 0.30),
                                  ),
                                ),
                                child: Text(
                                  _error!,
                                  key: const Key('login_error'),
                                  style: textTheme.bodySmall?.copyWith(
                                    color: tokens.error,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: EchoMetrics.space3),
                            // 靛蓝紫渐变主登录按钮（与全站 EchoPrimaryButton 一致）
                            EchoPrimaryButton(
                              key: const Key('login_submit'),
                              label: '登录',
                              busy: _busy,
                              onPressed: _busy ? null : _submit,
                            ),
                            const SizedBox(height: EchoMetrics.space1),
                            TextButton(
                              key: const Key('login_to_register'),
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => const RegisterPage(),
                                      ),
                                    ),
                              child: Text(
                                '还没有账号？创建账号',
                                style: TextStyle(color: tokens.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
