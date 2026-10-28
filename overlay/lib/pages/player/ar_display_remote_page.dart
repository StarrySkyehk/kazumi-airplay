import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/ar_display_service.dart';
import 'package:kazumi/services/storage/settings_keys.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/format.dart';

/// AR 眼镜投屏期间显示在手机上的全屏遥控页（手机不渲染视频）。
///
/// 视频由原生 AVPlayer 播放，本页只负责：状态展示、播放/暂停、进度拖动、
/// 弹幕开关、结束投屏。退出时一定先调用 [ARDisplayService.stop]，并通过
/// `Navigator.pop` 把原生播放位置（毫秒）带回播放页。
class ARDisplayRemotePage extends StatefulWidget {
  const ARDisplayRemotePage({
    super.key,
    required this.title,
    required this.initialPositionMs,
    required this.durationMs,
    required this.danmakuEnabled,
    required this.danmakuCount,
    this.superResolutionActive = false,
  });

  final String title;
  final int initialPositionMs;
  final int durationMs;
  final bool danmakuEnabled;
  final int danmakuCount;

  /// 手机端是否开启了超分辨率（Anime4K）。AR 眼镜走独立解码，着色器不生效，
  /// 状态区据此显示一行说明。
  final bool superResolutionActive;

  @override
  State<ARDisplayRemotePage> createState() => _ARDisplayRemotePageState();
}

class _ARDisplayRemotePageState extends State<ARDisplayRemotePage> {
  static const double _horizontalPadding = 24;
  static const double _verticalPadding = 16;

  StreamSubscription<ARDisplayEvent>? _eventSubscription;

  late bool _danmakuEnabled;
  late int _positionMs;
  late int _durationMs;

  bool _playing = true;
  bool _buffering = false;
  bool _ended = false;
  bool _connected = true;
  bool _exiting = false;
  bool _stopped = false;
  String? _error;

  /// 拖动进度条时用户值优先，事件不会覆盖。
  double? _dragPositionMs;
  int _screenWidth = 0;
  int _screenHeight = 0;
  bool _windowVisible = true;
  String? _sceneState;
  bool _upscalerActive = false;

  /// 播放倍速（0.5x ~ 2.0x）。
  double _speed = 1.0;
  /// 长按临时 2x：按住前的倍速，松手后恢复。
  double? _heldSpeed;
  bool _holdingFast = false;

  /// 「跳过片头」秒数（复用播放设置里的「顶部按钮快进时长」，可在本页长按调整）。
  int _skipSeconds = 80;

  /// 左右滑动调整进度：拖动中的预览位置（null 表示没有在拖）。
  double? _swipePreviewMs;
  double _swipeDeltaPx = 0;
  double _swipeStartMs = 0;

  /// 每滑过 1 像素对应的秒数。
  static const double _secondsPerPixel = 0.4;

  static const List<double> _speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  bool get _canControl => _connected && _error == null;

  @override
  void initState() {
    super.initState();
    _danmakuEnabled = widget.danmakuEnabled;
    _positionMs = math.max(0, widget.initialPositionMs);
    _durationMs = math.max(0, widget.durationMs);
    _skipSeconds = GStorage.getSetting<int>(SettingsKeys.buttonSkipTime);
    _eventSubscription = ARDisplayService.events.listen(_handleEvent);
    unawaited(_refreshDisplayState());
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    // 异常退出（非结束投屏按钮）时也保证原生播放被清理。
    if (!_stopped) {
      unawaited(ARDisplayService.stop());
    }
    super.dispose();
  }

