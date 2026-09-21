# LoveACE Linux AppImage 构建与发布管线

本文档梳理 Linux 桌面端 AppImage 从源码构建、CI 打包到 OTA 发布的完整管线。

## 1. 概览

LoveACE 桌面端基于 Flutter，Linux 产物以 **AppImage** 形式分发。管线分为两个阶段：

1. **构建阶段**：`flutter build linux --release` 生成原生 bundle，再用 `appimagetool` 打包为自解压 AppImage。
2. **发布阶段**：AppImage 上传到 S3，经 `utils/manifest_v2` 写入 v2 / 兼容 OTA 清单，最终通过 `https://release.loveace.top` 分发并被下载页与客户端 OTA 拉取。

```text
源码 (desktop/)
   │  flutter pub get / analyze
   ▼
flutter build linux --release
   │  build/linux/x64/release/bundle/
   ▼
desktop/appimage/build-appimage.sh
   │  组装 AppDir + appimagetool
   ▼
desktop/build/appimage/LoveACE-<version>-x86_64.AppImage
   │
   ├──(dry_run=true)  上传为 CI artifact，到此为止
   │
   └──(dry_run=false) utils/manifest_v2/cli.py release --platform linux
        │  S3: loveace/releases/linux/<version>/<build>/<file>
        ▼
      CDN https://release.loveace.top + manifest_v2.json / manifest.json
```

## 2. 关键文件与职责

| 文件 | 职责 |
| --- | --- |
| `desktop/appimage/build-appimage.sh` | 本地/CI 复用的 AppImage 构建脚本（版本读取、构建、打包一体） |
| `desktop/appimage/io.github.yeningyuan08.LoveACE.png` | 512×512 透明底应用图标（由仓库 `assets/logo.png` 生成） |
| `.github/workflows/build-desktop-linux-appimage.yml` | 手动触发的构建 + 发布工作流 |
| `desktop/io.github.yeningyuan08.LoveACE.desktop` | Linux 桌面项（`Exec=loveace`、`StartupWMClass=loveace`） |
| `desktop/io.github.yeningyuan08.LoveACE.metainfo.xml` | AppStream 元数据（应用商店/软件中心展示） |
| `utils/manifest_v2/cli.py` | 发布 CLI：上传产物 + 维护 v2 / 兼容 OTA 清单 |
| `utils/manifest_v2/manifest.py` | 清单数据模型与校验（含 `NATIVE_ARTIFACT_TYPES`） |

## 3. 本地构建

前置条件：Flutter stable（Linux desktop 已启用）、`clang`、`cmake`、`ninja-build`、`pkg-config`、`libgtk-3-dev`、`liblzma-dev`、`libsecret-1-dev`。

```bash
desktop/appimage/build-appimage.sh
```

脚本内部流程：

1. 从 `desktop/pubspec.yaml` 读取 `version`（如 `1.1.12`）。
2. `flutter pub get`。
3. `flutter build linux --release`（可选注入 `ANALYTICS_*` dart-define）。
4. 若 `appimagetool` 不存在，自动下载并缓存到 `desktop/appimage/appimagetool-x86_64.AppImage`。
5. 若图标缺失，用 Pillow 从 `assets/logo.png` 重建（仓库已内置图标，CI 无需 Pillow）。
6. 组装 AppDir 并用 `appimagetool` 打包。

产物：

```text
desktop/build/appimage/LoveACE-<version>-x86_64.AppImage
```

> AppImage 依赖宿主机 GTK3 运行时（主流 Linux 桌面均自带）；当前不做 GTK 全量静态捆绑，以控制体积（约 25 MB）。

### 可选环境变量

`ANALYTICS_ENDPOINT`、`ANALYTICS_API_KEY`、`ANALYTICS_SIGNING_SECRET`、`ANALYTICS_HASH_SALT` —— 与 macOS/Windows 工作流一致，未设置时使用默认/空值。

## 4. CI 工作流

工作流名：`Build Linux AppImage`，通过 `workflow_dispatch` 手动触发。

