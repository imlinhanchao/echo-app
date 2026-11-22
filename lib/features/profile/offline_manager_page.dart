import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/chunked_player_controller.dart';
import '../../core/offline/offline_store.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/bookshelf_tab.dart' show confirmDelete;
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;

/// 离线内容管理页（对齐设计 §4.1 我的页 → 离线内容管理）：
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
      '将删除《$title》的本地离线音频与字幕（不会删除云端书库），可随时重新下载。',
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

    return Scaffold(
      key: const Key('offline_manager_page'),
      appBar: AppBar(
        title: const Text('离线内容管理'),
        actions: [
          if (!_loading && !_summary.isEmpty)
            TextButton.icon(
              key: const Key('offline_clear_all'),
              onPressed: _clearAll,
              icon: Icon(Icons.delete_sweep_outlined, color: tokens.error),
              label: Text('清空全部', style: TextStyle(color: tokens.error)),
            ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: tokens.primary))
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(EchoMetrics.space2),
                children: [
                  // 顶部存储概览卡
                  Card(
                    key: const Key('offline_summary_card'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: EchoMetrics.space2,
                        vertical: EchoMetrics.space3,
                      ),
                      child: Row(
                        children: [
                          _SummaryMetric(
                            key: const Key('offline_metric_books'),
                            value: '${_summary.entries.length} 本',
                            label: '已下载',
                          ),
                          _SummaryMetric(
                            key: const Key('offline_metric_chunks'),
                            value: '${_summary.totalChunks} 章',
                            label: '音频分块',
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
                  const SizedBox(height: EchoMetrics.space2),
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
                            size: 48,
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
                    for (final entry in _summary.entries) ...[
                      Builder(
                        builder: (context) {
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

                          return Card(
                            key: Key('offline_item_${entry.audiobookId}'),
                            child: ListTile(
                              leading: BookCover(
                                url: book?.coverUrl,
                                width: 44,
                                height: 56,
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
                                style: textTheme.bodySmall?.copyWith(
                                  color: tokens.textSecondary,
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
                                        Icons.play_arrow,
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
      child: Column(
        children: [
          Text(
            value,
            style: textTheme.titleLarge?.copyWith(
              color: tokens.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
