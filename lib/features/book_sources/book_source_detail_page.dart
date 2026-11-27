import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/models.dart';
import '../../core/book_sources/book_source_manager.dart';
import '../../core/book_sources/book_source_models.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';

/// 单条书源详情与配置页：支持镜像切换、可用性探测、自定义域名/反代、动态认证表单与脱敏导出。
class BookSourceDetailPage extends ConsumerStatefulWidget {
  const BookSourceDetailPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<BookSourceDetailPage> createState() =>
      _BookSourceDetailPageState();
}

class _BookSourceDetailPageState extends ConsumerState<BookSourceDetailPage> {
  final _customDomainCtrl = TextEditingController();
  final _proxyPrefixCtrl = TextEditingController();
  String? _selectedDomain;
  bool _networkInitialized = false;

  bool _probing = false;
  List<MirrorProbeResult> _probeResults = const <MirrorProbeResult>[];
  bool _savingNetwork = false;

  String _authModeId = '';
  final Map<String, TextEditingController> _authCtrls =
      <String, TextEditingController>{};
  bool _savingAuth = false;
  bool _verifyingAuth = false;

  @override
  void dispose() {
    _customDomainCtrl.dispose();
    _proxyPrefixCtrl.dispose();
    for (final c in _authCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlForField(String key) =>
      _authCtrls.putIfAbsent(key, () => TextEditingController());

  List<BookSourceAuthMode> _effectiveAuthModes(ResolvedBookSource source) {
    final defined = source.definition.auth?.modes ?? const [];
    if (defined.isNotEmpty) return defined;
    if (source.driver == BookSourceDriverType.ebookApi) {
      return const <BookSourceAuthMode>[
        BookSourceAuthMode(
          id: 'password',
          label: '邮箱密码',
          fields: <BookSourceAuthField>[
            BookSourceAuthField(key: 'email', label: '邮箱', type: 'email'),
            BookSourceAuthField(key: 'password', label: '密码', type: 'password'),
            BookSourceAuthField(
              key: 'domain',
              label: '远端镜像（可选）',
              type: 'text',
              required: false,
            ),
          ],
        ),
        BookSourceAuthMode(
          id: 'cookies',
          label: 'Cookie 导入',
          fields: <BookSourceAuthField>[
            BookSourceAuthField(
              key: 'remix_userid',
              label: 'remix_userid',
              type: 'text',
            ),
            BookSourceAuthField(
              key: 'remix_userkey',
              label: 'remix_userkey',
              type: 'password',
            ),
            BookSourceAuthField(
              key: 'domain',
              label: '远端镜像（可选）',
              type: 'text',
              required: false,
            ),
          ],
        ),
      ];
    }
    return const <BookSourceAuthMode>[];
  }

  Future<void> _probeDomains() async {
    setState(() => _probing = true);
    try {
      final results = await ref
          .read(bookSourceControllerProvider.notifier)
          .probeSourceDomains(widget.sourceId);
      if (!mounted) return;
      setState(() {
        _probeResults = results;
        final fastestOk = results.where((r) => r.ok).toList()
          ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
        if (fastestOk.isNotEmpty) {
          _selectedDomain = fastestOk.first.domain;
        }
      });
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _saveNetwork() async {
    setState(() => _savingNetwork = true);
    try {
      await ref
          .read(bookSourceControllerProvider.notifier)
          .updateNetworkOverlay(
            widget.sourceId,
            preferredDomain: _selectedDomain ?? '',
            customDomain: _customDomainCtrl.text.trim(),
            proxyPrefix: _proxyPrefixCtrl.text.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('网络与镜像设置已保存')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _savingNetwork = false);
    }
  }

  Future<void> _saveAuth(BookSourceAuthMode mode) async {
    setState(() => _savingAuth = true);
    try {
      final inputs = <String, String>{
        for (final f in mode.fields) f.key: _ctrlForField(f.key).text,
      };
      await ref
          .read(bookSourceControllerProvider.notifier)
          .authenticateSource(
            sourceId: widget.sourceId,
            modeId: mode.id,
            inputs: inputs,
          );
      if (!mounted) return;
      for (final f in mode.fields) {
        if (f.type == 'password') {
          _ctrlForField(f.key).clear();
        }
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('账号已保存并验证通过')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _savingAuth = false);
    }
  }

  Future<void> _verifyAuth() async {
    setState(() => _verifyingAuth = true);
    try {
      await ref
          .read(bookSourceControllerProvider.notifier)
          .verifySource(widget.sourceId);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('凭据验证通过')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _verifyingAuth = false);
    }
  }

  Future<void> _exportSanitizedJson(String sourceName) async {
    try {
      final jsonText = ref
          .read(bookSourceControllerProvider.notifier)
          .exportSanitizedJson(widget.sourceId);
      unawaited(
        Clipboard.setData(ClipboardData(text: jsonText)).catchError((_) {}),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dlgCtx) => AlertDialog(
          title: Text('已复制「$sourceName」脱敏规则'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '已自动剥离所有个人账号凭据、Cookie、自定义域名与反代配置，可安全分享。',
                  style: TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  jsonText,
                  key: const Key('source_detail_export_preview'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Share.share(jsonText, subject: '$sourceName 书源配置');
                Navigator.of(dlgCtx).pop();
              },
              child: const Text('系统分享'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dlgCtx).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final bsState = ref.watch(bookSourceControllerProvider);
    final manager = ref.read(bookSourceControllerProvider.notifier);
    final source = bsState.sourceById(widget.sourceId);

    if (source == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('书源详情')),
        body: const Center(child: Text('未找到该书源或已被移除')),
      );
    }

    if (!_networkInitialized) {
      _networkInitialized = true;
      _customDomainCtrl.text = source.customDomain;
      _proxyPrefixCtrl.text = source.proxyPrefix;
      _selectedDomain = source.preferredDomain.isNotEmpty
          ? source.preferredDomain
          : (source.definition.domains.isNotEmpty
                ? source.definition.domains.first
                : null);
    }

    final isActive = bsState.activeSource?.id == source.id;
    final authModes = _effectiveAuthModes(source);
    if (authModes.isNotEmpty &&
        !authModes.any((m) => m.id == _authModeId)) {
      _authModeId = authModes.first.id;
    }
    final activeAuthMode = authModes.isNotEmpty
        ? authModes.firstWhere((m) => m.id == _authModeId)
        : null;
    final domains = source.definition.domains;

    return Scaffold(
      key: const Key('book_source_detail_page'),
      appBar: AppBar(
        title: Text(source.name),
        actions: [
          IconButton(
            key: const Key('source_detail_export'),
            tooltip: '脱敏导出分享 JSON',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _exportSanitizedJson(source.name),
          ),
          if (!source.isBundled && source.origin != BookSourceOrigin.subscription)
            IconButton(
              key: const Key('source_detail_delete'),
              tooltip: '删除书源',
              icon: Icon(Icons.delete_outline_rounded, color: tokens.error),
              onPressed: () async {
                await manager.removeSource(source.id);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          padding: const EdgeInsets.all(EchoMetrics.pagePadding),
          children: [
            // 概览卡片
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      EchoPillBadge(
                        label: source.driver.displayLabel,
                        color: tokens.primary,
                      ),
                      EchoPillBadge(
                        label: source.origin.displayLabel,
                        color: tokens.textSecondary,
                      ),
                      EchoPillBadge(
                        label: source.statusSummary,
                        color: source.account?.needsLogin == true
                            ? tokens.error
                            : tokens.success,
                      ),
                    ],
                  ),
                  if (source.description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      source.description,
                      style: textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: isActive
                            ? EchoSecondaryButton(
                                icon: Icons.check_circle_outline_rounded,
                                label: '当前默认搜书源',
                                onPressed: null,
                              )
                            : EchoPrimaryButton(
                                key: const Key('source_detail_set_active'),
                                icon: Icons.search_rounded,
                                label: '设为当前搜书源',
                                onPressed: () async {
                                  await manager.setActiveSource(source.id);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.maybeOf(context)
                                      ?.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '已切换默认搜书源为「${source.name}」',
                                          ),
                                        ),
                                      );
                                },
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: EchoMetrics.space2),

            // 网络、镜像与反代卡片
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '网络与镜像设置',
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('source_detail_probe_button'),
                        onPressed: _probing ? null : _probeDomains,
                        icon: _probing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.speed_rounded, size: 17),
                        label: Text(_probing ? '探测中...' : '测速探测'),
                      ),
                    ],
                  ),
                  if (domains.length > 1) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: const Key('source_detail_mirror_dropdown'),
                      isExpanded: true,
                      initialValue: domains.contains(_selectedDomain)
                          ? _selectedDomain
                          : domains.first,
                      decoration: const InputDecoration(
                        labelText: '首选内置镜像',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      items: [
                        for (final d in domains)
                          DropdownMenuItem(
                            value: d,
                            child: Text(d, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) => setState(() => _selectedDomain = v),
                    ),
                  ],
                  if (_probeResults.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final pr in _probeResults)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              pr.ok
                                  ? Icons.check_circle_rounded
                                  : Icons.error_outline_rounded,
                              size: 15,
                              color: pr.ok ? tokens.success : tokens.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                pr.domain,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall,
                              ),
                            ),
                            Text(
                              pr.ok ? '${pr.latencyMs}ms' : pr.error,
                              style: textTheme.labelSmall?.copyWith(
                                color: pr.ok ? tokens.success : tokens.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('source_detail_custom_domain_field'),
                    controller: _customDomainCtrl,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: '自定义覆盖域名（可选）',
                      hintText: domains.isNotEmpty ? domains.first : 'https://...',
                      prefixIcon: const Icon(Icons.language_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('source_detail_proxy_prefix_field'),
                    controller: _proxyPrefixCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '反向代理前缀（可选，改善国内直连）',
                      hintText: 'https://proxy.example.com/ 或 .../?url={url}',
                      prefixIcon: Icon(Icons.alt_route_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  EchoSecondaryButton(
                    key: const Key('source_detail_save_network'),
                    onPressed: _savingNetwork ? null : _saveNetwork,
                    icon: Icons.save_outlined,
                    label: _savingNetwork ? '保存中...' : '保存网络设置',
                  ),
                ],
              ),
            ),

            // 动态认证与凭据卡片
            if (activeAuthMode != null) ...[
              const SizedBox(height: EchoMetrics.space2),
              Container(
                key: const Key('source_detail_auth_card'),
                padding: const EdgeInsets.all(EchoMetrics.space3),
                decoration: echoElevatedCardDecoration(context, radius: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          '账号与凭据',
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        EchoPillBadge(
                          key: const Key('source_detail_account_badge'),
                          label: source.hasCredentials
                              ? (source.account?.needsLogin == true
                                    ? '需重新登录'
                                    : '已配置')
                              : '未登录',
                          color: source.hasCredentials
                              ? (source.account?.needsLogin == true
                                    ? tokens.error
                                    : tokens.success)
                              : tokens.textSecondary,
                        ),
                      ],
                    ),
                    if (source.hasCredentials && source.account != null) ...[
                      const SizedBox(height: 8),
                      if (source.account!.email.isNotEmpty)
                        Text(
                          source.account!.email,
                          style: textTheme.bodySmall?.copyWith(
                            color: tokens.textPrimary,
                          ),
                        ),
                      if (source.account!.quotaKnown)
                        Text(
                          '今日配额：已用 ${source.account!.dailyUsed}/${source.account!.dailyLimit} · 剩余 ${source.account!.dailyRemaining}',
                          key: const Key('source_detail_quota'),
                          style: textTheme.labelSmall?.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          TextButton.icon(
                            key: const Key('source_detail_verify'),
                            onPressed: _verifyingAuth ? null : _verifyAuth,
                            icon: _verifyingAuth
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 17),
                            label: Text(_verifyingAuth ? '验证中...' : '重新验证'),
                          ),
                          TextButton.icon(
                            key: const Key('source_detail_clear_creds'),
                            style: TextButton.styleFrom(
                              foregroundColor: tokens.error,
                            ),
                            onPressed: () async {
                              await manager.clearCredentials(source.id);
                              if (!context.mounted) return;
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                const SnackBar(content: Text('已清除本机保存的凭据')),
                              );
                            },
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 17,
                            ),
                            label: const Text('清除凭据'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (authModes.length > 1) ...[
                      SegmentedButton<String>(
                        key: const Key('source_detail_auth_mode_segment'),
                        segments: [
                          for (final m in authModes)
                            ButtonSegment<String>(
                              value: m.id,
                              label: Text(m.label),
                            ),
                        ],
                        selected: <String>{activeAuthMode.id},
                        onSelectionChanged: (sel) =>
                            setState(() => _authModeId = sel.first),
                      ),
                      const SizedBox(height: 12),
                    ],
                    for (final field in activeAuthMode.fields) ...[
                      TextFormField(
                        key: Key('source_auth_field_${field.key}'),
                        controller: _ctrlForField(field.key),
                        obscureText: field.type == 'password',
                        maxLines: field.type == 'multiline' ? 3 : 1,
                        keyboardType: field.type == 'email'
                            ? TextInputType.emailAddress
                            : TextInputType.text,
                        decoration: InputDecoration(
                          labelText: field.label,
                          hintText: field.hint.isNotEmpty ? field.hint : null,
                          prefixIcon: Icon(
                            field.type == 'password'
                                ? Icons.lock_outline_rounded
                                : (field.type == 'email'
                                      ? Icons.mail_outline_rounded
                                      : Icons.key_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 6),
                    EchoPrimaryButton(
                      key: const Key('source_detail_auth_save'),
                      busy: _savingAuth,
                      onPressed: _savingAuth
                          ? null
                          : () => _saveAuth(activeAuthMode),
                      icon: Icons.verified_user_outlined,
                      label: '保存并验证',
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
