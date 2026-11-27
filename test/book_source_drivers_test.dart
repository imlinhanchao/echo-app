import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo/core/api/ebook_api_client.dart';
import 'package:echo/core/book_sources/book_source_models.dart';
import 'package:echo/core/book_sources/bundled_book_sources.dart';
import 'package:echo/core/book_sources/ebook_api_book_source_driver.dart';
import 'package:echo/core/book_sources/mirror_pool_manager.dart';
import 'package:echo/core/book_sources/opds_book_source_driver.dart';
import 'package:echo/core/book_sources/rule_book_source_driver.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _MockHttpReply = ({
  int status,
  Uint8List bytes,
  Map<String, List<String>> headers,
});

_MockHttpReply _jsonReply(
  Object body, {
  int status = 200,
  Map<String, List<String>> extraHeaders = const <String, List<String>>{},
}) {
  return (
    status: status,
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
      ...extraHeaders,
    },
  );
}

_MockHttpReply _textReply(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=utf-8',
  Map<String, List<String>> extraHeaders = const <String, List<String>>{},
}) {
  return (
    status: status,
    bytes: Uint8List.fromList(utf8.encode(body)),
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[contentType],
      ...extraHeaders,
    },
  );
}

_MockHttpReply _bytesReply(
  List<int> bytes, {
  int status = 200,
  String contentType = 'application/epub+zip',
  Map<String, List<String>> extraHeaders = const <String, List<String>>{},
}) {
  return (
    status: status,
    bytes: Uint8List.fromList(bytes),
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[contentType],
      Headers.contentLengthHeader: <String>['${bytes.length}'],
      ...extraHeaders,
    },
  );
}

_MockHttpReply _redirectReply(String location, {int status = 302}) {
  return (
    status: status,
    bytes: Uint8List(0),
    headers: <String, List<String>>{
      'location': <String>[location],
    },
  );
}

class _RecordedRequest {
  _RecordedRequest(this.options, this.decodedBody);

  final RequestOptions options;
  final String decodedBody;
}

class _ScriptedHttpAdapter implements HttpClientAdapter {
  _ScriptedHttpAdapter(this.handler);

