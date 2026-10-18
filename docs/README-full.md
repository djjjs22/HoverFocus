# HoverFocus

**鼠标悬停到窗口，键盘焦点就切过去 —— 不用点击。**

一个 macOS 菜单栏小工具，用来替代有 bug 的 AutoFocus。中文界面，`LSUIElement`（只在菜单栏，没有 Dock 图标）。

---

## 它解决什么问题

在 macOS 上，键盘输入只会进「当前前台 App」。你想在旁边的窗口里打字，必须先点一下它 —— 这一下点击可能还会把窗口置顶、打乱你的布局。

HoverFocus 让鼠标停在哪个窗口上，键盘焦点就跟着切到那个窗口。**默认不改变窗口叠放顺序**，所以布局不会被打乱。

---

## 和 AutoFocus 的区别

| | AutoFocus | HoverFocus |
|---|---|---|
| 焦点切换 | 会顺带置顶窗口 | **默认只切焦点，不动窗口叠放**（可选开启置顶） |
| 误触发 | 手划过就抢 | **dwell 悬停延时 + 动作后冷却**，划过不会抢 |
| 排除某些 App | 无 | **排除名单**，一键排除当前 App |
| 全屏 / 其他 Space | 可能乱跳 | **全屏守卫**，只在当前可见窗口上动作 |
| 拖拽中 | 可能抢 | **拖拽守卫**，拖窗口/拖选文字时完全不动 |
| 权限 | 需要辅助功能 | **默认零权限可用**；授权只是精度增强 |

---

## 安装

```bash
cd "hover-focus"
make install
```

`make install` 会依次：创建自签证书 → 构建 → 停掉旧实例 → 装到 `/Applications/HoverFocus.app` → 打印权限说明 → 启动。

- **不会碰 `/Applications/AutoFocus.app`**。脚本只操作 `HoverFocus.app`。
- 如果 `/Applications/HoverFocus.app` 已存在，会先问你要不要覆盖（旧版本备份成 `.bak`）。
- 想装完不自动启动：`bash Scripts/install.sh --no-launch`
- 不想被问：`bash Scripts/install.sh --yes`

装好后菜单栏会出现一个 HoverFocus 图标。**不需要授予任何权限，直接就能用。**

### 开发时用

```bash
make app        # 只构建，产物 build/HoverFocus.app
make run        # 构建并启动
make kill       # 停掉正在跑的 HoverFocus
make clean      # 删掉 build/
```

### 打成 dmg（给别人用 / 留档）

```bash
make dmg-build    # 重新构建 + 打包 → dist/HoverFocus-0.1.0.dmg（620K）
make dmg          # 只打包，沿用现有 build/HoverFocus.app
make dmg-verify   # 挂载 dmg 实测：结构 / 隐藏标记 / 签名 / 拖拽后能不能跑
```

dmg 里是 `HoverFocus.app` + 一个指向 `/Applications` 的软链接 + `使用说明.txt`，
双击挂载后把 app 拖进「应用程序」就行。

**签名与分发的如实说明**：这个 dmg 用的是 `make-signing-cert.sh` 的**自签证书**
（`Authority = HoverFocus Dev`），**不是** Apple Developer ID，也没有公证。

- 在你自己机器上：完全没影响，辅助功能授权也不会失效（DR 基于证书指纹）。
- 拷给别人：对方首次打开会被 Gatekeeper 拦（提示「无法验证开发者」），
  需要**右键点 app → 打开**再确认一次。这是自签分发的固有限制，不是 bug。
- 要彻底解决，需要 Apple Developer Program 账号（$99/年）签 Developer ID
  并提交公证。本机没有 Xcode，也没配公证凭据，这条路现在走不通。

`Scripts/make-dmg.sh` 头部有同样的一段说明。

---

## 关于权限（重要：默认不需要）

HoverFocus 有两种「鼠标事件来源」，默认用的是**不需要任何权限**的那种。

### 默认：轮询模式（零权限）

每 16ms 读一次光标位置。纯读取系统状态，**不需要任何授权**，装完即用。

- 最坏延迟一个轮询周期（约 16ms），对「悬停切焦点」这件事完全无感。
- 没有 CGEventTap 被系统禁用的问题，也就没有「用一会儿就失灵」。

