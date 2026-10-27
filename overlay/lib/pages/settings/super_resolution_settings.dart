import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/player/anime4k_offline_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/settings/settings_list.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late SuperResolutionMode superResolutionMode;

  @override
  void initState() {
    super.initState();
    disableWarning = GStorage.getSetting<bool>(
      SettingsKeys.disableSuperResolutionWarning,
    );
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('超分辨率'),
      body: SettingsList(
        sections: [
          SettingsRadioSection<SuperResolutionMode>(
            title: Text('超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu'),
            groupValue: superResolutionMode,
            onChanged: (SuperResolutionMode? value) {
              if (value == null) return;
              GStorage.putSetting<int>(
                SettingsKeys.defaultSuperResolutionMode,
                value.storageValue,
              );
              setState(() {
                superResolutionMode = value;
              });
            },
            tiles: [
              for (final mode in SuperResolutionMode.values)
                SettingsTile<SuperResolutionMode>.radioTile(
                  title: Text(mode.label),
                  description: Text(mode.description),
                  radioValue: mode,
                ),
            ],
          ),
          SettingsSection(
            title: Text('默认行为'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.notifications_off_rounded,
                title: Text('关闭提示'),
                description: Text('关闭每次启用超分辨率时的提示'),
                initialValue: disableWarning,
                onToggle: (value) async {
                  disableWarning = value ?? !disableWarning;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.disableSuperResolutionWarning,
                    disableWarning,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          SettingsSection(
            title: Text('离线视频'),
            tiles: [
              SettingsTile(
                leading: Icons.auto_awesome_rounded,
                title: Text('离线视频一键超分（Anime4K）'),
                description: Text(
                  '选择 Kazumi 已下载的视频或本地视频，用真正的 Anime4K 着色器在手机上超分并导出新视频（仅 iOS，处理较慢）',
                ),
                onPressed: (context) {
                  Anime4KOfflineService.open();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
