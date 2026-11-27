import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ebook_api_client.dart';
import '../../core/api/models.dart';
import '../../core/book_sources/book_source_manager.dart';
import '../../core/book_sources/book_source_models.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_buttons.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import 'book_source_detail_page.dart';

/// Injectable JSON file picker for deterministic widget testing.
final Provider<Future<String?> Function()> bookSourceFilePickerProvider =
    Provider<Future<String?> Function()>((ref) {
      return () async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const <String>['json'],
        );
        return result?.files.single.path;
      };
    });

/// 统一书源管理页：管理内置公版源、远程订阅、本地 JSON 规则、OPDS 与自建 ebook-api。
class BookSourcesPage extends ConsumerStatefulWidget {
  const BookSourcesPage({super.key});

  @override
  ConsumerState<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends ConsumerState<BookSourcesPage> {
  String? _refreshingSubId;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() {
      if (!mounted) return;
      ref.read(bookSourceControllerProvider.notifier).ensureLoaded();
    });
  }

  Future<void> _refreshSubscription(String subId) async {
    setState(() => _refreshingSubId = subId);
    try {
      final res = await ref
          .read(bookSourceControllerProvider.notifier)
          .refreshSubscription(subId);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(res.message)));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _refreshingSubId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final bsState = ref.watch(bookSourceControllerProvider);
    final manager = ref.read(bookSourceControllerProvider.notifier);
    final activeId = bsState.activeSource?.id ?? '';

    return Scaffold(
      key: const Key('book_sources_page'),
      appBar: AppBar(
        title: const Text('书源管理'),
        actions: [
          IconButton(
            key: const Key('book_sources_add_icon_button'),
            tooltip: '添加书源',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => showAddBookSourceSheet(context, ref),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'disable_all') {
                await manager.disableAllSources();
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('已停用全部在线书源（仅使用本地导入）')),
                );
              } else if (value == 'enable_bundled') {
                await manager.enableBundledSources();
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('已启用内置公版书源')),
                );
              }
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem(
                value: 'enable_bundled',
                child: Text('恢复启用内置公版源'),
              ),
              PopupMenuItem(
                value: 'disable_all',
                child: Text('全部停用（仅用本地导入）'),
              ),
            ],
          ),
        ],
      ),
      body: EchoAmbientBackground(
        child: ListView(
          padding: const EdgeInsets.all(EchoMetrics.pagePadding),
          children: [
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        color: tokens.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '端侧统一书源引擎',
                          style: textTheme.titleMedium?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      EchoPillBadge(
                        label: '已启用 ${bsState.enabledSources.length}',
                        color: bsState.enabledSources.isNotEmpty
                            ? tokens.success
                            : tokens.textSecondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '无需部署服务端即可直接解析配置化书源或接入 OPDS 书库；也可同时连接自建 ebook-api 用于海外中转或配额共享。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  EchoPrimaryButton(
                    key: const Key('book_sources_add_button'),
                    icon: Icons.add_circle_outline_rounded,
                    label: '添加 / 导入书源',
                    onPressed: () => showAddBookSourceSheet(context, ref),
                  ),
                ],
              ),
            ),
            if (bsState.subscriptions.isNotEmpty) ...[
              const SizedBox(height: EchoMetrics.space3),
              const EchoSectionHeader(title: '远程订阅'),
              const SizedBox(height: 8),
              for (final sub in bsState.subscriptions)
                Container(
                  key: Key('book_source_sub_${sub.id}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: echoElevatedCardDecoration(context, radius: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sub.name,
                              style: textTheme.titleSmall?.copyWith(
                                color: tokens.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${sub.sources.length} 个书源${sub.configVersion.isNotEmpty ? " · v${sub.configVersion}" : ""}',
                              style: textTheme.bodySmall?.copyWith(
                                color: tokens.textSecondary,
                              ),
                            ),
                            Text(
                              sub.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: tokens.textDisabled,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: Key('book_source_sub_refresh_${sub.id}'),
                        tooltip: '刷新订阅',
                        onPressed: _refreshingSubId == sub.id
                            ? null
                            : () => _refreshSubscription(sub.id),
                        icon: _refreshingSubId == sub.id
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh_rounded, size: 20),
                      ),
                      IconButton(
                        key: Key('book_source_sub_delete_${sub.id}'),
                        tooltip: '移除订阅',
                        onPressed: () => manager.removeSubscription(sub.id),
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                          color: tokens.error,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: EchoMetrics.space3),
            EchoSectionHeader(
              title: '全部书源',
              subtitle: '${bsState.sources.length} 个',
            ),
            const SizedBox(height: 8),
            for (final src in bsState.sources)
              _BookSourceCard(
                source: src,
                isActive: src.id == activeId,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => BookSourceDetailPage(sourceId: src.id),
                  ),
                ),
                onToggleEnabled: (enabled) =>
                    manager.setSourceEnabled(src.id, enabled),
              ),
          ],
        ),
      ),
    );
  }
}

