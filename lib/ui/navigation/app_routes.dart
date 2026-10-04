import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/category.dart';
import '../../models/home_feed.dart';
import '../../models/playlist.dart';
import '../screens/detail/album_detail_screen.dart';
import '../screens/detail/artist_detail_screen.dart';
import '../screens/detail/playlist_detail_screen.dart';
import '../screens/detail/podcast_detail_screen.dart';
import '../screens/home/home_section_screen.dart';
import '../screens/search/category_screen.dart';

/// 详情页导航入口。
///
/// - 详情页压入「当前 Tab 的嵌套 Navigator」（由 MainShell 注册），播放器常驻可见。
/// - 从全屏播放器、底部面板等根级弹层中跳转时，先关闭所有弹层（PopupRoute），
///   与 Spotify 的「Go to album / Go to artist」行为一致。
class AppRoutes {
  AppRoutes._();

  /// MainShell 注册：返回当前 Tab 的 NavigatorState。
  static NavigatorState? Function()? contentNavigator;

  static void openPlaylist(BuildContext context, SpotifyPlaylist playlist) =>
      _push(context, PlaylistDetailScreen(playlist: playlist));

  /// 播客单集的「专辑 / 艺人」是所属节目（uri 为 `spotify:show:`），跳到节目页；
  /// 没有 id 的引用（无法加载详情）忽略。
  static void openAlbum(BuildContext context, SpotifyAlbum album) {
    if (album.uri.startsWith('spotify:show:')) {
      openPodcast(context, album.uri, initialTitle: album.name, initialCover: album.coverUrl);
      return;
    }
    if (album.id.isEmpty) return;
    _push(context, AlbumDetailScreen(album: album));
  }

  static void openArtist(BuildContext context, SpotifyArtist artist) {
    if (artist.uri.startsWith('spotify:show:')) {
      openPodcast(context, artist.uri, initialTitle: artist.name);
      return;
    }
    if (artist.id.isEmpty) return;
    _push(context, ArtistDetailScreen(artist: artist));
  }

  /// 播客节目页。[showUri] 为 `spotify:show:xxx`；[initialTitle] / [initialCover] 来自卡片，加载前先展示。
  static void openPodcast(
    BuildContext context,
    String showUri, {
    String initialTitle = '',
    String initialCover = '',
  }) => _push(
    context,
    PodcastDetailScreen(
      showId: showUri.startsWith('spotify:show:')
          ? showUri.substring(13)
          : showUri,
      initialTitle: initialTitle,
      initialCover: initialCover,
    ),
  );

  /// 主页分区的「显示全部」。
  static void openHomeSection(
    BuildContext context,
    HomeSection section, {
    String facet = '',
  }) => _push(context, HomeSectionScreen(section: section, facet: facet));

  /// 分类页（browsePage）。
  static void openCategory(BuildContext context, SpotifyCategory category) =>
      _push(context, CategoryScreen(category: category));

  static void _push(BuildContext context, Widget page) {
    // 先取出两个 Navigator：关闭弹层后 context 可能已失效
    final root = Navigator.of(context, rootNavigator: true);
    final target = contentNavigator?.call() ?? Navigator.of(context);
    root.popUntil((route) => route is! PopupRoute);
    target.push(MaterialPageRoute(builder: (_) => page));
  }
}
