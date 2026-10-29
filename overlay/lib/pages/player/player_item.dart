import 'dart:async';
import 'dart:io';
import 'package:kazumi/pages/player/player_item_panel.dart';
import 'package:kazumi/pages/player/player_keyboard_shortcuts.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/pages/player/player_pointer_interaction.dart';
import 'package:kazumi/pages/player/player_gesture_detector.dart';
import 'package:kazumi/pages/player/player_screenshot_feedback_overlay.dart';
import 'package:kazumi/pages/player/player_screenshot_sheet.dart';
import 'package:kazumi/pages/player/controller/player_screenshot_controller.dart';
import 'package:kazumi/pages/player/syncplay_sheet.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:flutter/gestures.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:window_manager/window_manager.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/video_details_sheet.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/danmaku_source_sheet.dart';
import 'package:kazumi/pages/player/player_item_surface.dart';
import 'package:mobx/mobx.dart' as mobx;
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/timed_shutdown_service.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/services/platform/player_menu_service.dart';
import 'package:kazumi/pages/player/ar_display_remote_page.dart';
import 'package:kazumi/services/player/ar_display_service.dart';

class PlayerItem extends StatefulWidget {
  const PlayerItem({
    super.key,
    required this.playerController,
    required this.videoPageController,
    required this.fillsWindow,
    this.onToggleSidePanel,
    required this.changeEpisode,
    required this.onBackPressed,
    required this.keyboardFocus,
    required this.pauseForTimedShutdown,
    this.disableAnimations = false,
  });

  final PlayerController playerController;
  final VideoPageController videoPageController;
  final bool fillsWindow;
  final VoidCallback? onToggleSidePanel;
  final Future<void> Function(int episode, {int currentRoad, int offset})
      changeEpisode;
  final VoidCallback onBackPressed;
  final FocusNode keyboardFocus;
  final bool disableAnimations;
  final VoidCallback pauseForTimedShutdown;

  @override
  State<PlayerItem> createState() => _PlayerItemState();
}

