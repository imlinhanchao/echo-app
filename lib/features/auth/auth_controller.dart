import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ebook_api_client.dart';
import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../../core/api/provider_token_store.dart';
import '../../core/api/standalone_echo_api.dart';
import '../../core/auth/token_store.dart';
import '../../core/book_sources/book_source_manager.dart';
import '../../core/books/local_library_store.dart';
import '../../core/settings/standalone_config_store.dart';
import '../../core/tts/local_convert_service.dart';
import '../../core/tts/tts_model_manager.dart';
import '../library/library_controller.dart';

/// Token 存储（保留兼容符号，单机版不依赖服务端登录）。
final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

/// 单机版全局 API 入口（统一承接本地书库、统一书源管理与本地 TTS 任务）。
final Provider<EchoApi> echoApiProvider = Provider<EchoApi>(
  (ref) => StandaloneEchoApi(
    libraryStore: ref.watch(localLibraryStoreProvider),
    readEbookApi: () => ref.read(ebookApiClientProvider),
    tokenStore: ref.watch(providerTokenStoreProvider),
    ttsModelManager: ref.watch(ttsModelManagerProvider.notifier),
    convertService: ref.watch(localConvertServiceProvider),
    readConfig: () => ref.read(standaloneConfigProvider),
    bookSourceManager: ref.watch(bookSourceControllerProvider.notifier),
    onLibraryChanged: () =>
        ref.read(libraryControllerProvider.notifier).refresh(),
  ),
);

/// 当前是否具备可用的在线书源搜索能力：
/// 在线书源启用列表非空即视为可用，同时兼容覆盖 [echoApiProvider] 的测试桩。
final Provider<bool> onlineSearchAvailableProvider = Provider<bool>((ref) {
  ref.watch(standaloneConfigProvider);
  final bookSourcesState = ref.watch(bookSourceControllerProvider);
  final api = ref.watch(echoApiProvider);
  if (api is StandaloneEchoApi && api.usesBookSourceManager) {
    return bookSourcesState.enabledSources.isNotEmpty;
  }
  return api.baseUrl.trim().isNotEmpty;
});

/// 认证生命周期状态。
sealed class AuthState {
  const AuthState();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthLoggedOut extends AuthState {
  const AuthLoggedOut({this.reason});

  /// 服务端原因（如会话过期），登录页展示。
  final String? reason;
}

class AuthLoggedIn extends AuthState {
  const AuthLoggedIn({required this.user});

  final EchoUser user;
}

/// 认证控制器：引导恢复会话、登录/注册/登出、会话过期处理。
/// 纯 Dart 状态机，可在无 Riverpod 环境下直接单测。
class AuthController extends StateNotifier<AuthState> {
  AuthController(this._api, this._store) : super(const AuthLoading());

  final EchoApi _api;
  final TokenStore _store;

  /// 启动引导：有 Token 则恢复会话（401 时拦截器自动 refresh），无则登录态。
  Future<void> bootstrap() async {
    final token = await _store.read();
    if (token == null || token.isEmpty) {
      state = const AuthLoggedOut();
      return;
    }
    try {
      final me = await _api.me();
      state = AuthLoggedIn(user: me.user);
    } on ApiException {
      // Token 已失效（拦截器已尝试 refresh 并清理）。
      state = const AuthLoggedOut();
    }
  }

  /// 登录：成功返回 null，失败返回可展示给用户的错误文案。
  Future<String?> login(String email, String password) async {
    try {
      final token = await _api.login(email: email, password: password);
      await _store.write(token.token);
      final me = await _api.me();
      state = AuthLoggedIn(user: me.user);
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  /// 注册后自动登录。
  Future<String?> register(String email, String password) async {
    try {
      await _api.register(email: email, password: password);
      return await login(email, password);
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<void> logout() async {
    try {
      await _api.revoke();
    } catch (_) {
      // 撤销失败也继续本地登出。
    }
    await _store.clear();
    state = const AuthLoggedOut();
  }

  /// 401 后 refresh 失败：进入登录态并提示。
  void handleSessionExpired() {
    if (state is AuthLoggedIn) {
      state = const AuthLoggedOut(reason: '会话已过期，请重新登录');
    }
  }

  /// 服务地址已切换：新服务端不认旧 Token，清掉本机凭据并回登录页。
  Future<void> handleServerChanged() async {
    await _store.clear();
    state = const AuthLoggedOut(reason: '服务地址已切换，请重新登录');
  }
}

final StateNotifierProvider<AuthController, AuthState> authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
      final controller = AuthController(
        ref.read(echoApiProvider),
        ref.read(tokenStoreProvider),
      );
      // 异步恢复会话；期间 UI 停留在 AuthLoading。
      controller.bootstrap();
      return controller;
    });