class _BookSourceCard extends StatelessWidget {
  const _BookSourceCard({
    required this.source,
    required this.isActive,
    required this.onTap,
    required this.onToggleEnabled,
  });

  final ResolvedBookSource source;
  final bool isActive;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggleEnabled;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: echoElevatedCardDecoration(
        context,
        radius: 16,
        borderColor: isActive ? tokens.primary.withValues(alpha: 0.45) : null,
      ),
      child: InkWell(
        key: Key('book_source_item_${source.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            source.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        EchoPillBadge(
                          label: source.driver.displayLabel,
                          color: tokens.textSecondary,
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 6),
                          EchoPillBadge(
                            label: '当前搜书',
                            color: tokens.primary,
                          ),
                        ],
                      ],
                    ),
                    if (source.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        source.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        EchoPillBadge(
                          label: source.origin.displayLabel,
                          color: tokens.textSecondary,
                        ),
                        EchoPillBadge(
                          label: source.statusSummary,
                          color: source.account?.needsLogin == true
                              ? tokens.error
                              : (source.isReadyForDownload
                                    ? tokens.success
                                    : tokens.warning),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Switch(
                key: Key('book_source_switch_${source.id}'),
                value: source.isEnabled,
                onChanged: onToggleEnabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出「添加 / 导入书源」4 合 1 底部抽屉（URL 订阅 / JSON 导入 / 快捷 OPDS / 自建 ebook-api）。
Future<void> showAddBookSourceSheet(
  BuildContext context,
  WidgetRef ref, {
  int initialTab = 0,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddBookSourceSheet(initialTab: initialTab),
  );
}

class _AddBookSourceSheet extends ConsumerStatefulWidget {
  const _AddBookSourceSheet({this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<_AddBookSourceSheet> createState() =>
      _AddBookSourceSheetState();
}

class _AddBookSourceSheetState extends ConsumerState<_AddBookSourceSheet> {
  late int _tab = widget.initialTab.clamp(0, 3);
  bool _busy = false;
  String? _statusMsg;
  bool _statusOk = false;

  // Tab 0: URL
  final _urlCtrl = TextEditingController();
  bool _asSubscription = true;

  // Tab 1: JSON
  final _jsonCtrl = TextEditingController();

  // Tab 2: OPDS
  final _opdsNameCtrl = TextEditingController();
  final _opdsUrlCtrl = TextEditingController();
  final _opdsSearchUrlCtrl = TextEditingController();
  final _opdsUserCtrl = TextEditingController();
  final _opdsPassCtrl = TextEditingController();

  // Tab 3: ebook-api
  final _eapiNameCtrl = TextEditingController(text: '自建 ebook-api');
  final _eapiUrlCtrl = TextEditingController();
  final _eapiKeyCtrl = TextEditingController();
  final _eapiProviderCtrl = TextEditingController(text: 'zlib');

  @override
  void dispose() {
    _urlCtrl.dispose();
    _jsonCtrl.dispose();
    _opdsNameCtrl.dispose();
    _opdsUrlCtrl.dispose();
    _opdsSearchUrlCtrl.dispose();
    _opdsUserCtrl.dispose();
    _opdsPassCtrl.dispose();
    _eapiNameCtrl.dispose();
    _eapiUrlCtrl.dispose();
    _eapiKeyCtrl.dispose();
    _eapiProviderCtrl.dispose();
    super.dispose();
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusOk = false;
      _statusMsg = msg;
    });
  }

  Future<void> _submitUrl() async {
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final res = await ref
          .read(bookSourceControllerProvider.notifier)
          .importFromUrl(_urlCtrl.text, asSubscription: _asSubscription);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(res.message)));
    } on ApiException catch (e) {
      _setError(e.message);
    } catch (e) {
      _setError('导入失败：$e');
    }
  }

  Future<void> _pickJsonFile() async {
    try {
      final path = await ref.read(bookSourceFilePickerProvider)();
      if (path == null || path.trim().isEmpty) return;
      final content = await File(path).readAsString();
      if (!mounted) return;
      _jsonCtrl.text = content;
    } catch (e) {
      _setError('读取文件失败：$e');
    }
  }

  Future<void> _submitJson() async {
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final res = await ref
          .read(bookSourceControllerProvider.notifier)
          .importFromJsonString(_jsonCtrl.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(res.message)));
    } on ApiException catch (e) {
      _setError(e.message);
    } catch (e) {
      _setError('导入失败：$e');
    }
  }

  Future<void> _submitOpds() async {
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final src = await ref
          .read(bookSourceControllerProvider.notifier)
          .addQuickOpds(
            name: _opdsNameCtrl.text,
            catalogUrl: _opdsUrlCtrl.text,
            searchUrl: _opdsSearchUrlCtrl.text,
            username: _opdsUserCtrl.text,
            password: _opdsPassCtrl.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('已添加 OPDS 书库「${src.name}」')));
    } on ApiException catch (e) {
      _setError(e.message);
    } catch (e) {
      _setError('添加失败：$e');
    }
  }

  Future<void> _testEbookApi() async {
    final err = validateEbookApiUrl(_eapiUrlCtrl.text);
    if (err != null) {
      _setError(err);
      return;
    }
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final health = await EbookApiClient(
        baseUrl: _eapiUrlCtrl.text,
        apiKey: _eapiKeyCtrl.text,
      ).checkHealth();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusOk = health.ok;
        _statusMsg = health.ok
            ? '连接成功！可用书源：${health.providers.isEmpty ? "默认" : health.providers.join(", ")}'
            : '服务返回异常状态';
      });
    } on ApiException catch (e) {
      _setError('连接失败：${e.message}');
    } catch (e) {
      _setError('连接失败：$e');
    }
  }

  Future<void> _submitEbookApi() async {
    setState(() {
      _busy = true;
      _statusMsg = null;
    });
    try {
      final src = await ref
          .read(bookSourceControllerProvider.notifier)
          .addQuickEbookApi(
            name: _eapiNameCtrl.text,
            baseUrl: _eapiUrlCtrl.text,
            apiKey: _eapiKeyCtrl.text,
            remoteProvider: _eapiProviderCtrl.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('已添加书源「${src.name}」')));
    } on ApiException catch (e) {
      _setError(e.message);
    } catch (e) {
      _setError('添加失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          EchoMetrics.pagePadding,
          4,
          EchoMetrics.pagePadding,
          EchoMetrics.space3 + bottomInset,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const EchoSheetDragHandle(),
              Text(
                '添加书源',
                style: textTheme.titleMedium?.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      key: const Key('add_source_tab_url'),
                      label: const Text('URL 订阅'),
                      selected: _tab == 0,
                      onSelected: (_) => setState(() {
                        _tab = 0;
                        _statusMsg = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: const Key('add_source_tab_json'),
                      label: const Text('导入 JSON'),
                      selected: _tab == 1,
                      onSelected: (_) => setState(() {
                        _tab = 1;
                        _statusMsg = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: const Key('add_source_tab_opds'),
                      label: const Text('OPDS 书库'),
                      selected: _tab == 2,
                      onSelected: (_) => setState(() {
                        _tab = 2;
                        _statusMsg = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: const Key('add_source_tab_ebook_api'),
                      label: const Text('ebook-api'),
                      selected: _tab == 3,
                      onSelected: (_) => setState(() {
                        _tab = 3;
                        _statusMsg = null;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_tab == 0) ...[
                TextField(
                  key: const Key('add_source_url_field'),
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '书源规则 JSON 地址',
                    hintText: 'https://example.com/book-sources.json',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('作为远程订阅（可自动更新规则）'),
                  subtitle: const Text('更新时仅刷新规则模板，绝不覆盖账号凭据和自定义域名'),
                  value: _asSubscription,
                  onChanged: (v) => setState(() => _asSubscription = v),
                ),
                const SizedBox(height: 12),
                EchoPrimaryButton(
                  key: const Key('add_source_url_submit'),
                  busy: _busy,
                  onPressed: _busy ? null : _submitUrl,
                  icon: Icons.cloud_download_outlined,
                  label: '拉取并导入',
                ),
              ] else if (_tab == 1) ...[
                EchoSecondaryButton(
                  key: const Key('add_source_pick_file'),
                  onPressed: _busy ? null : _pickJsonFile,
                  icon: Icons.folder_open_outlined,
                  label: '从本地选择 .json 文件',
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_json_field'),
                  controller: _jsonCtrl,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '或直接粘贴书源 JSON',
                    hintText: '{"schema_version":1,"id":"...","driver":"rule",...}',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                EchoPrimaryButton(
                  key: const Key('add_source_json_submit'),
                  busy: _busy,
                  onPressed: _busy ? null : _submitJson,
                  icon: Icons.check_rounded,
                  label: '导入 JSON 书源',
                ),
              ] else if (_tab == 2) ...[
                TextField(
                  key: const Key('add_source_opds_name'),
                  controller: _opdsNameCtrl,
                  decoration: const InputDecoration(
                    labelText: '书库名称',
                    hintText: '例如：家庭 Calibre / Komga / 古登堡 OPDS',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_opds_url'),
                  controller: _opdsUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'OPDS 根目录 URL',
                    hintText: 'https://books.home.lan/opds',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_opds_search_url'),
                  controller: _opdsSearchUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '搜索模板 URL（可选，留空自动探测 OpenSearch）',
                    hintText: 'https://.../search?q={searchTerms}',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('add_source_opds_user'),
                        controller: _opdsUserCtrl,
                        decoration: const InputDecoration(labelText: '用户名（可选）'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('add_source_opds_pass'),
                        controller: _opdsPassCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码（可选）'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                EchoPrimaryButton(
                  key: const Key('add_source_opds_submit'),
                  busy: _busy,
                  onPressed: _busy ? null : _submitOpds,
                  icon: Icons.library_books_outlined,
                  label: '添加 OPDS 书库',
                ),
              ] else ...[
                TextField(
                  key: const Key('add_source_ebook_api_name'),
                  controller: _eapiNameCtrl,
                  decoration: const InputDecoration(labelText: '展示名称'),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_ebook_api_url'),
                  controller: _eapiUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'ebook-api 服务地址',
                    hintText: 'http://192.168.1.10:8091',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_ebook_api_key'),
                  controller: _eapiKeyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key（可选）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('add_source_ebook_api_provider'),
                  controller: _eapiProviderCtrl,
                  decoration: const InputDecoration(
                    labelText: '远端书源 ID',
                    hintText: 'zlib',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    EchoSecondaryButton(
                      key: const Key('add_source_ebook_api_test'),
                      onPressed: _busy ? null : _testEbookApi,
                      label: '测试连接',
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: EchoPrimaryButton(
                        key: const Key('add_source_ebook_api_submit'),
                        busy: _busy,
                        onPressed: _busy ? null : _submitEbookApi,
                        label: '添加服务',
                      ),
                    ),
                  ],
                ),
              ],
              if (_statusMsg != null) ...[
                const SizedBox(height: 12),
                Text(
                  _statusMsg!,
                  key: const Key('add_source_status_msg'),
                  style: textTheme.bodySmall?.copyWith(
                    color: _statusOk ? tokens.success : tokens.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
