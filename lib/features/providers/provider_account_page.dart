import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import 'providers_controller.dart';

/// 书源账号配置页（极简书房 Editorial Minimalism）：
/// 镜像选择 + 账密登录 / Cookie 导入、验证、配额、失效重配。
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
    String? error;
    try {
      error = await ref
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
    } catch (e) {
      error = '保存失败：$e';
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (!mounted) return;
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
      body: EchoAmbientBackground(
        child: state.isLoading && state.providers.isEmpty
            ? Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: tokens.primary,
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(EchoMetrics.pagePadding),
                children: [
                  if (state.error != null)
                    Container(
                      key: const Key('providers_error_banner'),
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 14,
                        color: tokens.error.withValues(alpha: 0.08),
                        borderColor: tokens.error.withValues(alpha: 0.25),
                      ),
                      child: Text(
                        state.error!,
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.error,
                        ),
                      ),
                    ),
                  for (final provider in state.providers) ...[
                    _AccountStatusCard(
                      provider: provider,
                      onVerify: controller.verify,
                      onRemove: controller.remove,
                    ),
                    const SizedBox(height: 16),
                    _AccountFormCard(
                      provider: provider,
                      mode: _mode,
                      onModeChanged: (m) => setState(() => _mode = m),
                      selectedDomain: _selectedDomain,
                      onDomainChanged: (d) =>
                          setState(() => _selectedDomain = d),
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
      ),
    );
  }
}

class _AccountStatusCard extends StatefulWidget {
  const _AccountStatusCard({
    required this.provider,
    required this.onVerify,
    required this.onRemove,
  });

  final ProviderInfo provider;
  final Future<String?> Function(String providerId) onVerify;
  final Future<String?> Function(String providerId) onRemove;

  @override
  State<_AccountStatusCard> createState() => _AccountStatusCardState();
}

class _AccountStatusCardState extends State<_AccountStatusCard> {
  bool _verifying = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final provider = widget.provider;
    final account = provider.account;
    final hasAccount = account != null && account.configured;
    final providerId = provider.id;

    return Container(
      key: Key('provider_status_${provider.id}'),
      padding: const EdgeInsets.all(16),
      decoration: echoElevatedCardDecoration(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.source_outlined, size: 20, color: tokens.primary),
              const SizedBox(width: 8),
              Text(
                provider.name,
                style: textTheme.titleMedium?.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (!hasAccount)
                EchoPillBadge(
                  key: Key('provider_${provider.id}_unconfigured'),
                  label: '未配置',
                  color: tokens.textSecondary,
                )
              else
                EchoPillBadge(
                  key: Key('provider_${provider.id}_status_chip'),
                  label: account.needsLogin ? '需重新登录' : '正常',
                  color: account.needsLogin ? tokens.error : tokens.success,
                ),
            ],
          ),
          if (hasAccount) ...[
            const SizedBox(height: 10),
            if (account.email.isNotEmpty)
              Text(
                account.email,
                key: Key('provider_${provider.id}_email'),
                style: textTheme.bodySmall?.copyWith(
                  color: tokens.textPrimary,
                ),
              ),
            if (account.quotaKnown)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '今日配额：已用 ${account.dailyUsed}/${account.dailyLimit} · 剩余 ${account.dailyRemaining}',
                  key: Key('provider_${provider.id}_quota'),
                  style: textTheme.labelSmall?.copyWith(
                    color: tokens.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            if (account.lastVerifiedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '上次验证：${account.lastVerifiedAt!.toLocal()}'.split('.').first,
                  style: textTheme.labelSmall?.copyWith(
                    color: tokens.textDisabled,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  key: Key('provider_${providerId}_verify'),
                  onPressed: _verifying
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          setState(() => _verifying = true);
                          String? error;
                          try {
                            error = await widget.onVerify(providerId);
                          } catch (e) {
                            error = '验证失败：$e';
                          } finally {
                            if (mounted) setState(() => _verifying = false);
                          }
                          if (!mounted) return;
                          messenger?.showSnackBar(
                            SnackBar(
                              content: Text(error ?? '账号验证通过'),
                            ),
                          );
                        },
                  icon: _verifying
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(_verifying ? '验证中...' : '重新验证'),
                ),
                TextButton.icon(
                  key: Key('provider_${providerId}_delete'),
                  style: TextButton.styleFrom(foregroundColor: tokens.error),
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
                            style: FilledButton.styleFrom(
                              backgroundColor: tokens.error,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () =>
                                Navigator.of(dialogCtx).pop(true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await widget.onRemove(providerId);
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

    return Container(
      key: Key('provider_form_${provider.id}'),
      padding: const EdgeInsets.all(16),
      decoration: echoElevatedCardDecoration(context, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '账号配置',
            style: textTheme.titleSmall?.copyWith(color: tokens.textPrimary),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            key: const Key('account_mode_segment'),
            segments: const [
              ButtonSegment(
                value: 'password',
                icon: Icon(Icons.password_rounded, size: 17),
                label: Text('邮箱密码'),
              ),
              ButtonSegment(
                value: 'cookies',
                icon: Icon(Icons.cookie_outlined, size: 17),
                label: Text('Cookie 导入'),
              ),
            ],
            selected: <String>{mode},
            onSelectionChanged: (selection) => onModeChanged(selection.first),
          ),
          const SizedBox(height: 16),
          if (domains.isNotEmpty)
            DropdownButtonFormField<String>(
              key: const Key('account_domain_dropdown'),
              isExpanded: true,
              initialValue: selectedDomain ?? domains.first,
              decoration: const InputDecoration(
                labelText: '镜像域名',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              items: [
                for (final d in domains)
                  DropdownMenuItem(
                    value: d,
                    child: Text(d, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onDomainChanged,
            ),
          const SizedBox(height: 12),
          if (mode == 'password') ...[
            TextFormField(
              key: const Key('account_email_field'),
              controller: emailController,
              decoration: const InputDecoration(
                labelText: '邮箱',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('account_password_field'),
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
          ] else ...[
            TextFormField(
              key: const Key('account_remix_userid_field'),
              controller: remixUserIdController,
              decoration: const InputDecoration(
                labelText: 'remix_userid',
                prefixIcon: Icon(Icons.key_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('account_remix_userkey_field'),
              controller: remixUserKeyController,
              decoration: const InputDecoration(
                labelText: 'remix_userkey',
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
            ),
          ],
          const SizedBox(height: 18),
          EchoPrimaryButton(
            key: const Key('account_form_save'),
            onPressed: saving ? null : onSave,
            busy: saving,
            icon: Icons.verified_user_outlined,
            label: '保存并验证',
          ),
        ],
      ),
    );
  }
}
