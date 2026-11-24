import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/offline/offline_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/bookshelf_tab.dart' show confirmDelete;
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;

/// 离线内容管理页（极简书房 Editorial Minimalism）：
/// 汇总展示已下载书目数、分块/章节数与本地占用体积，支持单本播放/删除与一键清空。
class OfflineManagerPage extends ConsumerStatefulWidget {
  const OfflineManagerPage({super.key});

  @override
  ConsumerState<OfflineManagerPage> createState() => _OfflineManagerPageState();
}

class _OfflineManagerPageState extends ConsumerState<OfflineManagerPage> {
  OfflineSummary _summary = const OfflineSummary();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final summary = await OfflineFiles.scanAll();
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _loading = false;
    });
  }

  Future<void> _removeOne(int audiobookId, String title) async {
    final ok = await confirmDelete(
      context,
      '删除离线缓存',
      '将删除《$title》的本地离线音频与字幕（不会删除书库），可随时重新下载。',
    );
    if (!ok || !mounted) return;
    await ref.read(offlineStoreProvider.notifier).removeById(audiobookId);
    await _reload();
  }

  Future<void> _clearAll() async {
    final ok = await confirmDelete(
      context,
      '清空全部离线缓存',
      '将清理本地全部 ${_summary.entries.length} 本离线有声书，释放 ${formatBytes(_summary.totalBytes)} 空间。',
    );
    if (!ok || !mounted) return;
    await ref.read(offlineStoreProvider.notifier).clearAll();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final libState = ref.watch(libraryControllerProvider);
    final hairline = echoHairlineColor(context, darkAlpha: 0.08);

    return Scaffold(
      key: const Key('offline_manager_page'),
      appBar: AppBar(
        title: const Text('离线内容管理'),
        actions: [
          if (!_loading && !_summary.isEmpty)
            TextButton.icon(
              key: const Key('offline_clear_all'),
              onPressed: _clearAll,
              icon: Icon(
                Icons.delete_sweep_outlined,
                size: 19,
                color: tokens.error,
              ),
              label: Text('清空全部', style: TextStyle(color: tokens.error)),
            ),
        ],
      ),
      body: EchoAmbientBackground(
        child: _loading
            ? Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: tokens.primary,
                ),
              )
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  padding: const EdgeInsets.all(EchoMetrics.pagePadding),
                  children: [
                    // 顶部三列存储概览卡
                    Container(
                      key: const Key('offline_summary_card'),
                      decoration: echoElevatedCardDecoration(
                        context,
                        radius: 16,
                      ),
                      child: IntrinsicHeight(
                        child: Row(
                          children: [
                            _SummaryMetric(
                              key: const Key('offline_metric_books'),
                              value: '${_summary.entries.length} 本',
                              label: '已下载',
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 0.6,
                              indent: 14,
                              endIndent: 14,
                              color: hairline,
                            ),
                            _SummaryMetric(
                              key: const Key('offline_metric_chunks'),
                              value: '${_summary.totalChunks} 章',
                              label: '音频分块',
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 0.6,
                              indent: 14,
                              endIndent: 14,
                              color: hairline,
                            ),
                            _SummaryMetric(
                              key: const Key('offline_metric_bytes'),
                              value: formatBytes(_summary.totalBytes),
                              label: '占用空间',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: EchoMetrics.space3),
                    if (_summary.isEmpty)
                      Padding(
                        key: const Key('offline_empty'),
                        padding: const EdgeInsets.symmetric(
                          vertical: EchoMetrics.space5,
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.offline_pin_outlined,
                              size: 44,
                              color: tokens.textDisabled,
                            ),
                            const SizedBox(height: EchoMetrics.space2),
                            Text(
                              '还没有离线下载的有声书',
                              style: textTheme.titleSmall?.copyWith(
                                color: tokens.textPrimary,
                              ),
                            ),
                            const SizedBox(height: EchoMetrics.spaceHalf),
                            Text(
                              '在书籍详情页点击下载按钮，无网也能随时收听',
                              style: textTheme.bodySmall?.copyWith(
                                color: tokens.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      for (var i = 0; i < _summary.entries.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        Builder(
                          builder: (context) {
                            final entry = _summary.entries[i];
                            final audio = libState.audiobooks
                                .where((a) => a.id == entry.audiobookId)
                                .firstOrNull;
                            final book = audio == null
                                ? null
                                : libState.books
                                      .where((b) => b.id == audio.bookId)
                                      .firstOrNull;
                            final title = (audio?.bookTitle.isNotEmpty ?? false)
                                ? audio!.bookTitle
                                : (book?.title.isNotEmpty ?? false)
                                ? book!.title
                                : '有声书 #${entry.audiobookId}';
                            final meta = <String>[
                              '${entry.chunks} 章',
                              formatBytes(entry.bytes),
                              if (audio?.model.isNotEmpty == true) audio!.model,
                            ].join(' · ');

                            return Container(
                              key: Key('offline_item_${entry.audiobookId}'),
                              decoration: echoElevatedCardDecoration(
                                context,
                                radius: 14,
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 4,
                                ),
                                leading: BookCover(
                                  url: book?.coverUrl,
                                  title: title,
                                  width: 40,
                                  height: 56,
                                  borderRadius: 6,
                                ),
                                title: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleSmall?.copyWith(
                                    color: tokens.textPrimary,
                                  ),
                                ),
                                subtitle: Text(
                                  meta,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: tokens.textSecondary,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (audio != null && audio.isReady)
                                      IconButton(
                                        key: Key(
                                          'offline_play_${entry.audiobookId}',
                                        ),
                                        tooltip: '离线播放',
                                        icon: Icon(
                                          Icons.play_arrow_rounded,
                                          color: tokens.primary,
                                        ),
                                        onPressed: () async {
                                          await ref
                                              .read(
                                                chunkedPlayerProvider.notifier,
                                              )
                                              .loadAudiobook(
                                                audio,
                                                coverUrl: book?.coverUrl,
                                              );
                                          if (context.mounted) {
                                            await openPlayer(context);
                                          }
                                        },
                                      ),
                                    IconButton(
                                      key: Key(
                                        'offline_delete_${entry.audiobookId}',
                                      ),
                                      tooltip: '删除缓存',
                                      icon: Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                        color: tokens.error,
                                      ),
                                      onPressed: () =>
                                          _removeOne(entry.audiobookId, title),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({super.key, required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Column(
          children: [
            Text(
              value,
              style: textTheme.titleLarge?.copyWith(
                color: tokens.primary,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
