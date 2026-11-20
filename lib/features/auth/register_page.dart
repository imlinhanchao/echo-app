import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import 'auth_controller.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
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
        .register(_emailController.text.trim(), _passwordController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 注册成功（状态切换为已登录）时自动回到根路由。
    ref.listen<AuthState>(authControllerProvider, (previous, next) {
      if (next is AuthLoggedIn && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      key: const Key('register_page'),
      appBar: AppBar(title: const Text('创建账号')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(EchoMetrics.space4),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(EchoMetrics.space3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          key: const Key('register_email'),
                          controller: _emailController,
                          decoration: const InputDecoration(
                            labelText: '邮箱',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                          keyboardType: TextInputType.emailAddress,
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
                          key: const Key('register_password'),
                          controller: _passwordController,
                          decoration: const InputDecoration(
                            labelText: '密码',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          obscureText: true,
                          textInputAction: TextInputAction.next,
                          validator: (v) =>
                              (v == null || v.length < 6) ? '密码至少 6 位' : null,
                        ),
                        const SizedBox(height: EchoMetrics.space2),
                        TextFormField(
                          key: const Key('register_confirm'),
                          controller: _confirmController,
                          decoration: const InputDecoration(
                            labelText: '确认密码',
                            prefixIcon: Icon(Icons.lock_reset),
                          ),
                          obscureText: true,
                          onFieldSubmitted: (_) {
                            if (!_busy) _submit();
                          },
                          validator: (v) => v != _passwordController.text
                              ? '两次输入的密码不一致'
                              : null,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: EchoMetrics.space2),
                          Text(
                            _error!,
                            key: const Key('register_error'),
                            style: textTheme.bodySmall
                                ?.copyWith(color: tokens.error),
                          ),
                        ],
                        const SizedBox(height: EchoMetrics.space3),
                        FilledButton(
                          key: const Key('register_submit'),
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('注册并登录'),
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
