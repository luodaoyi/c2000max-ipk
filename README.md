# c2000max-ipk

本仓库的用途非常明确：

- **只为 鲲鹏 C2000-MAX 原厂固件补充两个插件**
  - `luci-app-openclash`
  - `luci-app-zerotier`
- **不面向其他插件**
- **不面向其他设备**
- **不面向第三方固件 / 魔改固件 / 非原厂固件**

## 支持范围

本仓库**仅支持**以下固件环境：

- 固件名称：`鲲鹏 C2000-MAX`
- 型号：`C2000-788`
- 原厂固件版本：`OpenWrt 21.02-SNAPSHOT 2.1.2.n0.c1`
- Target：`mediatek/mt7987`
- 架构：`aarch64_cortex-a53`
- 内核：`5.4.281`

除了上面这套 **鲲鹏 C2000-MAX 原厂固件（C2000-788）** 之外，其他环境一律**不保证可用**。

## 仓库目标

本仓库的业务目标只有两个：

1. 编译 `luci-app-openclash`
2. 编译 `luci-app-zerotier`

说明：

- `luci-app-openclash` 使用 `vernesong/OpenClash` 官方源码
- `luci-app-zerotier` 使用 `shidahuilang/openwrt-package` 中的源码
- 由于 `luci-app-zerotier` 只是 LuCI 页面，实际发布时会**额外附带** `zerotier` 运行时 IPK
- 这个额外的 `zerotier` 包只是为了让 `luci-app-zerotier` 能正常工作，**不改变本仓库“只服务两个插件”的定位**

## 编译原则

- 编译 SDK 固定使用：`OpenWrt 21.02.7 / aarch64_cortex-a53`
- 只构建**用户态 IPK**
- **不构建任何 kmod**
- 只为当前这台 **鲲鹏 C2000-MAX 原厂固件（型号 C2000-788）** 做兼容适配

这样做是为了尽量兼容原厂固件当前的 ABI，并避免错误分发与内核 ABI 强绑定的模块包。

## 工作流说明

### 1. `build-c200max-mt7987-ipk`
通用构建工作流。

用途：
- 手动编译当前仓库默认配置对应的 IPK
- 默认只构建，不自动发版
- 如需手动发布 Release，可开启 `publish_release`
- 如果开启发布且不填写 `release_tag`，会自动按版本规则生成版本号

### 2. `release-c200max-versioned-ipk`
正式发版工作流。

用途：
- 拉取当前配置对应的最新上游源码
- 自动编译最新 IPK
- 自动创建或更新**版本号 Release**

#### 版本规则

- 第一版从：`1.0.0` 开始
- 以后每次点击运行：
  - 如果**不指定版本号**，则自动在当前最新版本的 **patch** 位 `+1`
  - 例如：`1.0.0 -> 1.0.1 -> 1.0.2`
- 如果你**手动指定版本号**，则使用你指定的版本号
  - 例如：`1.2.0`

也就是说：

- 默认自动递增版本
- 特殊情况下你也可以手动指定版本号

## 默认产物

默认会产出以下文件：

- `luci-app-openclash_*.ipk`
- `luci-app-zerotier_*.ipk`
- `zerotier_*.ipk`（作为 `luci-app-zerotier` 的运行时依赖）
- `Packages`
- `Packages.gz`
- `SHA256SUMS`
- `BUILD_INFO.txt`
- `RELEASE_NOTES.md`

## 重要限制

请务必注意：

- 本仓库**只针对 鲲鹏 C2000-MAX 原厂固件（型号 C2000-788）**
- 本仓库**只围绕 OpenClash 和 ZeroTier 这两个插件**
- 不承诺支持其他机型
- 不承诺支持第三方 OpenWrt 固件
- 不承诺支持其他内核版本
- 不承诺支持其他 target / board / ABI

如果你的环境不是上面列出的原厂固件，请不要直接使用本仓库产物。