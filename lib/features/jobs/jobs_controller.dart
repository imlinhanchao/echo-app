import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../auth/auth_controller.dart';
import '../library/library_controller.dart';

@immutable
class JobsState {
  const JobsState({
    this.jobs = const <JobInfo>[],
    this.total = 0,
    this.isLoading = false,
    this.error,
  });

  final List<JobInfo> jobs;
  final int total;
  final bool isLoading;
  final String? error;

  bool get hasActiveJobs => jobs.any((j) => j.isActive);

  JobsState copyWith({
    List<JobInfo>? jobs,
    int? total,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return JobsState(
      jobs: jobs ?? this.jobs,
      total: total ?? this.total,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 任务中心控制器：服务端 jobs 的镜像 + 可见时轮询。
///
/// - 轮询仅在任务页可见时开启（3s 间隔），有活跃任务时保持；
/// - 任一任务新近完成时回调 [onJobFinished]（用于刷新书架）；
/// - 取消任务、失败原因直显（错误码语义来自服务端）。
class JobsController extends StateNotifier<JobsState> {
  JobsController(this._api, {this.onJobFinished})
      : super(const JobsState());

  final EchoApi _api;
  final VoidCallback? onJobFinished;

  Timer? _timer;
  final Set<int> _knownDoneJobIds = <int>{};

  /// 页面可见时开启轮询；立即刷一次。
  void startPolling() {
    refresh();
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  /// 页面不可见时停止轮询。
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    try {
      final page = await _api.listJobs();
      var anyNewlyFinished = false;
      for (final job in page.jobs) {
        final isDone = job.status == JobStatus.done;
        if (isDone && !_knownDoneJobIds.contains(job.id)) {
          anyNewlyFinished = true;
        }
        if (isDone) {
          _knownDoneJobIds.add(job.id);
        } else {
          _knownDoneJobIds.remove(job.id);
        }
      }
      state = state.copyWith(
        jobs: page.jobs,
        total: page.total,
        isLoading: false,
        clearError: true,
      );
      if (anyNewlyFinished) {
        onJobFinished?.call();
      }
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  Future<String?> cancel(int id) async {
    try {
      await _api.cancelJob(id);
      await refresh();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}

final StateNotifierProvider<JobsController, JobsState> jobsControllerProvider =
    StateNotifierProvider<JobsController, JobsState>((ref) {
  return JobsController(
    ref.watch(echoApiProvider),
    // 任务完成（下载入库 / 转换产出入书架）时刷新书架列表。
    onJobFinished: () =>
        ref.read(libraryControllerProvider.notifier).refresh(),
  );
});
