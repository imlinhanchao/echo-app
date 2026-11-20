import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/models.dart';

void main() {
  group('Phase 2 契约模型（providers / search / jobs / tts）', () {
    test('ProviderInfo & ProviderAccountInfo：账号状态与配额', () {
      final provider = ProviderInfo.fromJson(<String, dynamic>{
        'id': 'zlib',
        'name': 'Z-Library',
        'capabilities': <String>['search', 'download'],
        'default_domain': 'z-library.sk',
        'domains': <String>['z-library.sk', '1lib.sk'],
        'credential_keys': <String>['remix_userid', 'remix_userkey'],
        'account': <String, dynamic>{
          'configured': true,
          'status': 'ok',
          'email': 'hancel@example.com',
          'daily_used': 3,
          'daily_limit': 10,
          'daily_remaining': 7,
          'quota_known': true,
        },
      });
      expect(provider.id, 'zlib');
      expect(provider.domains, hasLength(2));
      expect(provider.account?.configured, isTrue);
      expect(provider.account?.needsLogin, isFalse);
      expect(provider.account?.dailyRemaining, 7);
      expect(provider.account?.quotaKnown, isTrue);
    });

    test('ProviderAccountInfo：会话失效状态 needs_login', () {
      final account =
          ProviderAccountInfo.fromJson(<String, dynamic>{
        'configured': true,
        'status': 'needs_login',
      });
      expect(account.needsLogin, isTrue);
    });

    test('SearchPageInfo：搜索信封与分页', () {
      final page = SearchPageInfo.fromJson(<String, dynamic>{
        'books': <Map<String, dynamic>>[
          <String, dynamic>{
            'provider': 'zlib',
            'ref': '123456:abcdef',
            'title': '三体',
            'authors': <String>['刘慈欣'],
            'year': '2008',
            'format': 'EPUB',
            'size': '2.5 MB',
          },
        ],
        'page': 1,
        'total_pages': 3,
        'provider': 'zlib',
      });
      expect(page.books.single.ref, '123456:abcdef');
      expect(page.books.single.authors, <String>['刘慈欣']);
      expect(page.page, 1);
      expect(page.hasMore, isTrue);
    });

    test('JobInfo：kind/status 枚举映射与 result 透传', () {
      final job = JobInfo.fromJson(<String, dynamic>{
        'id': 9,
        'kind': 'audiobook',
        'status': 'running',
        'progress': 42,
        'ref_id': 42,
        'created_at': '2026-11-20T07:00:00Z',
        'result': <String, dynamic>{'book_id': 42},
      });
      expect(job.kind, JobKind.audiobook);
      expect(job.status, JobStatus.running);
      expect(job.isActive, isTrue);
      expect(job.kindLabel, '转有声书');
      expect(job.refId, 42);
      expect(job.result?['book_id'], 42);

      final doneJob = JobInfo.fromJson(<String, dynamic>{
        'id': 10,
        'kind': 'download',
        'status': 'done',
        'progress': 100,
        'error': '',
      });
      expect(doneJob.isActive, isFalse);
      expect(doneJob.kind, JobKind.download);
    });

    test('JobsPageInfo：任务列表信封', () {
      final page = JobsPageInfo.fromJson(<String, dynamic>{
        'jobs': <Map<String, dynamic>>[
          <String, dynamic>{'id': 9, 'kind': 'download', 'status': 'done', 'progress': 100},
          <String, dynamic>{'id': 8, 'kind': 'audiobook', 'status': 'failed', 'progress': 30, 'error': 'TTS 不可用'},
        ],
        'total': 2,
      });
      expect(page.jobs, hasLength(2));
      expect(page.jobs[1].error, 'TTS 不可用');
      expect(page.jobs[1].status, JobStatus.failed);
      expect(page.total, 2);
    });

    test('TtsModelsResponse：模型列表与健康预检', () {
      final response = TtsModelsResponse.fromJson(<String, dynamic>{
        'health': <String, dynamic>{
          'status': 'ok',
          'models': <String>['qwen3-tts-0.6b'],
          'busy': false,
        },
        'models': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'qwen3-tts-0.6b',
            'default': true,
            'provider': 'local',
            'voices': <String>['zf_xiaoxiao'],
          },
          <String, dynamic>{
            'id': 'edge-tts',
            'default': false,
            'provider': 'edge',
            'voices': <String>[],
          },
        ],
        'max_job_chars': 500000,
      });
      expect(response.ttsHealthy, isTrue);
      expect(response.maxJobChars, 500000);
      expect(response.models.first.isDefault, isTrue);
      expect(response.models.first.provider, 'local');
      expect(response.models[1].provider, 'edge');
    });
  });
}
