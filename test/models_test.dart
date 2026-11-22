import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo/core/api/models.dart';

void main() {
  group('API 响应模型（对应 echo-service README 与 views.go 契约）', () {
    test('AuthToken.fromJson：token 响应', () {
      final token = AuthToken.fromJson(<String, dynamic>{
        'token': 'echo_pat_abc123',
        'token_type': 'Bearer',
        'expires_at': '2027-01-01T00:00:00Z',
        'user': {'id': 7, 'email': 'hancel@example.com', 'name': 'iPhone'},
      });
      expect(token.token, 'echo_pat_abc123');
      expect(token.tokenType, 'Bearer');
      expect(token.expiresAt, DateTime.parse('2027-01-01T00:00:00Z'));
      expect(token.user?.id, 7);
      expect(token.user?.email, 'hancel@example.com');
      expect(token.user?.name, 'iPhone');
    });

    test('AuthToken.fromJson：字段缺失时安全降级', () {
      final token = AuthToken.fromJson(<String, dynamic>{});
      expect(token.token, '');
      expect(token.tokenType, 'Bearer');
      expect(token.user, isNull);
    });

    test('MeInfo.fromJson：user 与 registration_open', () {
      final me = MeInfo.fromJson(<String, dynamic>{
        'user': {'id': 7, 'email': 'hancel@example.com'},
        'registration_open': false,
      });
      expect(me.user.id, 7);
      expect(me.registrationOpen, isFalse);
    });

    test('ApiException.fromResponse：服务端错误契约', () {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/api/auth/token'),
        statusCode: 401,
        data: <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'invalid_credentials',
            'message': '邮箱或密码错误',
          },
        },
      );
      final exception = ApiException.fromResponse(response);
      expect(exception.code, 'invalid_credentials');
      expect(exception.message, '邮箱或密码错误');
      expect(exception.statusCode, 401);
      expect(exception.toString(), '邮箱或密码错误');
    });

    test('ApiException.fromResponse：网络层失败（无响应）', () {
      final exception = ApiException.fromResponse(null);
      expect(exception.message, '网络连接失败，请检查服务');
      expect(exception.statusCode, isNull);
    });

    test('LibraryBook & BookDetail.fromJson：书库与关联有声书', () {
      final detail = BookDetail.fromJson(<String, dynamic>{
        'book': <String, dynamic>{
          'id': 42,
          'provider': 'zlib',
          'provider_book_id': 'z-42',
          'title': '三体',
          'authors': <String>['刘慈欣'],
          'format': 'epub',
          'size_bytes': 1048576,
          'status': 'ready',
        },
        'audiobooks': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 101,
            'book_id': 42,
            'book_title': '三体',
            'model': 'kokoro-82m',
            'voice': 'zf_xiaoxiao',
            'speed': 1.0,
            'status': 'done',
            'progress': 100,
            'duration_s': 3600.5,
            'chapters_url': '/api/audiobooks/101/chapters',
          },
        ],
      });
      expect(detail.book?.id, 42);
      expect(detail.book?.title, '三体');
      expect(detail.book?.authors, <String>['刘慈欣']);
      expect(detail.audiobooks.single.id, 101);
      expect(detail.audiobooks.single.isReady, isTrue);
      expect(
        detail.audiobooks.single.chaptersUrl,
        '/api/audiobooks/101/chapters',
      );
    });

    test('ChaptersManifestInfo.fromJson：分章清单与音频/SRT 地址', () {
      final manifest = ChaptersManifestInfo.fromJson(<String, dynamic>{
        'audiobook_id': 101,
        'format': 'mp3',
        'duration_s': 120.0,
        'chunk_seconds': 1800,
        'chunks': <Map<String, dynamic>>[
          <String, dynamic>{
            'n': 0,
            'chapter_index': 0,
            'title': '第一章 科学边界',
            'start_s': 0.0,
            'end_s': 60.0,
            'duration_s': 60.0,
            'size_bytes': 512000,
            'audio_url': '/api/files/audiobooks/101?variant=chapter&n=0',
            'srt_url': '/api/files/audiobooks/101?variant=chapter_srt&n=0',
          },
        ],
      });
      expect(manifest.audiobookId, 101);
      expect(manifest.format, 'mp3');
      expect(manifest.chunks.single.title, '第一章 科学边界');
      expect(
        manifest.chunks.single.audioUrl,
        '/api/files/audiobooks/101?variant=chapter&n=0',
      );
      expect(
        manifest.chunks.single.srtUrl,
        '/api/files/audiobooks/101?variant=chapter_srt&n=0',
      );
    });
  });
}