### 可选：授予「辅助功能」权限 = 精度增强

授权**不是使用前提**，它带来两件事：

1. **命中测试从「降级」升级为「精确」**
   - 不授权 → 用窗口列表判断鼠标在哪个窗口上。**分屏场景完全准确**；但窗口重叠、圆角、阴影、透明区域可能判错。
   - 授权后 → 用 AX 命中测试（`AXUIElementCopyElementAtPosition`），重叠和圆角都对。
   - 菜单里的「命中精度：精确 / 降级」会如实显示当前是哪种。
2. 可以另外选用**低延迟监听方式**（CGEventTap，见下）。

授权步骤：点菜单栏图标 →「授予辅助功能权限以提高命中精度（可选）…」→ 在 **系统设置 → 隐私与安全性 → 辅助功能** 里勾选 HoverFocus。

**授权后不需要重启**：程序每秒检查一次权限状态，1 秒内自动升级为精确模式。

### 可选：低延迟监听方式（需要权限）

菜单栏 →「监听方式」→「CGEventTap 低延迟」。事件驱动，没有轮询周期。

- **未授权时它完全收不到事件**（系统会静默丢弃所有鼠标事件，这是实测结论）。这时图标会变成警告态，菜单里会给一个「改回零权限的轮询模式」的一键回退。
- 如果勾了「辅助功能」还是收不到事件，去 **系统设置 → 隐私与安全性 → 输入监控** 里再勾一次 HoverFocus。菜单里也会提示这一点。

---

## 设置项说明

菜单栏图标 →「打开设置…」（`⌘,`）。所有改动**立刻生效并持久化**，不需要点保存。

### 总开关
关掉后悬停不切换焦点。菜单栏第一项也能直接切。

### 激活模式
- **只切焦点，不置顶**（默认）：键盘输入切过去，窗口叠放顺序不变。走私有 SkyLight `_SLPSSetFrontProcessWithOptions`；做不到时会退回公开 API 并**如实**在诊断里报告「置顶了 = 是」，不会假装成功。
- **切焦点并置顶窗口**：用 `NSRunningApplication.activate()`，窗口会浮到最前。

### 悬停延时（dwell，0–1000ms，默认 120ms）
指针要在**同一个窗口**上停住这么久才动手。
- 调大 → 更稳，鼠标划过不会误抢。
- 调小 → 更跟手。
- 中途移到别的窗口会重新计时。

### 动作后冷却（0.06–1.0s，默认 150ms）
一次动作之后这段时间内不再动作，防抖。
下限 0.06s 是硬下限：窗口探测有 50ms 缓存，冷却太小会出现「同一个窗口被反复聚焦」的动作风暴。

### 守卫（三个开关，默认全开）
- **按住修饰键（⌘/⌥/⌃/⇧）时不动焦点** —— 你在用快捷键时不要抢。
- **拖拽窗口 / 拖选文字时不动焦点** —— 拖拽过程中焦点乱跳非常难受。
- **前台 App 全屏时绝不抢焦点** —— 看视频/演示时不要乱跳。

### 排除名单
名单里的 App 永远不会被悬停抢焦点。
- 按 **Bundle ID** 匹配（如 `com.apple.Safari`），它是稳定的主键；App 显示名作为兜底。
- 最方便的用法：鼠标停在目标 App 上 → 点菜单栏 →「排除『Safari』（悬停不抢它的焦点）」。
- 设置窗口里可以「添加当前前台 App」「手动添加…」「移除选中」。
- 重启后依然有效（存在系统偏好里）。

### 监听方式
见上文「关于权限」。默认轮询。

---

## 诊断（出问题时先看这里）

菜单栏图标 →「诊断信息」，里面有：

- 版本、辅助功能权限、鼠标监听是否在运行、驱动错误
- 当前事件源（轮询 / 低延迟）与**命中精度**（精确 / 降级）
- SkyLight 私有符号是否可用（不可用时「不置顶」会退化成置顶）
- tick 定时器是否有效、CGEventTap 被系统禁用过几次
- **忽略原因计数** —— 「为什么没生效」直接看这里，原因都有中文解释：
  `总开关关闭` / `正在拖拽` / `按住修饰键` / `指针在菜单栏` / `指针下没有窗口` /
  `HoverFocus 自己的窗口` / `系统 UI` / `目标 App 被隐藏` / `非普通窗口` /
  `命中排除名单` / `已经是当前焦点窗口` / `冷却中` / `前台 App 全屏中` / `窗口不在当前 Space`
