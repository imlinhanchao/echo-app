import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/models.dart';
import '../../design/echo_metrics.dart';
import '../../design/echo_tokens.dart';
import 'jobs_controller.dart';

/// 任务中心 Tab：服务端 jobs 的镜像（下载/转换），可见时轮询 3s。
class JobsPage extends ConsumerStatefulWidget {
  const JobsPage({super.key});

  @override
  ConsumerState<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends ConsumerState<JobsPage> {
  JobsController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(jobsControllerProvider.notifier);
    _controller?.startPolling();
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
                style: textTheme.headlineSmall
                    ?.copyWith(color: tokens.textPrimary),
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
              style:
                  textTheme.bodySmall?.copyWith(color: tokens.error),
            ),
          ),
        Expanded(
          child: state.jobs.isEmpty
              ? Center(
                  key: const Key('jobs_empty'),
                  child: Text(
                    '暂无任务。去「发现」下载一本书吧。',
                    style: textTheme.bodyLarge
                        ?.copyWith(color: tokens.textSecondary),
                  ),
                )
              : ListView.separated(
                  key: const Key('jobs_list'),
                  padding: const EdgeInsets.all(EchoMetrics.space2),
                  itemCount: state.jobs.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: EchoMetrics.space1),
                  itemBuilder: (context, index) {
                    final job = state.jobs[index];
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

    final (statusLabel, statusColor) = switch (job.status) {
      JobStatus.queued => ('排队中', tokens.textSecondary),
      JobStatus.running => ('进行中 ${job.progress}%', tokens.primary),
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
              children: [
                Icon(
                  job.kind == JobKind.download
                      ? Icons.file_download
                      : Icons.graphic_eq,
                  color: job.kind == JobKind.download
                      ? tokens.accent
                      : tokens.primary,
                ),
                const SizedBox(width: EchoMetrics.space1),
                Expanded(
                  child: Text(
                    '${job.kindLabel} #${job.id}',
                    style: textTheme.titleSmall
                        ?.copyWith(color: tokens.textPrimary),
                  ),
                ),
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
                    style:
                        textTheme.labelSmall?.copyWith(color: statusColor),
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
                        ScaffoldMessenger.maybeOf(context)
                            ?.showSnackBar(SnackBar(content: Text(error)));
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
                  style:
                      textTheme.bodySmall?.copyWith(color: tokens.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
