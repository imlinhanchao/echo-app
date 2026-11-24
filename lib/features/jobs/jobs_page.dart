import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../core/audio/chunked_player_controller.dart';
import '../../design/book_cover.dart';
import '../../design/echo_ambient.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_surfaces.dart';
import '../../design/echo_tokens.dart';
import '../library/book_detail_page.dart';
import '../library/convert_sheet.dart';
import '../library/library_controller.dart';
import '../player/player_sheet.dart' show openPlayer;
import 'jobs_controller.dart';

enum _JobFilter { all, active, completed }

/// 任务中心 Tab（极简书房 Editorial Minimalism）：
/// 极简分段筛选胶囊（全部 / 进行中 / 已完成）+ 细描边卡片 + 清晰章级进度。
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
    final hasPlayer = ref.watch(
      chunkedPlayerProvider.select((s) => s.hasBook),
    );

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
            EchoMetrics.pagePadding,
            EchoMetrics.space2,
            12,
            EchoMetrics.space1,
          ),
          child: Row(
            children: [
              Text(
                '任务中心',
                key: const Key('jobs_title'),
                style: textTheme.headlineSmall?.copyWith(
                  fontSize: 25,
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const Key('jobs_refresh'),
                tooltip: '刷新任务',
                color: tokens.textSecondary,
                onPressed: controller.refresh,
                icon: const Icon(Icons.refresh_rounded, size: 22),
              ),
            ],
          ),
        ),
        // 极简胶囊分段筛选：全部 / 进行中 / 已完成
        Padding(
          padding: const EdgeInsets.fromLTRB(
            EchoMetrics.pagePadding,
            4,
            EchoMetrics.pagePadding,
            14,
          ),
          child: Row(
            children: [
              _SegmentPill(
                key: const Key('jobs_filter_all'),
                label: '全部 (${state.jobs.length})',
                selected: _filter == _JobFilter.all,
                onTap: () => setState(() => _filter = _JobFilter.all),
              ),
              const SizedBox(width: 8),
              _SegmentPill(
                key: const Key('jobs_filter_active'),
                label: '进行中 ($activeCount)',
                selected: _filter == _JobFilter.active,
                onTap: () => setState(() => _filter = _JobFilter.active),
              ),
              const SizedBox(width: 8),
              _SegmentPill(
                key: const Key('jobs_filter_completed'),
                label: '已完成 ($doneCount)',
                selected: _filter == _JobFilter.completed,
                onTap: () => setState(() => _filter = _JobFilter.completed),
              ),
            ],
          ),
        ),
        if (state.error != null)
          Container(
            key: const Key('jobs_error_banner'),
            margin: const EdgeInsets.fromLTRB(
              EchoMetrics.pagePadding,
              0,
              EchoMetrics.pagePadding,
              12,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: echoElevatedCardDecoration(
              context,
              radius: 12,
              color: tokens.error.withValues(alpha: 0.08),
              borderColor: tokens.error.withValues(alpha: 0.25),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.checklist_rounded,
                        size: 38,
                        color: tokens.textDisabled,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        state.jobs.isEmpty
                            ? '暂无任务，去「发现」或书库开启创作吧'
                            : (_filter == _JobFilter.active
                                  ? '当前没有进行中的任务'
                                  : '还没有已完成的任务'),
                        style: textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  key: const Key('jobs_list'),
                  padding: EdgeInsets.fromLTRB(
                    EchoMetrics.pagePadding,
                    0,
                    EchoMetrics.pagePadding,
                    hasPlayer ? 112 : EchoMetrics.space3,
                  ),
                  itemCount: filteredJobs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
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

/// 极简筛选胶囊（无刺眼蓝紫高光与阴影）。
class _SegmentPill extends StatelessWidget {
  const _SegmentPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: EchoMetrics.motionFast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? tokens.primary : tokens.surfaceElevated,
            borderRadius: BorderRadius.circular(EchoMetrics.radiusPill),
            border: Border.all(
              color: selected ? tokens.primary : echoHairlineColor(context),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontSize: 12.5,
              color: selected ? tokens.textOnPrimary : tokens.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
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
      final bookId = (job.result?['book_id'] as num?)?.toInt() ?? job.refId;
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

    return Container(
      key: Key('job_card_${job.id}'),
      padding: const EdgeInsets.all(14),
      decoration: echoElevatedCardDecoration(context, radius: 16),
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
                    BookCover(
                      url: book.coverUrl,
                      title: resolvedTitle,
                      width: 42,
                      height: 60,
                      borderRadius: 7,
                    ),
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
                            Icons.check_circle_rounded,
                            size: 16,
                            color: tokens.success,
                          ),
                        ),
                      ),
                  ],
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tokens.surfaceSubtle,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    job.status == JobStatus.done
                        ? Icons.check_circle_rounded
                        : (job.kind == JobKind.download
                              ? Icons.file_download_outlined
                              : Icons.graphic_eq_rounded),
                    size: 20,
                    color: job.status == JobStatus.done
                        ? tokens.success
                        : tokens.primary,
                  ),
                ),
              const SizedBox(width: 12),
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
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          statusLabel,
                          key: Key('job_status_${job.id}'),
                          style: textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (voiceMeta.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: EchoPillBadge(
                              label: voiceMeta,
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (job.isActive)
                IconButton(
                  key: Key('job_cancel_${job.id}'),
                  tooltip: '取消任务',
                  icon: Icon(
                    Icons.close_rounded,
                    size: 19,
                    color: tokens.textSecondary,
                  ),
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
              padding: const EdgeInsets.only(top: 12),
              child: job.kind == JobKind.audiobook
                  ? _SegmentedProgressBar(
                      key: Key('job_progress_${job.id}'),
                      progress: (job.progress / 100).clamp(0.0, 1.0),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        key: Key('job_progress_${job.id}'),
                        value: (job.progress / 100).clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: tokens.surfaceSubtle,
                        color: tokens.primary,
                      ),
                    ),
            ),
          if (job.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                job.error,
                key: Key('job_error_${job.id}'),
                style: textTheme.bodySmall?.copyWith(color: tokens.error),
              ),
            ),
          if (audiobook != null &&
              audiobook.isPlayable &&
              (job.status == JobStatus.done || job.isActive))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: Key('job_listen_${job.id}'),
                  onPressed: () async {
                    await ref
                        .read(chunkedPlayerProvider.notifier)
                        .loadAudiobook(audiobook!, coverUrl: book?.coverUrl);
                    if (context.mounted) {
                      await openPlayer(context);
                    }
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(audiobook.isReady ? '立即收听' : '抢先收听'),
                ),
              ),
            )
          else if (job.status == JobStatus.done &&
              job.kind == JobKind.download &&
              book != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
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
              padding: const EdgeInsets.only(top: 12),
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
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重新转换'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 分段式转换进度条。
class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<EchoTokens>()!;
    const segments = 6;
    final filledExact = progress * segments;
    return Row(
      children: [
        for (var i = 0; i < segments; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: (filledExact - i).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: tokens.surfaceSubtle,
                color: tokens.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
