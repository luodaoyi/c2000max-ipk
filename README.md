# c2000max-ipk

基于 GitHub Actions 的 OpenWrt IPK 自动编译仓库，目标设备固定为：

- 设备 `HC-WT9303`
- 板型 `HCMT7987-SNSD`
- 原厂固件 `OpenWrt 21.02-SNAPSHOT 2.1.2.n0.c1`
- Target `mediatek/mt7987`
- 架构 `aarch64_cortex-a53`
- 内核 `5.4.281`

其中：

- **编译 SDK** 仍固定使用官方 `OpenWrt 21.02.7 / aarch64_cortex-a53`
- **只构建用户态 IPK**
- **不构建任何 kmod**

这样做是为了尽量兼容这台设备当前的厂商固件 ABI，同时避免错误分发与内核 ABI 强绑定的模块包。

## 当前默认构建目标

- `luci-app-openclash`
  - 使用 `vernesong/OpenClash` 官方源码
- `luci-app-zerotier`
  - 使用 `shidahuilang/openwrt-package` 源码
- `zerotier`
  - 使用 SDK 官方 `packages` feed 中的 `net/zerotier`

之所以这样配置，是因为：

- `shidahuilang/openwrt-package` 当前并不存在 `luci-app-openclash` 目录
- `luci-app-zerotier` 只是 LuCI 页面，**真正运行 ZeroTier 还必须有 `zerotier` 本体包**
- `zerotier` 本体优先从 SDK 官方 feed 构建，尽量减少与 SDK 自身 feeds 的偏差

## 仓库内容

- `.github/workflows/build-openwrt-ipk.yml`
  - 通用构建工作流，可手动运行，也可被其他 workflow 复用
- `.github/workflows/release-latest-ipk.yml`
  - 一键 latest release 工作流；点击后会自动拉最新上游源码、编译并更新固定 `latest` Release
- `scripts/build-ipk.sh`
  - 在 OpenWrt SDK 容器内执行的实际编译脚本
- `config/target.env`
  - 固定设备元数据、SDK 镜像和默认源码仓库参数
- `config/packages.txt`
  - 默认待编译包列表，支持“包目录 + 源码仓库 + 分支/标签”三段式配置，也支持直接引用 SDK 官方 feed

## `config/packages.txt` 格式

每行一条，支持三种写法：

1. 仅写包目录：

```text
luci-app-zerotier
```

2. 显式指定源码：

```text
luci-app-openclash|https://github.com/vernesong/OpenClash.git|master
```

3. 使用 SDK 官方 feed：

```text
net/zerotier|sdk://packages|builtin
```

格式为：

```text
package_dir|source_url|source_ref
```

如果只写 `package_dir`，会自动使用 `config/target.env` 里的默认源码仓库与分支。

其中 `sdk://packages` 表示直接使用 SDK 已配置的官方 `packages` feed。

## 使用方式

### 方式 1：直接推送触发默认构建

推送到 `master` 或 `main` 分支后，会自动按 `config/packages.txt` 中的包列表执行构建。

### 方式 2：手动运行通用构建工作流

在仓库 Actions 页面运行 `build-c200max-mt7987-ipk`，可选输入：

- `packages`
  - 待编译包目录；支持换行输入
  - 支持：
    - `luci-app-zerotier`
    - `luci-app-openclash|https://github.com/vernesong/OpenClash.git|master`
    - `net/zerotier|sdk://packages|builtin`
- `source_ref`
  - 默认源码分支/标签/提交，默认 `Lede`
- `publish_release`
  - 是否创建或更新 GitHub Release
- `release_tag`
  - Release 标签；留空会自动生成

### 方式 3：一键发布 latest release

在仓库 Actions 页面运行 `release-c200max-latest-ipk`：

- 无需填写参数
- 会自动拉取当前默认配置对应的**最新上游源码**
- 自动编译最新 IPK
- 自动更新固定标签的 GitHub Release：`latest`

适合你平时点一下就刷新 Release。

## 产物说明

工作流结束后会产出：

- `*.ipk`
- `Packages`
- `Packages.gz`
- `SHA256SUMS`
- `BUILD_INFO.txt`
- `RELEASE_NOTES.md`
- `build.log`（便于排障）

如果开启 `publish_release`，Release 中会上传：

- `*.ipk`
- `Packages`
- `Packages.gz`
- `SHA256SUMS`
- `BUILD_INFO.txt`
- `RELEASE_NOTES.md`

## 注意事项

- `package_dir` 必须对应各自源码仓库中的真实目录。
- `zerotier` 建议始终与 `luci-app-zerotier` 一起构建和发布。
- 本仓库面向当前这台 `mt7987 / 5.4.281` 设备，只建议分发用户态 IPK。
- 如果某些包依赖同仓库里的其他自定义包，请把相关目录一起加入清单。
- 如果上游包之间本身存在互斥关系，请不要放在同一次构建里。