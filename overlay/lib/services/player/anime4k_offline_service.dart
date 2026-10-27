import 'dart:io';

import 'package:flutter/services.dart';
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

  /// 当前平台是否支持（只有 iOS 有原生实现）。
  static bool get isSupported => Platform.isIOS;

  /// 打开原生「离线视频 Anime4K 超分」工具页。
  static Future<bool> open() async {
    if (!Platform.isIOS) {
      return false;
    }
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
}
