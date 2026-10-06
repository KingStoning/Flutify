import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'access_point.dart';
import 'audio_cache_store.dart';
import 'audio_normalization.dart';
import 'decrypt/decrypt_backend.dart';
import 'episode_metadata.dart';
import 'extended_metadata.dart';
import 'progressive_download.dart';
import 'spotify_id.dart';
import 'storage_resolver.dart';
import 'track_metadata.dart';
import 'track_playback_exception.dart';
import '../audio/audio_engine.dart';

export 'audio_normalization.dart';
export 'decrypt/decrypt_backend.dart'
    show DecryptBackend, InlineDecryptBackend, IsolateDecryptBackend;
export 'progressive_download.dart' show ProgressiveAudio;
export 'track_playback_exception.dart';

/// 音频解密 IV（协议固定常量，对应 librespot `audio/src/decrypt.rs` 的 AUDIO_AESIV）。
final Uint8List kAudioAesIv = Uint8List.fromList([
  0x72,
  0xe0,
  0x67,
  0xfb,
  0xdd,
  0xcb,
  0xcf,
  0x77,
  0xeb,
  0xe8,
  0xbc,
  0x64,
  0x3f,
  0x63,
  0x0d,
  0x93,
]);

/// 一首「完整版全曲」的音频（已解密，可直接交给播放器）。
///
/// [stream] 为空时 [file] 是已落盘的缓存文件；非空时曲目仍在下载，应按流播放，
/// 下载完成后才会写入 [file]。
class LoadedAudio {
  final File file;
  final TrackAudioFile source;
  final int? durationMs;
  final String trackId;

  /// 文件自带的响度数据（音量均衡用）；MP3 / 旧缓存没有时为 null。
  final AudioNormalization? normalization;

  /// 边下边播的音频流（[TrackAudioSource.open] 未命中缓存时）。
  final ProgressiveAudio? stream;

  /// DRM 曲目的 EME 内容；非空时由 EME 引擎播放（[file] 是加密 fMP4，just_audio 不解）。
  final EmeTrackContent? emeContent;

  const LoadedAudio({
    required this.file,
    required this.source,
    required this.durationMs,
    required this.trackId,
    this.normalization,
    this.stream,
    this.emeContent,
  });

  String get path => file.path;
}

typedef AccessTokenGetter = Future<String> Function();

/// 曲目音频来源抽象：PlaybackProvider 只依赖它，测试可用替身实现（不必真的联网）。
abstract class TrackAudioSource {
  /// 取得一首曲目的本地可播放文件（等整首下载完）；失败抛 [TrackPlaybackException]。
  Future<LoadedAudio> load(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  });

  /// 尽快取得可播放的音频：已缓存时与 [load] 相同；否则文件头一到就返回边下边播的
  /// [LoadedAudio.stream]。失败抛 [TrackPlaybackException]。
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  });

  /// 预取（失败静默，不影响当前播放）。
  Future<void> prefetch(String trackIdOrUri);
}

/// 一次加载会话：要么命中缓存（[cached]），要么正在下载（[download]，完成后写入 [destination]）。
class _AudioSession {
  final SpotifyId id;
  final TrackAudioFile file;
  final int? durationMs;
  final LoadedAudio? cached;
  final ProgressiveDownload? download;
  final File destination;

  /// 下载完成并落盘后的结果（仅 [download] 非空时）。
  Future<LoadedAudio>? persisted;

  _AudioSession.cached(LoadedAudio audio, this.id)
    : file = audio.source,
      durationMs = audio.durationMs,
      cached = audio,
      download = null,
      destination = audio.file;

  _AudioSession.downloading({
    required this.id,
    required this.file,
    required this.durationMs,
    required ProgressiveDownload this.download,
    required this.destination,
  }) : cached = null;
}

