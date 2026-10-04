import 'track.dart';

/// 查歌词所需的曲目信息。
///
/// Spotify 官方歌词只要 [trackId]；第三方歌词库（LRCLIB）按曲名 / 歌手 / 专辑 / 时长匹配。
class LyricsQuery {
  final String trackId;
  final String title;

  /// 多位艺人以 ", " 连接（与 [SpotifyTrack.artistNames] 一致）。
  final String artist;
  final String album;
  final int durationMs;

  /// 播客单集：没有歌词，不查任何歌词源（LRCLIB 按「节目名」会匹配到无关歌曲）。
  final bool isEpisode;

  const LyricsQuery({
    required this.trackId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationMs = 0,
    this.isEpisode = false,
  });

  factory LyricsQuery.fromTrack(SpotifyTrack track) => LyricsQuery(
    trackId: track.id,
    title: track.name,
    artist: track.artistNames,
    album: track.album?.name ?? '',
    durationMs: track.durationMs,
    isEpisode: track.uri.startsWith('spotify:episode:'),
  );

  /// 第一位艺人：LRCLIB 的 artist_name 通常只登记主唱，带上合作者反而匹配不到。
  String get primaryArtist {
    final i = artist.indexOf(', ');
    return i < 0 ? artist : artist.substring(0, i);
  }
}
