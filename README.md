# c2000max-ipk

基于 GitHub Actions 的 OpenWrt IPK 自动编译仓库，目标固定为：

- OpenWrt `21.02.7`
- 架构 `aarch64_cortex-a53`
- 上游源码仓库 `shidahuilang/openwrt-package`

## 仓库内容

- `.github/workflows/build-openwrt-ipk.yml`
  - 负责拉起 OpenWrt SDK 容器、编译包、上传产物，并可按需自动发布 GitHub Release
- `scripts/build-ipk.sh`
  - 在 OpenWrt SDK 容器内执行的实际编译脚本
- `config/target.env`
  - 固定目标版本、架构、SDK 镜像和上游仓库参数
- `config/packages.txt`
  - 默认待编译包列表（当前预置 `luci-app-openclash` 与 `luci-app-zerotier`）

## 使用方式

### 方式 1：直接推送触发默认构建

推送到 `master` 或 `main` 分支后，会自动按 `config/packages.txt` 中的包列表执行构建。

### 方式 2：手动触发 GitHub Actions

在仓库 Actions 页面运行 `build-openwrt-21.02.7-a53-ipk`，可选输入：

- `packages`
  - 待编译包目录，相对 `https://github.com/shidahuilang/openwrt-package`
  - 支持逗号、空格或换行分隔
- `source_ref`
  - 上游源码分支/标签/提交，默认 `Lede`
- `publish_release`
  - 是否创建或更新 GitHub Release
- `release_tag`
  - Release 标签；留空会自动生成

### 方式 3：维护默认包清单

编辑 `config/packages.txt`，每行填写一个要编译的包目录。当前默认已经预置：`luci-app-openclash`、`luci-app-zerotier`。

如果 `workflow_dispatch` 没有填写 `packages` 输入，工作流会自动读取这个文件。

## 产物说明

工作流结束后会产出：

- `*.ipk`
- `Packages`
- `Packages.gz`
- `SHA256SUMS`
- `BUILD_INFO.txt`

如果开启 `publish_release`，这些文件也会被上传到 GitHub Release，便于直接下载或作为自建 feed 使用。

## 注意事项

- `config/packages.txt` 里的路径必须对应上游仓库中的真实目录。
- 如果某些包依赖同仓库里的其他自定义包，请把相关目录一起加入清单。
- 如果上游包之间本身存在互斥关系，请不要放在同一次构建里。
