# Kazumi · AR 眼镜外接屏播放补丁（iOS）

给 [Kazumi](https://github.com/Predidit/Kazumi)（Flutter 番剧 App）加一个 iOS 专属能力：
**把视频直接输出到 USB‑C 外接屏（AR 眼镜），满屏 16:9，并且弹幕也画在眼镜上。**

> 为什么需要这个：iPhone 屏幕约 19.5:9 / 21:9，直接「屏幕镜像」到 16:9 的 AR 眼镜会四边留黑边
> （画面利用率约 67%）。本补丁不镜像手机屏幕，而是在眼镜那块屏幕上新建一个全屏窗口，
> 自己渲染视频 + 原生弹幕，所以看起来是 100% 满屏（和 B 站「外接播放」的效果一致，但额外保留了弹幕）。

## 目录结构

```
.github/workflows/build-ipa.yml   # 在 macOS 云端 runner 上构建未签名 IPA
overlay/                          # 对上游 Kazumi 的改动文件（按仓库相对路径覆盖）
  ios/Runner/...                  #   原生：UISceneAccessory 外接屏场景 + AVPlayer + 原生弹幕渲染
  lib/...                         #   Flutter：通道封装、播放页按钮、手机端遥控页
scripts/sync-overlay.sh           # 把本地改动同步进 overlay/ 的工具脚本
```

构建时流水线会：克隆上游 `Predidit/Kazumi` 的**固定提交** `55e317e` → 覆盖 `overlay/` 中的文件 →
`flutter build ios --release --no-codesign` → 打包成未签名 `.ipa` 并作为 artifact 上传。

## 如何构建

1. 打开仓库的 **Actions** → 左侧 `ios-ipa` → **Run workflow**
2. `runner` 选择 **`xcode-27`**（必须：补丁用到了 iOS 27 SDK 的 `UISceneAccessory`；
   选择 `macos-26` 会编译失败 `cannot find 'UISceneAccessory' in scope`）
3. `label` 随便填（只影响 artifact 名字）
4. 等 10~15 分钟，在该次 run 页面底部下载 artifact `ios_outputs_<label>`，解压得到
   `Kazumi_ios_<label>_no_sign.ipa`

弹幕 API 凭据通过仓库 Secrets 注入（`DANDANAPI_APPID/KEY`、`KAZUMI_APPID/KEY`），
不在代码里、也不会出现在公开仓库内容中。**如果你 fork 到自己的账号，需要重新配置这四个 Secrets**，
否则弹幕接口会 401/403，视频本身不受影响。

## 如何安装（Windows + iloader）

未签名 IPA 需要自签：用你已有的 iloader 选择该 `.ipa`，用自己的 Apple ID 签名安装（免费证书 7 天有效），
和安装官方 `Kazumi_ios_*_no_sign.ipa` 的方式完全一样。

## 使用方法

1. 用 USB‑C 把 AR 眼镜接到 iPhone（系统要求 **iOS 27+**；低版本不支持该外接屏 API）
2. 打开 Kazumi，进入任意剧集播放页
3. 点播放器顶部的 **AirPlay 图标**（`AR 眼镜播放`）
4. 视频会出现在眼镜里：满屏 16:9 + 弹幕；手机变成遥控页（播放/暂停、拖动进度、弹幕开关、结束投屏）
5. 点「结束投屏」或返回，视频回到手机播放器，并从眼镜上播到的位置继续

## 已知限制

- **必须 iOS 27 及以上**。iOS 26 及更早没有 `UISceneAccessory`，按钮会提示不支持。
- 眼镜上的视频由系统 `AVPlayer` 解码，支持 HLS(m3u8) / MP4 等 Apple 支持的格式；
  个别站点要求特殊请求头的分片可能失败（会弹出错误提示，可换线路后用普通模式观看）。
- 眼镜上显示的是「视频 + 弹幕」，没有播放器控件；进度/暂停在手机遥控页操作。
- 不开 AR 模式时，眼镜仍是系统镜像，黑边不变（系统行为，App 无法改变）。
- 本补丁只影响 iOS 端；Android / Windows / macOS 行为不变。

## 许可

上游 Kazumi 为 GPL‑3.0；本补丁作为衍生作品同样遵循 GPL‑3.0。
