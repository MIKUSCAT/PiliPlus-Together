# 构建一起看 Android 版

本分支保留原版所需的 Flutter / material_ui 补丁。请使用专门的 Flutter checkout，避免影响其他项目。已使用 Flutter 3.47.9、Dart 3.13.7、Java 21、Android SDK 37 和 NDK 28.2.13676358 构建。

## 环境与依赖

```powershell
git clone --depth 1 --branch 3.47.9 https://github.com/flutter/flutter.git C:\dev\piliplus-flutter
$env:FLUTTER_ROOT = 'C:\dev\piliplus-flutter'
$env:PUB_CACHE = 'C:\dev\piliplus-pub-cache'
$env:ANDROID_HOME = 'E:\AndroidSDK'
$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot'
& "$env:FLUTTER_ROOT\bin\flutter.bat" config --android-sdk $env:ANDROID_HOME --no-analytics --no-enable-windows-desktop
.\tool\setup_flutter.ps1 -FlutterRoot $env:FLUTTER_ROOT -PubCache $env:PUB_CACHE
```

按实际安装位置修改路径。`setup_flutter.ps1` 只应用必要补丁，并为当前进程开启 Git 长路径支持；可以重复执行。不要在修改过的 SDK 上运行原版的重置脚本。

Android SDK 需要 command-line tools、platform-tools、`platforms;android-37.0`、`build-tools;37.0.0` 和 `ndk;28.2.13676358`。先用 `sdkmanager --licenses` 接受许可。

## 本地测试和调试包

```powershell
& "$env:FLUTTER_ROOT\bin\flutter.bat" analyze --no-pub --no-fatal-infos
& "$env:FLUTTER_ROOT\bin\flutter.bat" test --no-pub test/watch_together
.\tool\build_android.ps1 -Debug -TargetPlatform android-x64
cd server
npm ci
npm test
```

Windows 的 Flutter 测试还需要可被 `vswhere` 识别的 Visual Studio C++ Build Tools 和 Windows SDK，因为原版依赖包含桌面原生库。仅构建 Android 不需要 Visual Studio。GitHub 的 **Together checks** 会在完整的 Windows 构建环境运行客户端和布局测试。

`build_android.ps1` 在 Windows 上为当前构建禁用 Kotlin 增量缓存，避免 Pub cache 与项目位于不同盘符时的路径错误。没有改变 Android 的运行行为。

## 正式签名和 APK

生成并妥善保管自己的 keystore，创建 `android/key.properties`：

```properties
storeFile=C:/private/piliplus-together-release.jks
storePassword=你的签名库密码
keyAlias=piliplus-together
keyPassword=你的密钥密码
```

```powershell
.\tool\build_android.ps1
```

输出位于 `build/app/outputs/flutter-apk/`。脚本从 pubspec 读取版本号，写入版本、构建时间和提交号，生成 ARM64、ARMv7 和 x86_64 APK。大部分手机选择 ARM64。应用 ID 为 `com.example.piliplus.together`，可与原版并存。

可选 `-ServerUrl https://watch.example.com` 预填服务地址；不传时由使用者首次配置。不要将签名密钥或 `key.properties` 放进 Git、发布附件或日志；此仓库已忽略这些文件。后续升级必须使用同一签名密钥并递增 pubspec 的 `+版本号`。

## 可复现的发布材料

- **Together checks**：服务端测试、Flutter 分析、同步与布局测试，附面板预览图。
- **Together server images**：手动触发，构建并实际启动 amd64 / arm64 镜像，验证健康接口后导出 tar.gz。
- 原版多平台工作流保留用于参考；本次分支交付和验证范围为 Android。

发布时把正式 APK、两种服务器镜像、`server/deploy` 的配置压缩包和 SHA256 校验文件放到同一个 Release；源代码 tag 应对应实际构建的提交。
