import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/home_feed.dart';
import '../../../models/playback_context.dart';
import '../../../models/track.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../widgets/toast/app_toast.dart';

/// 主页条目（卡片 / 快捷入口 / 推荐流）的点击与播放。
///
/// - 点击：打开对应详情页；播客打开节目页，单集打开所属节目（缺节目 URI 时先经单集页解析）；
/// - 播放键：先取曲目再整张播放；取不到曲目（未登录 / 网络失败）时退回打开详情页，由详情页说明原因。
class HomeItemActions {
  HomeItemActions._();

  static void open(BuildContext context, HomeItem item) {
    switch (item.kind) {
      case HomeItemKind.likedSongs:
        AppRoutes.openPlaylist(
          context,
          context.read<LibraryProvider>().likedSongsPlaylist,
        );
      case HomeItemKind.playlist:
        AppRoutes.openPlaylist(context, item.playlist!);
      case HomeItemKind.album:
        AppRoutes.openAlbum(context, item.album!);
      case HomeItemKind.artist:
        AppRoutes.openArtist(context, item.artist!);
      case HomeItemKind.podcast:
        AppRoutes.openPodcast(
          context,
          item.uri,
          initialTitle: item.title,
          initialCover: item.imageUrl,
        );
      case HomeItemKind.episode:
        _openEpisode(context, item);
    }
  }

  /// 单集 → 所属节目页。主页解析已带节目 URI 时直接打开；否则先拉单集页解析。
  static void _openEpisode(BuildContext context, HomeItem item) {
    if (item.parentUri.isNotEmpty) {
      AppRoutes.openPodcast(
        context,
        item.parentUri,
        initialCover: item.imageUrl,
      );
      return;
    }
    final api = context.read<SpotifyApiService>();
    api
        .getPodcastEpisode(_episodeId(item))
        .then((episode) {
          if (context.mounted && episode.showUri.isNotEmpty) {
            AppRoutes.openPodcast(
              context,
              episode.showUri,
              initialTitle: episode.showName,
              initialCover: episode.coverUrl,
            );
          }
        })
        .catchError((Object _) {
          if (context.mounted) {
            AppToast.show(
              context,
              context.l10n.detailLoadFailed,
              icon: Icons.podcasts_rounded,
              tone: ToastTone.warning,
            );
          }
        });
  }

  static String _episodeId(HomeItem item) =>
      item.uri.startsWith('spotify:episode:')
      ? item.uri.substring(16)
      : item.uri;

  /// 卡片上是否显示播放键（播客节目点开看单集列表，不直接播放；单集可以直接播）。
  static bool canPlay(HomeItem item) => item.kind != HomeItemKind.podcast;

  static Future<void> play(BuildContext context, HomeItem item) async {
    final api = context.read<SpotifyApiService>();
    final playback = context.read<PlaybackProvider>();
    final library = context.read<LibraryProvider>();

    final (
      List<SpotifyTrack> tracks,
      PlaybackContext playContext,
    ) = switch (item.kind) {
      HomeItemKind.likedSongs => (
        library.likedTracks,
        PlaybackContext.collection(
          context.l10n.likedSongs,
          uri: LibraryProvider.likedSongsUri,
        ),
      ),
      HomeItemKind.playlist => (
        await _guard(
          () async => (await api.getPlaylist(item.playlist!.id)).tracks,
        ),
        PlaybackContext.playlist(item.title, uri: item.uri),
      ),
      HomeItemKind.album => (
        await _guard(() => api.getAlbumTracks(item.album!)),
        PlaybackContext.album(item.title, uri: item.uri),
      ),
      HomeItemKind.artist => (
        await _guard(() => api.getArtistTopTracks(item.artist!.id)),
        PlaybackContext.artist(item.title, uri: item.uri),
      ),
      HomeItemKind.episode => (
        await _guard(
          () async => [
            (await api.getPodcastEpisode(_episodeId(item))).toTrack(),
          ],
        ),
        PlaybackContext.none,
      ),
      HomeItemKind.podcast => (const <SpotifyTrack>[], PlaybackContext.none),
    };

    if (!context.mounted) return;
    if (tracks.isEmpty) {
      open(context, item);
      return;
    }
    await playback.playContext(tracks, playContext);
  }

  static Future<List<SpotifyTrack>> _guard(
    Future<List<SpotifyTrack>> Function() load,
  ) async {
    try {
      return await load();
    } catch (_) {
      return const [];
    }
  }
}