  Future<void> _refreshDisplayState() async {
    final ARDisplayState state = await ARDisplayService.getState();
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = state.connected;
      _screenWidth = state.screenWidth;
      _screenHeight = state.screenHeight;
      if (!state.supported && _error == null) {
        _error = '当前系统版本不支持 AR 眼镜播放';
      }
    });
  }

  void _handleEvent(ARDisplayEvent event) {
    if (!mounted) {
      return;
    }
    switch (event) {
      case ARDisplayConnectedEvent(
          :final width,
          :final height,
          :final windowVisible,
        ):
        setState(() {
          _connected = true;
          _screenWidth = width;
          _screenHeight = height;
          _windowVisible = windowVisible;
        });
      case ARDisplayDisconnectedEvent():
        setState(() {
          _connected = false;
          _playing = false;
        });
      case ARDisplayStateEvent(
          :final playing,
          :final positionMs,
          :final durationMs,
          :final buffering,
          :final ended,
          :final error,
          :final windowVisible,
          :final sceneState,
          :final upscalerActive,
          :final speed,
        ):
        setState(() {
          _playing = playing;
          _buffering = buffering;
          _ended = ended;
          _windowVisible = windowVisible;
          _sceneState = sceneState;
          _upscalerActive = upscalerActive;
          if (!_holdingFast) {
            _speed = speed.clamp(0.5, 2.0).toDouble();
          }
          if (durationMs > 0) {
            _durationMs = durationMs;
          }
          if (_dragPositionMs == null && _swipePreviewMs == null) {
            _positionMs = positionMs;
          }
          // 原生恢复可播放时会把 error 清空，这里同步跟随。
          _error = error;
        });
      case ARDisplayErrorEvent(:final message):
        setState(() {
          _error = message;
          _playing = false;
        });
    }
  }

  Future<void> _togglePlay() async {
    if (!_canControl) {
      return;
    }
    final bool target = !_playing;
    setState(() => _playing = target);
    final bool ok =
        target ? await ARDisplayService.play() : await ARDisplayService.pause();
    if (!mounted || ok) {
      return;
    }
    setState(() => _playing = !target);
    KazumiDialog.showToast(message: '控制 AR 眼镜失败，请重试');
  }

  Future<void> _seek(int positionMs) async {
    final bool ok = await ARDisplayService.seek(positionMs);
    if (!mounted || ok) {
      return;
    }
    KazumiDialog.showToast(message: '跳转失败，请重试');
  }

  void _commitSeek(double value) {
    final int targetMs = value.round();
    setState(() {
      _dragPositionMs = null;
      _positionMs = targetMs;
      _ended = false;
    });
    unawaited(_seek(targetMs));
  }

  Future<void> _setSpeed(double value, {bool showToast = true}) async {
    final double target = value.clamp(0.5, 2.0).toDouble();
    if ((target - _speed).abs() < 0.001) {
      return;
    }
    final double previous = _speed;
    setState(() => _speed = target);
    final bool ok = await ARDisplayService.setSpeed(target);
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() => _speed = previous);
      if (showToast) {
        KazumiDialog.showToast(message: '调整倍速失败，请重试');
      }
    }
  }

  /// 长按状态区域：临时 2x 快进，松手恢复到长按前的倍速。
  Future<void> _beginHoldFast() async {
    if (!_canControl || _holdingFast) {
      return;
    }
    _heldSpeed = _speed;
    setState(() => _holdingFast = true);
    await _setSpeed(2.0, showToast: false);
  }

  Future<void> _endHoldFast() async {
    if (!_holdingFast) {
      return;
    }
    final double restore = _heldSpeed ?? 1.0;
    setState(() => _holdingFast = false);
    _heldSpeed = null;
    await _setSpeed(restore, showToast: false);
  }

  /// 跳过片头：从当前位置快进 [_skipSeconds] 秒。
  Future<void> _skipForward() async {
    if (!_canControl || _durationMs <= 0) {
      return;
    }
    final int target = (_positionMs + _skipSeconds * 1000)
        .clamp(0, _durationMs)
        .toInt();
    setState(() {
      _positionMs = target;
      _ended = false;
    });
    await _seek(target);
  }

  /// 长按「跳过」按钮：调整跳过秒数（写回播放设置，和手机端的快进按钮共用）。
  Future<void> _editSkipSeconds() async {
    final TextEditingController controller =
        TextEditingController(text: _skipSeconds.toString());
    final int? result = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('跳过时长'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '秒数（1-600）',
              helperText: '与手机端播放器的「顶部按钮快进时长」共用',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final int? parsed = int.tryParse(controller.text.trim());
                Navigator.of(context).pop(parsed);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (!mounted || result == null) {
      return;
    }
    final int seconds = result.clamp(1, 600);
    setState(() => _skipSeconds = seconds);
    await GStorage.putSetting<int>(SettingsKeys.buttonSkipTime, seconds);
  }

  void _swipeStart(DragStartDetails details) {
    if (!_canControl || _durationMs <= 0) {
      return;
    }
    _swipeStartMs = (_dragPositionMs ?? _positionMs.toDouble());
    _swipeDeltaPx = 0;
    setState(() => _swipePreviewMs = _swipeStartMs);
  }

  void _swipeUpdate(DragUpdateDetails details) {
    if (_swipePreviewMs == null) {
      return;
    }
    _swipeDeltaPx += details.delta.dx;
    final double targetMs = (_swipeStartMs +
            _swipeDeltaPx * _secondsPerPixel * 1000)
        .clamp(0.0, _durationMs.toDouble())
        .toDouble();
    setState(() => _swipePreviewMs = targetMs);
  }

  Future<void> _swipeEnd([DragEndDetails? details]) async {
    final double? target = _swipePreviewMs;
    if (target == null) {
      return;
    }
    setState(() {
      _swipePreviewMs = null;
      _swipeDeltaPx = 0;
      _positionMs = target.round();
      _ended = false;
    });
    await _seek(target.round());
  }

  Future<void> _setDanmakuEnabled(bool enabled) async {
    if (!_canControl) {
      return;
    }
    setState(() => _danmakuEnabled = enabled);
    final bool ok = await ARDisplayService.setDanmakuEnabled(enabled);
    if (!mounted || ok) {
      return;
    }
    setState(() => _danmakuEnabled = !enabled);
    KazumiDialog.showToast(message: '切换弹幕失败，请重试');
  }

  /// 结束投屏：先 stop 拿回原生位置，再带结果 pop。
  Future<void> _exit() async {
    if (_exiting) {
      return;
    }
    setState(() => _exiting = true);
    final ARDisplayStopResult result = await ARDisplayService.stop();
    if (!mounted) {
      return;
    }
    _stopped = true;
    KazumiLogger().i(
      'ARDisplayRemotePage: stopped, ok: ${result.ok}, positionMs: ${result.positionMs}',
    );
    Navigator.of(context).pop(result.hasPosition ? result.positionMs : null);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        unawaited(_exit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double minHeight = math.max(
                0.0,
                constraints.maxHeight - _verticalPadding * 2,
              );
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: _horizontalPadding,
                  vertical: _verticalPadding,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildHeader(context),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onLongPressStart: _canControl
                              ? (_) => unawaited(_beginHoldFast())
                              : null,
                          onLongPressEnd: _canControl
                              ? (_) => unawaited(_endHoldFast())
                              : null,
                          onLongPressCancel: _canControl
                              ? () => unawaited(_endHoldFast())
                              : null,
                          onHorizontalDragStart:
                              _canControl ? _swipeStart : null,
                          onHorizontalDragUpdate:
                              _canControl ? _swipeUpdate : null,
                          onHorizontalDragEnd: _canControl
                              ? (DragEndDetails details) =>
                                  unawaited(_swipeEnd(details))
                              : null,
                          onHorizontalDragCancel: _canControl
                              ? () => unawaited(_swipeEnd())
                              : null,
                          child: _buildStatus(context),
                        ),
                      ),
                      _buildControls(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.airplay, color: Colors.white70, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'AR 眼镜播放',
                style: textTheme.titleMedium?.copyWith(color: Colors.white70),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          widget.title.isEmpty ? '正在播放' : widget.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.headlineSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final _StatusInfo info = _statusInfo();
    return Column(
      children: [
        Icon(info.icon, size: 56, color: info.color),
        const SizedBox(height: 16),
        Text(
          info.title,
          textAlign: TextAlign.center,
          style: textTheme.titleLarge?.copyWith(
            color: info.color,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          info.detail,
          textAlign: TextAlign.center,
          style: textTheme.bodyMedium?.copyWith(color: Colors.white60),
        ),
        if (widget.superResolutionActive) ...[
          const SizedBox(height: 12),
          Text(
            _upscalerActive
                ? 'AR 眼镜端超分已启用（Lanczos 放大 + 锐化）'
                : '超分未生效，已回退普通投屏',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: Colors.white38),
          ),
        ],
        if (_swipePreviewMs != null) ...[
          const SizedBox(height: 12),
          Text(
            _swipeLabel(_swipePreviewMs!),
            textAlign: TextAlign.center,
            style: textTheme.titleMedium?.copyWith(
              color: Colors.lightBlueAccent,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (_holdingFast) ...[
          const SizedBox(height: 12),
          Text(
            '2× 快进中（松手恢复 ${_heldSpeed?.toStringAsFixed(2) ?? '1.0'}×）',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: Colors.lightGreenAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (_buffering && _canControl) ...[
          const SizedBox(height: 16),
          const SizedBox(
            width: 160,
            child: LinearProgressIndicator(minHeight: 3),
          ),
        ],
      ],
    );
  }

  _StatusInfo _statusInfo() {
    final String? error = _error;
    if (error != null) {
      return _StatusInfo(
        icon: Icons.error_outline_rounded,
        title: '投屏出错',
        detail: error,
        color: Colors.redAccent,
      );
    }
    if (!_connected) {
      return const _StatusInfo(
        icon: Icons.usb_off_rounded,
        title: 'AR 眼镜已断开连接',
        detail: '请用 USB-C 数据线重新连接眼镜，然后结束投屏并在手机上继续观看',
        color: Colors.orangeAccent,
      );
    }
    if (_ended) {
      return const _StatusInfo(
        icon: Icons.flag_rounded,
        title: '播放已结束',
        detail: '点击播放可从头重新播放，也可以结束投屏返回手机',
        color: Colors.white70,
      );
    }
    final String screenDetail = (_screenWidth > 0 && _screenHeight > 0
            ? '外接屏 $_screenWidth×$_screenHeight'
            : '外接屏已连接') +
        (_windowVisible ? '' : ' · 尚未显示${_sceneState == null ? '' : '（$_sceneState）'}');
    if (_playing) {
      return _StatusInfo(
        icon: Icons.play_circle_outline_rounded,
        title: '正在 AR 眼镜上播放',
        detail: _buffering ? '缓冲中…' : screenDetail,
        color: Colors.lightGreenAccent,
      );
    }
    return _StatusInfo(
      icon: Icons.pause_circle_outline_rounded,
      title: '已暂停',
      detail: screenDetail,
      color: Colors.white70,
    );
  }

  Widget _buildSpeedControl(bool canControl) {
    final bool enabled = canControl && !_holdingFast;
    final String speedLabel = _speed.toStringAsFixed(
      (_speed * 100).round() % 100 == 0 ? 1 : 2,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.speed_rounded,
              color: _holdingFast ? Colors.lightGreenAccent : Colors.white70,
            ),
            const SizedBox(width: 12),
            Text(
              _holdingFast ? '2× 快进中…' : '播放倍速',
              style: TextStyle(
                color: _holdingFast ? Colors.lightGreenAccent : Colors.white,
              ),
            ),
            const Spacer(),
            Text(
              '$speedLabel×',
              style: TextStyle(
                color: _holdingFast ? Colors.lightGreenAccent : Colors.white70,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final double option in _speedOptions)
              ChoiceChip(
                label: Text(_chipLabel(option)),
                selected: (_speed - option).abs() < 0.001,
                onSelected: enabled
                    ? (_) => unawaited(_setSpeed(option))
                    : null,
                showCheckmark: false,
                selectedColor: Colors.lightGreenAccent,
                backgroundColor: Colors.white12,
                disabledColor: Colors.white10,
                labelStyle: TextStyle(
                  color: (_speed - option).abs() < 0.001
                      ? Colors.black
                      : Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                side: BorderSide(color: Colors.white24, width: 0.5),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '上方状态区域：左右滑动调整进度；长按临时 2× 快进（松手恢复）\n'
          '长按「跳过」按钮可以改跳过秒数',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  String _swipeLabel(double targetMs) {
    final int deltaSeconds =
        ((targetMs - _swipeStartMs) / 1000).round();
    final String sign = deltaSeconds >= 0 ? '+' : '';
    return '进度 ${durationToString(Duration(milliseconds: targetMs.round()))}'
        '（$sign${deltaSeconds}s）';
  }

  String _chipLabel(double value) {
    final String text = value == value.roundToDouble()
        ? value.toStringAsFixed(1)
        : value.toString();
    return '${text}×';
  }

  Widget _buildControls() {
    final bool canControl = _canControl;
    final double maxPosition = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final double sliderValue =
        (_dragPositionMs ?? _swipePreviewMs ?? _positionMs.toDouble())
            .clamp(0.0, maxPosition)
            .toDouble();
    final int labelPositionMs =
        (_dragPositionMs ?? _swipePreviewMs)?.round() ?? _positionMs;
    final String playTooltip = _playing
        ? '暂停'
        : _ended
            ? '重新播放'
            : '播放';
    const TextStyle timeStyle = TextStyle(
      color: Colors.white70,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              durationToString(Duration(milliseconds: labelPositionMs)),
              style: timeStyle,
            ),
            Text(
              durationToString(Duration(milliseconds: _durationMs)),
              style: timeStyle,
            ),
          ],
        ),
        Slider(
          value: sliderValue,
          max: maxPosition,
          activeColor: Colors.white,
          inactiveColor: Colors.white24,
          thumbColor: Colors.white,
          onChanged: canControl && _durationMs > 0
              ? (double value) => setState(() => _dragPositionMs = value)
              : null,
          onChangeEnd: canControl && _durationMs > 0
              ? (double value) => _commitSeek(value)
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onLongPress:
                  canControl ? () => unawaited(_editSkipSeconds()) : null,
              child: OutlinedButton.icon(
                onPressed:
                    canControl ? () => unawaited(_skipForward()) : null,
                icon: const Icon(Icons.skip_next_rounded, size: 20),
                label: Text('跳过 $_skipSeconds 秒'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 28),
            IconButton(
              iconSize: 56,
              color: Colors.white,
              disabledColor: Colors.white24,
              tooltip: playTooltip,
              onPressed: canControl ? () => unawaited(_togglePlay()) : null,
              icon: Icon(
                _playing
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_filled_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildSpeedControl(canControl),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.subtitles_outlined, color: Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '弹幕',
                      style: TextStyle(color: Colors.white),
                    ),
                    Text(
                      widget.danmakuCount > 0
                          ? '已发送 ${widget.danmakuCount} 条弹幕到眼镜'
                          : '当前没有可显示的弹幕',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _danmakuEnabled,
                onChanged: canControl
                    ? (bool value) => unawaited(_setDanmakuEnabled(value))
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _exiting ? null : () => unawaited(_exit()),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(_exiting ? '正在结束…' : '结束投屏'),
        ),
      ],
    );
  }
}

class _StatusInfo {
  const _StatusInfo({
    required this.icon,
    required this.title,
    required this.detail,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;
}
