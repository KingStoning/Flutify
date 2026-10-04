import 'audio_cache_store.dart';
import 'track_audio_loader.dart';

/// 按 URI 类型分流的音频来源：`spotify:episode:` 走 [episodes]（AP 协议链路：Mercury 元数据 →
/// 明文 / 外部地址下载，见 [TrackAudioLoader]），其余曲目走 [tracks]（EME / Widevine 链路）。
///
/// 为什么单集不能走 EME：EME 链路的 track-playback 只认曲目 id，单集 URI 会被当成曲目查询而失败；
/// 而单集元数据只能从 AP 上的 Mercury `hm://metadata/4/episode` 取得。
///
/// 缓存管理（[AudioCacheStore]）合并两边：大小相加、清理两边、上限同时下发。
class PodcastRoutingAudioSource implements TrackAudioSource, AudioCacheStore {
  final TrackAudioSource tracks;
  final TrackAudioSource episodes;

  PodcastRoutingAudioSource({required this.tracks, required this.episodes});

  static bool isEpisode(String trackIdOrUri) =>
      trackIdOrUri.startsWith('spotify:episode:');

  TrackAudioSource _route(String trackIdOrUri) =>
      isEpisode(trackIdOrUri) ? episodes : tracks;

  @override
  Future<LoadedAudio> load(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) => _route(trackIdOrUri).load(trackIdOrUri, progress: progress);

  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) => _route(trackIdOrUri).open(trackIdOrUri, progress: progress);

  @override
  Future<void> prefetch(String trackIdOrUri) =>
      _route(trackIdOrUri).prefetch(trackIdOrUri);

  Iterable<AudioCacheStore> get _stores => [
    tracks,
    episodes,
  ].whereType<AudioCacheStore>();

  @override
  int get maxCacheBytes {
    final stores = _stores;
    return stores.isEmpty ? 0 : stores.first.maxCacheBytes;
  }

  @override
  set maxCacheBytes(int value) {
    for (final store in _stores) {
      store.maxCacheBytes = value;
    }
  }

  @override
  Future<int> sizeBytes() async {
    var total = 0;
    for (final store in _stores) {
      total += await store.sizeBytes();
    }
    return total;
  }

  @override
  Future<int> clear() async {
    var freed = 0;
    for (final store in _stores) {
      freed += await store.clear();
    }
    return freed;
  }
}
