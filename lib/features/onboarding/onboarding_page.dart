import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ebook_api_client.dart';
import '../../core/api/models.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/tts/tts_model_catalog.dart';
import '../../core/tts/tts_model_manager.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';

/// 单机版首次启动两步引导页：
/// Step 1：配置 ebook-api 书源服务地址（不内置写死，支持测试连接与跳过）；
/// Step 2：下载首个端侧离线 TTS 模型（支持跳过，稍后在「我的」管理）。
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  int _step = 0;
  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _keyCtrl = TextEditingController();
  bool _testing = false;
  String? _testMessage;
  bool _testOk = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _testEbookApi() async {
    final err = validateEbookApiUrl(_urlCtrl.text);
    if (err != null) {
      setState(() {
        _testOk = false;
        _testMessage = err;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = null;
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
        _testOk = health.ok;
        _testMessage = health.ok
            ? '连接成功（可用书源：${health.providers.join(", ")}）'
            : '服务响应异常';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = '连接失败：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = '连接失败：$e';
      });
    }
  }

  Future<void> _saveApiAndNext() async {
    final raw = _urlCtrl.text.trim();
    if (raw.isNotEmpty) {
      final err = validateEbookApiUrl(raw);
      if (err != null) {
        setState(() {
          _testOk = false;
          _testMessage = err;
        });
        return;
      }
      await ref
          .read(standaloneConfigProvider.notifier)
          .setEbookApi(baseUrl: raw, apiKey: _keyCtrl.text.trim());
    }
    if (!mounted) return;
    setState(() => _step = 1);
  }

  Future<void> _finish() async {
    await ref.read(standaloneConfigProvider.notifier).completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      key: const Key('standalone_onboarding_page'),
      body: EchoAmbientBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.all(EchoMetrics.space4),
                children: [
                  const SizedBox(height: EchoMetrics.space2),
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 52,
                    color: tokens.primary,
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  Text(
                    '欢迎使用回声 · 单机版',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineSmall?.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _step == 0
                        ? '第 1 步 / 共 2 步 · 配置在线书源服务（可选）'
                        : '第 2 步 / 共 2 步 · 下载端侧离线语音模型（可选）',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space4),
                  if (_step == 0)
                    _buildStep1(context, tokens, textTheme)
                  else
                    _buildStep2(context, tokens, textTheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep1(
    BuildContext context,
    EchoTokens tokens,
    TextTheme textTheme,
  ) {
    return Container(
      padding: const EdgeInsets.all(EchoMetrics.space3),
      decoration: echoElevatedCardDecoration(context, radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '连接 ebook-api 搜书服务',
            style: textTheme.titleMedium?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '应用不内置服务地址。填写你部署的 ebook-api 地址即可在线搜书下载；也可以先跳过，直接导入手机里的 EPUB / TXT。',
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: EchoMetrics.space3),
          TextField(
            key: const Key('onboarding_url_field'),
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'ebook-api 地址',
              hintText: 'http://192.168.1.10:8091',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: EchoMetrics.space2),
          TextField(
            key: const Key('onboarding_key_field'),
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key（可选）',
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          if (_testMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _testMessage!,
              style: textTheme.bodySmall?.copyWith(
                color: _testOk ? tokens.success : tokens.error,
              ),
            ),
          ],
          const SizedBox(height: EchoMetrics.space3),
          Row(
            children: [
              OutlinedButton(
                onPressed: _testing ? null : _testEbookApi,
                child: Text(_testing ? '测试中...' : '测试连接'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('onboarding_next_button'),
                  onPressed: _saveApiAndNext,
                  child: const Text('下一步'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('onboarding_skip_api_button'),
            onPressed: () => setState(() => _step = 1),
            child: const Text('暂不配置，跳过此步'),
          ),
        ],
      ),
    );
  }

  Widget _buildStep2(
    BuildContext context,
    EchoTokens tokens,
    TextTheme textTheme,
  ) {
    final modelsState = ref.watch(ttsModelManagerProvider);
    final manager = ref.read(ttsModelManagerProvider.notifier);
    final config = ref.watch(standaloneConfigProvider);
    final configCtrl = ref.read(standaloneConfigProvider.notifier);
    final mirrorIds = TtsModelCatalog.downloadMirrors.map((m) => m.id).toSet();
    final selectedMirrorId = mirrorIds.contains(config.ttsDownloadMirror)
        ? config.ttsDownloadMirror
        : TtsModelCatalog.mirrorGhFast;

    return Container(
      padding: const EdgeInsets.all(EchoMetrics.space3),
      decoration: echoElevatedCardDecoration(context, radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择一个离线语音模型',
            style: textTheme.titleMedium?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '所有语音合成完全在手机本地运行，无需联网。可直接使用 Android 系统语音，或下载离线高质量模型。',
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: 10),
          DropdownButtonHideUnderline(
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: '下载镜像源',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButton<String>(
                key: const Key('onboarding_mirror_dropdown'),
                isExpanded: true,
                value: selectedMirrorId,
                items: [
                  for (final opt in TtsModelCatalog.downloadMirrors)
                    DropdownMenuItem<String>(
                      value: opt.id,
                      child: Text(opt.label),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    configCtrl.setTtsDownloadMirror(v);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: EchoMetrics.space2),
          for (final entry in modelsState.orderedEntries) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tokens.surfaceElevated.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: tokens.textDisabled.withValues(alpha: 0.28),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.spec.name,
                          style: textTheme.titleSmall?.copyWith(
                            color: tokens.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        entry.spec.isSystemTts
                            ? '免下载'
                            : '~${entry.spec.estimatedSizeMb}MB',
                        style: textTheme.labelSmall?.copyWith(
                          color: tokens.textDisabled,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.spec.subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (entry.spec.isSystemTts)
                    Row(
                      children: [
                        if (entry.isInstalled) ...[
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: tokens.success,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '免下载就绪',
                            style: textTheme.labelMedium?.copyWith(
                              color: tokens.success,
                            ),
                          ),
                          const Spacer(),
                          FilledButton.tonal(
                            onPressed: () => configCtrl.setActiveTtsModel(
                              entry.spec.id,
                              speakerId: 0,
                            ),
                            child: Text(
                              config.activeTtsModelId == entry.spec.id
                                  ? '已设为默认'
                                  : '设为默认',
                            ),
                          ),
                        ] else
                          Text(
                            '仅 Android 真机可用',
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textDisabled,
                            ),
                          ),
                      ],
                    )
                  else if (entry.isBusy || entry.isPaused) ...[
                    LinearProgressIndicator(
                      value: entry.progress > 0
                          ? entry.progress
                          : (entry.isPaused ? 0 : null),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.statusText,
                            style: textTheme.labelSmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ),
                        if (entry.status == ModelInstallStatus.downloading)
                          TextButton(
                            onPressed: () =>
                                manager.pauseDownload(entry.spec.id),
                            child: const Text('暂停'),
                          )
                        else if (entry.isPaused) ...[
                          TextButton(
                            onPressed: () =>
                                manager.clearPartialDownload(entry.spec.id),
                            child: const Text('清除'),
                          ),
                          FilledButton.tonal(
                            onPressed: () =>
                                manager.downloadModel(entry.spec.id),
                            child: const Text('继续下载'),
                          ),
                        ],
                      ],
                    ),
                  ] else if (entry.isInstalled)
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 16,
                          color: tokens.success,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '已就绪',
                          style: textTheme.labelMedium?.copyWith(
                            color: tokens.success,
                          ),
                        ),
                      ],
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonal(
                        onPressed: () => manager.downloadModel(entry.spec.id),
                        child: const Text('下载模型'),
                      ),
                    ),
                  if (entry.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        entry.error!,
                        style: textTheme.labelSmall?.copyWith(
                          color: tokens.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: EchoMetrics.space2),
          FilledButton(
            key: const Key('onboarding_finish_button'),
            onPressed: _finish,
            child: Text(
              modelsState.installedEntries.isNotEmpty ? '开始使用回声' : '先进入书架，稍后下载',
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _step = 0),
            child: const Text('返回上一步'),
          ),
        ],
      ),
    );
  }
}
