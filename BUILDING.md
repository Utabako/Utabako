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
