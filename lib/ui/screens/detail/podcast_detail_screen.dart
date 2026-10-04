import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../l10n/l10n.dart';
import '../../../models/playback_context.dart';
import '../../../models/podcast.dart';
import '../../../models/share_target.dart';
import '../../../models/track.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../services/podcast/episode_progress_store.dart';
import '../../../services/spotify_api_service.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/hover_builder.dart';
import '../../widgets/menu/desktop_menu.dart';
import '../../widgets/share/share_button.dart';
import '../../widgets/share/share_sheet.dart';
import '../../widgets/toast/app_toast.dart';
import 'widgets/collection_hero.dart';
import 'widgets/collection_widgets.dart';

/// 播客节目详情页：封面 + 出版方 + 关注 / 分享 + 简介 + 最新单集列表。
///
/// 数据来自 open.spotify.com 节目页（[SpotifyApiService.getPodcastShow]），无需登录即可加载；
/// 单集点击即播放（AP 协议链路，见 PodcastRoutingAudioSource）。
/// 收听进度 / 已播完来自本机记录（[PlaybackProvider.episodeProgress]），页面数据里的 playedState
/// 只在本机没有记录时兜底（未登录的页面数据里通常为空）。
class PodcastDetailScreen extends StatefulWidget {
  /// 节目 id（`spotify:show:xxx` 中的 xxx）。
  final String showId;

  /// 卡片带来的节目标题 / 封面（加载完成前先展示）。
  final String initialTitle;
  final String initialCover;

  const PodcastDetailScreen({
    super.key,
    required this.showId,
    this.initialTitle = '',
    this.initialCover = '',
  });

