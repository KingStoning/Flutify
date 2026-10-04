import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/lyrics_query.dart';
import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/podcast.dart';
import 'package:flutify_app/models/share_target.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/auth/proto_codec.dart';
import 'package:flutify_app/services/pathfinder/pathfinder_parsers.dart';
import 'package:flutify_app/services/lyrics/lyrics_resolver.dart';
import 'package:flutify_app/services/podcast/episode_progress_store.dart';
import 'package:flutify_app/services/protocol/audio_cache_store.dart';
import 'package:flutify_app/services/protocol/decrypt/audio_decryptor.dart';
import 'package:flutify_app/services/protocol/episode_metadata.dart';
import 'package:flutify_app/services/protocol/podcast_routing_audio_source.dart';
import 'package:flutify_app/services/protocol/progressive_download.dart';
import 'package:flutify_app/services/protocol/spotify_id.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutify_app/services/protocol/track_metadata.dart';
import 'package:flutify_app/services/spotify_api_service.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_audio_player_service.dart';
import 'fakes/fake_track_audio_source.dart';
import 'fixtures/sample_catalog.dart';

const _episodeA = PodcastEpisode(
  id: 'episodeA00000000000001',
  uri: 'spotify:episode:episodeA00000000000001',
  name: 'Episode A',
  durationMs: 60 * 60 * 1000,
  showUri: 'spotify:show:showA00000000000000001',
  showName: 'Show A',
);

const _episodeB = PodcastEpisode(
  id: 'episodeB00000000000002',
  uri: 'spotify:episode:episodeB00000000000002',
  name: 'Episode B',
  durationMs: 30 * 60 * 1000,
  showUri: 'spotify:show:showA00000000000000001',
  showName: 'Show A',
);

/// 单集元数据走 AP（测试里不可用）：直接返回预设结果。
class _StubEpisodeLoader extends TrackAudioLoader {
  final EpisodeMetadata meta;

  _StubEpisodeLoader(this.meta, {required super.cacheDirectory, required http.Client client})
    : super(accessToken: () async => 'token', client: client);

  @override
  Future<EpisodeMetadata> fetchEpisodeMetadata(SpotifyId id) async => meta;
}

/// 记录被路由到的一侧，并带缓存管理能力（验证合并）。
class _RecordingSource extends FakeTrackAudioSource implements AudioCacheStore {
  final int size;
  int cleared = 0;
  int limit = 0;

  _RecordingSource(this.size);

  @override
  int get maxCacheBytes => limit;
  @override
  set maxCacheBytes(int value) => limit = value;
  @override
  Future<int> sizeBytes() async => size;
  @override
  Future<int> clear() async {
    cleared++;
    return size;
  }
}

