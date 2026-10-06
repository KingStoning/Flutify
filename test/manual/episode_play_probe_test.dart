// 单集播放链路实测（手动运行，CI 中自动跳过）：用本机 App 已保存的登录态，
// 走一遍与 App 完全相同的单集加载流程。不会登录、不会修改账号。
//
// 用法（Windows PowerShell，先在 App 里登录一次）：
//   $env:FLUTIFY_PROBE = "https://open.spotify.com/show/xxxx"   # 或单集链接 / id
//   flutter test test/manual/episode_play_probe_test.dart
//   传节目时依次试该节目页上的前 3 集。
// 可选：$env:FLUTIFY_PREFS = "<shared_preferences.json 路径>"
//   （默认依次找 %APPDATA%\Flutify\Flutify\ 与 %APPDATA%\com.flutify.music\flutify_app\ 下的 shared_preferences.json）
// 登录令牌约一小时过期：运行前先打开 App 并播放一首歌，让 App 刷新令牌。
//
// 输出不含任何令牌，可以直接贴给开发者：
//   - Mercury 元数据：音频文件格式列表、external_url 的域名；
//   - 实际加载结果：成功（文件格式 / 大小 / 文件头）或失败原因。
import 'dart:convert';
import 'dart:io';

import 'package:flutify_app/services/podcast/podcast_service.dart';
import 'package:flutify_app/services/protocol/spotify_id.dart';
import 'package:flutify_app/services/protocol/track_audio_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final input = Platform.environment['FLUTIFY_PROBE'] ?? '';
  test(
    '单集播放链路实测',
    () => _probe(input, Platform.environment['FLUTIFY_PREFS']),
    skip: input.isEmpty ? '设置 FLUTIFY_PROBE 后手动运行' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _probe(String input, String? prefsPath) async {
  final id = RegExp(r'([0-9A-Za-z]{22})').firstMatch(input)?.group(1);
  if (id == null) {
    fail('无法解析 id：$input');
  }

  // 发布版（安装包 / 便携版）存在 %APPDATA%\\Flutify\\Flutify；旧的开发构建存在 com.flutify.music\\flutify_app
  final appData = Platform.environment['APPDATA'] ?? '';
  prefsPath ??= [
    '$appData\\Flutify\\Flutify\\shared_preferences.json',
    '$appData\\com.flutify.music\\flutify_app\\shared_preferences.json',
  ].firstWhere((path) => File(path).existsSync(), orElse: () => '');
  if (prefsPath.isEmpty) fail('没有找到 App 的设置文件：请先在 App 里登录（或用 FLUTIFY_PREFS 指定）');
  stdout.writeln('登录态来自：$prefsPath');
  final prefs = jsonDecode(File(prefsPath).readAsStringSync()) as Map<String, dynamic>;
  final token = prefs['flutter.sp_access_token'] as String? ?? '';
  final clientToken = prefs['flutter.sp_client_token'] as String? ?? '';
  final deviceId = prefs['flutter.sp_device_id'] as String? ?? '';
  if (token.isEmpty) {
    fail('没有找到登录态：请先在 App 里登录（或用 FLUTIFY_PREFS 指定文件）');
  }

  // 节目：取节目页的前 3 集
  var episodeIds = [id];
  if (input.contains('show')) {
    final show = await PodcastService().fetchShow(id);
    stdout.writeln('节目：${show.name}（${show.episodes.length} 集）');
    episodeIds = [for (final e in show.episodes.take(3)) e.id];
  }

  final cache = Directory.systemTemp.createTempSync('flutify_episode_probe_');
  final loader = TrackAudioLoader(
    accessToken: () async => token,
    clientToken: clientToken.isEmpty ? null : () async => clientToken,
    deviceId: deviceId.isEmpty ? null : deviceId,
    cacheDirectory: cache.path,
  );
  var ok = 0;
  try {
    for (final episodeId in episodeIds) {
      final uri = 'spotify:episode:$episodeId';
      stdout.writeln('\n=== $uri ===');
      try {
        final meta = await loader.fetchEpisodeMetadata(SpotifyId.fromUri(uri));
        stdout.writeln('标题：${meta.name}');
        stdout.writeln('音频文件：${meta.files.map((f) => f.format.name).join(', ')}');
        stdout.writeln('external_url：${meta.externalUrl.isEmpty ? '(无)' : _host(meta.externalUrl)}');
      } catch (e) {
        stdout.writeln('元数据失败：$e');
        continue;
      }
      final sw = Stopwatch()..start();
      try {
        final audio = await loader.load(uri, progress: (_) {});
        final bytes = audio.file.lengthSync();
        final head = audio.file.openSync()..setPositionSync(0);
        final magic = head.readSync(4);
        head.closeSync();
        stdout.writeln(
          '✅ 加载成功：${audio.source.format.name}，${(bytes / 1024 / 1024).toStringAsFixed(1)} MB，'
          '文件头 ${String.fromCharCodes(magic.map((b) => b >= 32 && b < 127 ? b : 46))}，'
          '用时 ${sw.elapsed.inSeconds}s',
        );
        ok++;
      } on TrackPlaybackException catch (e) {
        stdout.writeln('❌ 加载失败（${e.kind.name}）：${e.message}');
        if (e.cause != null) stdout.writeln('   原因：${e.cause}');
      }
    }
  } finally {
    loader.dispose();
    cache.deleteSync(recursive: true);
  }
  stdout.writeln('\n结果：${episodeIds.length} 集中 $ok 集可以播放');
  expect(ok, episodeIds.length, reason: '有单集加载失败，详见上面的输出');
}

/// 只显示外部地址的域名（地址里可能带订阅者参数）。
String _host(String url) => Uri.tryParse(url)?.host ?? '(无法解析)';
