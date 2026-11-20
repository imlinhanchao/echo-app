import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import 'auth_controller.dart';
import 'register_page.dart';

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
    return Scaffold(
      key: const Key('login_page'),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(EchoMetrics.space4),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Echo',
                  key: const Key('login_title'),
                  textAlign: TextAlign.center,
                  style: textTheme.displaySmall
                      ?.copyWith(color: tokens.primary, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: EchoMetrics.space1),
                Text(
                  '回声 · 听看一体书客户端',
                  textAlign: TextAlign.center,
                  style: textTheme.bodyLarge?.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: EchoMetrics.space4),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(EchoMetrics.space3),
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
                          decoration: const InputDecoration(
                            labelText: '密码',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          onFieldSubmitted: (_) {
                            if (!_busy) _submit();
                          },
                          validator: (v) =>
                              (v == null || v.isEmpty) ? '请输入密码' : null,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: EchoMetrics.space2),
                          Text(
                            _error!,
                            key: const Key('login_error'),
                            style: textTheme.bodySmall?.copyWith(color: tokens.error),
                          ),
                        ],
                        const SizedBox(height: EchoMetrics.space3),
                        FilledButton(
                          key: const Key('login_submit'),
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('登录'),
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
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
