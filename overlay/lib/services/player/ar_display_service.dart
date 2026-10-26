import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 外接屏（AR 眼镜）播放的 Dart 侧封装。
///
/// 对应原生通道：
/// - MethodChannel `com.predidit.kazumi/ar_display`
/// - EventChannel `com.predidit.kazumi/ar_display_events`
///
/// 仅 iOS 支持；其它平台不会触发任何通道调用，统一安全降级。
class ARDisplayService {
  ARDisplayService._();

  static const MethodChannel _methodChannel =
      MethodChannel('com.predidit.kazumi/ar_display');
  static const EventChannel _eventChannel =
      EventChannel('com.predidit.kazumi/ar_display_events');

  static final StreamController<ARDisplayEvent> _eventController =
      StreamController<ARDisplayEvent>.broadcast();
  static bool _listeningForEvents = false;

  /// 原生外接屏状态。
  static Future<ARDisplayState> getState() async {
    if (!Platform.isIOS) {
      return const ARDisplayState.unsupported();
    }
    final map = await _invokeMap('getState');
    if (map == null) {
      return const ARDisplayState.unsupported();
    }
    return ARDisplayState.fromMap(map);
  }

  /// 开始在 AR 眼镜上播放，并推送弹幕数据与完整弹幕外观配置。
  ///
  /// [isLocalFile] 为 true 时 [url] 是本地文件路径（可能带 `file://` 前缀），
  /// 原生侧用 `AVAssetResourceLoader` 处理本地 HLS；网络地址不用 ResourceLoader。
  ///
  /// [danmakuConfig] 对应协议 §一：`opacity`、`fontScale`、`area`、
  /// `durationSeconds`、`lineHeight`、`strokeWidth`、`fontWeight`、
  /// `massiveMode`、`hideTop`、`hideScroll`、`hideBottom`。
  static Future<ARDisplayStartResult> start({
    required String url,
    required Map<String, String> headers,
    required bool isLocalFile,
    required int positionMs,
    required String title,
    required List<ARDisplayDanmakuItem> danmaku,
    required bool danmakuEnabled,
    required Map<String, Object?> danmakuConfig,
  }) async {
    if (!Platform.isIOS) {
      return const ARDisplayStartResult.failed('当前平台不支持 AR 眼镜播放');
    }
    final map = await _invokeMap('start', <String, Object?>{
      'url': url,
      'headers': headers,
      'isLocalFile': isLocalFile,
      'positionMs': positionMs,
      'title': title,
      'danmaku': <Map<String, Object>>[
        for (final item in danmaku) item.toMap(),
      ],
      'danmakuEnabled': danmakuEnabled,
      'danmakuConfig': danmakuConfig,
    });
    if (map == null) {
      return const ARDisplayStartResult.failed('AR 眼镜投屏启动失败');
    }
    return ARDisplayStartResult(
      ok: map['ok'] == true,
      error: _asOptionalString(map['error']),
    );
  }

  static Future<bool> play() async {
    if (!Platform.isIOS) {
      return false;
    }
    return _invokeCommand('play');
  }

  static Future<bool> pause() async {
    if (!Platform.isIOS) {
      return false;
    }
    return _invokeCommand('pause');
  }

  static Future<bool> seek(int positionMs) async {
    if (!Platform.isIOS) {
      return false;
    }
    return _invokeCommand('seek', <String, Object?>{'positionMs': positionMs});
  }

  static Future<bool> setDanmakuEnabled(bool enabled) async {
    if (!Platform.isIOS) {
      return false;
    }
    return _invokeCommand(
      'setDanmakuEnabled',
      <String, Object?>{'enabled': enabled},
    );
  }

  static Future<bool> setSpeed(double speed) async {
    if (!Platform.isIOS) {
      return false;
    }
    return _invokeCommand('setSpeed', <String, Object?>{'speed': speed});
  }

  /// 结束投屏并返回原生播放器最后的位置（毫秒）。
  static Future<ARDisplayStopResult> stop() async {
    if (!Platform.isIOS) {
      return const ARDisplayStopResult.failed();
    }
    final map = await _invokeMap('stop');
    if (map == null) {
      return const ARDisplayStopResult.failed();
    }
    return ARDisplayStopResult(
      positionMs: _asInt(map['positionMs']),
      durationMs: _asInt(map['durationMs']),
    );
  }

  /// 原生播放状态事件流；遥控页订阅，页面 dispose 时取消订阅。
  ///
  /// 非 iOS 平台返回永不发出事件的流（不会触发任何原生通道调用）。
  static Stream<ARDisplayEvent> get events {
    if (Platform.isIOS) {
      _ensureEventListening();
    }
    return _eventController.stream;
  }

  static void _ensureEventListening() {
    if (_listeningForEvents) {
      return;
    }
    _listeningForEvents = true;
    _eventChannel.receiveBroadcastStream().listen(
          _handleNativeEvent,
          onError: _handleNativeEventError,
          cancelOnError: false,
        );
  }

  static void _handleNativeEvent(dynamic event) {
    final ARDisplayEvent? decoded = _decodeEvent(event);
    if (decoded != null) {
      _eventController.add(decoded);
    }
  }

  static ARDisplayEvent? _decodeEvent(dynamic event) {
    if (event is! Map) {
      return null;
    }
    return ARDisplayEvent.fromMap(event.cast<Object?, Object?>());
  }