class _PlayerItemState extends State<PlayerItem>
    with
        WindowListener,
        WidgetsBindingObserver,
        TickerProviderStateMixin,
        KazumiDialogOwner {
  late final PlayerController playerController;
  late final VideoPageController videoPageController =
      widget.videoPageController;
  final HistoryController historyController = inject<HistoryController>();
  final MyController myController = inject<MyController>();
  AudioController get _audioController => playerController.audioController;
  late final Map<String, PlayerShortcutAction> keyboardActions;
  late final Map<String, PlayerLongPressShortcutActions>
      keyboardLongPressActions;

  late bool webDavEnable;
  late bool webDavEnableHistory;

  final _danmuKey = GlobalKey();
  final _videoSurfaceKey = GlobalKey();
  late bool _border;
  late double _opacity;
  double get _fontSize => GStorage.getSetting(
        SettingsKeys.danmakuFontSize,
        context: SettingContext(
          compactLayout: MediaQuery.sizeOf(context).shortestSide < 600,
        ),
      );

  // AR 眼镜原生弹幕以手机端参考字号 16 为 1.0；协议 §一要求 clamp 到 0.4–3.0。
  static const double _arDanmakuFontReferenceSize = 16.0;
  static const double _arDanmakuFontScaleMin = 0.4;
  static const double _arDanmakuFontScaleMax = 3.0;
  bool _arDisplayInProgress = false;
  StreamSubscription<ARDisplayEvent>? _arHistorySubscription;
  int _arLastHistorySecond = -1;
  bool _arConnectingDialogVisible = false;
  bool _arConnectingCancelled = false;
  bool _arCancelResumeStarted = false;
  int _arStartPositionMs = 0;
  bool _arResumePlayback = false;
  Future<void>? _arReleaseFuture;

  late double _danmakuArea;
  late bool _hideTop;
  late bool _hideBottom;
  late bool _hideScroll;
  late bool _massiveMode;
  late bool _danmakuColor;
  late bool _danmakuBiliBiliSource;
  late bool _danmakuGamerSource;
  late bool _danmakuDanDanSource;
  late double _danmakuDuration;
  late double _danmakuLineHeight;
  late int _danmakuFontWeight;
  late bool _danmakuUseSystemFont;
  late double _danmakuBorderSize;

  late bool autoPlayNext;
  late bool backgroundPlayback;
  late bool brightnessVolumeGesture;

  // Auto-hide delay in milliseconds.
  late int playerControllerLayerDisappearTime;

  Timer? hideTimer;
  Timer? playerTimer;
  Timer? mouseScrollerTimer;
  Timer? _adjustmentHudHideTimer;
  final Set<PlayerPanelHold> _playerPanelHolds = <PlayerPanelHold>{};
  int _openPlayerMenuCount = 0;
  PlayerPanelHold? _progressBarDragHold;
  PointerDeviceKind? _lastTapPointerKind;
  PointerDeviceKind? _lastDoubleTapPointerKind;

  late final AnimationController _panelVisibilityController;
  late final AnimationController _screenshotFeedbackController;
  late final Animation<double> _screenshotFeedbackAnimation;
  late final PlayerScreenshotController _screenshots =
      playerController.screenshots;
  bool _screenshotSheetOpen = false;

  double lastPlayerSpeed = 1.0;
  late double longPressPlaySpeed;
  bool? _lastPipPlaying;
  bool? _lastPipDanmakuEnabled;
  Rect? _lastPipSourceRect;
  bool _pipSourceRectSyncScheduled = false;
  bool _pipEnterRequested = false;
  late mobx.ReactionDisposer _playerSizeListener;

  late mobx.ReactionDisposer _fullscreenListener;

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleAndroidPIPSourceRectSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused && !backgroundPlayback) {
      // Suspend before awaiting pause so a later resume wins; pause alone keeps prefetching.
      final suspend = playerController.playback.setPrefetchSuspended(true);
      if (playerController.playback.mediaPlayer != null &&
          playerController.playback.playerPlaying) {
        try {
          await playerController.pause(enableSync: false);
        } catch (_) {}
      }
      await suspend;
      return;
    }
    if (state == AppLifecycleState.resumed) {
      await playerController.playback.setPrefetchSuspended(false);
    }
    try {
      if (playerController.playback.playerPlaying) {
        playerController.danmaku.canvasController.resume();
      }
    } catch (_) {}
  }

  Future<void> _syncAndroidAutoEnterPIPSetting() async {
    if (!Platform.isAndroid) {
      return;
    }
    final bool autoEnterPIPEnabled =
        GStorage.getSetting(SettingsKeys.androidAutoEnterPIP);
    try {
      await PipUtils.setAndroidAutoEnterPIPEnabled(autoEnterPIPEnabled);
    } catch (e) {
      KazumiLogger().w(
        'PlayerItem: failed to sync android auto enter pip setting',
        error: e,
      );
    }
  }

  Future<void> _syncAndroidPIPPlayerPageState(bool inPlayerPage) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await PipUtils.setAndroidPIPInPlayerPage(inPlayerPage);
    } catch (e) {
      KazumiLogger().w(
        'PlayerItem: failed to sync android pip player page state',
        error: e,
      );
    }
  }

  Future<void> _updateAndroidPIPActions({bool force = false}) async {
    if (!Platform.isAndroid) {
      return;
    }
    final bool playing = playerController.playback.playing;
    final bool danmakuEnabled = playerController.danmaku.danmakuOn;
    // In picture in picture the measured rect is the small window itself.
    final Rect? sourceRect = videoPageController.isPip
        ? _lastPipSourceRect
        : _androidPIPSourceRect();
    if (!force &&
        _lastPipPlaying == playing &&
        _lastPipDanmakuEnabled == danmakuEnabled &&
        _lastPipSourceRect == sourceRect) {
      return;
    }

    _lastPipPlaying = playing;
    _lastPipDanmakuEnabled = danmakuEnabled;
    _lastPipSourceRect = sourceRect;
    await PipUtils.updateAndroidPIPActions(
      playing: playing,
      danmakuEnabled: danmakuEnabled,
      width: playerController.debug.playerWidth,
      height: playerController.debug.playerHeight,
      sourceRect: sourceRect,
    );
  }

  // Android PiP expects the letterboxed video bounds in physical pixels.
  Rect? _androidPIPSourceRect() {
    if (!mounted) {
      return null;
    }
    final renderObject = _videoSurfaceKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    final Size size = renderObject.size;
    if (size.isEmpty) {
      return null;
    }
    Rect rect = Offset.zero & size;
    final int videoWidth = playerController.debug.playerWidth;
    final int videoHeight = playerController.debug.playerHeight;
    if (videoWidth > 0 && videoHeight > 0) {
      final double scale =
          (rect.width / videoWidth) < (rect.height / videoHeight)
              ? rect.width / videoWidth
              : rect.height / videoHeight;
      rect = Rect.fromCenter(
        center: rect.center,
        width: videoWidth * scale,
        height: videoHeight * scale,
      );
    }
    // Convert the fitted video rectangle to window coordinates for native PiP.
    rect = MatrixUtils.transformRect(renderObject.getTransformTo(null), rect);
    final double ratio = MediaQuery.devicePixelRatioOf(context);
    return Rect.fromLTRB(
      rect.left * ratio,
      rect.top * ratio,
      rect.right * ratio,
      rect.bottom * ratio,
    );
  }

  // Remove controls before PiP entry to avoid rebuilding during the resize animation.
  Future<void> enterAndroidPictureInPicture() async {
    if (!Platform.isAndroid || !mounted) {
      return;
    }
    final bool supported = await PipUtils.isAndroidPIPSupported();
    if (!mounted) {
      return;
    }
    if (!supported) {
      KazumiDialog.showToast(message: '当前设备不支持画中画');
      return;
    }
    setState(() {
      _pipEnterRequested = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    await _updateAndroidPIPActions(force: true);
    final bool entered = await PipUtils.enterAndroidPIPWindow(
      width: playerController.debug.playerWidth,
      height: playerController.debug.playerHeight,
    );
    if (entered || !mounted) {
      return;
    }
    KazumiDialog.showToast(message: '进入画中画失败');
    setState(() {
      _pipEnterRequested = false;
    });
  }

  void _handleAndroidPIPModeChanged(bool inPipMode) {
    if (!mounted || videoPageController.isPip == inPipMode) {
      return;
    }
    setState(() {
      videoPageController.isPip = inPipMode;
    });
    if (!inPipMode) {
      _pipEnterRequested = false;
      _scheduleAndroidPIPSourceRectSync();
    }
  }

  void _scheduleAndroidPIPSourceRectSync() {
    if (!Platform.isAndroid || _pipSourceRectSyncScheduled) {
      return;
    }
    _pipSourceRectSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pipSourceRectSyncScheduled = false;
      if (!mounted) {
        return;
      }
      unawaited(_updateAndroidPIPActions());
    });
  }

  Future<void> _syncPIPAspectWhenVideoSizeReady() async {
    if (playerController.debug.playerWidth <= 0 ||
        playerController.debug.playerHeight <= 0) {
      return;
    }
    if (Platform.isAndroid) {
      await _updateAndroidPIPActions(force: true);
      return;
    }
    if (isDesktop() && videoPageController.isPip) {
      await PipUtils.enterDesktopPIPWindow(
        width: playerController.debug.playerWidth,
        height: playerController.debug.playerHeight,
      );
    }
  }

  void _initKeyboardActions() {
    keyboardActions = {
      'playorpause': () => playerController.playOrPause(),
      'forward': handleShortcutForwardDown,
      'rewind': handleShortcutRewind,
      'next': () => handlePreNextEpisode('next'),
      'prev': () => handlePreNextEpisode('prev'),
      'volumeup': () => handleShortcutVolumeChange('up'),
      'volumedown': () => handleShortcutVolumeChange('down'),
      'togglemute': () => handleShortcutVolumeChange('mute'),
      'fullscreen': () => handleShortcutFullscreen(),
      'screenshot': handleScreenshot,
      'skip': skipOP,
      'exitfullscreen': () => handleShortcutExitFullscreen(),
      'toggledanmaku': () => handleDanmaku(),
      'speed1': () => setPlaybackSpeed(1.0),
      'speed2': () => setPlaybackSpeed(2.0),
      'speed3': () => setPlaybackSpeed(3.0),
      'speedup': () => handleSpeedChange('up'),
      'speeddown': () => handleSpeedChange('down'),
    };
    keyboardLongPressActions = {
      'forward': PlayerLongPressShortcutActions(
        onRepeat: handleShortcutForwardRepeat,
        onRelease: handleShortcutForwardUp,
      ),
    };
  }

  void _initPlayerMenu() {
    unawaited(PlayerMenuService.initialize(keyboardActions));
  }

  void _disposePlayerMenu() {
    unawaited(PlayerMenuService.dispose());
  }

  Future<void> handlePreNextEpisode(String direction) async {
    if (videoPageController.loading) return;
    final selection = videoPageController.selectedEpisode;
    final currentRoad = selection.road;
    final episodes = videoPageController.roadList[currentRoad].data;
    int targetEpisode;
    if (direction == 'next') {
      targetEpisode = selection.episode + 1;
    } else if (direction == 'prev') {
      targetEpisode = selection.episode - 1;
    } else {
      return;
    }

    if (targetEpisode > episodes.length) {
      KazumiDialog.showToast(message: '已经是最新一集');
      return;
    }
    if (targetEpisode <= 0) {
      KazumiDialog.showToast(message: '已经是第一集');
      return;
    }

    final targetSelection = VideoEpisodeSelection(
      episode: targetEpisode,
      road: currentRoad,
    );
    final targetRef = videoPageController.resolveEpisode(targetSelection);
    if (targetRef != null) {
      KazumiDialog.showToast(message: '正在加载${targetRef.displayTitle}');
    }
    widget.changeEpisode(targetEpisode, currentRoad: currentRoad);
  }

  Future<void> handleShortcutRewind() async {
    try {
      await _seekWithPlayerTimer(
        () => playerController.seekBy(
          Duration(seconds: -playerController.playback.arrowKeySkipTime),
        ),
      );
    } catch (e) {
      KazumiLogger().e('PlayerController: seek failed', error: e);
    }
  }

  void handleShortcutForwardDown() {
    lastPlayerSpeed = playerController.playback.playerSpeed;
  }

  Future<void> handleShortcutForwardRepeat() async {
    final double defaultShortcutForwardPlaySpeed =
        GStorage.getSetting(SettingsKeys.defaultShortcutForwardPlaySpeed);
    if (playerController.playback.playerSpeed <
        defaultShortcutForwardPlaySpeed) {
      playerController.panel.showPlaySpeed = true;
      await setPlaybackSpeed(defaultShortcutForwardPlaySpeed);
    }
  }

  Future<void> handleShortcutForwardUp() async {
    if (playerController.panel.showPlaySpeed) {
      playerController.panel.showPlaySpeed = false;
      await setPlaybackSpeed(lastPlayerSpeed);
    } else {
      try {
        await _seekWithPlayerTimer(
          () => playerController.seekBy(
            Duration(seconds: playerController.playback.arrowKeySkipTime),
          ),
        );
      } catch (e) {
        KazumiLogger().e('PlayerController: seek failed', error: e);
      }
    }
  }

  void handleShortcutFullscreen() {
    if (!videoPageController.isPip) handleFullscreen();
  }

  void handleShortcutExitFullscreen() {
    if (videoPageController.isFullscreen) {
      unawaited(videoPageController.fullscreen.setFullscreen(false));
    } else if (isDesktop() && !Platform.isMacOS) {
      playerController.pause();
      windowManager.hide();
    }
  }

  void _toggleVideoController() {
    if (playerController.panel.showVideoController) {
      hideVideoController();
    } else {
      showVideoController();
    }
  }

  void _handleTap(PointerDeviceKind? pointerKind) {
    if (shouldToggleControllerOnPrimaryTap(
      isDesktop: isDesktop(),
      pointerKind: pointerKind,
    )) {
      _toggleVideoController();
      return;
    }
    playerController.playOrPause();
  }

  void _handleDoubleTap(PointerDeviceKind? pointerKind) {
    if (shouldToggleFullscreenOnDoubleTap(
      isDesktop: isDesktop(),
      isPip: videoPageController.isPip,
      pointerKind: pointerKind,
    )) {
      handleFullscreen();
      return;
    }
    playerController.playOrPause();
  }

  void _handleMouseScroller() {
    playerController.panel.showVolume = true;
    mouseScrollerTimer?.cancel();
    mouseScrollerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        playerController.panel.showVolume = false;
      }
      mouseScrollerTimer = null;
    });
  }

  void _cancelAdjustmentHudHideTimer() {
    _adjustmentHudHideTimer?.cancel();
    _adjustmentHudHideTimer = null;
  }

  void _showVolumeAdjustmentHud() {
    _cancelAdjustmentHudHideTimer();
    playerController.panel.showBrightness = false;
    playerController.panel.showVolume = true;
  }

  void _showBrightnessAdjustmentHud() {
    _cancelAdjustmentHudHideTimer();
    playerController.panel.showVolume = false;
    playerController.panel.showBrightness = true;
  }

  void _scheduleAdjustmentHudHide({
    Duration delay = const Duration(milliseconds: 650),
  }) {
    _cancelAdjustmentHudHideTimer();
    _adjustmentHudHideTimer = Timer(delay, () {
      if (mounted) {
        playerController.panel.showVolume = false;
        playerController.panel.showBrightness = false;
      }
      _adjustmentHudHideTimer = null;
    });
  }

  void _finishAdjustmentGesture() {
    if (!brightnessVolumeGesture) {
      return;
    }
    if (playerController.panel.volumeSeeking) {
      playerController.panel.volumeSeeking = false;
      unawaited(playerController.finishVolumeGesture());
    }
    if (playerController.panel.brightnessSeeking) {
      playerController.panel.brightnessSeeking = false;
    }
    _scheduleAdjustmentHudHide();
  }

  Future<void> skipOP() async {
    await playerController.seekBy(
      Duration(seconds: playerController.playback.buttonSkipTime),
    );
  }

  void handleDanmaku() {
    playerController.danmaku.canvasController.clear();
    if (playerController.danmaku.danmakuOn) {
      playerController.danmaku.setDanmakuEnabled(false);
      GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, false);
      unawaited(_updateAndroidPIPActions(force: true));
      return;
    }
    if (playerController.danmaku.danDanmakus.isEmpty) {
      showDanmakuSwitch();
      unawaited(_updateAndroidPIPActions(force: true));
      return;
    }
    playerController.danmaku.setDanmakuEnabled(true);
    GStorage.putSetting(SettingsKeys.danmakuEnabledByDefault, true);
    unawaited(_updateAndroidPIPActions(force: true));
  }

  Future<void> _syncHistoryWithWebDav() async {
    if (webDavEnable && webDavEnableHistory) {
      try {
        var webDav = WebDav();
        await webDav.syncHistory();
      } catch (e) {
        KazumiLogger().w('WebDav: auto history sync failed', error: e);
      }
    }
  }

  Future<void> _bindAudioService() async {
    try {
      await _audioController.bindCallbacks(
        onPlay: () => playerController.play(),
        onPause: () => playerController.pause(),
        onSkipToNext: () => handlePreNextEpisode('next'),
        onSkipToPrevious: () => handlePreNextEpisode('prev'),
        onSeek: (position) => playerController.seek(position),
        artworkUrl: videoPageController.bangumiItem.images['large'],
      );
      _syncAudioServiceState();
    } catch (e) {
      KazumiLogger().w('AudioController: failed to bind callbacks', error: e);
    }
  }

  void _syncAudioServiceState() {
    try {
      final selection = videoPageController.playbackEpisode;
      final currentRoad = selection.road;
      final currentEpisode = selection.episode;
      if (videoPageController.roadList.isEmpty ||
          currentRoad < 0 ||
          currentRoad >= videoPageController.roadList.length) {
        return;
      }
      final currentRoadData = videoPageController.roadList[currentRoad];
      if (currentEpisode <= 0 || currentRoadData.data.isEmpty) return;
      final episodeRef = videoPageController.resolveEpisode(selection);
      if (episodeRef == null) return;
      final queueIndex = episodeRef.listIndex - 1;

      if (playerController.playback.duration <= Duration.zero) return;

      final canSkipToPrevious = currentEpisode > 1;
      final canSkipToNext = currentEpisode < currentRoadData.data.length;
      final bangumiTitle = videoPageController.bangumiItem.nameCn.isNotEmpty
          ? videoPageController.bangumiItem.nameCn
          : videoPageController.bangumiItem.name;

      unawaited(
        _audioController.updateSession(
          mediaId:
              '${videoPageController.bangumiItem.id}_${currentRoad}_$currentEpisode',
          title: bangumiTitle,
          album: videoPageController.isOfflineMode
              ? videoPageController.offlinePluginName
              : videoPageController.currentPlugin.name,
          artist: episodeRef.displayTitle,
          duration: playerController.playback.duration,
          playing: playerController.playback.playing,
          loading: playerController.playback.loading,
          buffering: playerController.playback.isBuffering,
          completed: playerController.playback.completed,
          updatePosition: playerController.playback.currentPosition,
          bufferedPosition: playerController.playback.buffer,
          speed: playerController.playback.playerSpeed,
          queueIndex: queueIndex,
          canSkipToNext: canSkipToNext,
          canSkipToPrevious: canSkipToPrevious,
        ),
      );
    } catch (e) {
      KazumiLogger()
          .w('AudioController: failed to sync playback state', error: e);
    }
  }

  void _handleFullscreenChange() async {
    playerController.panel.lockPanel = false;
    _releasePlayerPanelHolds();
    playerController.danmaku.canvasController.clear();
    _scheduleAndroidPIPSourceRectSync();

    await _syncHistoryWithWebDav();
  }

  void handleProgressBarDragStart() {
    _beginInteractiveSeek();
    _syncAudioServiceState();
    _progressBarDragHold = acquirePlayerPanelHold();
  }

  void handleProgressBarDragEnd(bool cancelled) {
    unawaited(_finishInteractiveSeek(cancelled: cancelled));
  }

  void _beginInteractiveSeek() {
    _progressBarDragHold?.release();
    _progressBarDragHold = null;
    playerTimer?.cancel();
    playerController.seeking.beginInteractiveSeek();
  }

  Future<void> _finishInteractiveSeek({bool cancelled = false}) async {
    var completed = false;
    try {
      completed = await playerController.seeking
          .finishInteractiveSeek(cancelled: cancelled);
    } catch (e) {
      KazumiLogger().e('PlayerController: interactive seek failed', error: e);
    }
    if (!mounted ||
        (!completed && playerController.seeking.hasActiveInteractiveSeek)) {
      return;
    }
    _progressBarDragHold?.release();
    _progressBarDragHold = null;
    if (completed) {
      _syncAudioServiceState();
    }
    _restartPlayerTimer();
  }

  void _restartPlayerTimer() {
    playerTimer?.cancel();
    playerTimer = getPlayerTimer();
  }

  Future<void> _seekWithPlayerTimer(
    Future<void> Function() seekAction,
  ) async {
    playerTimer?.cancel();
    try {
      await seekAction();
    } finally {
      if (mounted) {
        _restartPlayerTimer();
      }
    }
  }

  Future<void> handleScreenshot() async {
    if (!mounted) return;
    if (!isDesktop()) {
      await _saveScreenshotToGallery();
      return;
    }
    if (_screenshots.busy || _screenshotSheetOpen) return;
    final episode = videoPageController.playbackEpisode;
    final source = videoPageController.src;
    final player = playerController.playback.mediaPlayer;
    if (videoPageController.loading || player == null) {
      KazumiDialog.showToast(message: '暂未获取到画面，请等视频显示后重试');
      return;
    }
    final added = await _screenshots.capture(
      capturePng: playerController.screenshotPng,
      title: videoPageController.title,
      episode:
          videoPageController.resolveEpisode(episode)?.displayTitle ??
          '第 ${episode.episode} 集',
      position: player.state.position,
      isCurrent: () =>
          mounted &&
          !videoPageController.loading &&
          videoPageController.playbackEpisode == episode &&
          videoPageController.src == source &&
          identical(playerController.playback.mediaPlayer, player),
    );
    if (!mounted) return;
    if (added) _playScreenshotFeedback();
    if (!_screenshotSheetOpen) {
      showVideoController();
      if (!added || _screenshots.candidates.length == 1) {
        KazumiDialog.showToast(
          message: added
              ? '已截取画面，点击右上角图库挑选保存'
              : _screenshots.message ?? '截图失败，请重试',
          showActionButton: _screenshots.candidates.isNotEmpty,
          actionLabel: '挑选截图',
          onActionPressed: showScreenshotCandidates,
        );
      }
    }
  }

  Future<void> _saveScreenshotToGallery() async {
    _playScreenshotFeedback();
    try {
      final screenshot = await playerController.screenshotPng();
      if (!mounted) return;
      if (screenshot == null || screenshot.isEmpty) {
        KazumiDialog.showToast(message: '截图失败：未获取到图像');
        return;
      }
      final result = await SaverGallery.saveImage(
        screenshot,
        fileName: DateTime.timestamp().millisecondsSinceEpoch.toString(),
        extension: 'png',
        skipIfExists: false,
      );
      if (mounted && !result.isSuccess) {
        KazumiDialog.showToast(message: '截图保存失败：${result.errorMessage}');
      }
    } catch (e) {
      if (mounted) KazumiDialog.showToast(message: '截图失败：$e');
    }
  }

  Future<void> showScreenshotCandidates() async {
    if (!isDesktop() || !mounted || _screenshotSheetOpen || _screenshots.busy) {
      return;
    }
    _screenshotSheetOpen = true;
    final hold = acquirePlayerPanelHold();
    final player = playerController.playback.mediaPlayer;
    final episode = videoPageController.playbackEpisode;
    final source = videoPageController.src;
    final resume =
        playerController.playback.playing &&
        !playerController.syncplay.hasSession;
    final sleepRemaining = TimedShutdownService().remainingSecondsNotifier.value;
    final sleepDeadline = sleepRemaining > 0
        ? DateTime.now().add(Duration(seconds: sleepRemaining))
        : null;
    try {
      if (resume) await playerController.pause(enableSync: false);
      if (!mounted) return;
      await showPlayerScreenshotSheet(context, controller: _screenshots);
    } finally {
      _screenshotSheetOpen = false;
      if (mounted) {
        hold.release();
        widget.keyboardFocus.requestFocus();
        // Resume only the same local playback, respecting the sleep timer.
        if (resume &&
            identical(player, playerController.playback.mediaPlayer) &&
            videoPageController.playbackEpisode == episode &&
            videoPageController.src == source &&
            !videoPageController.loading &&
            !playerController.syncplay.hasSession &&
            (sleepDeadline == null || DateTime.now().isBefore(sleepDeadline)) &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
            (ModalRoute.of(context)?.isCurrent ?? false)) {
          await playerController.play(enableSync: false);
        }
      } else {
        hold.releaseSilently();
      }
    }
  }

  void _playScreenshotFeedback() {
    if (!mounted ||
        widget.disableAnimations ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    _screenshotFeedbackController.forward(from: 0);
  }

  Future<void> handleSuperResolutionChange(SuperResolutionMode mode) async {
    if (!mounted) return;

    // The mediacodec_embed renderer cannot apply super-resolution shaders.
    if (Platform.isAndroid && mode != SuperResolutionMode.off) {
      final String androidVideoRenderer =
          GStorage.getSetting(SettingsKeys.androidVideoRenderer);

      if (androidVideoRenderer == 'mediacodec_embed') {
        await KazumiDialog.show(builder: (context) {
          return AlertDialog(
            title: const Text('兼容性提示'),
            content: const Text('MediaCodec 渲染器不支持超分辨率功能。\n\n'
                '如需使用超分辨率，请在播放设置中将视频渲染器切换为 gpu 或 gpu-next。'),
            actions: [
              TextButton(
                onPressed: () {
                  KazumiDialog.dismiss(context: context);
                },
                child: const Text('确定'),
              ),
            ],
          );
        });
        return;
      }
    }

    final bool requiresPerformanceWarning = mode == SuperResolutionMode.quality;
    final bool warningDisabled = GStorage.getSetting(
      SettingsKeys.disableSuperResolutionWarning,
    );

    if (requiresPerformanceWarning && !warningDisabled) {
      bool confirmed = false;

      await KazumiDialog.show(builder: (context) {
        bool dontAskAgain = false;

        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: const Text('性能提示'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('启用超分辨率（质量档）可能会造成设备卡顿，是否继续？'),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: dontAskAgain,
                      onChanged: (value) =>
                          setState(() => dontAskAgain = value ?? false),
                    ),
                    const Text('下次不再询问'),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  if (dontAskAgain) {
                    await GStorage.putSetting(
                      SettingsKeys.disableSuperResolutionWarning,
                      true,
                    );
                  }
                  if (!context.mounted) return;
                  KazumiDialog.dismiss(context: context);
                },
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  confirmed = true;
                  if (dontAskAgain) {
                    await GStorage.putSetting(
                      SettingsKeys.disableSuperResolutionWarning,
                      true,
                    );
                  }
                  if (!context.mounted) return;
                  KazumiDialog.dismiss(context: context);
                },
                child: const Text('确认'),
              ),
            ],
          );
        });
      });

      if (confirmed && mounted) {
        playerController.setShader(mode);
      }
    } else {
      playerController.setShader(mode);
    }
  }

  void handleFullscreen() {
    if (!videoPageController.isPip) {
      unawaited(videoPageController.fullscreen.toggle());
    }
  }

  bool get _canHidePlayerPanel =>
      playerController.panel.canHidePlayerPanel && _playerPanelHolds.isEmpty;

  void showVideoController({bool restartHideTimer = true}) {
    // Re-forwarding restarts the ticker and stalls a frame, so hover must not.
    if (!_panelVisibilityController.isForwardOrCompleted) {
      _panelVisibilityController.forward();
    }
    playerController.panel.showVideoController = true;
    if (restartHideTimer && _canHidePlayerPanel) {
      _startHideTimer();
    }
  }

  void hideVideoController() {
    if (!_canHidePlayerPanel) {
      return;
    }
    _panelVisibilityController.reverse();
    _cancelHideTimer();
    playerController.panel.showVideoController = false;
  }

  PlayerPanelHold acquirePlayerPanelHold() {
    late final PlayerPanelHold hold;
    hold = PlayerPanelHold(
      onRelease: () {
        _playerPanelHolds.remove(hold);
        if (_playerPanelHolds.isNotEmpty) {
          return;
        }
        playerController.panel.canHidePlayerPanel = true;
        _startHideTimer();
      },
    );
    _playerPanelHolds.add(hold);
    playerController.panel.canHidePlayerPanel = false;
    _cancelHideTimer();
    showVideoController(restartHideTimer: false);
    return hold;
  }

  void _handlePlayerMenuVisibilityChanged(bool isOpen) {
    if (isOpen) {
      _openPlayerMenuCount++;
    } else if (_openPlayerMenuCount > 0) {
      _openPlayerMenuCount--;
    }
  }

  // Fullscreen and system overlays can dispose controls before their holds are released.
  void _releasePlayerPanelHolds() {
    for (final hold in _playerPanelHolds.toList()) {
      hold.releaseSilently();
    }
    _playerPanelHolds.clear();
    _progressBarDragHold = null;
    playerController.panel.canHidePlayerPanel = true;
    _startHideTimer();
  }

  Future<void> setPlaybackSpeed(double speed) async {
    await playerController.setPlaybackSpeed(speed);
  }

  Future<void> handleSpeedChange(String type) async {
    try {
      final currentSpeed = playerController.playback.playerSpeed;
      int index = defaultPlaySpeedList.indexOf(currentSpeed);
      if (type == "up") {
        if (index < defaultPlaySpeedList.length - 1) {
          index++;
          setPlaybackSpeed(defaultPlaySpeedList[index]);
        } else {
          KazumiDialog.showToast(message: '已达倍速上限');
        }
      } else if (type == "down") {
        if (index > 0) {
          index--;
          setPlaybackSpeed(defaultPlaySpeedList[index]);
        } else {
          KazumiDialog.showToast(message: '已达倍速下限');
        }
      }
    } catch (e) {
      KazumiLogger().e('PlayerController: speed change failed', error: e);
    }
  }

  Future<void> handleShortcutVolumeChange(String type) async {
    try {
      switch (type) {
        case 'up':
          await playerController
              .setVolume(playerController.playback.volume + 10);
          break;
        case 'down':
          await playerController
              .setVolume(playerController.playback.volume - 10);
          break;
        case 'mute':
          await playerController.toggleMute();
          break;
        default:
          return;
      }
      _showVolumeAdjustmentHud();
      _scheduleAdjustmentHudHide(delay: const Duration(seconds: 1));
    } catch (e) {
      KazumiLogger().e('PlayerController: volume change failed', error: e);
    }
  }

  Future<void> setBrightness(double value) async {
    try {
      await ScreenBrightnessPlatform.instance
          .setApplicationScreenBrightness(value);
    } catch (_) {}
  }

  void _startHideTimer() {
    _cancelHideTimer();
    if (!_canHidePlayerPanel) {
      return;
    }
    hideTimer =
        Timer(Duration(milliseconds: playerControllerLayerDisappearTime), () {
      if (mounted) {
        hideVideoController();
      }
      hideTimer = null;
    });
  }

  void _cancelHideTimer() {
    hideTimer?.cancel();
    hideTimer = null;
  }

  bool _isDanmakuSourceEnabled(DanmakuEntry danmaku) {
    if (!_danmakuBiliBiliSource && danmaku.source.contains('BiliBili')) {
      return false;
    }
    if (!_danmakuGamerSource && danmaku.source.contains('Gamer')) {
      return false;
    }
    if (!_danmakuDanDanSource &&
        !(danmaku.source.contains('BiliBili') ||
            danmaku.source.contains('Gamer'))) {
      return false;
    }
    return true;
  }

  DanmakuItemType _danmakuItemType(DanmakuEntry danmaku) {
    if (danmaku.type == 4) {
      return DanmakuItemType.bottom;
    }
    if (danmaku.type == 5) {
      return DanmakuItemType.top;
    }
    return DanmakuItemType.scroll;
  }

  /// 把已加载弹幕转换成原生通道载荷：`{t 毫秒, m, c 0xRRGGBB, y}`。
  /// 投屏期间按原生状态事件的进度持续写观看历史：投屏时手机端计时器是停的，
  /// 否则退出投屏后重新打开视频会丢失这一段进度。
  void _startArHistoryRecording({required int durationMs}) {
    final PlaybackHistoryIdentity? identity =
        videoPageController.currentHistoryIdentity;
    if (identity == null || !identity.canRecord) {
      return;
    }
    _arLastHistorySecond = -1;
    _arHistorySubscription?.cancel();
    _arHistorySubscription = ARDisplayService.events.listen((event) {
      if (event is! ARDisplayStateEvent || event.positionMs <= 0) {
        return;
      }
      final int second = event.positionMs ~/ 1000;
      if (second == _arLastHistorySecond) {
        return;
      }
      _arLastHistorySecond = second;
      final int duration =
          event.durationMs > 0 ? event.durationMs : durationMs;
      unawaited(historyController.updateHistory(
        identity,
        Duration(milliseconds: event.positionMs),
        duration: Duration(milliseconds: duration),
      ));
    });
  }

  void _stopArHistoryRecording() {
    _arHistorySubscription?.cancel();
    _arHistorySubscription = null;
    _arLastHistorySecond = -1;
  }

  void _recordArHistory({required int positionMs, required int durationMs}) {
    final PlaybackHistoryIdentity? identity =
        videoPageController.currentHistoryIdentity;
    if (identity == null || !identity.canRecord || positionMs <= 0) {
      return;
    }
    unawaited(historyController.updateHistory(
      identity,
      Duration(milliseconds: positionMs),
      duration: Duration(milliseconds: durationMs),
    ));
  }

  List<ARDisplayDanmakuItem> _buildArDisplayDanmaku() {
    final List<DanmakuEntry> entries = playerController.danmaku.allDanmakus();
    // 弹幕时间校准：手机端的映射是「播放位置 - 偏移 = 弹幕源时间」，
    // 所以眼镜端的显示时间 = 弹幕源时间 + 偏移，和手机端保持一致。
    final double offsetMs =
        playerController.danmaku.timelineOffsetSeconds * 1000.0;
    return <ARDisplayDanmakuItem>[
      for (final DanmakuEntry entry in entries)
        ARDisplayDanmakuItem(
          timeMs: entry.time * 1000.0 + offsetMs,
          message: entry.message,
          color: _arDisplayColorValue(entry.color),
          type: _arDisplayDanmakuType(entry),
        ),
    ];
  }

  int _arDisplayColorValue(Color color) {
    return ((color.r * 255).toInt() << 16) |
        ((color.g * 255).toInt() << 8) |
        (color.b * 255).toInt();
  }

  /// 与 [_danmakuItemType] 一致：1 滚动 / 5 顶部 / 4 底部。
  int _arDisplayDanmakuType(DanmakuEntry danmaku) {
    if (danmaku.type == 4) {
      return 4;
    }
    if (danmaku.type == 5) {
      return 5;
    }
    return 1;
  }

  /// 当前 DanmakuScreen 实际生效的弹幕配置；画面尚未创建时返回 null。
  DanmakuOption? _liveDanmakuOption() {
    try {
      return playerController.danmaku.canvasController.option;
    } catch (_) {
      // canvasController 是 late 字段，未创建时访问会抛错，回退到设置值。
      return null;
    }
  }

  /// 组装协议 §一的 `danmakuConfig`：优先用直播中的 [DanmakuOption]（用户本次
  /// 调整立即生效），取不到时回退到 GStorage 设置值。
  Map<String, Object?> _buildArDanmakuConfig() {
    final DanmakuOption? option = _liveDanmakuOption();
    final double fontSize = option?.fontSize ?? _fontSize;
    final double strokeWidth =
        option?.strokeWidth ?? (_border ? _danmakuBorderSize : 0.0);
    return <String, Object?>{
      'opacity': (option?.opacity ?? _opacity).clamp(0.1, 1.0),
      'fontScale': (fontSize / _arDanmakuFontReferenceSize)
          .clamp(_arDanmakuFontScaleMin, _arDanmakuFontScaleMax),
      'area': (option?.area ?? _danmakuArea).clamp(0.0, 1.0),
      'durationSeconds': option?.duration ?? _danmakuDuration,
      'lineHeight': option?.lineHeight ?? _danmakuLineHeight,
      'strokeWidth': strokeWidth,
      'fontWeight': option?.fontWeight ?? _danmakuFontWeight,
      'massiveMode': option?.massiveMode ?? _massiveMode,
      'hideTop': option?.hideTop ?? _hideTop,
      'hideScroll': option?.hideScroll ?? _hideScroll,
      'hideBottom': option?.hideBottom ?? _hideBottom,
    };
  }

  /// 连接外接屏可能耗时（等系统创建外接屏场景 / 原生播放器起播），期间给用户
  /// 一个可取消的提示，取消后回落到手机播放。
  void _showArConnectingDialog() {
    if (_arConnectingDialogVisible || !mounted) {
      return;
    }
    _arConnectingDialogVisible = true;
    _arConnectingCancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: const Row(
              children: <Widget>[
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 16),
                Expanded(child: Text('正在连接 AR 眼镜…')),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  KazumiLogger().i('AR: cancel tapped');
                  _arConnectingCancelled = true;
                  _hideArConnectingDialog();
                  KazumiDialog.showToast(message: '已取消投屏，正在恢复播放…');
                  if (!_arCancelResumeStarted) {
                    _arCancelResumeStarted = true;
                    unawaited(_cancelArHandoff());
                  }
                },
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _arConnectingDialogVisible = false;
    });
  }

  void _hideArConnectingDialog() {
    if (!_arConnectingDialogVisible || !mounted) {
      return;
    }
    _arConnectingDialogVisible = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  /// 把手机关联的 mpv 在后台彻底释放（停网络/磁盘缓存）后交给原生 AVPlayer。
  /// 释放不阻塞连接流程：超时或失败只记日志，不影响投屏本身。
  Future<void> _startArDisplay() async {
    if (!Platform.isIOS) {
      return;
    }
    // 投屏只需要 URL/headers/位置，不依赖手机端 mpv 是否已经重新加载完成：
    // 结束上一次投屏后立刻再次投屏、或恢复播放仍在缓冲时，都应该能直接投。
    if (playerController.videoUrl.isEmpty) {
      KazumiDialog.showToast(message: '视频尚未加载完成，请稍后再试');
      return;
    }
    if (_arDisplayInProgress) {
      return;
    }
    _arDisplayInProgress = true;
    _arCancelResumeStarted = false;
    final int startPositionMs =
        playerController.playback.playerPosition.inMilliseconds;
    _arStartPositionMs = startPositionMs;
    // 释放后 playback.duration 会归零，投屏页的时长必须提前取。
    final int durationMs = playerController.playback.duration.inMilliseconds;
    final bool resumePlayback = playerController.playback.playing;
    _arResumePlayback = resumePlayback;
    final bool superResolutionActive =
        playerController.playback.superResolutionMode !=
            SuperResolutionMode.off;
    final String displayTitle = playerController.displayTitle.isNotEmpty
        ? playerController.displayTitle
        : videoPageController.title;
    final List<ARDisplayDanmakuItem> danmaku = _buildArDisplayDanmaku();
    final Map<String, Object?> danmakuConfig = _buildArDanmakuConfig();
    playerTimer?.cancel();
    _showArConnectingDialog();
    KazumiLogger().i(
      'AR: begin handoff position=${startPositionMs}ms '
      'duration=${durationMs}ms playing=$resumePlayback '
      'danmaku=${danmaku.length}',
    );
    try {
      await _arPauseForHandoff();
      if (_arConnectingCancelled) {
        KazumiLogger().i('AR: cancelled before native start');
        if (!_arCancelResumeStarted) {
          await _resumeAfterArDisplay(
            positionMs: startPositionMs,
            resumePlayback: resumePlayback,
          );
        }
        return;
      }
      KazumiLogger().i('AR: releasing mobile playback in background');
      _arReleaseFuture = _releaseMobilePlaybackForHandoff();
      KazumiLogger().i('AR: calling native start');
      final ARDisplayStartResult startResult = await ARDisplayService.start(
        url: playerController.videoUrl,
        headers: playerController.httpHeaders,
        isLocalFile: playerController.isLocalPlayback,
        positionMs: startPositionMs,
        title: displayTitle,
        danmaku: danmaku,
        danmakuEnabled: playerController.danmaku.danmakuOn,
        danmakuConfig: danmakuConfig,
        superResolution: superResolutionActive,
        superResolutionQuality:
            playerController.playback.superResolutionMode ==
                SuperResolutionMode.quality,
      );
      KazumiLogger().i(
        'AR: native start returned ok=${startResult.ok} '
        'error=${startResult.error ?? ''}',
      );
      _hideArConnectingDialog();
      if (!mounted) {
        unawaited(ARDisplayService.stop());
        return;
      }
      if (_arConnectingCancelled) {
        KazumiLogger().i('AR: cancelled after native start');
        await ARDisplayService.stop();
        if (!_arCancelResumeStarted) {
          await _resumeAfterArDisplay(
            positionMs: startPositionMs,
            resumePlayback: resumePlayback,
          );
        }
        return;
      }
      if (!startResult.ok) {
        KazumiLogger().e(
          'PlayerItem: failed to start AR display: ${startResult.error}',
        );
        KazumiDialog.showToast(
          message: startResult.error ?? 'AR 眼镜投屏启动失败',
        );
        // 原生若在超时后才真正起播，这里兜底停掉，避免两端同时出声。
        try {
          await ARDisplayService.stop();
        } catch (error, stackTrace) {
          KazumiLogger().w(
            'AR: stop after failed start threw',
            error: error,
            stackTrace: stackTrace,
          );
        }
        await _resumeAfterArDisplay(
          positionMs: startPositionMs,
          resumePlayback: resumePlayback,
        );
        return;
      }
      KazumiLogger().i('AR: remote page opening');
      _startArHistoryRecording(durationMs: durationMs);
      final int? endPositionMs = await Navigator.of(context).push<int>(
        MaterialPageRoute<int>(
          fullscreenDialog: true,
          builder: (BuildContext context) => ARDisplayRemotePage(
            title: displayTitle,
            initialPositionMs: startPositionMs,
            durationMs: durationMs,
            danmakuEnabled: playerController.danmaku.danmakuOn,
            danmakuCount: danmaku.length,
            superResolutionActive: superResolutionActive,
          ),
        ),
      );
      KazumiLogger().i('AR: remote page closed, endPosition=$endPositionMs');
      _stopArHistoryRecording();
      _recordArHistory(
        positionMs: endPositionMs ?? startPositionMs,
        durationMs: durationMs,
      );
      if (!mounted) {
        return;
      }
      await _resumeAfterArDisplay(
        positionMs: endPositionMs ?? startPositionMs,
        resumePlayback: resumePlayback,
      );
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerItem: AR display handoff failed',
        error: error,
        stackTrace: stackTrace,
      );
      await ARDisplayService.stop();
      if (mounted) {
        KazumiDialog.showToast(message: 'AR 眼镜投屏失败，请重试');
        await _resumeAfterArDisplay(
          positionMs: startPositionMs,
          resumePlayback: resumePlayback,
        );
      }
    } finally {
      _hideArConnectingDialog();
      _stopArHistoryRecording();
      _arDisplayInProgress = false;
      _arCancelResumeStarted = false;
      KazumiLogger().i('AR: handoff flow finished');
    }
  }

  /// 「取消」按下后立刻做的事：停掉（可能刚起来的）原生播放并恢复手机播放，
  /// 不再等挂起的 native start 超时。
  Future<void> _cancelArHandoff() async {
    KazumiLogger().i('AR: cancel -> stopping native and restoring playback');
    try {
      await ARDisplayService.stop();
    } catch (error, stackTrace) {
      KazumiLogger().w('AR: stop during cancel failed', error: error, stackTrace: stackTrace);
    }
    if (!mounted) {
      return;
    }
    await _resumeAfterArDisplay(
      positionMs: _arStartPositionMs,
      resumePlayback: _arResumePlayback,
    );
  }

  Future<void> _arPauseForHandoff() async {
    try {
      await playerController.pause().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      KazumiLogger().w('AR: pause timed out, continuing');
    } catch (error, stackTrace) {
      KazumiLogger().w('AR: pause failed', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _releaseMobilePlaybackForHandoff() async {
    try {
      // 不能用 Future.timeout 包住：超时不会取消内层释放，晚到的 playback.stop()
      // 会把恢复后的播放器销毁并重新置 loading=true（表现为永远「播放器加载中」）。
      final bool released =
          await playerController.releasePlaybackForExternalDisplay();
      KazumiLogger().i('AR: mobile playback released=$released');
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'AR: release of mobile playback failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _awaitArPlaybackRelease() async {
    final Future<void>? release = _arReleaseFuture;
    _arReleaseFuture = null;
    if (release == null) {
      return;
    }
    // 必须等释放彻底结束：释放链里的 playback.stop() 会把 loading 置回 true 并销毁播放器，
    // 如果它在恢复播放之后才完成，页面就会永远停在「播放器加载中」。
    try {
      await release.timeout(const Duration(seconds: 45));
      KazumiLogger().i('AR: background playback release finished');
    } on TimeoutException {
      KazumiLogger().w('AR: waiting for playback release timed out (45s)');
    }
  }

  /// 退出投屏后恢复播放页：重建 mpv 并 seek 到最终位置、按退出前状态恢复播放，
  /// 最后恢复每秒同步（同步会重启弹幕/通知，因此放在播放恢复之后）。
  Future<void> _resumeAfterArDisplay({
    required int positionMs,
    required bool resumePlayback,
  }) async {
    if (!mounted) {
      return;
    }
    // 等投屏前发起的后台释放收尾，避免它和重建播放互相抢 mpv 状态。
    await _awaitArPlaybackRelease();
    // 原生期间的进度与手机端暂停前的画面无关，先清屏避免恢复后残留旧弹幕。
    try {
      playerController.danmaku.clearAndInvalidateScheduledDanmakus();
    } catch (_) {}
    final bool resumed =
        await playerController.resumePlaybackAfterExternalDisplay(
      positionMs: positionMs,
      resumePlaying: resumePlayback,
    );
    if (!resumed) {
      KazumiLogger().e(
        'PlayerItem: failed to resume playback after AR display',
      );
      playerController.playback.loading = false;
      return;
    }
    if (!mounted) {
      return;
    }
    // 释放时 audio_service 的回调与音量监听都被解绑，重建后需要重新绑定。
    unawaited(_bindAudioService());
    _restartPlayerTimer();
    showVideoController();
    // 保险：如果还有晚到的释放把 loading 置回 true，5 秒后清一次，避免停在加载页。
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted || _arDisplayInProgress) {
        return;
      }
      if (playerController.playback.loading &&
          playerController.playback.mediaPlayer != null) {
        KazumiLogger().w('AR: loading watchdog cleared playback.loading');
        playerController.playback.loading = false;
      }
    });
  }

  void _emitDanmakusForCurrentPosition() {
    if (playerController.playback.currentPosition.inMicroseconds == 0 ||
        playerController.playback.playerPlaying != true ||
        playerController.danmaku.danmakuOn != true) {
      return;
    }

    final danmakus = playerController.danmaku
        .danmakusForPlaybackPosition(playerController.playback.currentPosition);
    final danmakuCount = danmakus.length;
    for (final entry in danmakus.asMap().entries) {
      final idx = entry.key;
      final danmaku = entry.value;
      if (!_isDanmakuSourceEnabled(danmaku)) {
        continue;
      }

      final color = _danmakuColor ? danmaku.color : Colors.white;
      final delay = DanmakuTimeline.staggerDelayMilliseconds(
        index: idx,
        total: danmakuCount,
      );
      final scheduledDanmakuGeneration =
          playerController.danmaku.scheduledDanmakuGeneration;
      Future.delayed(Duration(milliseconds: delay), () {
        if (!mounted ||
            !playerController.playback.playerPlaying ||
            playerController.playback.playerBuffering ||
            !playerController.danmaku.danmakuOn ||
            playerController.danmaku.scheduledDanmakuGeneration !=
                scheduledDanmakuGeneration ||
            myController.isDanmakuBlocked(danmaku.message)) {
          return;
        }
        playerController.danmaku.canvasController.addDanmaku(
          DanmakuContentItem(
            danmaku.message,
            color: color,
            type: _danmakuItemType(danmaku),
          ),
        );
      });
    }
  }

  Timer getPlayerTimer() {
    return Timer.periodic(const Duration(seconds: 1), (timer) {
      playerController.syncPlaybackState();
      unawaited(_updateAndroidPIPActions());
      _syncAudioServiceState();
      _emitDanmakusForCurrentPosition();
      if (!playerController.panel.volumeSeeking) {
        if (isDesktop()) {
          playerController.playback
              .applyExternalVolume(playerController.playback.playerVolume);
        }
      }
      if (!isDesktop() && !playerController.panel.brightnessSeeking) {
        ScreenBrightnessPlatform.instance.application.then((value) {
          if (!mounted) return;
          playerController.panel.brightness = value;
        });
      }
      final historyIdentity = videoPageController.currentHistoryIdentity;
      if (playerController.playback.playerPlaying &&
          !videoPageController.loading &&
          historyIdentity != null &&
          historyIdentity.canRecord) {
        historyController.updateHistory(
          historyIdentity,
          playerController.playback.playerPosition,
          duration: playerController.playback.playerDuration,
        );
      }
      final playingSelection = videoPageController.playbackEpisode;
      final playingRoadData =
          videoPageController.roadList[playingSelection.road];
      if (playerController.playback.completed && !videoPageController.loading) {
        if (playerController.playback.resumedNearEnd) {
          // Replay stale near-end resumes instead of advancing to the next episode.
          unawaited(playerController.playback.restartFromBeginning());
        } else if (playingSelection.episode < playingRoadData.data.length &&
            autoPlayNext) {
          final nextSelection = VideoEpisodeSelection(
            episode: playingSelection.episode + 1,
            road: playingSelection.road,
          );
          // Let the controller report resolution failures without retrying every tick.
          final nextRef = videoPageController.resolveEpisode(nextSelection);
          if (nextRef != null) {
            KazumiDialog.showToast(message: '正在加载${nextRef.displayTitle}');
          }
          try {
            playerTimer!.cancel();
          } catch (_) {}
          widget.changeEpisode(playingSelection.episode + 1,
              currentRoad: playingSelection.road);
        }
      }
      playerController.setSyncPlayCurrentPosition();
    });
  }

  void showDanmakuSwitch() {
    unawaited(showDanmakuSourceSheet(
      context,
      bangumiId: videoPageController.bangumiItem.id,
      initialKeyword: videoPageController.title,
      danmakuController: playerController.danmaku,
      onBeforeApply: videoPageController.cancelAutomaticDanmakuLoad,
    ));
  }

  void showVideoInfo() {
    showVideoDetailsSheet(context, playerController: playerController);
  }

  void showSyncPlayPanel() {
    showSyncPlaySheet(
      context,
      playerController: playerController,
      changeEpisode: widget.changeEpisode,
    );
  }

  @override
  void onWindowRestore() {
    playerController.danmaku.canvasController.clear();
  }

  @override
  void initState() {
    super.initState();
    playerController = widget.playerController;
    _initKeyboardActions();
    _initPlayerMenu();
    _fullscreenListener = mobx.reaction<bool>(
      (_) => videoPageController.isFullscreen,
      (_) {
        _handleFullscreenChange();
      },
    );
    _playerSizeListener = mobx.reaction<String>(
      (_) =>
          '${playerController.debug.playerWidth}:${playerController.debug.playerHeight}',
      (_) {
        unawaited(_syncPIPAspectWhenVideoSizeReady());
      },
    );
    if (Platform.isAndroid) {
      PipUtils.initPipHandler(
        onAction: (action) async {
          if (!mounted) return;

          switch (action) {
            case 'play_pause':
              playerController.playOrPause();
              break;

            case 'toggle_danmaku':
              handleDanmaku();
              break;

            case 'forward':
              await skipOP();
              break;
          }

          await _updateAndroidPIPActions(force: true);
        },
        onModeChanged: _handleAndroidPIPModeChanged,
      );
      unawaited(_syncAndroidAutoEnterPIPSetting());
      unawaited(_syncAndroidPIPPlayerPageState(true));
      unawaited(_updateAndroidPIPActions(force: true));
      _scheduleAndroidPIPSourceRectSync();
    }
    WidgetsBinding.instance.addObserver(this);
    _panelVisibilityController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _screenshotFeedbackController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );
    _screenshotFeedbackAnimation = CurvedAnimation(
      parent: _screenshotFeedbackController,
      curve: Curves.linear,
    );
    webDavEnable = GStorage.getSetting(SettingsKeys.webDavEnable);
    webDavEnableHistory = GStorage.getSetting(SettingsKeys.webDavEnableHistory);
    playerController.danmaku.setDanmakuEnabled(
      GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault),
    );
    _border = GStorage.getSetting(SettingsKeys.danmakuBorder);
    _opacity = GStorage.getSetting(SettingsKeys.danmakuOpacity);
    _danmakuArea = GStorage.getSetting(SettingsKeys.danmakuArea);
    _hideTop = !GStorage.getSetting(SettingsKeys.danmakuTop);
    _hideBottom = !GStorage.getSetting(SettingsKeys.danmakuBottom);
    _hideScroll = !GStorage.getSetting(SettingsKeys.danmakuScroll);
    _massiveMode = GStorage.getSetting(SettingsKeys.danmakuMassive);
    _danmakuColor = GStorage.getSetting(SettingsKeys.danmakuColor);
    _danmakuDuration = GStorage.getSetting(SettingsKeys.danmakuDuration);
    _danmakuLineHeight = GStorage.getSetting(SettingsKeys.danmakuLineHeight);
    _danmakuBiliBiliSource =
        GStorage.getSetting(SettingsKeys.danmakuBiliBiliSource);
    _danmakuGamerSource = GStorage.getSetting(SettingsKeys.danmakuGamerSource);
    _danmakuDanDanSource =
        GStorage.getSetting(SettingsKeys.danmakuDanDanSource);
    _danmakuFontWeight = GStorage.getSetting(SettingsKeys.danmakuFontWeight);
    _danmakuUseSystemFont = GStorage.getSetting(SettingsKeys.useSystemFont);
    _danmakuBorderSize = GStorage.getSetting(SettingsKeys.danmakuBorderSize);
    autoPlayNext = GStorage.getSetting(SettingsKeys.autoPlayNext);
    backgroundPlayback = GStorage.getSetting(SettingsKeys.backgroundPlayback);
    brightnessVolumeGesture =
        GStorage.getSetting(SettingsKeys.brightnessVolumeGesture);
    playerControllerLayerDisappearTime =
        GStorage.getSetting(SettingsKeys.playerControllerLayerDisappearTime);
    longPressPlaySpeed =
        GStorage.getSetting(SettingsKeys.defaultShortcutForwardPlaySpeed);
    unawaited(_bindAudioService());
    playerTimer = getPlayerTimer();
    windowManager.addListener(this);
    showVideoController();
  }

  @override
  void dispose() {
    // The route-scoped PlayerController owns playback disposal.
    _fullscreenListener();
    _playerSizeListener();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    playerController.seeking.invalidateInteractiveSeek();
    playerTimer?.cancel();
    hideTimer?.cancel();
    mouseScrollerTimer?.cancel();
    _adjustmentHudHideTimer?.cancel();
    _panelVisibilityController.dispose();
    _screenshotFeedbackController.dispose();
    _disposePlayerMenu();
    if (Platform.isAndroid) {
      unawaited(_syncAndroidPIPPlayerPageState(false));
      PipUtils.disposePipHandler();
    }
    playerController.panel.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        return ClipRect(
          child: Container(
            color: Colors.black,
            child: MouseRegion(
              cursor: (videoPageController.isFullscreen &&
                      !playerController.panel.showVideoController)
                  ? SystemMouseCursors.none
                  : SystemMouseCursors.basic,
              onHover: (PointerEvent pointerEvent) {
                // Android taps can emit hover events.
                if (isDesktop()) {
                  if (pointerEvent.position.dy > 50 &&
                      pointerEvent.position.dy <
                          MediaQuery.of(context).size.height - 70) {
                    showVideoController();
                  } else {
                    if (!playerController.panel.showVideoController) {
                      _panelVisibilityController.forward();
                      playerController.panel.showVideoController = true;
                    }
                  }
                }
              },
              child: Listener(
                onPointerSignal: (pointerSignal) {
                  if (pointerSignal is PointerScrollEvent) {
                    _handleMouseScroller();
                    final scrollDelta = pointerSignal.scrollDelta;
                    final double volume =
                        playerController.playback.volume - scrollDelta.dy / 60;
                    playerController.setVolume(volume);
                  }
                },
                child: SizedBox.expand(
                  child: Stack(alignment: Alignment.center, children: [
                    PlayerKeyboardShortcuts(
                      focusScopeNode: widget.keyboardFocus,
                      actions: keyboardActions,
                      longPressActions: keyboardLongPressActions,
                      isBlocked: () => _openPlayerMenuCount > 0,
                    ),
                    Center(
                      key: _videoSurfaceKey,
                      child: PlayerItemSurface(
                        playerController: playerController,
                      ),
                    ),
                    (playerController.playback.isBuffering ||
                            videoPageController.loading)
                        ? const Positioned.fill(
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          )
                        : Container(),
                    GestureDetector(
                      onTapDown: (details) {
                        _lastTapPointerKind = details.kind;
                      },
                      onTap: () {
                        _handleTap(_lastTapPointerKind);
                        _lastTapPointerKind = null;
                      },
                      onTapCancel: () {
                        _lastTapPointerKind = null;
                      },
                      onDoubleTapDown: (playerController.panel.lockPanel)
                          ? null
                          : (details) {
                              _lastDoubleTapPointerKind = details.kind;
                            },
                      onDoubleTap: (playerController.panel.lockPanel)
                          ? null
                          : () {
                              _handleDoubleTap(
                                _lastDoubleTapPointerKind ??
                                    _lastTapPointerKind,
                              );
                              _lastDoubleTapPointerKind = null;
                              _lastTapPointerKind = null;
                            },
                      onLongPressStart: (_) {
                        if (playerController.panel.lockPanel) {
                          return;
                        }
                        setState(() {
                          playerController.panel.showPlaySpeed = true;
                        });
                        lastPlayerSpeed = playerController.playback.playerSpeed;
                        setPlaybackSpeed(longPressPlaySpeed);
                      },
                      onLongPressEnd: (_) {
                        if (playerController.panel.lockPanel) {
                          return;
                        }
                        setState(() {
                          playerController.panel.showPlaySpeed = false;
                        });
                        setPlaybackSpeed(lastPlayerSpeed);
                      },
                      child: Container(
                        color: Colors.transparent,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                    Positioned.fill(
                      child: DanmakuScreen(
                        key: _danmuKey,
                        createdController: (DanmakuController e) {
                          playerController.danmaku.canvasController = e;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            playerController.updateDanmakuSpeed();
                          });
                        },
                        option: DanmakuOption(
                          hideTop: _hideTop,
                          hideScroll: _hideScroll,
                          hideBottom: _hideBottom,
                          area: _danmakuArea,
                          opacity: _opacity,
                          fontSize: _fontSize,
                          // Speed scaling is applied after canvas creation.
                          duration: _danmakuDuration,
                          lineHeight: _danmakuLineHeight,
                          strokeWidth: _border ? _danmakuBorderSize : 0.0,
                          fontWeight: _danmakuFontWeight,
                          massiveMode: _massiveMode,
                          fontFamily: _danmakuUseSystemFont
                              ? null
                              : customAppFontFamily,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: PlayerScreenshotFeedbackOverlay(
                        animation: _screenshotFeedbackAnimation,
                      ),
                    ),
                    (Platform.isAndroid &&
                            (videoPageController.isPip || _pipEnterRequested))
                        ? const SizedBox.shrink()
                        : PlayerItemPanel(
                            fillsWindow: widget.fillsWindow,
                            playerController: playerController,
                            videoPageController: videoPageController,
                            onBackPressed: widget.onBackPressed,
                            setPlaybackSpeed: setPlaybackSpeed,
                            showDanmakuSwitch: showDanmakuSwitch,
                            onToggleSidePanel: widget.onToggleSidePanel,
                            handleFullscreen: handleFullscreen,
                            enterAndroidPictureInPicture:
                                enterAndroidPictureInPicture,
                            handleProgressBarDragStart:
                                handleProgressBarDragStart,
                            handleProgressBarDragEnd: handleProgressBarDragEnd,
                            handleSuperResolutionChange:
                                handleSuperResolutionChange,
                            onNextEpisode: () => handlePreNextEpisode('next'),
                            panelVisibilityController:
                                _panelVisibilityController,
                            keyboardFocus: widget.keyboardFocus,
                            acquirePlayerPanelHold: acquirePlayerPanelHold,
                            onMenuVisibilityChanged:
                                _handlePlayerMenuVisibilityChanged,
                            handleDanmaku: handleDanmaku,
                            showVideoInfo: showVideoInfo,
                            showSyncPlayPanel: showSyncPlayPanel,
                            pauseForTimedShutdown: widget.pauseForTimedShutdown,
                            disableAnimations: widget.disableAnimations,
                            handleScreenShot: handleScreenshot,
                            showScreenshotCandidates: showScreenshotCandidates,
                            skipOP: skipOP,
                            onArDisplayPressed: _startArDisplay,
                          ),
                    Positioned.fill(
                      left: 16,
                      top: 25,
                      right: 15,
                      bottom: 15,
                      child: (isDesktop() || playerController.panel.lockPanel)
                          ? Container()
                          : PlayerGestureDetector(
                              onSeekStart: () {
                                playerController.panel.seekDirection = 0;
                                playerController.panel.seekCancelPending = false;
                                _beginInteractiveSeek();
                              },
                              onSeekUpdate: (delta, cancelPending) {
                                playerController.panel.showSeekTime = true;
                                playerController.panel.seekCancelPending =
                                    cancelPending;
                                if (delta == 0) return;
                                playerController.panel.seekDirection =
                                    delta > 0 ? 1 : -1;
                                final double scale =
                                    180000 / MediaQuery.sizeOf(context).width;
                                playerController.seeking.updateInteractiveSeek(
                                  playerController.playback.currentPosition +
                                      Duration(
                                        milliseconds:
                                            (delta * scale).round(),
                                      ),
                                );
                              },
                              onSeekEnd: (cancelled) {
                                playerController.panel.showSeekTime = false;
                                playerController.panel.seekCancelPending = false;
                                playerController.panel.seekDirection = 0;
                                unawaited(
                                  _finishInteractiveSeek(cancelled: cancelled),
                                );
                              },
                              onVerticalDragUpdate:
                                  (DragUpdateDetails details) async {
                                if (!brightnessVolumeGesture) {
                                  return;
                                }
                                final double totalWidth =
                                    MediaQuery.sizeOf(context).width;
                                final double totalHeight =
                                    MediaQuery.sizeOf(context).height;
                                final double tapPosition =
                                    details.localPosition.dx;
                                final double sectionWidth = totalWidth / 2;
                                final double delta = details.delta.dy;

                                if (tapPosition < sectionWidth) {
                                  playerController.panel.brightnessSeeking =
                                      true;
                                  _showBrightnessAdjustmentHud();
                                  final double level = (totalHeight) * 2;
                                  final double brightness =
                                      playerController.panel.brightness -
                                          delta / level;
                                  final double result =
                                      brightness.clamp(0.0, 1.0);
                                  setBrightness(result);
                                  playerController.panel.brightness = result;
                                } else {
                                  _showVolumeAdjustmentHud();
                                  if (!playerController.panel.volumeSeeking) {
                                    playerController.panel.volumeSeeking = true;
                                    playerController.playback
                                        .invalidatePreciseVolume();
                                  }
                                  final double baseVolume = playerController
                                              .playback.preciseVolume >=
                                          0
                                      ? playerController.playback.preciseVolume
                                      : playerController.playback.volume;
                                  final double level = (totalHeight) * 0.03;
                                  final double volume =
                                      baseVolume - delta / level;
                                  playerController
                                      .setVolumeDuringGesture(volume);
                                }
                              },
                              onVerticalDragEnd: (_) {
                                _finishAdjustmentGesture();
                              },
                              onVerticalDragCancel: () {
                                _finishAdjustmentGesture();
                              },
                            ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
