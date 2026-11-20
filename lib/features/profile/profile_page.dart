import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../auth/auth_controller.dart';
import '../providers/provider_account_page.dart';

/// 我的 Tab：账号信息、服务地址、书源账号入口、登出。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key, required this.user});

  final EchoUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      key: const Key('profile_page'),
      padding: const EdgeInsets.all(EchoMetrics.space2),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(EchoMetrics.space3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: tokens.primary.withValues(alpha: 0.2),
                      child: Icon(Icons.person, color: tokens.primary),
                    ),
                    const SizedBox(width: EchoMetrics.space2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.email,
                            key: const Key('echo_user_email'),
                            style: textTheme.titleMedium
                                ?.copyWith(color: tokens.textPrimary),
                          ),
                          Text(
                            '用户 #${user.id}',
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: EchoMetrics.space2),
        Card(
          child: Column(
            children: [
              ListTile(
                key: const Key('profile_server_address'),
                leading: Icon(Icons.dns_outlined, color: tokens.accent),
                title: const Text('服务地址'),
                subtitle: Text(kEchoBaseUrl),
              ),
              ListTile(
                key: const Key('profile_providers'),
                leading: Icon(Icons.source_outlined, color: tokens.accent),
                title: const Text('书源账号'),
                subtitle: const Text('zlib 镜像 / 邮箱密码 / Cookie 导入'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ProviderAccountPage(),
                  ),
                ),
              ),
              ListTile(
                key: const Key('profile_about'),
                leading: Icon(Icons.info_outline, color: tokens.accent),
                title: const Text('关于'),
                subtitle: const Text('Echo · 回声 v0.1.0 · Phase 2 获取闭环'),
              ),
            ],
          ),
        ),
        const SizedBox(height: EchoMetrics.space3),
        FilledButton.tonalIcon(
          key: const Key('echo_logout'),
          onPressed: () => ref.read(authControllerProvider.notifier).logout(),
          icon: const Icon(Icons.logout),
          label: const Text('退出登录'),
        ),
      ],
    );
  }
}