  @override
  State<PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends State<PodcastDetailScreen> {
  PodcastShow? _show;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _error = null);
    try {
      final show = await context.read<SpotifyApiService>().getPodcastShow(
        widget.showId,
      );
      if (mounted) setState(() => _show = show);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final show = _show;
    final title = show?.name ?? widget.initialTitle;
    final cover = show?.coverUrl ?? widget.initialCover;
    final episodes = show?.episodes ?? const <PodcastEpisode>[];
    final tracks = [for (final e in episodes) e.toTrack()];
    final playbackContext = PlaybackContext.collection(
      title,
      uri: show?.uri ?? 'spotify:show:${widget.showId}',
    );
    final followed = context.select<LibraryProvider, bool>(
      (l) => l.isShowFollowed(widget.showId),
    );

    return Scaffold(
      body: CollectionTintScope(
        imageUrl: cover,
        fallback: const Color(0xFF3A3A48),
        child: CustomScrollView(
          slivers: [
            CollectionHero(
              typeLabel: l10n.typePodcast,
              title: title,
              imageUrl: cover,
              meta: _PodcastMeta(show: show),
              collapsedAction: ContextPlayButton(
                tracks: tracks,
                playbackContext: playbackContext,
                size: 44,
                elevated: false,
              ),
            ),
            SliverToBoxAdapter(
              child: CollectionHeroFade(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: CollectionActionRow(
                    tracks: tracks,
                    playbackContext: playbackContext,
                    showShuffle: false,
                    leading: [
                      if (show != null) ...[
                        _FollowButton(
                          followed: followed,
                          onPressed: () => context
                              .read<LibraryProvider>()
                              .toggleShowFollowed(show),
                        ),
                        const SizedBox(width: 4),
                        ShareButton(target: ShareTarget.show(show)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (show != null && show.description.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _ExpandableText(show.description),
                ),
              ),
            if (show == null && _error == null)
              const CollectionPlaceholder(loading: true)
            else if (_error != null)
              CollectionErrorPlaceholder(signedOut: false, onRetry: _fetch)
            else if (episodes.isEmpty)
              CollectionPlaceholder(
                message: l10n.podcastEmpty,
                icon: Icons.podcasts_rounded,
              )
            else ...[
              SliverList.builder(
                itemCount: episodes.length,
                itemBuilder: (context, index) => _EpisodeTile(
                  episode: episodes[index],
                  queue: tracks,
                  playbackContext: playbackContext,
                ),
              ),
              // 节目页只带一页单集（约 12 集，按节目设定的顺序），说明一下，免得以为只有这么多
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    l10n.podcastLatestHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
            const ContentBottomSpacer(),
          ],
        ),
      ),
    );
  }
}

/// 「关注 / 已关注」描边按钮（Spotify 节目页样式）。
class _FollowButton extends StatelessWidget {
  final bool followed;
  final VoidCallback onPressed;

  const _FollowButton({required this.followed, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: followed ? l10n.podcastUnfollow : l10n.podcastFollow,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          foregroundColor: followed ? context.tokens.accent : null,
          side: BorderSide(
            color: followed
                ? context.tokens.accent
                : Theme.of(context).colorScheme.outline,
          ),
        ),
        child: Text(
          followed ? l10n.podcastFollowing : l10n.podcastFollow,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// 节目简介：默认三行，点击展开 / 收起。
class _ExpandableText extends StatefulWidget {
  final String text;

  const _ExpandableText(this.text);

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedSize(
        duration: context.motion(const Duration(milliseconds: 200)),
        alignment: Alignment.topLeft,
        child: Text(
          widget.text,
          maxLines: _expanded ? null : 3,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

/// 头部元信息：出版方 · 集数。
class _PodcastMeta extends StatelessWidget {
  final PodcastShow? show;

  const _PodcastMeta({required this.show});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final show = this.show;
    if (show == null) return const SizedBox.shrink();
    return Row(
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: context.tokens.accent,
          child: Icon(
            Icons.podcasts_rounded,
            color: context.tokens.onAccent,
            size: 14,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            show.publisher,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (show.episodes.isNotEmpty)
          Flexible(
            child: Text(
              ' · ${l10n.podcastEpisodeCount(show.episodes.length)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// 单集操作。
enum _EpisodeAction { queue, togglePlayed, share }

/// 单集行：封面（叠播放态）+ 标题 + 简介 + 「日期 · 时长 · 播放进度」+ 更多。
class _EpisodeTile extends StatelessWidget {
  final PodcastEpisode episode;
  final List<SpotifyTrack> queue;
  final PlaybackContext playbackContext;

  const _EpisodeTile({
    required this.episode,
    required this.queue,
    required this.playbackContext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    // 当前播放态（按 uri 匹配，单集与曲目不会撞 id）与本机收听进度
    final (isCurrent, isPlaying, local) = context
        .select<PlaybackProvider, (bool, bool, EpisodeProgress?)>(
          (p) => (
            p.currentTrack?.uri == episode.uri,
            p.currentTrack?.uri == episode.uri && p.isPlaying,
            p.episodeProgress[episode.uri],
          ),
        );
    final played = local?.finished ?? episode.played;
    final resumeMs = local == null
        ? episode.resumeMs
        : (local.finished ? 0 : local.positionMs);
    final durationMs = episode.durationMs > 0
        ? episode.durationMs
        : (local?.durationMs ?? 0);

    // 元信息行：日期 · 时长（· 播至 mm:ss / 已播完）
    final parts = <String>[
      if (episode.releaseDate.isNotEmpty)
        Formatters.formatReleaseDate(
          l10n,
          episode.releaseDate.split('T').first,
        ),
      if (durationMs > 0) Formatters.formatDurationMs(durationMs),
      if (played)
        l10n.podcastPlayed
      else if (resumeMs > 0)
        l10n.podcastResumeFrom(Formatters.formatDurationMs(resumeMs)),
    ];

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: () => _play(context),
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition, played),
        onLongPressStart: (details) =>
            _showMenu(context, details.globalPosition, played),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: context.motion(const Duration(milliseconds: 150)),
          color: hovered
              ? colorScheme.surfaceContainerHighest.withAlpha(120)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(episode: episode, playing: isPlaying, hovered: hovered),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      episode.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isCurrent ? context.tokens.accent : null,
                      ),
                    ),
                    if (episode.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        episode.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          played
                              ? Icons.check_circle_rounded
                              : Icons.play_circle_outline_rounded,
                          size: 16,
                          color: played
                              ? context.tokens.accent
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            parts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // 续播进度条
                    if (!played && resumeMs > 0 && durationMs > 0) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (resumeMs / durationMs).clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation(
                            context.tokens.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Builder(
                builder: (buttonContext) => IconButton(
                  icon: const Icon(Icons.more_horiz_rounded),
                  color: colorScheme.onSurfaceVariant,
                  onPressed: () => _showMenu(
                    context,
                    DesktopMenu.anchorOf(buttonContext),
                    played,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(BuildContext context) {
    final playback = context.read<PlaybackProvider>();
    if (playback.currentTrack?.uri == episode.uri) {
      playback.togglePlayPause();
    } else {
      playback.playTrack(
        episode.toTrack(),
        contextQueue: queue,
        context: playbackContext,
      );
    }
  }

  Future<void> _showMenu(
    BuildContext context,
    Offset position,
    bool played,
  ) async {
    final l10n = context.l10n;
    final share = ShareTarget.track(episode.toTrack());
    final action = await DesktopMenu.show<_EpisodeAction>(context, position, [
      DesktopMenu.item(
        _EpisodeAction.queue,
        Icons.queue_music_rounded,
        l10n.trackAddToQueue,
      ),
      DesktopMenu.item(
        _EpisodeAction.togglePlayed,
        played ? Icons.remove_done_rounded : Icons.check_circle_outline_rounded,
        played ? l10n.podcastMarkUnplayed : l10n.podcastMarkPlayed,
      ),
      if (share.isShareable) ...[
        DesktopMenu.divider,
        DesktopMenu.item(
          _EpisodeAction.share,
          Icons.ios_share_rounded,
          l10n.commonShare,
        ),
      ],
    ]);
    if (action == null || !context.mounted) return;
    final playback = context.read<PlaybackProvider>();
    switch (action) {
      case _EpisodeAction.queue:
        playback.addToQueue(episode.toTrack());
        AppToast.show(
          context,
          l10n.toastAddedToQueue,
          icon: Icons.queue_music_rounded,
          tone: ToastTone.success,
        );
      case _EpisodeAction.togglePlayed:
        playback.markEpisodePlayed(episode.uri, !played);
      case _EpisodeAction.share:
        await ShareSheet.show(context, share);
    }
  }
}

/// 单集封面：悬停 / 播放中时叠加播放图标。
class _Cover extends StatelessWidget {
  final PodcastEpisode episode;
  final bool playing;
  final bool hovered;

  const _Cover({
    required this.episode,
    required this.playing,
    required this.hovered,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (episode.coverUrl.isNotEmpty)
              Image.network(
                episode.coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(colorScheme),
              )
            else
              _placeholder(colorScheme),
            if (hovered || playing)
              ColoredBox(
                color: Colors.black.withAlpha(90),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _placeholder(ColorScheme colorScheme) => ColoredBox(
    color: colorScheme.surfaceContainerHigh,
    child: Icon(Icons.podcasts_rounded, color: colorScheme.onSurfaceVariant),
  );
}
