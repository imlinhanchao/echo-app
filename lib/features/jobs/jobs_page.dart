import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import '../library/book_detail_page.dart';
import '../library/convert_sheet.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;
import 'jobs_controller.dart';

enum _JobFilter { all, active, completed }

/// 任务中心 Tab（对齐设计 §4.1）：
/// 全部 / 进行中 / 已完成筛选 + 书名/封面/音色/章级进度 + 完成直达「立即收听」。
class JobsPage extends ConsumerStatefulWidget {
  const JobsPage({super.key, this.isActive = true});

  final bool isActive;

  @override
  ConsumerState<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends ConsumerState<JobsPage> {
  JobsController? _controller;
  _JobFilter _filter = _JobFilter.all;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(jobsControllerProvider.notifier);
    if (widget.isActive) {
      _controller?.startPolling();
    }
  }

  @override
  void didUpdateWidget(JobsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _controller?.startPolling();
      } else {
        _controller?.stopPolling();
      }
    }
  }

  @override
  void dispose() {
    _controller?.stopPolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final state = ref.watch(jobsControllerProvider);
    final controller = ref.read(jobsControllerProvider.notifier);

    final activeCount = state.jobs.where((j) => j.isActive).length;
    final doneCount = state.jobs.where((j) => j.status == JobStatus.done).length;
    final filteredJobs = switch (_filter) {
      _JobFilter.all => state.jobs,
      _JobFilter.active => state.jobs.where((j) => j.isActive).toList(),
      _JobFilter.completed =>
        state.jobs.where((j) => j.status == JobStatus.done).toList(),
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            EchoMetrics.space2,
            EchoMetrics.space2,
            EchoMetrics.space1,
            0,
          ),
          child: Row(
            children: [
              Text(
                '任务',
                key: const Key('jobs_title'),
                style: textTheme.headlineSmall?.copyWith(
                  color: tokens.textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const Key('jobs_refresh'),
                tooltip: '刷新任务',
                onPressed: controller.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // 顶部三态筛选：全部 / 进行中 / 已完成
        Padding(
          padding: const EdgeInsets.fromLTRB(
            EchoMetrics.space2,
            EchoMetrics.space1,
            EchoMetrics.space2,
            EchoMetrics.space1,
          ),
          child: Row(
            children: [
              ChoiceChip(
                key: const Key('jobs_filter_all'),
                label: Text('全部 (${state.jobs.length})'),
                selected: _filter == _JobFilter.all,
                onSelected: (_) => setState(() => _filter = _JobFilter.all),
              ),
              const SizedBox(width: EchoMetrics.space1),
              ChoiceChip(
                key: const Key('jobs_filter_active'),
                label: Text('进行中 ($activeCount)'),
                selected: _filter == _JobFilter.active,
                onSelected: (_) => setState(() => _filter = _JobFilter.active),
              ),
              const SizedBox(width: EchoMetrics.space1),
              ChoiceChip(
                key: const Key('jobs_filter_completed'),
                label: Text('已完成 ($doneCount)'),
                selected: _filter == _JobFilter.completed,
                onSelected: (_) =>
                    setState(() => _filter = _JobFilter.completed),
              ),
            ],
          ),
        ),
        if (state.error != null)
          Container(
            key: const Key('jobs_error_banner'),
            width: double.infinity,
            color: tokens.error.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
              horizontal: EchoMetrics.space2,
              vertical: EchoMetrics.space1,
            ),
            child: Text(
              state.error!,
              style: textTheme.bodySmall?.copyWith(color: tokens.error),
            ),
          ),
        Expanded(
          child: filteredJobs.isEmpty
              ? Center(
                  key: const Key('jobs_empty'),
                  child: Text(
                    state.jobs.isEmpty
                        ? '暂无任务。去「发现」下载一本书吧。'
                        : (_filter == _JobFilter.active
                              ? '当前没有进行中的任务'
                              : '还没有已完成的任务'),
                    style: textTheme.bodyLarge?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                )
              : ListView.separated(
                  key: const Key('jobs_list'),
                  padding: const EdgeInsets.all(EchoMetrics.space2),
                  itemCount: filteredJobs.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: EchoMetrics.space1),
                  itemBuilder: (context, index) {
                    final job = filteredJobs[index];
                    return _JobCard(job: job);
                  },
                ),
        ),
      ],
    );
  }
}

class _JobCard extends ConsumerWidget {
  const _JobCard({required this.job});

  final JobInfo job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    final textTheme = Theme.of(context).textTheme;
    final controller = ref.read(jobsControllerProvider.notifier);
    final libState = ref.watch(libraryControllerProvider);

    // 关联书库信息（书名、封面、音色/模型）
    AudiobookInfo? audiobook;
    LibraryBook? book;
    if (job.kind == JobKind.audiobook) {
      final targetAudioId =
          job.refId ?? (job.result?['audiobook_id'] as num?)?.toInt();
      if (targetAudioId != null) {
        audiobook = libState.audiobooks
            .where((a) => a.id == targetAudioId)
            .firstOrNull;
      }
      final bookId =
          audiobook?.bookId ?? (job.result?['book_id'] as num?)?.toInt();
      if (bookId != null) {
        book = libState.books.where((b) => b.id == bookId).firstOrNull;
      }
    } else if (job.kind == JobKind.download) {
      final bookId =
          (job.result?['book_id'] as num?)?.toInt() ?? job.refId;
      if (bookId != null) {
        book = libState.books.where((b) => b.id == bookId).firstOrNull;
      }
    }

