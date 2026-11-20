import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 单一响应描述：状态码 + JSON 体。
typedef Responder = ({int status, Map<String, dynamic> body});

Responder okResponse(Map<String, dynamic> body) => (status: 200, body: body);

Responder errorResponse(int status, String code, String message) => (
      status: status,
      body: {
        'error': {'code': code, 'message': message},
      },
    );

/// 记录所有请求（含 [RequestOptions.data] 请求体）并按路由返回预设响应。
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.routes);

  final Map<String, Responder Function()> routes;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options, [
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ]) async {
    requests.add(options);
    final respond =
        routes[options.uri.path] ?? () => errorResponse(404, 'not_found', '路由未配置');
    final response = respond();
    return ResponseBody.fromString(
      jsonEncode(response.body),
      response.status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  Map<String, dynamic>? requestBodyAt(String path, [int index = 0]) {
    final matches =
        requests.where((r) => r.uri.path == path && r.data != null).toList();
    if (index >= matches.length) return null;
    final data = matches[index].data;
    return data is Map<String, dynamic> ? data : null;
  }

  List<RequestOptions> requestsTo(String path) =>
      requests.where((r) => r.uri.path == path).toList();

  @override
  void close({bool force = false}) {}
}

Dio stubDio(StubAdapter adapter) => Dio(BaseOptions(baseUrl: 'http://127.0.0.1:8090'))
  ..httpClientAdapter = adapter;
