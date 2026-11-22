import 'package:echo/core/api/echo_api.dart';
import 'package:echo/core/auth/token_store.dart';
import 'package:echo/design/echo_theme.dart';
import 'package:echo/design/echo_tokens.dart';
import 'package:echo/features/auth/auth_controller.dart';
import 'package:echo/features/jobs/jobs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stub_adapter.dart';
import 'tokens_fixtures.dart';

void main() {
  final darkTokens = EchoTokens.fromColors(darkColors, Brightness.dark);

  testWidgets('任务中心：三态筛选 + 书名/音色富化 + 已完成直达立即收听', (
    WidgetTester tester,
  ) async {
    final tokenStore = MemoryTokenStore();
    await tokenStore.write('echo_pat_jobs');
    final adapter = StubAdapter(<String, Responder Function()>{
      '/api/library': () => okResponse(<String, dynamic>{
        'books': <Map<String, dynamic>>[
          <String, dynamic>{'id': 42, 'title': '三体', 'format': 'epub'},
        ],
      }),
      '/api/audiobooks': () => okResponse(<String, dynamic>{
        'audiobooks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 101,
            'book_id': 42,
            'book_title': '三体',
            'model': 'qwen3-tts',
            'voice': 'zh_female',
            'status': 'done',
            'progress': 100,
          },
          <String, dynamic>{
            'id': 102,
            'book_id': 42,
            'book_title': '三体 · 精听版',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'status': 'running',
            'progress': 45,
          },
        ],
      }),
      '/api/jobs': () => okResponse(<String, dynamic>{
        'total': 2,
        'jobs': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'kind': 'audiobook',
            'status': 'done',
            'progress': 100,
            'ref_id': 101,
          },
          <String, dynamic>{
            'id': 2,
            'kind': 'audiobook',
            'status': 'running',
            'progress': 45,
            'ref_id': 102,
            'result': <String, dynamic>{
              'completed_chapters': 9,
              'total_chapters': 20,
            },
          },
        ],
      }),
    });
    final api = EchoApi(dio: stubDio(adapter), tokenStore: tokenStore);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[echoApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          theme: buildEchoTheme(Brightness.dark, darkTokens),
          home: const Scaffold(body: JobsPage(isActive: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 默认全部：展示 2 条任务，富化书名、章级进度、以及已完成卡片的「立即收听」按钮
    expect(find.byKey(const Key('job_card_1')), findsOneWidget);
    expect(find.byKey(const Key('job_card_2')), findsOneWidget);
    expect(find.text('三体'), findsOneWidget);
    expect(find.text('第 9/20 章'), findsOneWidget);
    expect(find.byKey(const Key('job_listen_1')), findsOneWidget);

    // 切到「进行中」：仅展示任务 2
    await tester.tap(find.byKey(const Key('jobs_filter_active')));
    await tester.pump();
    expect(find.byKey(const Key('job_card_1')), findsNothing);
    expect(find.byKey(const Key('job_card_2')), findsOneWidget);

    // 切到「已完成」：仅展示任务 1
    await tester.tap(find.byKey(const Key('jobs_filter_completed')));
    await tester.pump();
    expect(find.byKey(const Key('job_card_1')), findsOneWidget);
    expect(find.byKey(const Key('job_card_2')), findsNothing);
  });
}
