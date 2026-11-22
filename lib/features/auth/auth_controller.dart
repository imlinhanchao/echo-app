import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../../core/auth/token_store.dart';
import '../../core/settings/server_address_store.dart';

/// Token 存储（生产：安全存储）。
final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

/// echo-service API 客户端。
/// 服务地址取用户设置（登录页 / 我的页可改，持久化在 [ServerAddressStore]），
/// 未设置时回落到构建期 `--dart-define=ECHO_BASE_URL`。
/// 会话过期回调延迟读取 authControllerProvider，避免构造期循环依赖；
/// 显式标注顶层类型以断开相互引用的类型推断环。
final Provider<EchoApi> echoApiProvider = Provider<EchoApi>(
  (ref) => EchoApi(
    baseUri: Uri.parse(ServerAddressStore.current.value),
    tokenStore: ref.watch(tokenStoreProvider),
    onSessionExpired: () =>
        ref.read(authControllerProvider.notifier).handleSessionExpired(),
  ),
);

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
