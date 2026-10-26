import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/ar_display_service.dart';
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

  bool get _canControl => _connected && _error == null;

  @override
  void initState() {
    super.initState();
    _danmakuEnabled = widget.danmakuEnabled;
    _positionMs = math.max(0, widget.initialPositionMs);
    _durationMs = math.max(0, widget.durationMs);
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
        ):
        setState(() {
          _playing = playing;
          _buffering = buffering;
          _ended = ended;
          _windowVisible = windowVisible;
          _sceneState = sceneState;
          _upscalerActive = upscalerActive;
          if (durationMs > 0) {
            _durationMs = durationMs;
          }
          if (_dragPositionMs == null) {
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
                        child: _buildStatus(context),
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
                ? 'AR 眼镜端超分已启用（边缘保留放大 + 锐化）'
                : 'AR 眼镜端超分正在初始化…（若始终不生效将退回普通投屏）',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: Colors.white38),
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

  Widget _buildControls() {
    final bool canControl = _canControl;
    final double maxPosition = _durationMs > 0 ? _durationMs.toDouble() : 1.0;
    final double sliderValue =
        (_dragPositionMs ?? _positionMs.toDouble())
            .clamp(0.0, maxPosition)
            .toDouble();
    final int labelPositionMs = _dragPositionMs?.round() ?? _positionMs;
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
        Center(
          child: IconButton(
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
        ),
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
