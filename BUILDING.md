# 构建

## 环境

使用 [FVM](https://fvm.app/) 管理 Flutter 版本。Linux 构建环境需要 Python 3.11+、Go 1.25.8、JDK 21、Android SDK 36 和 NDK 28.0.13004108。

将 `JAVA_HOME` 指向 JDK 21，并在 `android/local.properties` 中配置本机 SDK 路径。

## 调试构建

```sh
fvm install
fvm flutter pub get --enforce-lockfile
fvm flutter build apk --debug --target-platform android-arm64 --no-pub
```

构建产物为 `build/app/outputs/flutter-apk/app-debug.apk`。

## Android 发布

在仓库的 GitHub Actions Secrets 中配置用于正式发布的签名密钥：

- `ANDROID_KEYSTORE_BASE64`：keystore 文件的单行 Base64 内容（例如 `base64 -w0 release.keystore`）。
- `ANDROID_KEY_PROPERTIES`：按 Java properties 格式填写 `keyAlias`、`keyPassword` 和 `storePassword`，每项一行；工作流会填写 `storeFile`。

推送指向含此工作流提交的 `vX.Y.Z` 标签即可触发发布。标签须与 `pubspec.yaml` 的版本名一致，例如 `0.1.0+1` 对应 `v0.1.0`。工作流运行 `tool/release.sh`，验证 APK 签名，将 `Utabako-vX.Y.Z-arm64-v8a.apk` 和对应的 `.sha256` 发布到 GitHub Releases。

## 原生内核

Gradle 会从固定的 [Utabako Core](https://github.com/Utabako/utabako-core) 提交构建原生内核，并从 NDK 获取 C++ 运行库。源码和工具缓存在 `.dart_tool/libbox/`，AAR、运行库及构建记录生成至 `build/app/libbox/`。固定源码、工具版本和构建标签见 [tool/libbox.json](tool/libbox.json)。

## Linux TUN 诊断原型

使用 Go 1.25.8、C/C++ 编译器、Python 3、`jq` 和 FVM，运行 `bash tool/linux_tun/build.sh`。产物位于 `build/linux-tun/`：`boxdd` 监督进程、`boxdd-core` 内核、`diagnostics` 和 `web/`。

请在专用虚拟机或隔离网络命名空间运行 TUN。启动 `boxdd run --working-directory <状态目录> --socket <套接字>` 后，用 `diagnostics -socket <套接字> start <配置文件>` 导入并启动配置；用 `diagnostics -socket <套接字> stop` 正常断开。

用 `diagnostics -socket <套接字> serve <web目录> 127.0.0.1:8766 <新链接文件>` 打开诊断服务。在本机浏览器打开链接文件中的私有地址。日志时间为诊断服务接收时间。

在支持无特权用户命名空间并装有 `ip`、`nft`、`curl` 和 `dig` 的 Linux 上，运行 `bash tool/linux_tun/check_recovery.sh` 可在隔离网络中验证正常停止与强杀内核后的网络恢复。`boxdd` 会在内核退出后清理本次运行创建的路由规则和 nftables 对象，再返回内核退出状态。原型支持同一网络命名空间内的单个原生 TUN；自动重定向使用 nftables。监督进程也被强杀、或整组进程被强杀的场景尚未接入恢复。
