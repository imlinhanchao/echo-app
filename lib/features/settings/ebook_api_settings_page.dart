import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ebook_api_client.dart';
import '../../core/api/models.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../providers/providers_controller.dart';

/// ebook-api 书源服务配置页（不内置默认地址，由首次启动引导或用户手动配置）。
class EbookApiSettingsPage extends ConsumerStatefulWidget {
  const EbookApiSettingsPage({super.key});

  @override
  ConsumerState<EbookApiSettingsPage> createState() =>
      _EbookApiSettingsPageState();
}

class _EbookApiSettingsPageState extends ConsumerState<EbookApiSettingsPage> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  bool _testing = false;
  String? _statusMsg;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(standaloneConfigProvider);
    _urlCtrl = TextEditingController(text: cfg.ebookApiBaseUrl);
    _keyCtrl = TextEditingController(text: cfg.ebookApiKey);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final err = validateEbookApiUrl(_urlCtrl.text);
    if (err != null) {
      setState(() {
        _statusOk = false;
        _statusMsg = err;
      });
      return;
    }
    setState(() {
      _testing = true;
      _statusMsg = null;
    });
    try {
      final client = EbookApiClient(
        baseUrl: _urlCtrl.text,
        apiKey: _keyCtrl.text,
      );
      final health = await client.checkHealth();
      if (!mounted) return;
      setState(() {
        _testing = false;
        _statusOk = health.ok;
        _statusMsg = health.ok
            ? '连接成功！可用书源：${health.providers.isEmpty ? "默认" : health.providers.join(", ")}'
            : '服务返回异常状态';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _statusOk = false;
        _statusMsg = '连接失败：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _statusOk = false;
        _statusMsg = '连接失败：$e';
      });
    }
  }

  Future<void> _save() async {
    final raw = _urlCtrl.text.trim();
    if (raw.isEmpty) {
      await ref.read(standaloneConfigProvider.notifier).clearEbookApi();
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }
    final err = validateEbookApiUrl(raw);
    if (err != null) {
      setState(() {
        _statusOk = false;
        _statusMsg = err;
      });
      return;
    }
    await ref
        .read(standaloneConfigProvider.notifier)
        .setEbookApi(baseUrl: raw, apiKey: _keyCtrl.text.trim());
    // 刷新书源列表
    ref.invalidate(providersControllerProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已保存 ebook-api 配置')));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('ebook-api 书源服务配置')),
      body: EchoAmbientBackground(
        child: ListView(
          padding: const EdgeInsets.all(EchoMetrics.space3),
          children: [
            Container(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              decoration: echoElevatedCardDecoration(context, radius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '在线搜书与下载服务',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '填写你自建的 ebook-api 地址后，即可在「发现」页直接搜书并下载到手机本地；留空则仅使用本地导入功能。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space3),
                  TextField(
                    key: const Key('ebook_api_url_field'),
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'ebook-api 服务地址',
                      hintText: '例如 http://192.168.1.10:8091',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  TextField(
                    key: const Key('ebook_api_key_field'),
                    controller: _keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key（可选）',
                      hintText: '服务端配置了 EBOOK_API_KEY 时填写',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                  ),
                  if (_statusMsg != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _statusMsg!,
                      style: textTheme.bodySmall?.copyWith(
                        color: _statusOk ? tokens.success : tokens.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: EchoMetrics.space3),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.wifi_tethering, size: 18),
                        label: const Text('测试连接'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const Key('ebook_api_save_button'),
                          onPressed: _save,
                          child: const Text('保存配置'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
