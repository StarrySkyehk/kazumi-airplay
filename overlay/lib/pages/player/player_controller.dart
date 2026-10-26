import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/player/external_playback_launcher.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_seek_controller.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/player/controller/player_panel_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/player/controller/player_screenshot_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/utils/device.dart';

export 'package:kazumi/pages/player/controller/player_models.dart';

class PlayerController implements Disposable {
  PlayerController(
    this.shaderAssetService,
    DownloadController downloadController,
    this.audioController,
  ) {
    danmaku = PlayerDanmakuController(
      isLocalPlayback: () => isLocalPlayback,
      downloadController: downloadController,
    );
  }

  final ShaderAssetService shaderAssetService;
  final AudioController audioController;
  final AsyncSessionOwner _initializations = AsyncSessionOwner();
  Future<void>? _shutdownFuture;

  /// 最近一次 [init] 的入参。AR 眼镜投屏结束后用它重建同一路播放。
  PlaybackInitParams? _lastPlaybackInitParams;

  final PlayerPanelController panel = PlayerPanelController();
  final PlayerScreenshotController screenshots = PlayerScreenshotController();
  final PlayerDebugController debug = PlayerDebugController();

  late final PlayerDanmakuController danmaku;
  late final PlayerPlaybackController playback = PlayerPlaybackController(
    shaderAssetService: shaderAssetService,
    debug: debug,
    videoUrl: () => videoUrl,
    isLocalPlayback: () => isLocalPlayback,
  );
  late final PlayerSyncPlayController syncplay = PlayerSyncPlayController(
    bangumiId: () => bangumiId,
    currentEpisode: () => currentEpisode,
    currentRoad: () => currentRoad,
    playing: () => playback.playing,
    currentPosition: () => playback.currentPosition,
    playerPosition: () => playback.playerPosition,
    duration: () => playback.duration,
    pause: pause,
    play: play,
    seek: seek,
  );
  late final PlayerSeekController seeking = PlayerSeekController(
    playback: playback,
    danmaku: danmaku,
    pause: pause,
    play: play,
    onSeekCompleted: _onSeekCompleted,
  );
  late final ExternalPlaybackLauncher externalPlayback =
      ExternalPlaybackLauncher(
    videoUrl: () => videoUrl,
    referer: () => referer,
  );

  late int bangumiId;
  late int currentEpisode;
  late int currentDanmakuEpisodeNumber;
  late int currentRoad;
  late String referer;
  String? coverUrl;
  String videoUrl = '';
  bool isLocalPlayback = false;
  Map<String, String> httpHeaders = const <String, String>{};
  String episodeTitle = '';
  String bangumiName = '';

  /// 番剧名 + 剧集名，供 AR 眼镜遥控页展示。
  String get displayTitle {
    final episode = episodeTitle.trim();
    final bangumi = bangumiName.trim();
    if (bangumi.isEmpty) {
      return episode;
    }
    if (episode.isEmpty) {
      return bangumi;
    }
    return '$bangumi $episode';
  }

  Timer? hideVolumeUITimer;
  Timer? _volumeGestureSyncTimer;
  double? _pendingGestureVolume;

  bool muted = false;
  double _preMuteVolume = 100;

