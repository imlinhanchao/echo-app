import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import 'providers_controller.dart';

/// 书源账号配置页：镜像选择 + 账密登录 / Cookie 导入、验证、配额、失效重配。
/// zlib 凭据只存服务端（AES-256-GCM），本页表单仅收集提交，不本地持久化。
class ProviderAccountPage extends ConsumerStatefulWidget {
  const ProviderAccountPage({super.key});

  @override
  ConsumerState<ProviderAccountPage> createState() =>
      _ProviderAccountPageState();
}

class _ProviderAccountPageState extends ConsumerState<ProviderAccountPage> {
  String _mode = 'password';
  String? _selectedDomain;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _remixUserIdController = TextEditingController();
  final _remixUserKeyController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _remixUserIdController.dispose();
    _remixUserKeyController.dispose();
    super.dispose();
  }

  Future<void> _save(
    String providerId,
    String defaultDomain,
    List<String> domains,
  ) async {
    if (_saving) return;
    setState(() => _saving = true);
    final error = await ref
        .read(providersControllerProvider.notifier)
        .saveAccount(
          providerId: providerId,
          mode: _mode,
          domain: _selectedDomain ?? defaultDomain,
          email: _emailController.text.trim(),
          password: _passwordController.text,
          remixUserId: _remixUserIdController.text.trim(),
          remixUserKey: _remixUserKeyController.text.trim(),
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error)));
    } else {
      setState(() {
        _passwordController.clear();
        _remixUserIdController.clear();
        _remixUserKeyController.clear();
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('账号已保存并验证通过')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(providersControllerProvider);
    final controller = ref.read(providersControllerProvider.notifier);

    return Scaffold(
      key: const Key('provider_account_page'),
      appBar: AppBar(title: const Text('书源账号')),
      body: state.isLoading && state.providers.isEmpty
          ? Center(child: CircularProgressIndicator(color: tokens.primary))
          : ListView(
              padding: const EdgeInsets.all(EchoMetrics.space2),
              children: [
                if (state.error != null)
                  Card(
                    key: const Key('providers_error_banner'),
                    child: Padding(
                      padding: const EdgeInsets.all(EchoMetrics.space2),
                      child: Text(
                        state.error!,
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.error,
                        ),
                      ),
                    ),
                  ),
                for (final provider in state.providers) ...[
                  _AccountStatusCard(
                    provider: provider,
                    onVerify: controller.verify,
                    onRemove: controller.remove,
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  _AccountFormCard(
                    provider: provider,
                    mode: _mode,
                    onModeChanged: (m) => setState(() => _mode = m),
                    selectedDomain: _selectedDomain,
                    onDomainChanged: (d) => setState(() => _selectedDomain = d),
                    emailController: _emailController,
                    passwordController: _passwordController,
                    remixUserIdController: _remixUserIdController,
                    remixUserKeyController: _remixUserKeyController,
                    saving: _saving,
                    onSave: () => _save(
                      provider.id,
                      provider.defaultDomain,
                      provider.domains,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _AccountStatusCard extends StatelessWidget {
  const _AccountStatusCard({
    required this.provider,
    required this.onVerify,
    required this.onRemove,
  });

  final ProviderInfo provider;
  final Future<String?> Function(String providerId) onVerify;
  final Future<String?> Function(String providerId) onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final account = provider.account;
    final providerId = provider.id;

    return Card(
      key: Key('provider_status_${provider.id}'),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.source_outlined, color: tokens.accent),
                const SizedBox(width: EchoMetrics.space1),
                Text(
                  provider.name,
                  style: textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                  ),
                ),
                const Spacer(),
                if (account == null)
                  Text(
                    '未配置',
                    key: Key('provider_${provider.id}_unconfigured'),
                    style: textTheme.labelMedium?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: EchoMetrics.space1,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (account.needsLogin ? tokens.error : tokens.success)
                              .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      account.needsLogin ? '需重新登录' : '正常',
                      key: Key('provider_${provider.id}_status_chip'),
                      style: textTheme.labelSmall?.copyWith(
                        color: account.needsLogin
                            ? tokens.error
                            : tokens.success,
                      ),
                    ),
                  ),
              ],
            ),
            if (account != null) ...[
              const SizedBox(height: EchoMetrics.space1),
              if (account.email.isNotEmpty)
                Text(
                  account.email,
                  key: Key('provider_${provider.id}_email'),
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              if (account.quotaKnown)
                Text(
                  '今日配额：已用 ${account.dailyUsed}/${account.dailyLimit} · 剩余 ${account.dailyRemaining}',
                  key: Key('provider_${provider.id}_quota'),
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              if (account.lastVerifiedAt != null)
                Text(
                  '上次验证：${account.lastVerifiedAt!.toLocal()}'.split('.').first,
                  style: textTheme.bodySmall?.copyWith(
                    color: tokens.textDisabled,
                  ),
                ),
              const SizedBox(height: EchoMetrics.space1),
              Row(
                children: [
                  TextButton.icon(
                    key: Key('provider_${providerId}_verify'),
                    onPressed: () async {
                      final error = await onVerify(providerId);
                      if (error != null && context.mounted) {
                        ScaffoldMessenger.maybeOf(
                          context,
                        )?.showSnackBar(SnackBar(content: Text(error)));
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新验证'),
                  ),
                  TextButton.icon(
                    key: Key('provider_${providerId}_delete'),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogCtx) => AlertDialog(
                          title: const Text('删除账号'),
                          content: const Text('确定删除该书源的账号配置吗？'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogCtx).pop(false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(dialogCtx).pop(true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await onRemove(providerId);
                      }
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountFormCard extends StatelessWidget {
  const _AccountFormCard({
    required this.provider,
    required this.mode,
    required this.onModeChanged,
    required this.selectedDomain,
    required this.onDomainChanged,
    required this.emailController,
    required this.passwordController,
    required this.remixUserIdController,
    required this.remixUserKeyController,
    required this.saving,
    required this.onSave,
  });

  final ProviderInfo provider;
  final String mode;
  final ValueChanged<String> onModeChanged;
  final String? selectedDomain;
  final ValueChanged<String?> onDomainChanged;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController remixUserIdController;
  final TextEditingController remixUserKeyController;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final domains = provider.domains.toList();
    if (domains.isEmpty && provider.defaultDomain.isNotEmpty) {
      domains.add(provider.defaultDomain);
    }

    return Card(
      key: Key('provider_form_${provider.id}'),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '账号配置',
              style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
            ),
            const SizedBox(height: EchoMetrics.space1),
            SegmentedButton<String>(
              key: const Key('account_mode_segment'),
              segments: const [
                ButtonSegment(
                  value: 'password',
                  icon: Icon(Icons.password),
                  label: Text('邮箱密码'),
                ),
                ButtonSegment(
                  value: 'cookies',
                  icon: Icon(Icons.cookie),
                  label: Text('Cookie 导入'),
                ),
              ],
              selected: <String>{mode},
              onSelectionChanged: (selection) => onModeChanged(selection.first),
            ),
            const SizedBox(height: EchoMetrics.space2),
            if (domains.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const Key('account_domain_dropdown'),
                initialValue: selectedDomain ?? domains.first,
                decoration: const InputDecoration(
                  labelText: '镜像域名',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                items: [
                  for (final d in domains)
                    DropdownMenuItem(value: d, child: Text(d)),
                ],
                onChanged: onDomainChanged,
              ),
            const SizedBox(height: EchoMetrics.space2),
            if (mode == 'password') ...[
              TextFormField(
                key: const Key('account_email_field'),
                controller: emailController,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: EchoMetrics.space2),
              TextFormField(
                key: const Key('account_password_field'),
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ] else ...[
              TextFormField(
                key: const Key('account_remix_userid_field'),
                controller: remixUserIdController,
                decoration: const InputDecoration(
                  labelText: 'remix_userid',
                  prefixIcon: Icon(Icons.key),
                ),
              ),
              const SizedBox(height: EchoMetrics.space2),
              TextFormField(
                key: const Key('account_remix_userkey_field'),
                controller: remixUserKeyController,
                decoration: const InputDecoration(
                  labelText: 'remix_userkey',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
              ),
            ],
            const SizedBox(height: EchoMetrics.space2),
            FilledButton.icon(
              key: const Key('account_form_save'),
              onPressed: saving ? null : onSave,
              icon: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存并验证'),
            ),
          ],
        ),
      ),
    );
  }
}