### 输入参数

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `dry_run` | boolean | `true` | `true` 仅构建并上传 artifact；`false` 追加执行发布 |
| `changelog` | string | `""` | 发布更新日志 |
| `content` | string | `""` | OTA 弹窗内容 |
| `force` | boolean | `false` | 强制 OTA 更新（设置 `minimum_supported_build`） |

### Job 1：`build`

- `runs-on: ubuntu-latest`
- Flutter `3.44.2` stable（`subosito/flutter-action`）
- 安装 Linux 桌面构建依赖
- 读取版本号，输出 `version` / `build` / `artifact_name=loveace-linux-<version>-<build>`
- `flutter pub get` → `flutter analyze` → `build-appimage.sh`
- 上传 AppImage artifact

### Job 2：`upload-manifest`（仅 `dry_run == false`）

- `needs: build`，`environment: S3`，并发组 `loveace-manifest-publish`（跨桌面端串行化发布）
- 下载 AppImage artifact
- 执行：

```bash
uv run python cli.py release \
  --version <version> --build <build> --platform linux --arch x86_64 \
  --file ../../appimage/LoveACE-<version>-x86_64.AppImage \
  --content "<content>" --changelog "<changelog>" [--force]
```

### 使用的 Secrets / 环境

| 名称 | 用途 |
| --- | --- |
| `ANALYTICS_API_KEY` / `ANALYTICS_SIGNING_SECRET` / `ANALYTICS_HASH_SALT` | 编译期注入的匿名统计密钥 |
| `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` / `S3_BUCKET` / `S3_REGION` | 产物与清单上传 |
| `CDN_BASE_URL` | 固定 `https://release.loveace.top` |

## 5. 发布阶段细节

`cli.py release` 的完整行为：

1. `infer_artifact_type()` 依据文件后缀判定产物类型；AppImage 对应 `appimage`（已加入 `NATIVE_ARTIFACT_TYPES`）。
2. 上传到 S3，对象键固定为：

   ```text
   loveace/releases/linux/<version>/<build>/LoveACE-<version>-x86_64.AppImage
   ```

3. 校验下载 URL 必须以 `https://release.loveace.top/loveace/releases/` 开头（原生产物必须走规范 CDN）。
4. 生成 `Release` 记录（版本、构建号、大小、SHA-256 / MD5 校验和、arch），写入 `linux` 平台清单。
5. `save_manifest_outputs()` 同时输出：
   - `manifest_v2.json`（v2 清单）
   - `manifest.json`（兼容 v1 OTA 清单）
6. 下载页 `download.html` 已内置 `linux` 平台图标与操作系统检测，直接读取清单展示 Linux 产物。

## 6. 触发方式

```bash
# 仅构建 + 上传 artifact
gh workflow run build-desktop-linux-appimage.yml --ref main

# 完整发布到 release.loveace.top
gh workflow run build-desktop-linux-appimage.yml \
  --ref main \
  -f dry_run=false \
  -f changelog="更新内容" \
  -f content="发现新版本" \
  -f force=false
```

## 7. 注意事项

- **AppDir 布局**：Flutter bundle 需保持二进制、`lib/`、`data/` 的相对结构不变，否则 `$ORIGIN/lib` 与资源定位会失效；`AppRun` 负责以 bundle 内二进制启动。
- **产物类型**：发布 AppImage 前，`NATIVE_ARTIFACT_TYPES`（`manifest.py` 与 `cli.py` 各一份）必须包含 `appimage`，否则 `release` 会报 `unsupported release artifact`。当前已补齐。
- **并发发布**：三个桌面端（macOS / Windows / Linux）共享 `loveace-manifest-publish` 并发组，避免同时写清单互相覆盖。
- **Flathub**：Flathub 打包（`flathub.io.github.yeningyuan08.LoveACE.json` 及截图）是独立于 AppImage 的另一个分发渠道，本管线不涉及；相关历史提交见 `backup/flathub-packaging` 分支。

## 8. Flatpak 打包管线（本地，2026-09 更新）

在 AppImage 之外，Flatpak 打包已落地为可复跑的本地管线，产物与 Flathub 规范一致。

### 关键文件

