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

## 原生内核

Gradle 会从固定的 [Utabako Core](https://github.com/Utabako/utabako-core) 提交构建原生内核，并从 NDK 获取 C++ 运行库。源码和工具缓存在 `.dart_tool/libbox/`，AAR、运行库及构建记录生成至 `build/app/libbox/`。固定源码、工具版本和构建标签见 [tool/libbox.json](tool/libbox.json)。
