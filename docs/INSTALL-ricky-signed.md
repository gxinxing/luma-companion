# 安装 Ricky 签名版 Luma

`LumaCompanion-dev.ipa` 使用 Ricky 的付费 Apple Developer 团队签名，只能安装到描述文件已登记的设备。当前文件 SHA-256：`05ed4f4a33f46bb249d0c091af65c42998256c45099bc4b3db00da13f62b7533`。

目前包含：

- Ricky iPhone 17 Pro：`00008150-000919D436EA401C`
- 星星 iPhone 15 Pro：`00008130-001E35880A90001C`

描述文件于 **2027-09-24** 到期。到期后需要重新签名并安装；App 内数据是否保留取决于安装方式和系统状态。

## 安装前

1. Mac 安装 Xcode，并用数据线连接 iPhone。
2. 在 iPhone 上解锁、信任这台 Mac，并开启“设置 → 隐私与安全性 → 开发者模式”。
3. 保留 IPA 原文件，不要改包内内容；任何修改都会破坏签名。

## 用 Xcode 安装

1. 打开 Xcode，选择“Window → Devices and Simulators”。
2. 在左侧选择已连接的 iPhone。
3. 在“Installed Apps”区域点击 `+`，选择 `LumaCompanion-dev.ipa`。
4. 安装完成后在 iPhone 上打开显示名为 **Luma** 的 App。

如果系统要求信任开发者，前往“设置 → 通用 → VPN 与设备管理”，信任对应的 Apple Development 开发者。

## 用命令行安装

`devicectl` 安装的是 `.app`，因此先从 IPA 解出 Payload：

```bash
IPA="$HOME/Downloads/LumaCompanion-dev.ipa"
DEST="$(mktemp -d)"
ditto -x -k "$IPA" "$DEST"

xcrun devicectl list devices
xcrun devicectl device install app \
  --device "<设备名称、CoreDevice ID 或 UDID>" \
  "$DEST/Payload/LumaCompanion.app"
```

安装完成后可以启动：

```bash
xcrun devicectl device process launch \
  --device "<设备名称、CoreDevice ID 或 UDID>" \
  com.rickyke.lumacompanion
```

## 首次使用

- 允许蓝牙与本地网络权限。
- 在“设备 → 蜂群中台”填写中台地址和操作员令牌；令牌只保存在设备本机，不应写入源码或分享截图。
- 此签名包含 Hotspot Configuration。进入“记忆”或“实时”时，App 会自动加入眼镜 Wi‑Fi；iPhone 会短暂离开普通 Wi‑Fi，退出对应页面后恢复。
- 测试前退出 EyeVue，避免它占用眼镜的 BLE 连接。