/// 完整曲目音频加载器：metadata → storage-resolve → AP 音频密钥 → CDN 下载解密。
///
/// 全程只走逆向协议（不依赖官方客户端/Web 播放器）。产物缓存在 [cacheDirectory]/audio，
/// 同一 file_id 的曲目直接复用；下载在内存中完成，结束后才写入缓存，不会留下半截文件。
/// 同一曲目的并发请求（预取 + 用户点播）共享一次下载：点播时若预取还没下完，
/// 直接边下边播这份下载。缓存总量超过 [maxCacheBytes] 时淘汰最旧文件。
class TrackAudioLoader implements TrackAudioSource, AudioCacheStore {
  final AccessTokenGetter accessToken;
  final AccessTokenGetter? clientToken;
  final String _cacheDirectory;
  final String Function()? cacheDirectoryProvider;
  String get cacheDirectory =>
      cacheDirectoryProvider?.call() ?? _cacheDirectory;
  final http.Client _client;
  final List<AudioFileFormat> formatPreference;
  final String? deviceId;

  /// 解密执行位置：App 中为常驻后台 Isolate（不占 UI 线程），默认在当前线程（探针脚本 / 测试）。
  final DecryptBackend decryptBackend;

  int _maxCacheBytes;

  /// 最近加载的两个文件（正在播放的 + 预取的下一首）：清缓存 / 淘汰时保留。
  final List<String> _recentPaths = [];

  bool _isProtected(File f) => _recentPaths.contains(f.path);

  Future<SpotifyAccessPoint>? _apSession;

  /// 进行中的加载会话（按曲目 id 合并）；下载完成并落盘后移除。
  final Map<String, Future<_AudioSession>> _inFlight = {};

  TrackAudioLoader({
    required this.accessToken,
    this.clientToken,
    required String cacheDirectory,
    this.cacheDirectoryProvider,
    this.formatPreference = kPlayableFormatPreference,
    this.deviceId,
    this.decryptBackend = const InlineDecryptBackend(),
    this._maxCacheBytes = 512 * 1024 * 1024,
    http.Client? client,
  }) : _cacheDirectory = cacheDirectory,
       _client = client ?? http.Client();

  // ---------------------------------------------------------------------------
  // 缓存管理（AudioCacheStore）
  // ---------------------------------------------------------------------------

  Directory get _audioDir =>
      Directory('$cacheDirectory${Platform.pathSeparator}audio');

  /// 音频缓存目录的容量上限（字节）。
  @override
  int get maxCacheBytes => _maxCacheBytes;

  @override
  set maxCacheBytes(int value) {
    _maxCacheBytes = value;
    _trimCache();
  }