- 「复制完整诊断信息到剪贴板」

命令行看日志（用 subsystem 过滤最可靠 —— 用 `open` 启动时进程名会被截断成 `anon<HoverFocus>`）：

```bash
log show --last 2m --predicate 'subsystem == "com.lunasama.HoverFocus"' --style compact
```

生命周期事件（启动 / 权限状态 / 监听启停 / 退出）走 `lifecycle` category，判定与动作走 `decision` category。
日志级别用的是 `notice` 而不是 `info` —— os_log 的 info 级别默认不被 `log show` 显示（要加 `--info`），
而「用户双击启动后到底怎么了」看不到就等于没写。

---

## 自检模式

```bash
./build/HoverFocus.app/Contents/MacOS/HoverFocus --selftest
```

（装到 /Applications 之后：`/Applications/HoverFocus.app/Contents/MacOS/HoverFocus --selftest`）

不进入常驻模式，而是：创建菜单栏图标 → 等 1 秒 → 输出**一行 JSON** → 退出 0。

为什么需要它：本机 `screencapture` 被系统拒绝（没有屏幕录制权限），而 macOS 26+ 的菜单栏图标由 MenuBarAgent 合成、**不是独立窗口**，`CGWindowListCopyWindowInfo` 里查不到。所以「图标到底出没出来」只能靠进程内自查 `NSStatusItem.button?.window`。

输出示例：

```json
{"statusItemCreated":true,"buttonWindowVisible":true,"buttonWindowFrame":"1132.0,1122.0,33.0,30.0",
 "axTrusted":false,"version":"0.1.0","driverStarted":true,"error":null,
 "monitorMode":"polling","hitTestMode":"windowListFallback","iconState":"on"}
```

关键字段：
- `statusItemCreated` / `buttonWindowVisible` / `buttonWindowFrame` —— 图标真的建出来并显示了
- `axTrusted` —— 是否已授予辅助功能
- `driverStarted` —— **未授权时也应该是 `true`**（轮询模式零权限可用）
- `iconState` —— `on` / `off` / `permissionMissing` / `inputMonitoringMissing` / `error`
- `error` —— 自检本身的问题（正常为 `null`）

自检**不会抢你的焦点**：driver 启动成功后会立刻停止（毫秒级），并且这一步的说明会写进 `notes` 字段。

---

## 代码签名（为什么需要，以及怎么恢复）

### 问题
系统「辅助功能」授权是按**指定要求（Designated Requirement）**记账的。ad-hoc 签名的 DR 是 `cdhash H"..."` —— 每次重新编译 cdhash 都变，于是**每次 `make app` 之后你都要去系统设置里重新勾一遍 HoverFocus**。

### 解决
用自签证书签名，DR 变成：

```
identifier "com.lunasama.HoverFocus" and certificate leaf = H"<证书指纹>"
```

证书不变 → DR 不变 → **重新构建后授权依然有效**。

```bash
bash Scripts/make-signing-cert.sh          # 创建/修复（幂等，不需要 sudo，不弹框）
bash Scripts/make-signing-cert.sh --check  # 只检查是否可用
bash Scripts/make-signing-cert.sh --uninstall  # 删掉证书和钥匙串（可逆）
```

`build.sh` 会自动用它签名，并打印当前 DR，明确告诉你「重新构建后授权是否有效」。

实现上用了**专用钥匙串**（`~/Library/Keychains/hoverfocus-signing.keychain-db`）而不是登录钥匙串 —— 因为从登录钥匙串取私钥会弹出 SecurityAgent 的密码框，脚本会卡死。专用钥匙串的密码由脚本生成并存到 `~/Library/Application Support/HoverFocus/signing-keychain-password`（权限 0600），所以可以非交互解锁。证书**不需要**被系统信任，也不需要 sudo。

没创建证书时 `build.sh` 会退回 ad-hoc 并**明确警告**，不会静默降级。

---