  Future<void> toggleMute() async {
    if (!muted && playback.volume > 0) {
      _preMuteVolume = playback.volume;
      muted = true;
      _persistMuteState();
      await setVolume(0);
    } else {
      muted = false;
      _persistMuteState();
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 100);
    }
  }

  void _persistMuteState() {
    if (!isDesktop()) {
      return;
    }
    unawaited(GStorage.putSetting<bool>(SettingsKeys.playerMuted, muted));
  }

  /// 在音量被主动调高（手势 / 按键 / 滚轮）时退出静音状态。
  void _clearMuteIfNeeded(double value) {
    if (muted && value > 0) {
      muted = false;
      _persistMuteState();
    }
  }

  void setVolumeDuringGesture(double value) {
    _pendingGestureVolume = value.clamp(0.0, 100.0);
    playback.updateVolume(_pendingGestureVolume!);
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = Timer(const Duration(milliseconds: 80), () {
      final vol = _pendingGestureVolume;
      if (vol == null) {
        return;
      }
      unawaited(playback.syncVolumeToDevice(vol));
    });
  }

  Future<void> finishVolumeGesture() async {
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = null;
    final vol = _pendingGestureVolume;
    _pendingGestureVolume = null;
    if (vol != null) {
      playback.volume = vol;
    }
    playback.invalidatePreciseVolume();
    await playback.syncVolumeToDevice(vol);
    final resolved = vol ?? playback.volume;
    _clearMuteIfNeeded(resolved);
    _persistDesktopVolume(resolved);
  }

  void _persistDesktopVolume(double value) {
    if (!isDesktop()) {
      return;
    }
    if (muted) {
      return;
    }
    final clamped = value.clamp(0.0, 100.0);
    final stored = GStorage.getSetting(SettingsKeys.defaultVolume);
    if (stored.round() == clamped.round()) {
      return;
    }
    unawaited(GStorage.putSetting<double>(SettingsKeys.defaultVolume, clamped));
  }

  Future<bool> init(PlaybackInitParams params) async {
    if (_initializations.isClosed) {
      return false;
    }
    _lastPlaybackInitParams = params;
    final initialization = _initializations.begin();

    videoUrl = params.videoUrl;
    isLocalPlayback = params.isLocalPlayback;
    bangumiId = params.bangumiId;
    currentEpisode = params.episode;
    currentDanmakuEpisodeNumber = params.danmakuEpisodeNumber;
    currentRoad = params.currentRoad;
    referer = params.referer;
    httpHeaders = params.httpHeaders;
    episodeTitle = params.episodeTitle;
    bangumiName = params.bangumiName ?? '';

    KazumiLogger().i(
        'PlayerController: ${params.isLocalPlayback ? "local" : "online"} playback, url: ${params.videoUrl}');

    playback.resetForInit();
    debug.playerLogLevel = GStorage.getSetting(SettingsKeys.playerLogLevel);
    playback.playerSpeed = GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    panel.aspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultAspectRatioType),
    );

    playback.buttonSkipTime = GStorage.getSetting(SettingsKeys.buttonSkipTime);
    playback.arrowKeySkipTime =
        GStorage.getSetting(SettingsKeys.arrowKeySkipTime);
    try {
      await _releasePlaybackResources();
    } catch (_) {}
    if (initialization.isStale) {
      return false;
    }

    final Player? player;
    try {
      player = await playback.createVideoController(
        params.httpHeaders,
        params.adBlockerEnabled,
        canInstall: () => initialization.isActive,
        offset: params.offset,
        videoSourceFormat: params.videoSourceFormat,
      );
    } catch (e) {
      if (initialization.isStale) {
        return false;
      }
      playback.loading = false;
      KazumiLogger()
          .e('PlayerController: failed to initialize video', error: e);
      return false;
    }
    if (player == null || !_ownsInitialization(initialization, player)) {
      return false;
    }

    if (isDesktop()) {
      final freshStart = playback.volume == -1;
      if (freshStart) {
        muted = GStorage.getSetting(SettingsKeys.playerMuted);
        final remembered = GStorage.getSetting(SettingsKeys.defaultVolume);
        _preMuteVolume = remembered > 0 ? remembered : 100;
        playback.volume = muted ? 0 : remembered;
      }
      await setVolume(playback.volume);
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }
    } else {
      await FlutterVolumeController.getVolume().then((value) {
        playback.volume = (value ?? 0.0) * 100;
      });
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }

      await FlutterVolumeController.updateShowSystemUI(false);
      if (!_ownsInitialization(initialization, player)) {
        await FlutterVolumeController.updateShowSystemUI(true);
        return false;
      }

      FlutterVolumeController.addListener((volume) {
        if (player == null || !_ownsInitialization(initialization, player)) {
          return;
        }
        if (panel.volumeSeeking) {
          return;
        }
        playback.applyExternalVolume(volume * 100);
        if (!Platform.isAndroid && !panel.volumeSeeking) {
          panel.showVolume = true;
          hideVolumeUITimer?.cancel();
          hideVolumeUITimer = Timer(const Duration(seconds: 1), () {
            panel.showVolume = false;
            hideVolumeUITimer = null;
          });
        }
      }, category: AudioSessionCategory.playback, emitOnStart: false);
      if (!_ownsInitialization(initialization, player)) {
        return false;
      }
    }
    await setPlaybackSpeed(playback.playerSpeed);
    if (!_ownsInitialization(initialization, player)) {
      return false;
    }
    KazumiLogger().i('PlayerController: video initialized');
    playback.loading = false;

    coverUrl = params.coverUrl;

    if (syncplay.syncplayController?.isConnected ?? false) {
      if (syncplay.syncplayController!.currentFileName !=
          "$bangumiId[$currentEpisode]") {
        setSyncPlayPlayingBangumi(
            forceSyncPlaying: true, forceSyncPosition: 0.0);
      }
    }
    return true;
  }

  bool _ownsInitialization(AsyncSession initialization, Player player) {
    return initialization.isActive && playback.isCurrentPlayer(player);
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    await playback.setShader(
      mode,
      player: player,
    );
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    await playback.setPlaybackSpeed(playerSpeed);
    try {
      updateDanmakuSpeed();
    } catch (_) {}
  }

  void updateDanmakuSpeed() {
    danmaku.updateDanmakuSpeed(playback.playerSpeed);
  }

  Future<void> setVolume(double value) async {
    await playback.setVolume(value);
    _clearMuteIfNeeded(value);
    _persistDesktopVolume(value);
  }

  void syncPlaybackState() {
    playback.syncPlaybackState();
  }

  Future<void> playOrPause() async {
    await playback.playOrPause(pause: pause, play: play);
  }

  Future<void> seek(Duration duration, {bool enableSync = true}) =>
      seeking.seekTo(duration, enableSync: enableSync);

  Future<void> seekBy(Duration offset, {bool enableSync = true}) =>
      seeking.seekBy(offset, enableSync: enableSync);

  Future<void> _onSeekCompleted(bool enableSync) async {
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync(doSeek: true);
      }
    }
  }

  Future<void> pause({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.pause();
    try {
      await player.pause();
    } catch (_) {
      return;
    }
    playback.playing = false;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  Future<void> play({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    danmaku.canvasController.resume();
    try {
      await player.play();
    } catch (_) {
      return;
    }
    playback.playing = true;
    if (syncplay.hasSession) {
      setSyncPlayCurrentPosition();
      if (enableSync) {
        await requestSyncPlaySync();
      }
    }
  }

  @override
  void dispose() {
    beginShutdown();
  }

  /// Starts the idempotent player shutdown without blocking route navigation.
  ///
  /// Native media and audio-session cleanup may finish after the route is
  /// removed. Immediate ownership detachment happens synchronously before this
  /// method returns.
  void beginShutdown() {
    _initializations.close();
    if (_shutdownFuture != null) {
      return;
    }
    screenshots.dispose();
    final shutdown = _shutdownResources();
    _shutdownFuture = shutdown;
    unawaited(
      shutdown.catchError((Object error, StackTrace stackTrace) {
        KazumiLogger().e(
          'PlayerController: failed to dispose asynchronously',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _shutdownResources() async {
    await Future.wait([
      _releasePlaybackResources(),
      syncplay.dispose(),
    ]);
  }

  Future<void> _releasePlaybackResources() async {
    hideVolumeUITimer?.cancel();
    _volumeGestureSyncTimer?.cancel();
    FlutterVolumeController.removeListener();
    await Future.wait([
      audioController.deactivate(),
      playback.stop(),
      _restoreSystemVolumeUi(),
    ]);
  }

  Future<void> _restoreSystemVolumeUi() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'PlayerController: failed to restore the system volume UI',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> stop() async {
    _initializations.cancel();
    await _releasePlaybackResources();
  }

  /// AR 眼镜投屏前释放手机端播放：与 [init] 复用同一条释放路径（停掉 mpv、
  /// 关闭网络/磁盘缓存、释放音频会话），但保留 controller 自身与 [_lastPlaybackInitParams]。
  ///
  /// 成功后 [PlayerPlaybackController.mediaPlayer] 为 null，AR 期间手机上不会
  /// 出现第二路解码/缓存。
  Future<bool> releasePlaybackForExternalDisplay() async {
    // 让仍在进行中的 init 失效，避免它在投屏期间重新装上一个 mpv 实例。
    _initializations.cancel();
    KazumiLogger().i('PlayerController: releasing playback for AR display');
    try {
      await _releasePlaybackResources();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerController: failed to release playback for AR display',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    final bool released = playback.mediaPlayer == null;
    KazumiLogger().i('PlayerController: AR display release done, released=$released');
    return released;
  }

  /// AR 眼镜投屏结束后重建播放。
  ///
  /// 用最后一次 [init] 的参数（offset 换成 [positionMs] 对应的秒数）重新初始化，
  /// 再 seek 到 [positionMs]，并按 [resumePlaying] 恢复播放/暂停。
  /// 失败时 toast 提示并返回 false。
  Future<bool> resumePlaybackAfterExternalDisplay({
    required int positionMs,
    required bool resumePlaying,
  }) async {
    final PlaybackInitParams? params = _lastPlaybackInitParams;
    if (params == null) {
      _showArResumeFailureToast();
      return false;
    }
    final int safePositionMs = positionMs < 0 ? 0 : positionMs;
    KazumiLogger().i(
      'PlayerController: resuming after AR display at ${safePositionMs}ms '
      '(mediaPlayer=${playback.mediaPlayer != null})',
    );
    // mpv 仍在（投屏前的后台释放还没完成/失败）：直接 seek 恢复，不再重建播放器。
    if (playback.mediaPlayer != null) {
      try {
        await seek(Duration(milliseconds: safePositionMs));
        if (resumePlaying) {
          await play();
        } else {
          await pause();
        }
        KazumiLogger().i('PlayerController: resumed existing player after AR');
        return true;
      } catch (error, stackTrace) {
        KazumiLogger().w(
          'PlayerController: failed to reuse existing player after AR display',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    final double previousSpeed = playback.playerSpeed;
    final bool initialized = await init(
      params.copyWithOffset((safePositionMs / 1000).round()),
    ).timeout(
      const Duration(seconds: 25),
      onTimeout: () {
        KazumiLogger().e('PlayerController: rebuild after AR timed out (25s)');
        return false;
      },
    );
    if (!initialized) {
      _showArResumeFailureToast();
      return false;
    }
    // init() 会把倍速重置为设置里的默认值，这里恢复用户退出前的倍速。
    if (previousSpeed > 0 && previousSpeed != playback.playerSpeed) {
      await setPlaybackSpeed(previousSpeed);
    }
    final Player? player = playback.mediaPlayer;
    if (player == null) {
      _showArResumeFailureToast();
      return false;
    }
    if (!resumePlaying) {
      // init() 会按设置自动起播，先停住，避免退出投屏后突然出声。
      await pause();
    }
    final Duration target = Duration(milliseconds: safePositionMs);
    try {
      await player.seek(target);
      playback.currentPosition = target;
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'PlayerController: failed to restore position after AR display',
        error: error,
        stackTrace: stackTrace,
      );
      KazumiDialog.showToast(message: '恢复播放进度失败，将从头继续播放');
    }
    if (resumePlaying) {
      await play();
    }
    return true;
  }

  void _showArResumeFailureToast() {
    KazumiDialog.showToast(message: 'AR 投屏结束后恢复播放失败，请重新打开该视频');
  }

  Future<Uint8List?> screenshotPng() => playback.screenshotPng();

  void setButtonForwardTime(int time) {
    playback.buttonSkipTime = time;
    GStorage.putSetting(SettingsKeys.buttonSkipTime, time);
  }

  void setArrowKeyForwardTime(int time) {
    playback.arrowKeySkipTime = time;
    GStorage.putSetting(SettingsKeys.arrowKeySkipTime, time);
  }

  Future<void> launchExternalPlayer() async {
    await externalPlayback.launch();
  }

  Future<void> createSyncPlayRoom(
      String room,
      String username,
      Future<void> Function(int episode, {int currentRoad, int offset})
          changeEpisode) async {
    await syncplay.createRoom(
      room,
      username,
      changeEpisode,
    );
  }

  void setSyncPlayCurrentPosition(
      {bool? forceSyncPlaying, double? forceSyncPosition}) {
    syncplay.setCurrentPosition(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> setSyncPlayPlayingBangumi(
      {bool? forceSyncPlaying, double? forceSyncPosition}) async {
    await syncplay.setPlayingBangumi(
      forceSyncPlaying: forceSyncPlaying,
      forceSyncPosition: forceSyncPosition,
    );
  }

  Future<void> requestSyncPlaySync({bool? doSeek}) async {
    await syncplay.requestSync(doSeek: doSeek);
  }

  Future<void> sendSyncPlayChatMessage(String message) async {
    await syncplay.sendChatMessage(message);
  }

  Future<void> exitSyncPlayRoom() async {
    await syncplay.exitRoom();
  }
}
