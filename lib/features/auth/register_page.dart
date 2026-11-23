import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
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
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
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
    if (error == null) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      key: const Key('register_page'),
      backgroundColor: tokens.surfaceBase,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('创建账号'),
      ),
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
                      Text(
                        '加入回声',
                        textAlign: TextAlign.center,
                        style: textTheme.headlineSmall?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '创建个人听看一体书库账号',
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: EchoMetrics.space3),
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
                              key: const Key('register_email'),
                              controller: _emailController,
                              decoration: const InputDecoration(
                                labelText: '邮箱',
                                hintText: 'you@example.com',
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
                              textInputAction: TextInputAction.next,
                              validator: (v) =>
                                  (v == null || v.length < 6) ? '密码至少 6 位' : null,
                            ),
                            const SizedBox(height: EchoMetrics.space2),
                            TextFormField(
                              key: const Key('register_confirm'),
                              controller: _confirmController,
                              decoration: InputDecoration(
                                labelText: '确认密码',
                                prefixIcon: const Icon(Icons.lock_reset),
                                suffixIcon: IconButton(
                                  tooltip: _obscureConfirm ? '显示密码' : '隐藏密码',
                                  onPressed: () => setState(
                                    () => _obscureConfirm = !_obscureConfirm,
                                  ),
                                  icon: Icon(
                                    _obscureConfirm
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                              obscureText: _obscureConfirm,
                              onFieldSubmitted: (_) {
                                if (!_busy) _submit();
                              },
                              validator: (v) => v != _passwordController.text
                                  ? '两次输入的密码不一致'
                                  : null,
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
                                  key: const Key('register_error'),
                                  style: textTheme.bodySmall?.copyWith(
                                    color: tokens.error,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: EchoMetrics.space3),
                            EchoPrimaryButton(
                              key: const Key('register_submit'),
                              label: '注册并登录',
                              busy: _busy,
                              onPressed: _busy ? null : _submit,
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