  final Future<_MockHttpReply> Function(_RecordedRequest req) handler;
  final List<_RecordedRequest> requests = <_RecordedRequest>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    var bodyStr = '';
    if (options.data is String) {
      bodyStr = options.data as String;
    } else if (options.data is List<int>) {
      bodyStr = utf8.decode(options.data as List<int>, allowMalformed: true);
    } else if (options.data != null) {
      bodyStr = options.data.toString();
    }
    final rec = _RecordedRequest(options, bodyStr);
    requests.add(rec);
    final reply = await handler(rec);
    return ResponseBody.fromBytes(
      reply.bytes,
      reply.status,
      headers: reply.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final bundled = loadBundledBookSourcesFallback();
  final gutendexDef = bundled.sources.firstWhere((s) => s.id == 'gutendex');
  final stdDef = bundled.sources.firstWhere((s) => s.id == 'standard_ebooks');
  final wsgDef = bundled.sources.firstWhere((s) => s.id == 'wenshuoge');

  group('RuleBookSourceDriver: multi-mirror EAPI-like workflow', () {
    test('login, verify quota, 503 bot failover + 10m cache, repeated form params, 2-hop link, cross-origin credential strip & RFC 5987 download retry', () async {
      var nowUtc = DateTime.utc(2026, 11, 27, 10, 0, 0);
      var cdnAttempts = 0;
      var searchAttempts = 0;

      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        // Mirror 1 always serves anti-bot HTML 503
        if (uri.host == 'm1.example.org') {
          return _textReply(
            '<html><body>Access Shield Verify</body></html>',
            status: 503,
          );
        }

        if (uri.host == 'm2.example.org') {
          if (uri.path == '/eapi/user/login' && req.options.method == 'POST') {
            expect(req.decodedBody, contains('email=u%40example.org'));
            expect(req.decodedBody, contains('password=pw123'));
            return _jsonReply(<String, dynamic>{
              'success': 1,
              'user': <String, dynamic>{
                'id': 7788,
                'email': 'u@example.org',
                'remix_userkey': 'rk_secret_123',
              },
            });
          }

          if (uri.path == '/eapi/user/profile') {
            expect(req.options.headers['remix-userid'], '7788');
            expect(req.options.headers['remix-userkey'], 'rk_secret_123');
            expect(req.options.headers['Cookie'], contains('remix_userid=7788'));
            return _jsonReply(<String, dynamic>{
              'success': 1,
              'user': <String, dynamic>{
                'email': 'u@example.org',
                'downloads_today': 2,
                'downloads_limit': 10,
                'downloads_remaining': 8,
              },
            });
          }

          if (uri.path == '/eapi/book/search' && req.options.method == 'POST') {
            searchAttempts++;
            expect(req.decodedBody, contains('message=dune'));
            if (searchAttempts == 1) {
              // Confirm repeated form params for filters on first filtered query
              expect(req.decodedBody, contains('extensions%5B%5D=EPUB'));
              expect(req.decodedBody, contains('extensions%5B%5D=TXT'));
              expect(req.decodedBody, contains('languages%5B%5D=english'));
            }
            return _jsonReply(<String, dynamic>{
              'success': 1,
              'books': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': '12345',
                  'hash': 'abc999',
                  'title': 'Dune',
                  'author': 'Frank Herbert',
                  'extension': 'EPUB',
                },
              ],
              'pagination': <String, dynamic>{
                'current': 1,
                'total_pages': 3,
              },
            });
          }

          if (uri.path == '/eapi/book/12345/abc999/file') {
            return _jsonReply(<String, dynamic>{
              'success': 1,
              'file': <String, dynamic>{
                'downloadLink': 'https://m2.example.org/d/interstitial/12345',
              },
            });
          }

          if (uri.path == '/d/interstitial/12345') {
            return _jsonReply(<String, dynamic>{
              'success': 1,
              'file': <String, dynamic>{
                'downloadLink': 'https://m2.example.org/d/final/12345',
              },
            });
          }

          if (uri.path == '/d/final/12345') {
            // Redirect to cross-origin CDN!
            return _redirectReply('https://cdn.other.org/files/download?id=1');
          }
        }

        if (uri.host == 'cdn.other.org') {
          // Cross-origin redirect MUST have stripped auth headers & cookies
          expect(req.options.headers.containsKey('Cookie'), isFalse);
          expect(req.options.headers.containsKey('Authorization'), isFalse);
          expect(req.options.headers.containsKey('Referer'), isFalse);
          expect(req.options.headers.containsKey('remix-userid'), isFalse);
          expect(req.options.headers.containsKey('remix-userkey'), isFalse);

          cdnAttempts++;
          if (cdnAttempts == 1) {
            return _textReply('busy', status: 503);
          }
          return _bytesReply(
            utf8.encode('EPUB-DATA-HERE'),
            extraHeaders: <String, List<String>>{
              'content-disposition': <String>[
                "attachment; filename=\"fallback.bin\"; filename*=UTF-8''%E4%B8%89%E4%BD%93.epub",
              ],
            },
          );
        }

        return _textReply('Not Found', status: 404);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final pool = MirrorPoolManager(
        dio: dio,
        now: () => nowUtc,
        delay: (_) async {},
      );
      final driver = RuleBookSourceDriver(
        mirrorPool: pool,
        delay: (_) async {},
        downloadRetryBaseDelay: Duration.zero,
      );

      final def = BookSourceDefinition.fromJson(<String, dynamic>{
        'schema_version': 1,
        'id': 'multi_mirror_eapi',
        'name': 'Multi Mirror EAPI',
        'driver': 'rule',
        'domains': <String>[
          'https://m1.example.org',
          'https://m2.example.org',
        ],
        'headers': <String, dynamic>{'source': 'android'},
        'errors': <String, dynamic>{
          'bot_protection': <String, dynamic>{
            'statuses': <int>[403, 503],
            'html_body': true,
          },
          'envelope': <String, dynamic>{
            'success_path': 'success',
            'success_values': <int>[1],
            'error_path': 'error',
          },
        },
        'auth': <String, dynamic>{
          'required': true,
          'inject': <String, dynamic>{
            'headers': <String, dynamic>{
              'remix-userid': '{{cred.remix_userid}}',
              'remix-userkey': '{{cred.remix_userkey}}',
            },
            'cookies': <String, dynamic>{
              'remix_userid': '{{cred.remix_userid}}',
              'remix_userkey': '{{cred.remix_userkey}}',
            },
          },
          'modes': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'password',
              'label': '邮箱密码',
              'fields': <Map<String, dynamic>>[
                <String, dynamic>{'key': 'email', 'label': '邮箱'},
                <String, dynamic>{'key': 'password', 'label': '密码'},
              ],
              'login': <String, dynamic>{
                'method': 'POST',
                'path': '/eapi/user/login',
                'content_type': 'form',
                'body': <String, dynamic>{
                  'email': '{{input.email}}',
                  'password': '{{input.password}}',
                },
                'save_credentials': <String, dynamic>{
                  'remix_userid': <String, dynamic>{'path': 'user.id'},
                  'remix_userkey': <String, dynamic>{'path': 'user.remix_userkey'},
                  'email': <String, dynamic>{'path': 'user.email'},
                },
              },
            },
          ],
          'verify': <String, dynamic>{
            'path': '/eapi/user/profile',
            'fields': <String, dynamic>{
              'email': <String, dynamic>{'path': 'user.email'},
              'daily_used': <String, dynamic>{'path': 'user.downloads_today'},
              'daily_limit': <String, dynamic>{'path': 'user.downloads_limit'},
              'daily_remaining': <String, dynamic>{'path': 'user.downloads_remaining'},
            },
          },
        },
        'search': <String, dynamic>{
          'request': <String, dynamic>{
            'method': 'POST',
            'path': '/eapi/book/search',
            'content_type': 'form',
            'body': <String, dynamic>{
              'message': '{{query.q}}',
              'page': '{{query.page}}',
            },
          },
          'filters': <String, dynamic>{
            'extensions': <String, dynamic>{
              'param': 'extensions[]',
              'mode': 'repeat',
            },
            'languages': <String, dynamic>{
              'param': 'languages[]',
              'mode': 'repeat',
            },
          },
          'response': <String, dynamic>{
            'mode': 'json',
            'items_path': 'books',
            'pagination': <String, dynamic>{
              'current_page_path': 'pagination.current',
              'total_pages_path': 'pagination.total_pages',
            },
            'fields': <String, dynamic>{
              'ref': <String, dynamic>{'template': '{{fields.id}}:{{fields.hash}}'},
              'id': <String, dynamic>{'path': 'id'},
              'hash': <String, dynamic>{'path': 'hash'},
              'title': <String, dynamic>{'path': 'title'},
              'authors': <String, dynamic>{'path': 'author'},
              'format': <String, dynamic>{'path': 'extension', 'transform': 'lower'},
            },
          },
        },
        'download': <String, dynamic>{
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'file_link',
              'method': 'GET',
              'path': '/eapi/book/{{book.ref_parts.0}}/{{book.ref_parts.1}}/file',
              'extract': <String, dynamic>{
                'url': <String, dynamic>{'path': 'file.downloadLink', 'resolve_url': true},
              },
              'follow_while_url_regex': r'^.*/d/interstitial/.*$',
              'max_hops': 3,
            },
          ],
          'file_request': <String, dynamic>{
            'url': '{{step.file_link.url}}',
            'same_origin_credentials': true,
            'headers': <String, dynamic>{'Referer': '{{origin}}/book'},
            'retries': 3,
          },
        },
      });

      final unauthed = ResolvedBookSource(definition: def, origin: BookSourceOrigin.local);
      final creds = await driver.authenticate(
        unauthed,
        modeId: 'password',
        inputs: <String, String>{'email': 'u@example.org', 'password': 'pw123'},
      );
      expect(creds.values['remix_userid'], '7788');
      expect(creds.values['remix_userkey'], 'rk_secret_123');

      final authed = ResolvedBookSource(
        definition: def,
        origin: BookSourceOrigin.local,
        credentials: creds,
      );
      final status = await driver.verify(authed);
      expect(status.dailyUsed, 2);
      expect(status.dailyLimit, 10);
      expect(status.dailyRemaining, 8);

      // Search fails over m1 -> m2, and m2 becomes cached healthy for 10 minutes
      final reqCountBeforeSearch2 = adapter.requests.length;
      final page = await driver.search(
        authed,
        const BookSourceSearchRequest(
          query: 'dune',
          extensions: <String>['EPUB', 'TXT'],
          languages: <String>['english'],
        ),
      );
      expect(page.books, hasLength(1));
      expect(page.books.first.ref, '12345:abc999');
      expect(page.books.first.format, 'epub');
      expect(page.totalPages, 3);
      expect(pool.isHealthyCached(authed.id, 'https://m2.example.org'), isTrue);

      // Next search skips m1 completely while within 10m TTL!
      final m1CallsBefore = adapter.requests
          .where((r) => r.options.uri.host == 'm1.example.org')
          .length;
      await driver.search(authed, const BookSourceSearchRequest(query: 'dune'));
      final m1CallsAfter = adapter.requests
          .where((r) => r.options.uri.host == 'm1.example.org')
          .length;
      expect(m1CallsAfter, equals(m1CallsBefore));
      expect(adapter.requests.length, greaterThan(reqCountBeforeSearch2));

      // Download executes 2-hop link extraction, cross-origin redirect strip, 503 retry, RFC 5987 filename
      final tempDir = await Directory.systemTemp.createTemp('echo_eapi_dl_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final downloaded = await driver.downloadBook(
        authed,
        ref: '12345:abc999',
        savePath: '${tempDir.path}/book.epub',
        meta: page.books.first,
      );
      expect(cdnAttempts, 2);
      expect(downloaded.filename, '三体.epub');
      expect(downloaded.format, 'epub');
      expect(File(downloaded.savePath).readAsStringSync(), 'EPUB-DATA-HERE');

      // Advancing clock by 11 minutes expires cached healthy mirror
      nowUtc = nowUtc.add(const Duration(minutes: 11));
      expect(pool.isHealthyCached(authed.id, 'https://m2.example.org'), isFalse);
    });
  });

  group('Bundled rule drivers (mocked HTTP)', () {
    test('wenshuoge rule handles anonymous cursor search, JSON-LD detail, CSRF login, multi-step verify, 429 quota error, and async poll download', () async {
      var pollCount = 0;
      var return429OnAuthorize = false;
      var return401OnQuota = false;

      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        if (uri.path == '/api/v2/catalog') {
          if (uri.queryParameters['cursor'] == 'cur_page_2') {
            return _jsonReply(<String, dynamic>{
              'data': <String, dynamic>{
                'books': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'wsg_2',
                    'title': '史记（下）',
                    'author': '司马迁',
                    'era': '汉代',
                    'category': '史部',
                    'variantLabel': '繁体',
                    'tags': <String>['二十四史'],
                  },
                ],
              },
              'meta': <String, dynamic>{'total': 25, 'nextCursor': ''},
            });
          }
          expect(uri.queryParameters['q'], '史记');
          expect(uri.queryParameters['limit'], '20');
          return _jsonReply(<String, dynamic>{
            'data': <String, dynamic>{
              'books': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'wsg_1',
                  'title': '史记（上）',
                  'author': '司马迁，裴骃',
                  'era': '汉代',
                  'category': '史部',
                  'variantLabel': '简体',
                  'tags': <String>['正史', '纪传体'],
                },
              ],
            },
            'meta': <String, dynamic>{'total': 25, 'nextCursor': 'cur_page_2'},
          });
        }

        if (uri.path == '/book/wsg_1') {
          return _textReply('''
            <html><head>
            <script type="application/ld+json">
            {"description":"《史记》是中国历史上第一部纪传体通史。","image":"/covers/shiji.jpg"}
            </script>
            </head><body></body></html>
          ''');
        }

        if (uri.path == '/api/v2/auth/csrf') {
          return _jsonReply(
            <String, dynamic>{
              'data': <String, dynamic>{'token': 'csrf_tok_99'},
            },
            extraHeaders: <String, List<String>>{
              'set-cookie': <String>['wenshuoge_csrf=csrf_ck_88; Path=/; HttpOnly'],
            },
          );
        }

        if (uri.path == '/api/v2/auth/password/login') {
          expect(req.options.headers['X-CSRF-Token'], 'csrf_tok_99');
          expect(req.options.headers['Cookie'], contains('wenshuoge_csrf=csrf_ck_88'));
          final decoded = jsonDecode(req.decodedBody) as Map<String, dynamic>;
          expect(decoded['email'], 'reader@example.org');
          return _jsonReply(
            <String, dynamic>{
              'data': <String, dynamic>{
                'user': <String, dynamic>{'email': 'reader@example.org'},
              },
            },
            extraHeaders: <String, List<String>>{
              'set-cookie': <String>['wenshuoge_session=wsg_sess_abc; Path=/; HttpOnly'],
            },
          );
        }

        if (uri.path == '/api/v2/downloads/quota') {
          expect(req.options.headers['Cookie'], contains('wenshuoge_session=wsg_sess_abc'));
          if (return401OnQuota) {
            return _jsonReply(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 'login_required',
                'message': '请先登录',
              },
            }, status: 401);
          }
          return _jsonReply(<String, dynamic>{
            'data': <String, dynamic>{'limit': 1, 'used': 0, 'remaining': 1},
          });
        }

        if (uri.path == '/api/v2/auth/status') {
          return _jsonReply(<String, dynamic>{
            'data': <String, dynamic>{
              'user': <String, dynamic>{'email': 'reader@example.org'},
            },
          });
        }

        if (uri.path == '/api/v2/downloads/epub/authorize') {
          expect(req.options.headers['X-CSRF-Token'], 'csrf_tok_99');
          expect(req.options.headers['Cookie'], contains('wenshuoge_session=wsg_sess_abc'));
          expect(req.options.headers['Cookie'], contains('wenshuoge_csrf=csrf_ck_88'));
          if (return429OnAuthorize) {
            return _jsonReply(<String, dynamic>{
              'error': <String, dynamic>{
                'code': 'download_daily_limit',
                'message': '今日免费下载次数已用完',
              },
            }, status: 429);
          }
          return _jsonReply(<String, dynamic>{
            'data': <String, dynamic>{
              'state': 'queued',
              'intent': 'intent_42',
            },
          });
        }

        if (uri.path == '/api/v2/downloads/epub/status') {
          expect(uri.queryParameters['intent'], 'intent_42');
          pollCount++;
          if (pollCount < 2) {
            return _jsonReply(<String, dynamic>{
              'data': <String, dynamic>{'state': 'queued'},
            });
          }
          return _jsonReply(<String, dynamic>{
            'data': <String, dynamic>{
              'state': 'ready',
              'url': '/api/v2/downloads/epub/file/intent_42',
            },
          });
        }

        if (uri.path == '/api/v2/downloads/epub/file/intent_42') {
          expect(req.options.headers['Cookie'], contains('wenshuoge_session=wsg_sess_abc'));
          return _bytesReply(
            utf8.encode('WSG-EPUB-BYTES'),
            extraHeaders: <String, List<String>>{
              'content-disposition': <String>['attachment; filename="shiji.epub"'],
            },
          );
        }

        return _textReply('Not Found', status: 404);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final driver = RuleBookSourceDriver(
        mirrorPool: MirrorPoolManager(dio: dio, delay: (_) async {}),
        delay: (_) async {},
        downloadRetryBaseDelay: Duration.zero,
      );

      final wsgAnon = ResolvedBookSource(definition: wsgDef, origin: BookSourceOrigin.bundled);

      // 1. Anonymous cursor search (page 1 & page 2)
      final p1 = await driver.search(wsgAnon, const BookSourceSearchRequest(query: '史记'));
      expect(p1.books, hasLength(1));
      expect(p1.books.first.authors, <String>['司马迁', '裴骃']);
      expect(p1.hasMore, isTrue);

      final p2 = await driver.search(wsgAnon, const BookSourceSearchRequest(query: '史记', page: 2));
      expect(p2.books.single.ref, 'wsg_2');
      expect(p2.hasMore, isFalse);

      // 2. Detail JSON-LD extraction
      final detail = await driver.getBookDetail(wsgAnon, 'wsg_1', baseBook: p1.books.first);
      expect(detail.description, contains('第一部纪传体通史'));
      expect(detail.coverUrl, 'https://www.wenshuoge.com/covers/shiji.jpg');

      // 3. Unauthenticated download blocked upfront
      await expectLater(
        () => driver.downloadBook(wsgAnon, ref: 'wsg_1', savePath: '/tmp/nope.epub'),
        throwsA(isA<BookSourceException>().having((e) => e.code, 'code', 'PROVIDER_NOT_CONFIGURED')),
      );

      // 4. CSRF + password login
      final creds = await driver.authenticate(
        wsgAnon,
        modeId: 'password',
        inputs: <String, String>{'email': 'reader@example.org', 'password': 'pw'},
      );
      expect(creds.values['wenshuoge_session'], 'wsg_sess_abc');
      expect(creds.values['email'], 'reader@example.org');

      final wsgAuthed = ResolvedBookSource(
        definition: wsgDef,
        origin: BookSourceOrigin.bundled,
        credentials: creds,
      );

      // 5. Verify multi-step quota & 401 session expired detection
      final okStatus = await driver.verify(wsgAuthed);
      expect(okStatus.email, 'reader@example.org');
      expect(okStatus.dailyRemaining, 1);

      return401OnQuota = true;
      await expectLater(
        () => driver.verify(wsgAuthed),
        throwsA(isA<BookSourceException>().having((e) => e.code, 'code', 'SESSION_EXPIRED')),
      );
      return401OnQuota = false;

      // 6. 429 daily quota mapped cleanly
      return429OnAuthorize = true;
      await expectLater(
        () => driver.downloadBook(wsgAuthed, ref: 'wsg_1', savePath: '/tmp/limit.epub'),
        throwsA(isA<BookSourceException>().having((e) => e.code, 'code', 'QUOTA_EXCEEDED')),
      );
      return429OnAuthorize = false;

      // 7. Async poll queued -> ready -> file stream
      final tempDir = await Directory.systemTemp.createTemp('echo_wsg_dl_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dl = await driver.downloadBook(
        wsgAuthed,
        ref: 'wsg_1',
        savePath: '${tempDir.path}/shiji.epub',
        meta: detail,
      );
      expect(pollCount, 2);
      expect(dl.filename, 'shiji.epub');
      expect(File(dl.savePath).readAsStringSync(), 'WSG-EPUB-BYTES');
    });

    test('gutendex rule handles path_segments MIME keys, when_present, and cold-cache detail fallback', () async {
      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        if (uri.path == '/books') {
          expect(uri.queryParameters['languages'], 'zh,en');
          expect(uri.queryParameters['mime_type'], 'application/epub');
          expect(uri.queryParameters['sort'], 'ascending');
          return _jsonReply(<String, dynamic>{
            'count': 1,
            'next': null,
            'results': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 1342,
                'title': 'Pride and Prejudice',
                'authors': <Map<String, dynamic>>[
                  <String, dynamic>{'name': 'Austen, Jane'},
                ],
                'languages': <String>['en'],
                'subjects': <String>['Courtship -- Fiction'],
                'formats': <String, dynamic>{
                  'text/plain; charset=utf-8': 'https://cdn.gutendex.example/1342.txt',
                  'image/jpeg': 'https://cdn.gutendex.example/1342.jpg',
                },
              },
            ],
          });
        }
        if (uri.path == '/books/1342') {
          return _jsonReply(<String, dynamic>{
            'id': 1342,
            'title': 'Pride and Prejudice',
            'subjects': <String>['England -- Fiction'],
            'formats': <String, dynamic>{
              'application/epub+zip': 'https://gutendex.com/files/1342.epub',
              'image/jpeg': 'https://gutendex.com/covers/1342.jpg',
            },
          });
        }
        if (uri.path == '/files/1342.epub') {
          return _bytesReply(utf8.encode('GUTENBERG-EPUB'));
        }
        return _textReply('404', status: 404);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final driver = RuleBookSourceDriver(
        mirrorPool: MirrorPoolManager(dio: dio),
        downloadRetryBaseDelay: Duration.zero,
      );
      final src = ResolvedBookSource(definition: gutendexDef, origin: BookSourceOrigin.bundled);

      final page = await driver.search(
        src,
        const BookSourceSearchRequest(
          query: 'pride',
          extensions: <String>['EPUB'],
          languages: <String>['chinese', 'english'],
          order: 'ascending',
        ),
      );
      expect(page.books.single.authors, <String>['Austen, Jane']);
      expect(page.books.single.format, 'txt');
      expect(page.books.single.sourceVars['download_url'], 'https://cdn.gutendex.example/1342.txt');

      // Cold cache download (meta: null) hits /books/1342 to resolve download_url
      final tempDir = await Directory.systemTemp.createTemp('echo_gx_dl_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dl = await driver.downloadBook(
        src,
        ref: '1342',
        savePath: '${tempDir.path}/1342.epub',
      );
      expect(File(dl.savePath).readAsStringSync(), 'GUTENBERG-EPUB');
    });

    test('standard_ebooks rule parses HTML list, next page, detail paragraphs, and 2-step EPUB download', () async {
      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        if (uri.path == '/ebooks') {
          return _textReply('''
            <html><body>
              <ol class="ebooks-list">
                <li typeof="schema:Book" about="/ebooks/jane-austen/emma">
                  <picture><img src="/images/emma.jpg" /></picture>
                  <p><a property="schema:url"><span property="schema:name">Emma</span></a></p>
                  <p class="author"><span property="schema:name">Jane Austen</span></p>
                </li>
              </ol>
              <nav><a rel="next" href="/ebooks?query=emma&page=2">Next</a></nav>
            </body></html>
          ''');
        }
        if (uri.path == '/ebooks/jane-austen/emma') {
          return _textReply('''
            <html><body>
              <picture><img src="/images/emma-hero.jpg" /></picture>
              <div property="schema:description"><p>Para one.</p><p>Para two.</p></div>
              <a class="epub" href="/ebooks/jane-austen/emma/downloads/emma.epub">EPUB</a>
            </body></html>
          ''');
        }
        if (uri.path == '/ebooks/jane-austen/emma/downloads/emma.epub') {
          return _bytesReply(utf8.encode('STD-EPUB-BYTES'));
        }
        return _textReply('404', status: 404);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final driver = RuleBookSourceDriver(
        mirrorPool: MirrorPoolManager(dio: dio, delay: (_) async {}),
        delay: (_) async {},
        downloadRetryBaseDelay: Duration.zero,
      );
      final src = ResolvedBookSource(definition: stdDef, origin: BookSourceOrigin.bundled);

      final page = await driver.search(src, const BookSourceSearchRequest(query: 'emma'));
      expect(page.books.single.ref, '/ebooks/jane-austen/emma');
      expect(page.books.single.title, 'Emma');
      expect(page.books.single.authors, <String>['Jane Austen']);
      expect(page.hasMore, isTrue);

      final detail = await driver.getBookDetail(src, '/ebooks/jane-austen/emma', baseBook: page.books.first);
      expect(detail.description, 'Para one.\n\nPara two.');
      expect(detail.coverUrl, 'https://standardebooks.org/images/emma-hero.jpg');

      final tempDir = await Directory.systemTemp.createTemp('echo_std_dl_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dl = await driver.downloadBook(
        src,
        ref: '/ebooks/jane-austen/emma',
        savePath: '${tempDir.path}/emma.epub',
        meta: detail,
      );
      expect(dl.format, 'epub');
      expect(File(dl.savePath).readAsStringSync(), 'STD-EPUB-BYTES');
    });
  });

  group('OpdsBookSourceDriver & EbookApiBookSourceDriver & Proxy Rewriting', () {
    test('OPDS 1.2 OpenSearch auto-discovery, preferFormats, Basic Auth, OPDS 2.0 JSON, and local fallback', () async {
      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        if (uri.host == 'opds1.example.org') {
          expect(req.options.headers['Authorization'], startsWith('Basic '));
          if (uri.path == '/opds') {
            return _textReply('''
              <feed xmlns="http://www.w3.org/2005/Atom">
                <link rel="search" type="application/opensearchdescription+xml" href="/opensearch.xml" />
              </feed>
            ''', contentType: 'application/atom+xml');
          }
          if (uri.path == '/opensearch.xml') {
            return _textReply('''
              <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
                <Url type="application/atom+xml" template="https://opds1.example.org/search?q={searchTerms}&amp;page={startPage}" />
              </OpenSearchDescription>
            ''', contentType: 'application/xml');
          }
          if (uri.path == '/search') {
            expect(uri.queryParameters['q'], 'frankenstein');
            return _textReply('''
              <feed xmlns="http://www.w3.org/2005/Atom">
                <entry>
                  <id>urn:book:1</id>
                  <title>Frankenstein</title>
                  <author><name>Mary Shelley</name></author>
                  <link rel="http://opds-spec.org/acquisition" type="application/x-mobipocket-ebook" href="/dl/1.mobi" />
                  <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/dl/1.epub" />
                </entry>
              </feed>
            ''', contentType: 'application/atom+xml');
          }
          if (uri.path == '/dl/1.epub') {
            return _bytesReply(utf8.encode('OPDS1-EPUB'));
          }
        }

        if (uri.host == 'opds2.example.org') {
          if (uri.path == '/opds2') {
            return _jsonReply(<String, dynamic>{
              'publications': <Map<String, dynamic>>[
                <String, dynamic>{
                  'metadata': <String, dynamic>{
                    'identifier': 'id-2',
                    'title': 'Alice in Wonderland',
                    'author': 'Lewis Carroll',
                  },
                  'links': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'rel': 'http://opds-spec.org/acquisition',
                      'type': 'application/epub+zip',
                      'href': '/files/alice.epub',
                    },
                  ],
                },
                <String, dynamic>{
                  'metadata': <String, dynamic>{
                    'identifier': 'id-3',
                    'title': 'Unmatched Book',
                    'author': 'Anon',
                  },
                },
              ],
            });
          }
        }
        return _textReply('404', status: 404);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final driver = OpdsBookSourceDriver(
        mirrorPool: MirrorPoolManager(dio: dio),
        downloadRetryBaseDelay: Duration.zero,
      );

      final opds1 = ResolvedBookSource(
        definition: BookSourceDefinition.fromJson(<String, dynamic>{
          'schema_version': 1,
          'id': 'opds_1',
          'name': 'OPDS 1',
          'driver': 'opds',
          'domains': <String>['https://opds1.example.org/opds'],
        }),
        origin: BookSourceOrigin.local,
        credentials: const BookSourceCredentials(
          sourceId: 'opds_1',
          modeId: 'basic',
          values: <String, String>{'username': 'alice', 'password': 'pw'},
        ),
      );

      final page1 = await driver.search(opds1, const BookSourceSearchRequest(query: 'frankenstein'));
      expect(page1.books.single.title, 'Frankenstein');
      expect(page1.books.single.format, 'epub');
      expect(page1.books.single.sourceVars['download_url'], 'https://opds1.example.org/dl/1.epub');

      final tempDir = await Directory.systemTemp.createTemp('echo_opds_dl_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dl = await driver.downloadBook(
        opds1,
        ref: page1.books.single.ref,
        savePath: '${tempDir.path}/f.epub',
        meta: page1.books.single,
      );
      expect(File(dl.savePath).readAsStringSync(), 'OPDS1-EPUB');

      // OPDS 2.0 JSON local filter fallback when no search template is exposed
      final opds2 = ResolvedBookSource(
        definition: BookSourceDefinition.fromJson(<String, dynamic>{
          'schema_version': 1,
          'id': 'opds_2',
          'name': 'OPDS 2',
          'driver': 'opds',
          'domains': <String>['https://opds2.example.org/opds2'],
        }),
        origin: BookSourceOrigin.local,
      );
      final page2 = await driver.search(opds2, const BookSourceSearchRequest(query: 'wonderland'));
      expect(page2.books.single.title, 'Alice in Wonderland');
      expect(page2.books.single.authors, <String>['Lewis Carroll']);
      expect(page2.books.single.format, 'epub');
    });

    test('EbookApiBookSourceDriver delegates cleanly and MirrorPoolManager rewrites proxy prefixes + probes mirrors', () async {
      expect(
        MirrorPoolManager.rewriteWithProxy('https://a.org/books?q=1', 'https://proxy.example.com'),
        'https://proxy.example.com/https://a.org/books?q=1',
      );
      expect(
        MirrorPoolManager.rewriteWithProxy('https://a.org/books?q=1', 'https://proxy.example.com/?url={url}'),
        'https://proxy.example.com/?url=https%3A%2F%2Fa.org%2Fbooks%3Fq%3D1',
      );

      final adapter = _ScriptedHttpAdapter((req) async {
        final uri = req.options.uri;
        if (uri.path == '/v1/search') {
          return _jsonReply(<String, dynamic>{
            'books': <Map<String, dynamic>>[
              <String, dynamic>{
                'provider': 'zlib',
                'ref': 'z_10',
                'title': 'Three Body',
                'authors': <String>['Cixin Liu'],
                'format': 'epub',
              },
            ],
            'page': 1,
            'total_pages': 1,
            'provider': 'zlib',
          });
        }
        if (uri.host == 'good.example.org') {
          return _jsonReply(<String, dynamic>{'ok': true});
        }
        return _textReply('bad', status: 500);
      });

      final dio = Dio()..httpClientAdapter = adapter;
      final driver = EbookApiBookSourceDriver(
        clientFactory: ({required String baseUrl, String apiKey = ''}) =>
            EbookApiClient(baseUrl: baseUrl, apiKey: apiKey, dio: dio),
      );
      final src = ResolvedBookSource(
        definition: BookSourceDefinition.fromJson(<String, dynamic>{
          'schema_version': 1,
          'id': 'eapi_1',
          'name': 'Self Ebook API',
          'driver': 'ebook_api',
          'domains': <String>['http://127.0.0.1:8091'],
          'ebook_api': <String, dynamic>{'remote_provider': 'zlib'},
        }),
        origin: BookSourceOrigin.local,
      );
      final page = await driver.search(src, const BookSourceSearchRequest(query: 'three'));
      expect(page.books.single.title, 'Three Body');
      expect(page.books.single.provider, 'eapi_1');

      final pool = MirrorPoolManager(dio: dio);
      final probeSource = ResolvedBookSource(
        definition: BookSourceDefinition.fromJson(<String, dynamic>{
          'schema_version': 1,
          'id': 'probe_src',
          'name': 'Probe Src',
          'driver': 'opds',
          'domains': <String>[
            'https://bad.example.org',
            'https://good.example.org',
          ],
          'probe': <String, dynamic>{'path': '/health'},
        }),
        origin: BookSourceOrigin.local,
      );
      final probes = await pool.probeAll(probeSource);
      expect(probes, hasLength(2));
      expect(probes[0].ok, isFalse);
      expect(probes[1].ok, isTrue);
      expect(pool.isHealthyCached('probe_src', 'https://good.example.org'), isTrue);
    });
  });
}