| 文件 | 职责 |
| --- | --- |
| `flathub.io.github.yeningyuan08.LoveACE.json` | Flatpak manifest（app-id `io.github.yeningyuan08.LoveACE`，runtime 24.08 + llvm20 扩展） |
| `.flatpak-chroot-bin/` | chroot 构建脚手架（SDK 根文件系统装配 + 模块构建脚本 + 挂载拆卸） |
| `.flatpak-app/` | `flatpak build-init` 初始化的 app 构建树（`files/` 即沙箱 `/app`） |
| `.flatpak-repo/` | OSTree 仓库（`build-export` 目标） |
| `.flatpak-builder/downloads/` | 离线源码缓存（flutter 3.44.2 与 libsecret 0.21.7 tarball） |
| `.flatpak-pub-cache/` | 离线 pub 缓存（`flutter pub get --offline` 用） |
| `.flutter-sdk/` | flutter 3.44.2 SDK 解包目录 |

### 构建流程（chroot 回退方案）

环境里 flatpak 的 bwrap 沙箱不可用（`flatpak run` 报 "无法执行二进制文件"）时，用
`sudo chroot --userspec=1000:1000` + bind-mount 复刻 flatpak-builder 的 SDK 环境
（glibc 2.40），避免宿主 glibc 2.44 链接产物无法在 runtime 中运行：

```bash
flatpak build-init .flatpak-app io.github.yeningyuan08.LoveACE \
  org.freedesktop.Sdk org.freedesktop.Platform 24.08
.flatpak-chroot-bin/setup-mounts.sh          # SDK/proc/dev/tmp/workspace/app 挂载
sudo chroot --userspec=1000:1000 .flatpak-rootfs /chroot-bin/build-inside.sh
.flatpak-chroot-bin/teardown-mounts.sh       # 拆卸挂载
flatpak build-finish --command=loveace --share=network --share=ipc \
  --socket=wayland --socket=fallback-x11 --device=dri \
  --talk-name=org.freedesktop.secrets --filesystem=xdg-download .flatpak-app
flatpak build-export .flatpak-repo .flatpak-app
flatpak build-bundle .flatpak-repo LoveACE-<version>-x86_64.flatpak \
  io.github.yeningyuan08.LoveACE
```

`build-inside.sh` 依次完成：libsecret 0.21.7（meson，`crypto=libgcrypt`，装到 `/app/lib`）→
`flutter pub get --offline` → `flutter build linux --release --no-pub` → 安装 bundle /
图标 / desktop / metainfo 到 `/app`。clang 以 `exec gcc` 包装脚本提供（llvm20 的 clang
与 SDK 自带 libstdc++ 组合有兼容问题，gcc 包装是既往验证过的做法）。

### 产物与校验

```text
LoveACE-<version>-x86_64.flatpak   # 单文件 bundle，可直接 flatpak install
```

当前产物：`LoveACE-1.1.12-x86_64.flatpak`（22.4 MB，
sha256 `b49f3b2eab7b1e010176b51762a865eb730e0e754f86edf7f396a628a9304005`），
已验证可 `flatpak install --user`，app-id `io.github.yeningyuan08.LoveACE`。

### 注意事项

- **图标尺寸**：`assets/images/logo.png` 为 600×600，超过 `hicolor/512x512` 上限，
  `build-export` 会以 `Image too large` 拒绝；必须使用仓库内置的
  `desktop/appimage/io.github.yeningyuan08.LoveACE.png`（512×512 透明底）。
- **build-finish 暂存**：`build-finish` 会把 `files/` 复制到 `.flatpak-app/export/`；
  修完 `files/` 后务必删除 `export/` 重跑 finish，否则导出的仍是旧文件。
- **宿主机构建产物不可混用**：宿主（glibc 2.44）编译的 bundle 只能用于宿主验证，
  打包前须删除 `desktop/build/`、`desktop/.dart_tool/`，让 chroot 内全新编译。
- 若宿主 flatpak 沙箱恢复正常，可直接 `flatpak-builder --user --force-clean
  --disable-rofiles-fuse --repo=.flatpak-repo .flatpak-build
  flathub.io.github.yeningyuan08.LoveACE.json`，效果等价。
