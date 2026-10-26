import 'package:kazumi/services/video_source/video_source_format.dart';

class PlaybackInitParams {
  final String videoUrl;
  final int offset;
  final bool isLocalPlayback;
  final VideoSourceFormat videoSourceFormat;
  final int bangumiId;
  final String pluginName;
  final int episode;
  final int danmakuEpisodeNumber;
  final String pageUrl;

  /// Parsed title number online, downloaded episode number offline.
  final int? sortNumber;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final String episodeTitle;
  final String referer;
  final int currentRoad;
  final String? coverUrl;
  final String? bangumiName;

  const PlaybackInitParams({
    required this.videoUrl,
    required this.offset,
    required this.isLocalPlayback,
    required this.bangumiId,
    required this.pluginName,
    required this.episode,
    required this.danmakuEpisodeNumber,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episodeTitle,
    required this.referer,
    required this.currentRoad,
    this.videoSourceFormat = VideoSourceFormat.auto,
    this.pageUrl = '',
    this.sortNumber,
    this.coverUrl,
    this.bangumiName,
  });

  /// 仅替换起播位置（秒）的副本，其余字段保持不变。
  ///
  /// AR 眼镜投屏结束后用它按当前进度重建同一条播放。
  PlaybackInitParams copyWithOffset(int offset) {
    return PlaybackInitParams(
      videoUrl: videoUrl,
      offset: offset,
      isLocalPlayback: isLocalPlayback,
      videoSourceFormat: videoSourceFormat,
      bangumiId: bangumiId,
      pluginName: pluginName,
      episode: episode,
      danmakuEpisodeNumber: danmakuEpisodeNumber,
      pageUrl: pageUrl,
      sortNumber: sortNumber,
      httpHeaders: httpHeaders,
      adBlockerEnabled: adBlockerEnabled,
      episodeTitle: episodeTitle,
      referer: referer,
      currentRoad: currentRoad,
      coverUrl: coverUrl,
      bangumiName: bangumiName,
    );
  }
}

class SyncPlayChatMessage {
  final String username;
  final String message;
  final bool fromRemote;
  final DateTime time;

  SyncPlayChatMessage({
    required this.username,
    required this.message,
    this.fromRemote = true,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}
