<div align="center">
  <img src="Resources/AppIcon.icns" width="120" alt="HoverFocus">
  <h1>HoverFocus</h1>
  <p>鼠标悬停到窗口，键盘焦点就切过去 —— 不用点击。</p>
</div>

macOS 菜单栏小工具，用来替代有 bug 的 AutoFocus。中文界面，纯 Swift，无第三方依赖。

## 它解决什么

macOS 上键盘输入只会进当前前台 App。想在旁边的窗口里打字，得先点它一下—— 而这一下点击可能顺带把窗口顶上来，把你的布局搅乱。

HoverFocus 让鼠标停在哪个窗口上，键盘焦点就切到那个窗口。**默认不改变窗口叠放顺序**。

## 安装

下载 dmg，双击挂载，把 `HoverFocus.app` 拖进「应用程序」。

**不需要授予任何权限，装完即用。**

> dmg 用自签证书签名（不是 Apple Developer ID）。首次打开若提示「无法验证开发者」，
> 右键点 app → 打开 → 再确认一次。这是自签分发的固有限制。

<details>
<summary>或者自己构建</summary>

```bash
git clone https://github.com/djjjs22/HoverFocus.git
cd HoverFocus && make install
```

`make install` 会依次：创建自签证书 → 构建 → 停掉旧实例 → 装到 `/Applications` → 启动。
</details>

## 和 AutoFocus 的区别

| | AutoFocus | HoverFocus |
|---|---|---|
| 焦点切换 | 会顺带置顶窗口 | **默认只切焦点，不动叠放顺序** |
| 误触发 | 手划过就抢 | **dwell 延时 + 动作后冷却** |
| 排除某些 App | 无 | **排除名单**，一键排除当前 App |
| 全屏 / 其他 Space | 可能乱跳 | **全屏守卫** |
| 拖拽中 | 可能抢 | **拖拽守卫** |
| 权限 | 需要辅助功能 | **默认零权限可用** |

## 几个设计决定

**默认零权限。** 每 16ms 读一次光标位置，纯读取系统状态，不需要任何授权。授权是可选的精度增强（用 AX 命中测试解决窗口重叠、圆角、透明区域判不准），不是使用前提。

**焦点和叠放拆开。** 切焦点走私有 SkyLight `_SLPSSetFrontProcessWithOptions`，只改前台顺序不动窗口 z 序。符号不可用时会退回公开 API 并在诊断里**如实**报告「置顶了 = 是」，不会假装成功。

**主动承认不知道。** 下面这些限制都写在了文档里，没有藏着：

- 未授权时用窗口列表判断命中，窗口重叠 / 圆角 / 阴影可能判错
- 「低延迟」模式是否真比轮询更跟手，**没做过端到端对比**，所以默认仍用轮询
- 拖拽守卫用系统键状态，极短促的拖拽理论上可能漏判

## 开发

```bash
make app     # 构建 build/HoverFocus.app
make test    # 116 用例 / 281 断言
make dmg     # 打包 dist/HoverFocus-0.1.0.dmg
make dmg-verify  # 挂载 dmg 实测：结构 / 签名 / 拖拽后能不能跑
```

不用 `swift build` / `swift test` —— 本机 Command Line Tools 安装不一致，`ManifestAPI` 的 `.dylib` 不导出 `PackageDescription.swiftmodule` 需要的符号，SwiftPM 会在编译 manifest 阶段就失败。所以用一条 `swiftc` 命令单模块编译，测试是手写运行器。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/README-full.md](docs/README-full.md) | 完整文档：全部设置项、权限细节、代码签名、排障表、17 步判定契约 |
| [docs/VERIFICATION.md](docs/VERIFICATION.md) | 验证报告：每个结论标注「实测通过 / 仅单测覆盖 / 未验证」 |
| [docs/DMG-README.txt](docs/DMG-README.txt) | 打进 dmg 里的使用说明 |

验证报告里不把「没测的」写成「通过」。目前 116 个用例 / 281 个断言 / 0 失败，端到端悬停测试连跑三轮 z 序均未变化。

## 目录

```
Sources/HoverFocus/       菜单栏 App：UI、设置窗口、权限引导、自检
Sources/HoverFocusCore/   契约层与核心：判定引擎、窗口探测、事件源、激活策略
Scripts/                  build / install / make-dmg / test
Tools/                    探针、dmg 验证
docs/                     完整文档与验证报告
```

## 许可

自用工具，暂未指定开源许可。