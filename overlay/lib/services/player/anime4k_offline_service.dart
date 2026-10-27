import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 「离线视频一键超分」的 Dart 侧入口（仅 iOS）。
///
/// 实际处理在原生侧完成（真正的 Anime4K GLSL 着色器 → Metal，GPU 逐帧执行后重新编码），
/// 这里只负责打开原生工具页：
/// - MethodChannel `com.predidit.kazumi/anime4k_offline`，方法 `open`。
///
/// 工具页里可以选择 Kazumi 已下载的视频（video.mp4 / playlist.m3u8）、「文件」App 里的
/// 视频或相册视频，设置档位后一键超分，并把结果保存到相册或分享。
class Anime4KOfflineService {
  Anime4KOfflineService._();

  static const MethodChannel _channel =
      MethodChannel('com.predidit.kazumi/anime4k_offline');
  static const EventChannel _eventChannel =
      EventChannel('com.predidit.kazumi/anime4k_offline_events');
  static StreamSubscription<dynamic>? _eventSubscription;

  /// 当前平台是否支持（只有 iOS 有原生实现）。
  static bool get isSupported => Platform.isIOS;

  /// 打开原生「离线视频 Anime4K 超分」工具页。
  static Future<bool> open() async {
    if (!Platform.isIOS) {
      return false;
    }
    _ensureEventListening();
    try {
      final bool? opened = await _channel.invokeMethod<bool>('open');
      return opened ?? false;
    } on MissingPluginException catch (error) {
      KazumiLogger().w(
        'Anime4KOfflineService: channel unavailable',
        error: error,
      );
    } on PlatformException catch (error) {
      KazumiLogger().e(
        'Anime4KOfflineService: open failed',
        error: error,
      );
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'Anime4KOfflineService: open failed unexpectedly',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return false;
  }

  /// 原生工具页完成「自动替换原视频」后，把 Hive 里的本地路径切到新的 video.mp4。
  static void _ensureEventListening() {
    if (_eventSubscription != null) {
      return;
    }
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error, StackTrace stackTrace) {
        KazumiLogger().w(
          'Anime4KOfflineService: event channel error',
          error: error,
          stackTrace: stackTrace,
        );
      },
      cancelOnError: false,
    );
  }

  static Future<void> _handleNativeEvent(Object? event) async {
    if (event is! Map) {
      return;
    }
    if (event['type'] != 'replaced') {
      return;
    }
    final String? directory = event['directory'] as String?;
    final String? videoPath = event['videoPath'] as String?;
    if (directory == null || videoPath == null) {
      return;
    }
    try {
      final controller = inject<DownloadController>();
      final bool updated = await controller.replaceLocalVideoPath(
        directory: directory,
        videoPath: videoPath,
      );
      KazumiLogger().i(
        'Anime4KOfflineService: 替换原视频完成（Hive 记录更新: $updated）',
      );
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'Anime4KOfflineService: 更新下载记录失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
