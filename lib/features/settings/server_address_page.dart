import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/server_address_store.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';

/// 服务地址设置页（登录页与「我的」页共用）。
///
/// - 输入框支持手输 / 历史地址点选，[ServerAddressStore.normalize] 统一校验；
/// - 保存后立即切换当前 [EchoApi] 的 baseUrl，并持久化到安全存储；
/// - 已登录状态下切换地址会清除本机 Token 并回登录页（新服务端不认旧 Token）。
class ServerAddressPage extends ConsumerStatefulWidget {
  const ServerAddressPage({super.key});

  @override
  ConsumerState<ServerAddressPage> createState() => _ServerAddressPageState();
}

class _ServerAddressPageState extends ConsumerState<ServerAddressPage> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ServerAddressStore.current.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final normalized = ServerAddressStore.normalize(_controller.text);
    if (normalized == null) {
      setState(() => _error = '请输入有效的地址，例如 http://192.168.50.200:8090');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final wasLoggedIn = ref.read(authControllerProvider) is AuthLoggedIn;
    final auth = ref.read(authControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final changed = await ServerAddressStore.setCurrent(normalized);
    ref.read(echoApiProvider).updateBaseUrl(Uri.parse(normalized));
    if (changed && wasLoggedIn) {
      // 先回登录页再由状态机切登录态，避免已卸载路由上的导航操作。
      navigator.pop();
      await auth.handleServerChanged();
    } else {
      navigator.pop();
    }
    messenger.showSnackBar(
      SnackBar(content: Text(changed ? '服务地址已更新' : '服务地址未变化')),
    );
  }

  void _useAddress(String address) {
    _controller.text = address;
    setState(() => _error = null);
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      key: const Key('server_address_page'),
      appBar: AppBar(title: const Text('服务地址')),
      body: ListView(
        padding: const EdgeInsets.all(EchoMetrics.space3),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(EchoMetrics.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '回声服务端地址',
                    style: textTheme.titleMedium?.copyWith(
                      color: tokens.textPrimary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.spaceHalf),
                  Text(
                    '手机与电脑需在同一局域网；默认地址可在打包时通过 '
                    'ECHO_BASE_URL 指定。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  TextField(
                    key: const Key('server_address_input'),
                    controller: _controller,
                    keyboardType: TextInputType.url,
                    autofillHints: const [AutofillHints.url],
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      labelText: '服务地址',
                      hintText: 'http://192.168.50.200:8090',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      errorText: _error,
                      helperText: '可省略 http://，默认补全为 http',
                    ),
                  ),
                  const SizedBox(height: EchoMetrics.space2),
                  FilledButton.icon(
                    key: const Key('server_address_save'),
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.check),
                    label: Text(_busy ? '保存中…' : '保存并使用'),
                  ),
                  const SizedBox(height: EchoMetrics.space1),
                  TextButton.icon(
                    key: const Key('server_address_reset'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _controller.text = kEchoDefaultBaseUrl;
                            _error = null;
                          }),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('填入默认地址'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: EchoMetrics.space3),
          Text(
            '历史地址',
            style: textTheme.titleMedium?.copyWith(color: tokens.textPrimary),
          ),
          const SizedBox(height: EchoMetrics.space1),
          ValueListenableBuilder<List<String>>(
            valueListenable: ServerAddressStore.history,
            builder: (context, addresses, _) {
              if (addresses.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: EchoMetrics.space2,
                  ),
                  child: Text(
                    '还没有历史地址，保存后会出现在这里。',
                    style: textTheme.bodySmall?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                );
              }
              return Column(
                key: const Key('server_history_list'),
                children: [
                  for (var i = 0; i < addresses.length; i++)
                    _HistoryTile(
                      key: ValueKey<String>('server_history_$i'),
                      address: addresses[i],
                      isCurrent:
                          addresses[i] == ServerAddressStore.current.value,
                      enabled: !_busy,
                      onUse: () => _useAddress(addresses[i]),
                      onDelete: () =>
                          ServerAddressStore.removeHistory(addresses[i]),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    super.key,
    required this.address,
    required this.isCurrent,
    required this.enabled,
    required this.onUse,
    required this.onDelete,
  });

  final String address;
  final bool isCurrent;
  final bool enabled;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isCurrent ? Icons.check_circle : Icons.history,
        color: isCurrent ? tokens.accent : tokens.textSecondary,
      ),
      title: Text(
        address,
        style: textTheme.bodyMedium?.copyWith(
          color: isCurrent ? tokens.accent : tokens.textPrimary,
        ),
      ),
      subtitle: isCurrent
          ? Text(
              '当前使用中',
              style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            )
          : null,
      onTap: enabled ? onUse : null,
      trailing: IconButton(
        key: const Key('server_history_delete'),
        tooltip: '删除这条历史',
        icon: Icon(Icons.delete_outline, color: tokens.textSecondary),
        onPressed: enabled ? onDelete : null,
      ),
    );
  }
}
