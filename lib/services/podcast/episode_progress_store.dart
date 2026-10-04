import 'dart:convert';

import '../storage_service.dart';

/// 单集的收听进度。
class EpisodeProgress {
  final int positionMs;
  final int durationMs;

  /// 已听完（播到结尾，或停在离结尾不到 [EpisodeProgressStore.finishThreshold] 处）。
  final bool finished;

  /// 最后更新时间（毫秒时间戳），用于超量时淘汰最旧记录。
  final int updatedAt;

  const EpisodeProgress({
    required this.positionMs,
    required this.durationMs,
    this.finished = false,
    this.updatedAt = 0,
  });

  /// 0–1 的进度比例（时长未知时为 0）。
  double get fraction =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
    'p': positionMs,
    'd': durationMs,
    if (finished) 'f': true,
    't': updatedAt,
  };

  static EpisodeProgress? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final p = json['p'];
    final d = json['d'];
    if (p is! int || d is! int) return null;
    return EpisodeProgress(
      positionMs: p,
      durationMs: d,
      finished: json['f'] == true,
      updatedAt: json['t'] as int? ?? 0,
    );
  }
}

/// 本机保存的单集续播进度（按 `spotify:episode:` URI）。
///
/// open.spotify.com 节目页不带登录态，返回的 playedState 永远为空；这里在本机记录每集听到哪里、
/// 是否听完，供「从上次位置继续」与节目页的进度条 / 已播完标记使用。
/// 只保留最近更新的 [maxEntries] 条。
class EpisodeProgressStore {
  static const int maxEntries = 300;

  /// 离结尾不到这么多就算听完（片尾广告 / 结束语通常不会听）。
  static const Duration finishThreshold = Duration(seconds: 30);

  /// 开头这么短的进度不记（点开就切走不算「听过」）。
  static const Duration minPosition = Duration(seconds: 5);

  final StorageService? _storage;
  final DateTime Function() _now;
  final Map<String, EpisodeProgress> _items = {};

  EpisodeProgressStore(this._storage, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _load();
  }

  EpisodeProgress? operator [](String uri) => _items[uri];

  /// 续播位置：未听过 / 已听完 / 太靠前时为 null（从头播）。
  Duration? resumePosition(String uri) {
    final item = _items[uri];
    if (item == null || item.finished) return null;
    if (item.positionMs < minPosition.inMilliseconds) return null;
    return Duration(milliseconds: item.positionMs);
  }

  /// 记录进度；返回「已听完」状态是否发生变化（UI 需要刷新标记时）。
  bool update(String uri, Duration position, Duration duration) {
    final durMs = duration.inMilliseconds;
    final posMs = position.inMilliseconds;
    final before = _items[uri];
    if (posMs < minPosition.inMilliseconds && before == null) return false;
    // 时长未知时无法判断是否听完：保留原状态（播放结束时 setFinished 记下的「已听完」不被覆盖）
    final finished = durMs > 0
        ? durMs - posMs <= finishThreshold.inMilliseconds
        : (before?.finished ?? false);
    _put(
      uri,
      EpisodeProgress(
        positionMs: finished ? 0 : posMs,
        durationMs: durMs,
        finished: finished,
        updatedAt: _now().millisecondsSinceEpoch,
      ),
    );
    return before?.finished != finished;
  }

  /// 标记为已听完（播放结束）或未听（重新开始）。
  void setFinished(String uri, bool finished, {Duration? duration}) {
    final before = _items[uri];
    _put(
      uri,
      EpisodeProgress(
        positionMs: 0,
        durationMs: duration?.inMilliseconds ?? before?.durationMs ?? 0,
        finished: finished,
        updatedAt: _now().millisecondsSinceEpoch,
      ),
    );
  }

  void _put(String uri, EpisodeProgress progress) {
    _items.remove(uri);
    _items[uri] = progress;
    if (_items.length > maxEntries) {
      final oldest = _items.entries.toList()
        ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
      for (final e in oldest.take(_items.length - maxEntries)) {
        _items.remove(e.key);
      }
    }
    _save();
  }

  void _load() {
    final raw = _storage?.episodeProgressJson ?? '';
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      decoded.forEach((uri, value) {
        final item = EpisodeProgress.fromJson(value);
        if (item != null) _items[uri] = item;
      });
    } catch (_) {
      // 损坏的数据直接丢弃
    }
  }

  void _save() {
    _storage?.setEpisodeProgressJson(
      jsonEncode({for (final e in _items.entries) e.key: e.value.toJson()}),
    );
  }
}