  /// 缓存里的音频文件（不含下载中的 .part 与响度旁路文件）。
  List<File> _audioFiles() {
    final dir = _audioDir;
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              !f.path.endsWith('.part') &&
              !f.path.endsWith('.${AudioNormalization.sidecarExtension}'),
        )
        .toList();
  }

  /// 删除音频文件及其响度旁路文件；返回释放的字节数（删除失败为 0）。
  static int _deleteAudio(File file) {
    try {
      final size = file.lengthSync();
      file.deleteSync();
      final sidecar = AudioNormalization.sidecarFor(file);
      if (sidecar.existsSync()) sidecar.deleteSync();
      return size;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<int> sizeBytes() async {
    try {
      final dir = _audioDir;
      if (!dir.existsSync()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<int> clear() async {
    var freed = 0;
    try {
      for (final f in _audioFiles()) {
        if (_isProtected(f)) continue;
        freed += _deleteAudio(f);
      }
    } catch (_) {}
    return freed;
  }

  Future<Map<String, String>> _headers() async {
    final token = await accessToken();
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/x-protobuf',
    };
    if (clientToken != null) {
      headers['client-token'] = await clientToken!();
    }
    return headers;
  }

  /// 加载一首完整曲目（base62 id 或 `spotify:track:` URI），等整首下载完，返回本地已解密文件。
  ///
  /// [progress] 回调 0.0~1.0（下载/解密进度）。已缓存时立即返回。
  @override
  Future<LoadedAudio> load(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) async {
    final session = await _session(trackIdOrUri);
    final cached = session.cached;
    if (cached != null) {
      progress?.call(1.0);
      return cached;
    }
    if (progress != null) session.download!.addProgressListener(progress);
    return session.persisted!;
  }

  /// 边下边播：已缓存时返回本地文件；否则文件头一到就返回 [LoadedAudio.stream]，
  /// 下载在后台继续并在完成后写入缓存。
  @override
  Future<LoadedAudio> open(
    String trackIdOrUri, {
    void Function(double progress)? progress,
  }) async {
    final session = await _session(trackIdOrUri);
    final cached = session.cached;
    if (cached != null) {
      progress?.call(1.0);
      return cached;
    }
    final download = session.download!;
    if (progress != null) download.addProgressListener(progress);
    try {
      await download.ready;
    } on UnrecognizedAudioException catch (e) {
      throw TrackPlaybackException(
        TrackPlaybackFailure.unavailable,
        '这集播客的音频受加密保护，暂不支持播放',
        e,
      );
    } catch (e) {
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '音频下载失败，请检查网络后重试',
        e,
      );
    }
    _protect(session.destination);
    return LoadedAudio(
      file: session.destination,
      source: session.file,
      durationMs: session.durationMs,
      trackId: session.id.toBase62(),
      normalization: download.normalization,
      stream: download,
    );
  }

  /// 取得（或复用进行中的）加载会话。会话在下载落盘后移出 [_inFlight]，之后再请求直接命中缓存。
  Future<_AudioSession> _session(String trackIdOrUri) {
    final SpotifyId id;
    try {
      id = SpotifyId.fromUri(trackIdOrUri);
    } on FormatException {
      return Future.error(
        const TrackPlaybackException(
          TrackPlaybackFailure.unavailable,
          '这首歌不是 Spotify 曲目，无法播放',
        ),
      );
    }
    // 单集与曲目共用缓存键：前缀区分，避免同 base62 的不同类型互相命中
    final isEpisode = trackIdOrUri.contains(':episode:');
    final key = '${isEpisode ? 'episode' : 'track'}:${id.toBase62()}';
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _startSession(id, isEpisode: isEpisode);
    _inFlight[key] = future;
    void release() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }

    future.then((session) {
      final persisted = session.persisted;
      if (persisted == null) {
        release();
      } else {
        persisted
            .then<void>((_) {}, onError: (Object _) {})
            .whenComplete(release);
      }
    }, onError: (Object _) => release());
    return future;
  }

  Future<_AudioSession> _startSession(
    SpotifyId id, {
    bool isEpisode = false,
  }) async {
    // 1) metadata：取各格式 file_id（曲目走 extended-metadata；单集走 AP 上的 mercury hm://metadata/4/episode）
    final List<({TrackAudioFile file, Uint8List gid})> candidates;
    final bool hasAnyFile;
    final int? durationMs;
    var externalUrl = '';
    if (isEpisode) {
      _episodeLog('开始加载 ${id.toBase62()}');
      final EpisodeMetadata meta;
      try {
        meta = await fetchEpisodeMetadata(id);
      } on TrackPlaybackException catch (e) {
        _episodeLog('元数据失败：${e.message}（${e.cause}）');
        rethrow;
      } catch (e) {
        _episodeLog('元数据失败：$e');
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '获取单集信息失败，请检查网络',
          e,
        );
      }
      candidates = meta.candidateFiles(formatPreference);
      hasAnyFile = meta.hasAnyFile;
      durationMs = meta.durationMs > 0 ? meta.durationMs : null;
      externalUrl = meta.externalUrl;
      _episodeLog(
        '${id.toBase62()} 元数据：文件 [${meta.files.map((f) => f.format.name).join(', ')}]，'
        '可用 ${candidates.length} 个，外部地址 ${_hostOf(externalUrl)}',
      );
    } else {
      final TrackMetadata meta;
      try {
        meta = await fetchTrackMetadata(id);
      } on TrackPlaybackException {
        rethrow;
      } catch (e) {
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '获取曲目信息失败，请检查网络',
          e,
        );
      }
      candidates = meta.candidateFiles(formatPreference);
      hasAnyFile = meta.hasAnyFile;
      durationMs = meta.durationMs > 0 ? meta.durationMs : null;
    }
    if (candidates.isEmpty) {
      // 非 Spotify 托管的单集：只有外部 RSS 音频地址
      if (externalUrl.isNotEmpty) {
        _episodeLog('没有可用的 Spotify 文件，改用外部地址');
        return _externalSession(id, externalUrl, durationMs);
      }
      // 有音频文件但都不是 OGG/MP3（FLAC / AAC 走 Widevine DRM，AP 不下发密钥）
      throw TrackPlaybackException(
        TrackPlaybackFailure.unavailable,
        hasAnyFile
            ? (isEpisode ? '这集播客仅提供 DRM 加密格式，暂不支持播放' : '这首歌仅提供 DRM 加密格式，暂不支持播放')
            : (isEpisode ? '这集播客在你所在的地区或账号下暂不可播放' : '这首歌在你所在的地区或账号下暂不可播放'),
      );
    }

    // 2) 缓存命中：任一候选格式已落盘即直接使用
    for (final c in candidates) {
      final cached = _cacheFile(c.file);
      if (cached.existsSync() && cached.lengthSync() > 0) {
        // 更新修改时间：淘汰按「最久未用」而不是「最早下载」
        try {
          cached.setLastModifiedSync(DateTime.now());
        } catch (_) {}
        return _AudioSession.cached(
          _loaded(cached, c.file, durationMs, id),
          id,
        );
      }
    }

    // 3) 音频密钥（AP 协议）：按音质逐档尝试，被拒（如免费账号请求 320k）则降一档
    final SpotifyAccessPoint ap;
    try {
      ap = await _ensureAccessPoint();
    } on ApLoginException catch (e) {
      _disposeAccessPoint();
      throw TrackPlaybackException(
        TrackPlaybackFailure.notSignedIn,
        '播放服务登录失败：${e.message}',
        e,
      );
    } catch (e) {
      _disposeAccessPoint();
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '无法连接 Spotify 播放服务，请检查网络',
        e,
      );
    }
    TrackAudioFile? file;
    Uint8List? key;
    Object? keyError;
    for (final c in candidates) {
      try {
        key = await ap.requestAudioKey(c.file.fileId, c.gid);
        file = c.file;
        break;
      } on ApKeyException catch (e) {
        keyError = e;
        if (isEpisode) _episodeLog('密钥被拒（${c.file.format.name}）：$e');
      } catch (e) {
        if (isEpisode) _episodeLog('请求密钥失败：$e');
        _disposeAccessPoint();
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '获取音频密钥超时，请稍后重试',
          e,
        );
      }
    }
    final DecryptSpec decrypt;
    var plain = false;
    if (file != null && key != null) {
      decrypt = AesCtrDecryptSpec(key: key, iv: kAudioAesIv);
      if (isEpisode) _episodeLog('拿到密钥（${file.format.name}），按加密文件下载');
    } else if (isEpisode) {
      _episodeLog('没有密钥，按明文下载 ${candidates.first.file.format.name}');
      // 单集拿不到密钥是常态：与 librespot 一致按明文下载（多数单集文件未加密），
      // 文件头不像音频时判定为加密文件，再回退外部地址
      file = candidates.first.file;
      decrypt = const PassthroughDecryptSpec();
      plain = true;
    } else {
      throw TrackPlaybackException(
        TrackPlaybackFailure.unavailable,
        '这首歌暂时无法播放（可能需要 Premium 或受版权限制）',
        keyError,
      );
    }

    // 4) CDN 解析，随后在后台下载 + 流式解密（边下边播由 open 读取同一份下载）
    final List<String> cdnUrls;
    try {
      cdnUrls = (await resolveAudioStorage(
        fileIdHex: file.fileIdHex,
        headers: _headers,
        client: _client,
      )).cdnUrls;
    } catch (e) {
      if (isEpisode) _episodeLog('CDN 地址解析失败：$e');
      if (plain && externalUrl.isNotEmpty) {
        return _externalSession(id, externalUrl, durationMs);
      }
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '音频下载失败，请检查网络后重试',
        e,
      );
    }
    final download = ProgressiveDownload(
      urls: cdnUrls,
      decrypt: decrypt,
      backend: decryptBackend,
      format: file.format,
      client: _client,
      validateHead: plain ? SpotifyAudioHeader.looksLikePlainAudio : null,
    )..start();
    final session = _downloadSession(id, file, durationMs, download);
    if (plain) {
      // 等文件头到达再交出会话：确认是明文才能播放 / 落盘
      try {
        await download.ready;
        _episodeLog('文件头校验通过，开始播放');
      } on UnrecognizedAudioException {
        _episodeLog('文件头不是明文音频（文件是加密的）');
        if (externalUrl.isNotEmpty) {
          _episodeLog('改用外部地址');
          return _externalSession(id, externalUrl, durationMs);
        }
        throw const TrackPlaybackException(
          TrackPlaybackFailure.unavailable,
          '这集播客的音频受加密保护，暂不支持播放',
        );
      } catch (e) {
        // 网络类失败交给 open / load 统一报告
        _episodeLog('下载失败：$e');
      }
    }
    return session;
  }

  /// 外部托管的单集音频（RSS 原始地址，明文）：按地址的 SHA-1 作缓存键，下载方式与 CDN 相同。
  Future<_AudioSession> _externalSession(
    SpotifyId id,
    String url,
    int? durationMs,
  ) async {
    final file = TrackAudioFile(
      fileId: Uint8List.fromList(sha1.convert(utf8.encode(url)).bytes),
      format: externalAudioFormat(url),
    );
    final cached = _cacheFile(file);
    if (cached.existsSync() && cached.lengthSync() > 0) {
      try {
        cached.setLastModifiedSync(DateTime.now());
      } catch (_) {}
      return _AudioSession.cached(_loaded(cached, file, durationMs, id), id);
    }
    final download = ProgressiveDownload(
      urls: [url],
      decrypt: const PassthroughDecryptSpec(),
      backend: decryptBackend,
      format: file.format,
      client: _client,
      validateHead: SpotifyAudioHeader.looksLikePlainAudio,
    )..start();
    final session = _downloadSession(id, file, durationMs, download);
    try {
      await download.ready;
      _episodeLog('外部地址 ${_hostOf(url)} 下载正常，开始播放');
    } on UnrecognizedAudioException {
      _episodeLog('外部地址 ${_hostOf(url)} 返回的不是音频');
      throw const TrackPlaybackException(
        TrackPlaybackFailure.unavailable,
        '这集播客的音频格式无法识别，暂不支持播放',
      );
    } catch (_) {
      // 网络类失败交给 open / load 统一报告
    }
    return session;
  }

  /// 单集链路诊断日志（App 日志里以 [episode] 开头；外部地址只记域名，可能带订阅参数）。
  static void _episodeLog(String message) => debugPrint('[episode] $message');

  static String _hostOf(String url) =>
      url.isEmpty ? '(无)' : (Uri.tryParse(url)?.host ?? '(无法解析)');

  /// 外部音频地址 → 文件格式（只决定缓存扩展名与 MIME；未知按 MP3）。
  static AudioFileFormat externalAudioFormat(String url) {
    final path = (Uri.tryParse(url)?.path ?? '').toLowerCase();
    if (path.endsWith('.m4a') || path.endsWith('.mp4') || path.endsWith('.aac')) {
      return AudioFileFormat.aac48;
    }
    if (path.endsWith('.ogg') || path.endsWith('.oga') || path.endsWith('.opus')) {
      return AudioFileFormat.oggVorbis160;
    }
    return AudioFileFormat.mp3_160;
  }

  /// 正在下载的会话：下载完成后落盘并淘汰旧缓存。
  _AudioSession _downloadSession(
    SpotifyId id,
    TrackAudioFile file,
    int? durationMs,
    ProgressiveDownload download,
  ) {
    final destination = _cacheFile(file);
    final session = _AudioSession.downloading(
      id: id,
      file: file,
      durationMs: durationMs,
      download: download,
      destination: destination,
    );
    session.persisted = () async {
      try {
        await download.done;
        await _persist(download, destination);
      } on UnrecognizedAudioException {
        throw const TrackPlaybackException(
          TrackPlaybackFailure.unavailable,
          '这集播客的音频受加密保护，暂不支持播放',
        );
      } catch (e) {
        throw TrackPlaybackException(
          TrackPlaybackFailure.network,
          '音频下载失败，请检查网络后重试',
          e,
        );
      }
      final result = _loaded(destination, file, durationMs, id);
      _trimCache();
      return result;
    }();
    session.persisted!.ignore(); // 只预取 / 只边下边播时没人等它，失败不应成为未捕获异常
    return session;
  }

  /// 标记为最近使用（正在播放 + 预取的下一首），清缓存 / 淘汰时跳过。
  void _protect(File file) {
    _recentPaths
      ..remove(file.path)
      ..add(file.path);
    if (_recentPaths.length > 2) _recentPaths.removeAt(0);
  }

  LoadedAudio _loaded(
    File cached,
    TrackAudioFile source,
    int? durationMs,
    SpotifyId id,
  ) {
    _protect(cached);
    return LoadedAudio(
      file: cached,
      source: source,
      durationMs: durationMs,
      trackId: id.toBase62(),
      normalization: AudioNormalization.readSidecar(cached),
    );
  }

  /// 落盘：写入已去掉 Spotify 私有头的音频（规则见 [SpotifyAudioHeader]），先写 `.part` 再改名，
  /// 中途失败不会留下半截缓存。私有头里的响度数据另存为 `.norm` 旁路文件。
  static Future<void> _persist(
    ProgressiveDownload download,
    File destination,
  ) async {
    await destination.parent.create(recursive: true);
    final tmp = File('${destination.path}.part');
    try {
      await tmp.writeAsBytes(download.playableBytes, flush: true);
      if (destination.existsSync())
        destination.deleteSync(); // Windows 上 rename 不覆盖已有文件
      await tmp.rename(destination.path);
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
    final loudness = download.normalizationBytes;
    if (loudness != null) {
      try {
        AudioNormalization.sidecarFor(destination).writeAsBytesSync(loudness);
      } catch (_) {}
    }
  }

  /// 缓存淘汰：音频总量超过 [maxCacheBytes] 时，按修改时间（最近一次使用）从旧到新删除，
  /// 最近加载的两首（正在播放 + 预取）保留。
  void _trimCache() {
    try {
      final files = _audioFiles();
      var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
      if (total <= _maxCacheBytes) return;
      files.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );
      for (final f in files) {
        if (total <= _maxCacheBytes) break;
        if (_isProtected(f)) continue;
        total -= _deleteAudio(f);
      }
    } catch (_) {
      // 淘汰失败（文件被占用等）不影响播放
    }
  }

  /// 预取（失败静默，不影响播放流程）。
  @override
  Future<void> prefetch(String trackIdOrUri) async {
    try {
      await load(trackIdOrUri);
    } catch (_) {}
  }

  /// 拉取曲目 metadata。
  ///
  /// 优先 extended-metadata `TRACK_V4`（现网唯一稳定带 file 列表的来源）；
  /// 该扩展缺失时回退 `metadata/4/track/{gid}`（旧接口，新版客户端身份下常不含 file）。
  Future<TrackMetadata> fetchTrackMetadata(SpotifyId id) async {
    try {
      final payload = await ExtendedMetadataClient(
        _client,
        headers: _headers,
      ).fetch('spotify:track:${id.toBase62()}', ExtensionKind.trackV4);
      if (payload != null) {
        final meta = TrackMetadata.parse(payload);
        if (meta.files.isNotEmpty || meta.alternatives.isNotEmpty) return meta;
      }
    } on ExtendedMetadataHttpException catch (e) {
      if (e.statusCode == 401) {
        throw const TrackPlaybackException(
          TrackPlaybackFailure.notSignedIn,
          '登录已失效，请重新登录后再播放',
        );
      }
    }

    final res = await _client.get(
      Uri.parse(
        'https://spclient.wg.spotify.com/metadata/4/track/${id.toBase16()}',
      ),
      headers: await _headers(),
    );
    switch (res.statusCode) {
      case 200:
        return TrackMetadata.parse(res.bodyBytes);
      case 401:
        throw const TrackPlaybackException(
          TrackPlaybackFailure.notSignedIn,
          '登录已失效，请重新登录后再播放',
        );
      case 404:
        throw const TrackPlaybackException(
          TrackPlaybackFailure.unavailable,
          '找不到这首歌的音频',
        );
      default:
        throw StateError('metadata 请求失败：HTTP ${res.statusCode}');
    }
  }

  /// 拉取单集 metadata：AP 加密通道上的 Mercury `hm://metadata/4/episode/{gid}`。
  ///
  /// 单集没有 HTTPS 元数据入口（spclient metadata/4/episode 已 404、extended-metadata
  /// EPISODE_V4 对该身份返回 400），Mercury 是唯一可用来源（tool/mercury_probe.dart 验证）。
  Future<EpisodeMetadata> fetchEpisodeMetadata(SpotifyId id) async {
    final SpotifyAccessPoint ap;
    try {
      ap = await _ensureAccessPoint();
    } on ApLoginException catch (e) {
      _disposeAccessPoint();
      throw TrackPlaybackException(
        TrackPlaybackFailure.notSignedIn,
        '播放服务登录失败：${e.message}',
        e,
      );
    } catch (e) {
      _disposeAccessPoint();
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '无法连接 Spotify 播放服务，请检查网络',
        e,
      );
    }
    try {
      final body = await ap.requestMercury(
        'hm://metadata/4/episode/${id.toBase16()}',
      );
      return EpisodeMetadata.parse(body);
    } on ApMercuryException catch (e) {
      if (e.statusCode == 404) {
        throw TrackPlaybackException(
          TrackPlaybackFailure.unavailable,
          '找不到这集播客的音频',
          e,
        );
      }
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '获取单集信息失败，请检查网络',
        e,
      );
    } on TimeoutException catch (e) {
      throw TrackPlaybackException(
        TrackPlaybackFailure.network,
        '获取单集信息超时，请稍后重试',
        e,
      );
    }
  }

  /// 复用 AP 会话（登录失效时重建一次）。
  Future<SpotifyAccessPoint> _ensureAccessPoint() async {
    Future<SpotifyAccessPoint> create() async {
      final ap = await SpotifyAccessPoint.connect(client: _client);
      await ap.authenticate(
        ApCredentials.accessToken(await accessToken()),
        deviceId: deviceId,
      );
      return ap;
    }

    try {
      final existing = await (_apSession ??= create());
      if (!existing.isClosed) return existing;
      _apSession = null;
      return await (_apSession = create());
    } catch (_) {
      _disposeAccessPoint();
      final ap = await create();
      _apSession = Future.value(ap);
      return ap;
    }
  }

  void _disposeAccessPoint() {
    final session = _apSession;
    _apSession = null;
    session?.then((ap) => ap.close()).catchError((_) {});
  }

  File _cacheFile(TrackAudioFile file) => File(
    '$cacheDirectory${Platform.pathSeparator}audio${Platform.pathSeparator}'
    '${file.fileIdHex}.${file.extension}',
  );

  /// 释放资源（AP 会话与 HTTP 客户端）。
  void dispose() {
    _disposeAccessPoint();
    _client.close();
  }
}