## 为什么不用 `swift build` / `swift test`

本机 Command Line Tools 安装不一致：

```
/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/libPackageDescription.dylib  (Sep 2)
```

不导出 `PackageDescription.swiftmodule`（Oct 9）需要的符号，所以**任何** `swift build` / `swift test` / `swift package` 都会在编译 manifest 阶段链接失败。

所以本项目：

- 用 `Scripts/build.sh` 里**一条 `swiftc` 命令**编译，所有源文件编进**同一个模块** —— 因此源文件之间**不要**写 `import HoverFocusCore`。
- 没有 XCTest（跑不起来），测试是手写运行器。
- `make app` / `make test` / `make probe` 都绕开了 SwiftPM。

`build.sh` 里有一把**构建锁**（`build/.build.lock`，最多等 120 秒）：多个终端/多个 agent 同时构建会互相覆盖 `build/`，锁能挡住；编译失败时如果检测到源文件在编译期间被改动，会明确告诉你是「并发编辑」而不是「代码错误」。

---

## 已知限制（如实说明）

- **降级命中模式的精度**：未授予辅助功能时用窗口列表判断命中窗口，分屏场景准确，**窗口重叠 / 圆角 / 阴影 / 透明区域可能判错**。想要精确就授权。
- **低延迟模式（CGEventTap）**：已实测「授权后 tap 能创建且 `tapIsEnabled = true`」（即系统不再静默禁用，`--selftest` 在该模式下 `driverStarted=true`）；但**「它是否真的比轮询更跟手」没有做过端到端对比**，所以默认仍用轮询。
- **「不置顶」依赖私有 SkyLight 符号**（`_SLPSSetFrontProcessWithOptions`）。符号不存在时会退回公开 API，那时窗口会被置顶 —— 程序会**如实**在诊断里报「置顶了 = 是」，不会假装成功。诊断里能看到 `SkyLight 私有符号可用`。
- 拖拽守卫用的是系统键状态；极短促的拖拽（小于一个采样周期）理论上可能漏判。
- 全屏守卫判断的是「当前前台 App 是否全屏」；某些自绘全屏的应用可能识别不到。

---

## 目录结构

```
Sources/HoverFocus/          菜单栏 App：UI、设置窗口、权限引导、开机自启、自检
Sources/HoverFocusCore/      契约层与核心：判定引擎、窗口探测、鼠标事件源、激活策略
Scripts/build.sh             构建（含构建锁、签名校验）
Scripts/install.sh           安装到 /Applications
Scripts/make-dmg.sh          打包 dmg（含隐藏标记、拖拽软链接、完整性校验）
Scripts/make-signing-cert.sh 自签证书
Scripts/test.sh              手写测试运行器
Scripts/build-probe.sh       诊断探针
Tools/hf-probe/              探针源码
Tools/verify-dmg.sh          dmg 交付验证（挂载 → 拖拽 → 验签 → 跑自检）
docs/DMG-README.txt          打进 dmg 里的使用说明
docs/VERIFICATION.md         验证报告（哪些实测通过、哪些只是单测、哪些未验证）
```

---

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 菜单栏没有图标 | `log show --last 2m --predicate 'process == "HoverFocus"' --style compact` 看日志；跑 `--selftest` 看 `statusItemCreated` |
| 悬停完全没反应 | 菜单 →「诊断信息」→ 看「忽略原因计数」和「最近判定」 |
| 图标是橙色警告 | 选的是低延迟模式但缺权限 → 菜单里「改回零权限的轮询模式」 |
| 勾了辅助功能还是没反应 | 去「系统设置 → 隐私与安全性 → **输入监控**」再勾一次（只有低延迟模式需要） |
| 窗口重叠时切错窗口 | 未授权的降级模式所致，授予辅助功能即可精确 |
| 每次重建都要重新授权 | 自签证书没生效 → `bash Scripts/make-signing-cert.sh`，然后看 `make app` 输出里 DR 是否含 `certificate leaf` |
| `make app` 报「input file was modified during the build」 | 有别的进程在改源码，不是代码错误。等它写完重跑 |
| 和 AutoFocus 同时跑会互相抢焦点 | 两个都退出一个。HoverFocus 不会动 AutoFocus.app |
