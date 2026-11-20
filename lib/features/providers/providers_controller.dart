import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/echo_api.dart';
import '../../core/api/models.dart';
import '../auth/auth_controller.dart';

@immutable
class ProvidersState {
  const ProvidersState({
    this.providers = const <ProviderInfo>[],
    this.isLoading = false,
    this.error,
  });

  final List<ProviderInfo> providers;
  final bool isLoading;
  final String? error;

  ProvidersState copyWith({
    List<ProviderInfo>? providers,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ProvidersState(
      providers: providers ?? this.providers,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 书源账号状态控制器：列表刷新、账密/Cookie 保存、验证、删除。
class ProvidersController extends StateNotifier<ProvidersState> {
  ProvidersController(this._api) : super(const ProvidersState());

  final EchoApi _api;

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      state = state.copyWith(
        providers: await _api.listProviders(),
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    }
  }

  /// 保存账号（password / cookies 两种模式），成功后刷新列表。
  /// 返回 null 表示成功，否则为用户可读错误文案。
  Future<String?> saveAccount({
    required String providerId,
    required String mode,
    String domain = '',
    String email = '',
    String password = '',
    String remixUserId = '',
    String remixUserKey = '',
  }) async {
    try {
      await _api.saveProviderAccount(
        providerId: providerId,
        mode: mode,
        domain: domain,
        email: email,
        password: password,
        remixUserId: remixUserId,
        remixUserKey: remixUserKey,
      );
      await refresh();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }

  Future<String?> verify(String providerId) async {
    try {
      await _api.verifyProviderAccount(providerId);
      await refresh();
      return null;
    } on ApiException catch (e) {
      await refresh();
      return e.message;
    }
  }

  Future<String?> remove(String providerId) async {
    try {
      await _api.deleteProviderAccount(providerId);
      await refresh();
      return null;
    } on ApiException catch (e) {
      return e.message;
    }
  }
}

final StateNotifierProvider<ProvidersController, ProvidersState>
    providersControllerProvider =
    StateNotifierProvider<ProvidersController, ProvidersState>((ref) {
  final controller = ProvidersController(ref.watch(echoApiProvider));
  controller.refresh();
  return controller;
});