void main() {
  group('EpisodeProgressStore', () {
    late StorageService storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = await StorageService.init();
    });

    test('记录进度并持久化；太靠前的位置不作为续播点', () {
      final store = EpisodeProgressStore(storage);
      expect(store.resumePosition(_episodeA.uri), isNull);

      // 刚点开就切走：不记录
      store.update(_episodeA.uri, const Duration(seconds: 2), const Duration(minutes: 60));
      expect(store[_episodeA.uri], isNull);

      store.update(_episodeA.uri, const Duration(minutes: 20), const Duration(minutes: 60));
      expect(store.resumePosition(_episodeA.uri), const Duration(minutes: 20));

      // 重新读取（模拟重启）
      final reloaded = EpisodeProgressStore(storage);
      expect(reloaded.resumePosition(_episodeA.uri), const Duration(minutes: 20));
      expect(reloaded[_episodeA.uri]!.fraction, closeTo(1 / 3, 1e-9));
    });

    test('离结尾不到 30 秒算听完；听完后不再续播', () {
      final store = EpisodeProgressStore(storage);
      final changed = store.update(
        _episodeA.uri,
        const Duration(minutes: 59, seconds: 45),
        const Duration(minutes: 60),
      );
      expect(changed, isTrue);
      expect(store[_episodeA.uri]!.finished, isTrue);
      expect(store.resumePosition(_episodeA.uri), isNull);

      store.setFinished(_episodeA.uri, false);
      expect(store[_episodeA.uri]!.finished, isFalse);
      expect(store.resumePosition(_episodeA.uri), isNull); // 标记未播放 = 从头开始
    });

    test('时长未知时不覆盖「已听完」', () {
      final store = EpisodeProgressStore(storage);
      store.setFinished(_episodeA.uri, true);
      store.update(_episodeA.uri, const Duration(minutes: 10), Duration.zero);
      expect(store[_episodeA.uri]!.finished, isTrue);
    });

    test('超过上限时淘汰最久未更新的记录', () {
      var now = 0;
      final store = EpisodeProgressStore(
        storage,
        now: () => DateTime.fromMillisecondsSinceEpoch(++now),
      );
      for (var i = 0; i < EpisodeProgressStore.maxEntries + 5; i++) {
        store.setFinished('spotify:episode:$i', true);
      }
      expect(store['spotify:episode:0'], isNull);
      expect(store['spotify:episode:4'], isNull);
      expect(store['spotify:episode:5'], isNotNull);
      expect(store['spotify:episode:${EpisodeProgressStore.maxEntries + 4}'], isNotNull);
    });

    test('损坏的数据被忽略', () async {
      await storage.setEpisodeProgressJson('{not json');
      expect(EpisodeProgressStore(storage)[_episodeA.uri], isNull);
    });
  });

  group('PlaybackProvider 播客', () {
    late FakeAudioPlayerService audio;
    late FakeTrackAudioSource loader;
    late PlaybackProvider playback;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      audio = FakeAudioPlayerService();
      loader = FakeTrackAudioSource();
      playback = PlaybackProvider(audio, storage, random: Random(1), audioLoader: loader);
    });

    tearDown(() => playback.dispose());

    test('单集按完整 URI 加载（走单集链路），音乐按 id', () async {
      await playback.playTrack(_episodeA.toTrack());
      await playback.playTrack(SampleCatalog.track1);
      expect(loader.loaded, [_episodeA.uri, SampleCatalog.track1.id]);
      expect(playback.isEpisode, isFalse);
    });

    test('单集从上次听到的位置继续；显式 startAt 优先', () async {
      playback.episodeProgress.update(
        _episodeA.uri,
        const Duration(minutes: 20),
        const Duration(minutes: 60),
      );
      await playback.playTrack(_episodeA.toTrack());
      expect(audio.initialPositions.last, const Duration(minutes: 20));
      expect(playback.position, const Duration(minutes: 20));

      await playback.playLocal(_episodeA.toTrack(), startAt: const Duration(minutes: 5));
      expect(audio.initialPositions.last, const Duration(minutes: 5));
    });

    test('切到别的曲目时记下单集进度', () async {
      await playback.playTrack(_episodeA.toTrack());
      audio.positionController.add(const Duration(minutes: 12));
      await playback.playTrack(_episodeB.toTrack());

      expect(playback.episodeProgress.resumePosition(_episodeA.uri), const Duration(minutes: 12));
      // 再切回来：从 12 分钟继续
      await playback.playTrack(_episodeA.toTrack());
      expect(audio.initialPositions.last, const Duration(minutes: 12));
    });

    test('播放结束标记为已听完，下次从头播', () async {
      await playback.playTrack(_episodeA.toTrack(), contextQueue: [_episodeA.toTrack()]);
      audio.positionController.add(const Duration(minutes: 30));
      audio.stateController.add(PlayerState(true, ProcessingState.completed));
      await pumpEventQueue();

      expect(playback.episodeProgress[_episodeA.uri]!.finished, isTrue);
      await playback.playTrack(_episodeA.toTrack());
      expect(audio.initialPositions.last, isNull);
    });

    test('播放速度只作用于单集，并持久化', () async {
      playback.setPodcastSpeed(1.5);
      await playback.playTrack(_episodeA.toTrack());
      expect(audio.lastSpeed, 1.5);

      await playback.playTrack(SampleCatalog.track1);
      expect(audio.lastSpeed, 1.0);

      // 超出范围被夹住
      playback.setPodcastSpeed(10);
      expect(playback.podcastSpeed, 3.0);
    });

    test('快进 / 快退：不会退到 0 之前', () async {
      await playback.playTrack(_episodeA.toTrack());
      audio.positionController.add(const Duration(seconds: 5));
      await playback.skipBy(const Duration(seconds: -10));
      expect(audio.seeks.last, Duration.zero);
      await playback.skipBy(const Duration(seconds: 30));
      expect(audio.seeks.last, const Duration(seconds: 30));
    });

    test('随机播放开着也按节目顺序播单集', () async {
      playback.setShuffle(true);
      final tracks = [
        for (var i = 0; i < 8; i++)
          PodcastEpisode(id: 'episode${i}0000000000000', uri: 'spotify:episode:episode${i}0000000000000', name: '$i')
              .toTrack(),
      ];
      await playback.playContext(tracks, const PlaybackContext.collection('Show A', uri: 'spotify:show:x'));
      expect(playback.currentTrack?.uri, tracks.first.uri);
      expect(playback.upNext.map((e) => e.track.uri), tracks.skip(1).map((t) => t.uri));
    });

    test('手动标记已播完 / 未播放', () {
      playback.markEpisodePlayed(_episodeB.uri, true);
      expect(playback.episodeProgress[_episodeB.uri]!.finished, isTrue);
      playback.markEpisodePlayed(_episodeB.uri, false);
      expect(playback.episodeProgress[_episodeB.uri]!.finished, isFalse);
    });
  });

  group('LibraryProvider 关注节目', () {
    test('关注 / 取消关注并持久化（不保存单集）', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await StorageService.init();
      final library = LibraryProvider(storage);
      const show = PodcastShow(
        id: 'showA00000000000000001',
        uri: 'spotify:show:showA00000000000000001',
        name: 'Show A',
        publisher: 'Pub',
        episodes: [_episodeA],
      );

      library.toggleShowFollowed(show);
      expect(library.isShowFollowed(show.id), isTrue);
      expect(library.shows.single.episodes, isEmpty);

      final reloaded = LibraryProvider(storage);
      expect(reloaded.shows.single.name, 'Show A');
      expect(reloaded.shows.single.publisher, 'Pub');

      reloaded.toggleShowFollowed(show);
      expect(reloaded.isShowFollowed(show.id), isFalse);
      expect(LibraryProvider(storage).shows, isEmpty);
    });

    test('单集不能点赞（不会写进已点赞的歌曲）', () async {
      SharedPreferences.setMockInitialValues({});
      final library = LibraryProvider(await StorageService.init());
      library.toggleLike(_episodeA.toTrack());
      expect(library.likedTracks, isEmpty);
    });
  });

  group('PodcastRoutingAudioSource', () {
    test('单集走单集来源，曲目走曲目来源；缓存管理合并两边', () async {
      final tracks = _RecordingSource(100);
      final episodes = _RecordingSource(23);
      final source = PodcastRoutingAudioSource(tracks: tracks, episodes: episodes);

      await source.open(_episodeA.uri);
      await source.load(SampleCatalog.track1.id);
      await source.prefetch(SampleCatalog.track2.id);
      expect(episodes.loaded, [_episodeA.uri]);
      expect(tracks.loaded, [SampleCatalog.track1.id]);
      expect(tracks.prefetched, [SampleCatalog.track2.id]);

      expect(await source.sizeBytes(), 123);
      expect(await source.clear(), 123);
      expect(tracks.cleared, 1);
      expect(episodes.cleared, 1);
      source.maxCacheBytes = 42;
      expect(tracks.limit, 42);
      expect(episodes.limit, 42);
    });
  });

  group('明文单集下载', () {
    test('文件头识别：Ogg / Spotify Ogg / ID3 / MPEG 帧 / MP4，随机字节不算', () {
      Uint8List head(List<int> prefix, [int at = 0]) {
        final b = Uint8List(SpotifyAudioHeader.probeLength);
        b.setAll(at, prefix);
        return b;
      }

      expect(SpotifyAudioHeader.looksLikePlainAudio(head('OggS'.codeUnits)), isTrue);
      expect(
        SpotifyAudioHeader.looksLikePlainAudio(head('OggS'.codeUnits, SpotifyAudioHeader.oggHeaderEnd)),
        isTrue,
      );
      expect(SpotifyAudioHeader.looksLikePlainAudio(head('ID3'.codeUnits)), isTrue);
      expect(SpotifyAudioHeader.looksLikePlainAudio(head([0xFF, 0xFB, 0x90, 0x64])), isTrue);
      expect(SpotifyAudioHeader.looksLikePlainAudio(head('ftyp'.codeUnits, 4)), isTrue);
      // 同步字对、但码率为保留值 1111：不是合法帧头
      expect(SpotifyAudioHeader.looksLikePlainAudio(head([0xFF, 0xFB, 0xF0, 0x64])), isFalse);

      final random = Random(7);
      var falsePositives = 0;
      for (var i = 0; i < 2000; i++) {
        final b = Uint8List.fromList(List.generate(SpotifyAudioHeader.probeLength, (_) => random.nextInt(256)));
        if (SpotifyAudioHeader.looksLikePlainAudio(b)) falsePositives++;
      }
      expect(falsePositives, lessThan(5));
    });

    test('文件头不像音频：以 UnrecognizedAudioException 结束，不换地址重试', () async {
      var requests = 0;
      final noise = Uint8List.fromList(List.generate(4096, (i) => (i * 97 + 13) & 0xff));
      final client = MockClient.streaming((request, _) async {
        requests++;
        return http.StreamedResponse(Stream.value(noise), 200, contentLength: noise.length);
      });
      final download = ProgressiveDownload(
        urls: const ['https://cdn-a/x', 'https://cdn-b/x'],
        decrypt: const PassthroughDecryptSpec(),
        format: AudioFileFormat.oggVorbis96,
        client: client,
        validateHead: SpotifyAudioHeader.looksLikePlainAudio,
      )..start();

      await expectLater(download.ready, throwsA(isA<UnrecognizedAudioException>()));
      await expectLater(download.done, throwsA(isA<UnrecognizedAudioException>()));
      expect(requests, 1);
    });

    test('明文 MP3 正常下载，MIME 按格式给出', () async {
      final mp3 = Uint8List.fromList([...'ID3'.codeUnits, ...List.filled(2000, 7)]);
      final client = MockClient((_) async => http.Response.bytes(mp3, 200));
      final download = ProgressiveDownload(
        urls: const ['https://cdn/x.mp3'],
        decrypt: const PassthroughDecryptSpec(),
        format: TrackAudioLoader.externalAudioFormat('https://host/a/b.mp3?x=1'),
        client: client,
        validateHead: SpotifyAudioHeader.looksLikePlainAudio,
      )..start();
      await download.done;
      expect(download.playableBytes, mp3);
      expect(download.contentType, 'audio/mpeg');
    });

    test('外部地址的格式推断', () {
      expect(TrackAudioLoader.externalAudioFormat('https://a/b.m4a').extension, 'm4a');
      expect(TrackAudioLoader.externalAudioFormat('https://a/b.OGG').extension, 'ogg');
      expect(TrackAudioLoader.externalAudioFormat('https://a/redirect?u=1').extension, 'mp3');
    });
  });

  group('TrackAudioLoader 外部托管单集', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('flutify_podcast_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('没有 Spotify 音频文件时下载 external_url，落盘后再次播放命中缓存', () async {
      final mp3 = Uint8List.fromList([...'ID3'.codeUnits, ...List.filled(5000, 1)]);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.url.toString(), 'https://feeds.example.com/ep.mp3');
        return http.Response.bytes(mp3, 200);
      });
      final loader = _StubEpisodeLoader(
        EpisodeMetadata(
          gid: Uint8List(16),
          name: 'Ep',
          durationMs: 5000,
          externalUrl: 'https://feeds.example.com/ep.mp3',
        ),
        cacheDirectory: dir.path,
        client: client,
      );

      final first = await loader.load(_episodeA.uri);
      expect(first.file.readAsBytesSync(), mp3);
      expect(first.file.path, endsWith('.mp3'));
      expect(first.durationMs, 5000);

      final second = await loader.open(_episodeA.uri);
      expect(second.stream, isNull); // 命中缓存，直接播放文件
      expect(second.file.path, first.file.path);
      expect(requests, 1);
    });

    test('外部地址返回的不是音频：报「不可播放」，不写缓存', () async {
      final client = MockClient((_) async => http.Response('<html>blocked</html>' * 20, 200));
      final loader = _StubEpisodeLoader(
        EpisodeMetadata(gid: Uint8List(16), name: 'Ep', externalUrl: 'https://feeds.example.com/ep.mp3'),
        cacheDirectory: dir.path,
        client: client,
      );
      await expectLater(
        loader.open(_episodeA.uri),
        throwsA(isA<TrackPlaybackException>().having((e) => e.kind, 'kind', TrackPlaybackFailure.unavailable).having((e) => e.message, 'message', contains('格式无法识别'))),
      );
      final audioDir = Directory('${dir.path}${Platform.pathSeparator}audio');
      expect(audioDir.existsSync() ? audioDir.listSync() : const [], isEmpty);
    });

    test('既没有文件也没有外部地址：不可播放', () async {
      final loader = _StubEpisodeLoader(
        EpisodeMetadata(gid: Uint8List(16), name: 'Ep'),
        cacheDirectory: dir.path,
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        loader.open(_episodeA.uri),
        throwsA(isA<TrackPlaybackException>().having((e) => e.kind, 'kind', TrackPlaybackFailure.unavailable)),
      );
    });
  });

  test('EpisodeMetadata 解析 external_url（字段 83）', () {
    final gid = List<int>.generate(16, (i) => i + 1);
    final w = ProtoWriter()
      ..bytes(1, gid)
      ..string(2, 'Ep')
      ..string(83, 'https://example.com/ep.mp3');
    final meta = EpisodeMetadata.parse(w.toBytes());
    expect(meta.name, 'Ep');
    expect(meta.externalUrl, 'https://example.com/ep.mp3');
    expect(meta.hasAnyFile, isFalse);

    // 非 http(s) 的值不当作地址
    final bad = EpisodeMetadata.parse((ProtoWriter()..string(83, 'javascript:alert(1)')).toBytes());
    expect(bad.externalUrl, isEmpty);
  });

  test('Pathfinder 搜索结果解析播客节目与单集', () {
    final data = jsonDecode('''
    {"searchV2": {
      "podcasts": {"items": [
        {"__typename": "PodcastResponseWrapper", "data": {
          "__typename": "Podcast", "uri": "spotify:show:showA00000000000000001", "name": "Show A",
          "publisher": {"name": "Pub"},
          "coverArt": {"sources": [{"url": "https://i/s.jpg", "width": 300, "height": 300}]}}},
        {"__typename": "PodcastResponseWrapper", "data": {"__typename": "NotFound"}}
      ]},
      "episodes": {"items": [
        {"__typename": "EpisodeOrChapterResponseWrapper", "data": {
          "__typename": "Episode", "uri": "spotify:episode:episodeA00000000000001", "name": "Ep A",
          "description": "<b>hi</b> &amp; bye",
          "duration": {"totalMilliseconds": 123000},
          "releaseDate": {"isoString": "2026-01-02T00:00:00Z"},
          "podcastV2": {"data": {"__typename": "Podcast", "uri": "spotify:show:showA00000000000000001", "name": "Show A"}},
          "coverArt": {"sources": [{"url": "https://i/e.jpg", "width": 64, "height": 64}]}}}
      ]}
    }}
    ''') as Map<String, dynamic>;
    final r = PathfinderParsers.search(data);
    expect(r.tracks, isEmpty);
    expect(r.shows.single.name, 'Show A');
    expect(r.shows.single.publisher, 'Pub');
    expect(r.shows.single.id, 'showA00000000000000001');
    final ep = r.episodes.single;
    expect(ep.name, 'Ep A');
    expect(ep.description, 'hi & bye');
    expect(ep.durationMs, 123000);
    expect(ep.showName, 'Show A');
    expect(ep.showUri, 'spotify:show:showA00000000000000001');
    // 映射为播放层曲目：保留单集 URI，「专辑 / 艺人」指向节目
    final track = ep.toTrack();
    expect(track.uri, 'spotify:episode:episodeA00000000000001');
    expect(track.album!.uri, 'spotify:show:showA00000000000000001');
    expect(track.artists.single.uri, 'spotify:show:showA00000000000000001');
  });

  test('分享单集 / 节目使用正确的链接', () {
    final ep = ShareTarget.track(_episodeA.toTrack());
    expect(ep.kind, ShareKind.episode);
    expect(ep.webUrl, 'https://open.spotify.com/episode/episodeA00000000000001');
    const show = PodcastShow(id: 'showA00000000000000001', uri: 'spotify:show:showA00000000000000001', name: 'S');
    expect(ShareTarget.show(show).uri, 'spotify:show:showA00000000000000001');
    expect(ShareTarget.track(SampleCatalog.track1).kind, ShareKind.track);
  });

  test('单集不查歌词（官方与 LRCLIB 都不请求）', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await StorageService.init();
    var calls = 0;
    final spotify = SpotifyProvider(
      SpotifyApiService(storage, MockClient((_) async => http.Response('{}', 200))),
      storage,
      lyrics: LyricsResolver((_) async {
        calls++;
        return const SpotifyLyrics(lines: []);
      }),
    );
    addTearDown(spotify.dispose);

    final q = LyricsQuery.fromTrack(_episodeA.toTrack());
    expect(q.isEpisode, isTrue);
    expect((await spotify.fetchLyrics(q)).lines, isEmpty);
    expect(calls, 0);

    expect(LyricsQuery.fromTrack(SampleCatalog.track1).isEpisode, isFalse);
    await spotify.fetchLyrics(LyricsQuery.fromTrack(SampleCatalog.track1));
    expect(calls, 1);
  });

  test('PodcastShow JSON 往返', () {
    const show = PodcastShow(id: 'x', uri: 'spotify:show:x', name: 'N', publisher: 'P');
    final back = PodcastShow.fromJson(show.toJson());
    expect(back.uri, show.uri);
    expect(back.name, 'N');
    expect(back.publisher, 'P');
  });
}