    final resolvedTitle = (audiobook?.bookTitle.isNotEmpty ?? false)
        ? audiobook!.bookTitle
        : (book?.title.isNotEmpty ?? false)
        ? book!.title
        : (job.result?['title'] as String?)?.isNotEmpty == true
        ? job.result!['title'] as String
        : '${job.kindLabel} #${job.id}';

    // 章级进度（后端 result 携带时优先展示）
    final completedChapters =
        (job.result?['completed_chapters'] as num?)?.toInt();
    final totalChapters = (job.result?['total_chapters'] as num?)?.toInt();
    final chapterProgressText =
        (completedChapters != null &&
            totalChapters != null &&
            totalChapters > 0)
        ? '第 $completedChapters/$totalChapters 章'
        : null;

    final voiceMeta = <String>[
      if (audiobook?.model.isNotEmpty == true) audiobook!.model,
      if (audiobook?.voice.isNotEmpty == true) audiobook!.voice,
    ].join(' · ');

    final (statusLabel, statusColor) = switch (job.status) {
      JobStatus.queued => ('排队中', tokens.textSecondary),
      JobStatus.running => (
        chapterProgressText ?? '进行中 ${job.progress}%',
        tokens.primary,
      ),
      JobStatus.cancelling => ('取消中', tokens.warning),
      JobStatus.done => ('已完成', tokens.success),
      JobStatus.failed => ('失败', tokens.error),
      JobStatus.cancelled => ('已取消', tokens.textSecondary),
      JobStatus.unknown => ('未知', tokens.textSecondary),
    };

    return Card(
      key: Key('job_card_${job.id}'),
      child: Padding(
        padding: const EdgeInsets.all(EchoMetrics.space2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (book != null)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      BookCover(url: book.coverUrl, width: 42, height: 54),
                      if (job.status == JobStatus.done)
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: tokens.surfaceElevated,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.check_circle,
                              size: 16,
                              color: tokens.success,
                            ),
                          ),
                        ),
                    ],
                  )
                else
                  Icon(
                    job.status == JobStatus.done
                        ? Icons.check_circle
                        : (job.kind == JobKind.download
                              ? Icons.file_download
                              : Icons.graphic_eq),
                    color: job.status == JobStatus.done
                        ? tokens.success
                        : (job.kind == JobKind.download
                              ? tokens.accent
                              : tokens.primary),
                  ),
                const SizedBox(width: EchoMetrics.space2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        resolvedTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        voiceMeta.isNotEmpty
                            ? '${job.kindLabel} · $voiceMeta'
                            : '${job.kindLabel} #${job.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: EchoMetrics.space1),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: EchoMetrics.space1,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusLabel,
                    key: Key('job_status_${job.id}'),
                    style: textTheme.labelSmall?.copyWith(color: statusColor),
                  ),
                ),
                if (job.isActive)
                  IconButton(
                    key: Key('job_cancel_${job.id}'),
                    tooltip: '取消任务',
                    icon: Icon(Icons.close, color: tokens.error),
                    onPressed: () async {
                      final error = await controller.cancel(job.id);
                      if (error != null && context.mounted) {
                        ScaffoldMessenger.maybeOf(
                          context,
                        )?.showSnackBar(SnackBar(content: Text(error)));
                      }
                    },
                  ),
              ],
            ),
            if (job.status == JobStatus.running ||
                job.status == JobStatus.cancelling)
              Padding(
                padding: const EdgeInsets.only(top: EchoMetrics.space1),
                child: LinearProgressIndicator(
                  key: Key('job_progress_${job.id}'),
                  value: (job.progress / 100).clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: tokens.surfaceSubtle,
                  color: tokens.primary,
                ),
              ),
            if (job.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: EchoMetrics.space1),
                child: Text(
                  job.error,
                  key: Key('job_error_${job.id}'),
                  style: textTheme.bodySmall?.copyWith(color: tokens.error),
                ),
              ),
            // 完成直达 / 失败重试操作行
            if (job.status == JobStatus.done &&
                audiobook != null &&
                audiobook.isReady)
              Padding(
                padding: const EdgeInsets.only(top: EchoMetrics.space1),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    key: Key('job_listen_${job.id}'),
                    onPressed: () async {
                      await ref
                          .read(chunkedPlayerProvider.notifier)
                          .loadAudiobook(
                            audiobook!,
                            coverUrl: book?.coverUrl,
                          );
                      if (context.mounted) {
                        await openPlayer(context);
                      }
                    },
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('立即收听'),
                  ),
                ),
              )
            else if (job.status == JobStatus.done &&
                job.kind == JobKind.download &&
                book != null)
              Padding(
                padding: const EdgeInsets.only(top: EchoMetrics.space1),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    key: Key('job_detail_${job.id}'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BookDetailPage(book: book!),
                      ),
                    ),
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('查看详情'),
                  ),
                ),
              )
            else if (job.status == JobStatus.failed &&
                job.kind == JobKind.audiobook &&
                book != null)
              Padding(
                padding: const EdgeInsets.only(top: EchoMetrics.space1),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: Key('job_retry_${job.id}'),
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => ConvertSheet(book: book!),
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新转换'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