  static void _handleNativeEventError(Object error, StackTrace stackTrace) {
    KazumiLogger().w(
      'ARDisplayService: event channel error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  static Future<bool> _invokeCommand(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      await _methodChannel.invokeMethod<Object?>(method, arguments);
      return true;
    } on MissingPluginException catch (error) {
      KazumiLogger()
          .w('ARDisplayService: $method is unavailable', error: error);
    } on PlatformException catch (error) {
      KazumiLogger().e('ARDisplayService: $method failed', error: error);
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'ARDisplayService: $method failed unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return false;
  }

  static Future<Map<Object?, Object?>?> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        method,
        arguments,
      );
    } on MissingPluginException catch (error) {
      KazumiLogger()
          .w('ARDisplayService: $method is unavailable', error: error);
    } on PlatformException catch (error) {
      KazumiLogger().e('ARDisplayService: $method failed', error: error);
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'ARDisplayService: $method failed unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }
}

/// 外接屏状态（`getState` 返回值）。
class ARDisplayState {
  const ARDisplayState({
    required this.supported,
    required this.connected,
    required this.screenWidth,
    required this.screenHeight,
  });

  const ARDisplayState.unsupported()
      : supported = false,
        connected = false,
        screenWidth = 0,
        screenHeight = 0;

  factory ARDisplayState.fromMap(Map<Object?, Object?> map) {
    return ARDisplayState(
      supported: map['supported'] == true,
      connected: map['connected'] == true,
      screenWidth: _asInt(map['screenWidth']),
      screenHeight: _asInt(map['screenHeight']),
    );
  }

  final bool supported;
  final bool connected;
  final int screenWidth;
  final int screenHeight;
}

/// `start` 的返回值。
class ARDisplayStartResult {
  const ARDisplayStartResult({required this.ok, this.error});

  const ARDisplayStartResult.failed(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// `stop` 的返回值；失败时 [positionMs] 为 -1，调用方应忽略。
class ARDisplayStopResult {
  const ARDisplayStopResult({
    required this.positionMs,
    required this.durationMs,
  }) : ok = true;

  const ARDisplayStopResult.failed()
      : positionMs = -1,
        durationMs = 0,
        ok = false;

  final int positionMs;
  final int durationMs;
  final bool ok;

  /// 是否拿到了可信的原生播放位置。
  bool get hasPosition => ok && positionMs >= 0;
}

/// 单条弹幕载荷：`{t: 毫秒, m: 文本, c: 0xRRGGBB, y: 1 滚动 / 5 顶部 / 4 底部}`。
class ARDisplayDanmakuItem {
  const ARDisplayDanmakuItem({
    required this.timeMs,
    required this.message,
    required this.color,
    required this.type,
  });

  /// 弹幕出现时间（毫秒）。
  final double timeMs;
  final String message;

  /// 0xRRGGBB。
  final int color;

  /// 1 滚动，5 顶部，4 底部。
  final int type;

  Map<String, Object> toMap() => <String, Object>{
        't': timeMs,
        'm': message,
        'c': color,
        'y': type,
      };
}

/// 原生播放状态事件。
sealed class ARDisplayEvent {
  const ARDisplayEvent();

  static ARDisplayEvent? fromMap(Map<Object?, Object?> map) {
    final Object? type = map['type'];
    if (type is! String) {
      return null;
    }
    switch (type) {
      case 'connected':
        return ARDisplayConnectedEvent(
          width: _asInt(map['width']),
          height: _asInt(map['height']),
          windowVisible: map['windowVisible'] != false,
        );
      case 'disconnected':
        return const ARDisplayDisconnectedEvent();
      case 'state':
        return ARDisplayStateEvent(
          playing: map['playing'] == true,
          positionMs: _asInt(map['positionMs']),
          durationMs: _asInt(map['durationMs']),
          buffering: map['buffering'] == true,
          ended: map['ended'] == true,
          error: _asOptionalString(map['error']),
          windowVisible: map['windowVisible'] != false,
          sceneState: _asOptionalString(map['sceneState']),
        );
      case 'error':
        return ARDisplayErrorEvent(
          message: _asOptionalString(map['message']) ?? 'AR 眼镜投屏发生未知错误',
        );
      default:
        return null;
    }
  }
}

/// 外接屏已连接。
class ARDisplayConnectedEvent extends ARDisplayEvent {
  const ARDisplayConnectedEvent({
    required this.width,
    required this.height,
    this.windowVisible = true,
  });

  final int width;
  final int height;

  /// 原生外接屏窗口是否真的已经显示（用于排查「场景已连接但仍镜像」问题）。
  final bool windowVisible;
}

/// 外接屏已断开。
class ARDisplayDisconnectedEvent extends ARDisplayEvent {
  const ARDisplayDisconnectedEvent();
}

/// 周期性播放状态（默认 250ms 一次）。
class ARDisplayStateEvent extends ARDisplayEvent {
  const ARDisplayStateEvent({
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.buffering,
    required this.ended,
    this.error,
    this.windowVisible = true,
    this.sceneState,
  });

  final bool playing;
  final int positionMs;
  final int durationMs;
  final bool buffering;
  final bool ended;
  final String? error;

  /// 原生外接屏窗口是否已经显示。
  final bool windowVisible;

  /// 原生外接屏场景的激活状态（诊断用，如 foregroundActive）。
  final String? sceneState;
}

/// 致命错误（如 AVPlayerItem 失败）。
class ARDisplayErrorEvent extends ARDisplayEvent {
  const ARDisplayErrorEvent({required this.message});

  final String message;
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

String? _asOptionalString(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}
