import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 某一天的收听/阅读累计。
@immutable
class DayStat {
  const DayStat({this.listenMs = 0, this.pagesRead = 0});

  final int listenMs;
  final int pagesRead;

  DayStat copyWith({int? listenMs, int? pagesRead}) => DayStat(
    listenMs: listenMs ?? this.listenMs,
    pagesRead: pagesRead ?? this.pagesRead,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'listen_ms': listenMs,
    'pages': pagesRead,
  };

  factory DayStat.fromJson(Map<String, dynamic> json) => DayStat(
    listenMs: (json['listen_ms'] as num?)?.toInt() ?? 0,
    pagesRead: (json['pages'] as num?)?.toInt() ?? 0,
  );
}

/// 本地收听统计（设计图 ui-mobile-profile 的统计卡）：
/// 本周收听时长 / 连续天数 / 已听完本数。
///
/// 纯本地统计，不依赖服务端接口；写入做了防抖，避免频繁落盘。
class StatsStore {
  StatsStore._();

  static final StatsStore instance = StatsStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _key = 'echo_stats_v1';

  final Map<String, DayStat> _days = <String, DayStat>{};
  final Set<int> _finishedAudioIds = <int>{};
  bool _loaded = false;
  DateTime? _lastSaveAt;

  bool get isLoaded => _loaded;

  static String _dayKey(DateTime time) {
    final d = time.toLocal();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map<String, dynamic>) {
          final days = map['days'];
          if (days is Map<String, dynamic>) {
            for (final entry in days.entries) {
              final value = entry.value;
              if (value is Map<String, dynamic>) {
                _days[entry.key] = DayStat.fromJson(value);
              }
            }
          }
          final finished = map['finished'];
          if (finished is List) {
            for (final item in finished) {
              if (item is num) _finishedAudioIds.add(item.toInt());
            }
          }
        }
      }
    } catch (_) {
      // 数据损坏时从零开始
    }
    _loaded = true;
  }

  /// 累计一段收听时长（毫秒）。
  void addListenMs(int ms) {
    if (ms <= 0) return;
    final key = _dayKey(DateTime.now());
    final current = _days[key] ?? const DayStat();
    _days[key] = current.copyWith(listenMs: current.listenMs + ms);
    _scheduleSave();
  }

  /// 累计翻页阅读。
  void addPageRead() {
    final key = _dayKey(DateTime.now());
    final current = _days[key] ?? const DayStat();
    _days[key] = current.copyWith(pagesRead: current.pagesRead + 1);
    _scheduleSave();
  }

  /// 标记某本有声书已听完。
  void markFinished(int audiobookId) {
    if (_finishedAudioIds.add(audiobookId)) _scheduleSave();
  }

  bool isFinished(int audiobookId) => _finishedAudioIds.contains(audiobookId);

  int get finishedCount => _finishedAudioIds.length;

  /// 最近 [days] 天的收听总时长。
  int listenMsWithinDays(int days, {DateTime? now}) {
    final today = now ?? DateTime.now();
    var total = 0;
    for (var i = 0; i < days; i++) {
      final day = today.subtract(Duration(days: i));
      total += _days[_dayKey(day)]?.listenMs ?? 0;
    }
    return total;
  }

  int get weekListenMs => listenMsWithinDays(7);

  /// 连续收听/阅读天数（今天没动但昨天动了，仍从昨天算起）。
  int get streakDays {
    final today = DateTime.now();
    var streak = 0;
    for (var i = 0; i < 3660; i++) {
      final day = today.subtract(Duration(days: i));
      final stat = _days[_dayKey(day)];
      final active = stat != null && (stat.listenMs > 0 || stat.pagesRead > 0);
      if (active) {
        streak += 1;
      } else if (i == 0) {
        // 今天还没听：继续看昨天起的连续天数
        continue;
      } else {
        break;
      }
    }
    return streak;
  }

  /// 今日已听时长（用于展示）。
  int get todayListenMs => _days[_dayKey(DateTime.now())]?.listenMs ?? 0;

  /// 节流保存（不持有 Timer，避免测试环境残留定时器）。
  void _scheduleSave() {
    final now = DateTime.now();
    final last = _lastSaveAt;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastSaveAt = now;
    unawaited(save());
  }

  Future<void> save() async {
    try {
      final payload = <String, dynamic>{
        'days': <String, dynamic>{
          for (final entry in _days.entries) entry.key: entry.value.toJson(),
        },
        'finished': _finishedAudioIds.toList(),
      };
      await _storage.write(key: _key, value: jsonEncode(payload));
    } catch (_) {
      // 统计失败不影响主流程
    }
  }
}
