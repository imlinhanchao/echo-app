import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/api/models.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/features/jobs/jobs_controller.dart';

import 'stub_adapter.dart';

void main() {
  group('JobsController 任务轮询状态机（Stub 传输层）', () {
    test('刷新反映状态变化；任务完成时触发一次回调；完成后不重复触发', () async {
      var jobStatus = 'running';
      var finishedCalls = 0;

      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/jobs': () => okResponse(<String, dynamic>{
              'jobs': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 5,
                  'kind': 'audiobook',
                  'status': jobStatus,
                  'progress': 42,
                  'created_at': '2026-11-20T07:00:00Z',
                },
              ],
              'total': 1,
            }),
      });
      final api = EchoApi(
        dio: stubDio(adapter),
        tokenStore: MemoryTokenStore(),
      );
      final controller = JobsController(
        api,
        onJobFinished: () => finishedCalls++,
      );

      await controller.refresh();
      expect(controller.state.jobs.single.status, JobStatus.running);
      expect(controller.state.hasActiveJobs, isTrue);
      expect(finishedCalls, 0);

      // 转换完成：回调触发一次
      jobStatus = 'done';
      await controller.refresh();
      expect(controller.state.jobs.single.status, JobStatus.done);
      expect(finishedCalls, 1);

      // 再次轮询同一 done 任务：不重复触发
      await controller.refresh();
      expect(finishedCalls, 1);
    });

    test('取消任务：调用 cancel 端点并刷新列表', () async {
      var cancelCalled = false;
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/jobs': () => okResponse(<String, dynamic>{
              'jobs': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 5,
                  'kind': 'download',
                  'status': 'running',
                  'progress': 10,
                },
              ],
              'total': 1,
            }),
        '/api/jobs/5/cancel': () {
          cancelCalled = true;
          return okResponse(<String, dynamic>{
            'job': <String, dynamic>{
              'id': 5,
              'kind': 'download',
              'status': 'cancelling',
              'progress': 10,
            },
          });
        },
      });
      final api = EchoApi(
        dio: stubDio(adapter),
        tokenStore: MemoryTokenStore(),
      );
      final controller = JobsController(api);

      await controller.refresh();
      final error = await controller.cancel(5);

      expect(error, isNull);
      expect(cancelCalled, isTrue);
      expect(adapter.requestsTo('/api/jobs/5/cancel'), hasLength(1));
    });

    test('任务列表请求失败：错误态直显服务端文案', () async {
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/jobs': () =>
            errorResponse(502, 'INTERNAL', '读取任务失败'),
      });
      final api = EchoApi(
        dio: stubDio(adapter),
        tokenStore: MemoryTokenStore(),
      );
      final controller = JobsController(api);

      await controller.refresh();
      expect(controller.state.jobs, isEmpty);
      expect(controller.state.error, '读取任务失败');
    });

    test('取消不存在的任务：错误文案返回给 UI', () async {
      final adapter = StubAdapter(<String, Responder Function()>{
        '/api/jobs': () => okResponse(<String, dynamic>{
              'jobs': <Map<String, dynamic>>[],
              'total': 0,
            }),
        '/api/jobs/99/cancel': () =>
            errorResponse(404, 'JOB_NOT_FOUND', '任务不存在或无法取消'),
      });
      final api = EchoApi(
        dio: stubDio(adapter),
        tokenStore: MemoryTokenStore(),
      );
      final controller = JobsController(api);

      final error = await controller.cancel(99);
      expect(error, '任务不存在或无法取消');
    });
  });
}
