# HoverFocus 验证报告（VERIFICATION.md）

> 作者：verifier（独立验证者）
> 环境：macOS 27.2 (26B5112a) / arm64 / Swift 6.4 / 只有 Command Line Tools
> 初版：2026-10-18 18:20 (+08:00)　最后更新：2026-10-18 21:30 (+08:00)

本文件只写**能拿证据支撑的话**。每个结论都标三种状态之一：

| 状态 | 含义 |
|---|---|
| **实测通过** | 在**本机真实系统**上跑出来的结果（真鼠标/真窗口/真 TCC/真 SkyLight），可复现 |
| **仅单测覆盖** | 只用手写测试运行器 + 注入替身验证过逻辑；**没有**在真实系统上验过 |
| **未验证** | 既没实测也没单测，或本机根本不具备验证条件 |

> ⚠️ 本文件不把「没测的」写成「通过」。任何降级/推测的结论都会显式标注。
> 凡引用他人测量结果的地方都**注明来源**（Lead 的真机 harness / core-engine 的自测），不混入我自己的实测。

---

## 0. 一页结论

| 项目 | 结果 |
|---|---|
| 单元测试 | **116 用例 / 279 断言 / 0 失败 / 1 跳过**（`bash Scripts/test.sh`，退出码 0。上一轮基线 94 / 222，本轮 +22 用例 / +57 断言） |
| 契约 16 步覆盖 | **16/16 步**每步至少 1 个用例（脚本内置覆盖门，缺一步就 exit 1） |
| 诊断探针 | `bash Scripts/build-probe.sh` → `build/hf-probe` 可用 |
| 端到端（真实 .app + 真实光标） | **PASS**：悬停后目标 App 变前台，且 z 序不变（连跑 3 次，3 次 PASS） |
| 激活策略标定 | **实测**：`skyLightNoRaise` 切前台且**不置顶**；`axFrontmost` / `publicActivate` 都会置顶 |
| 动作路径性能 | **实测**：`focus()` 稳态中位 0.74–0.88ms（修复前 33.31ms，**38×**） |
| 5 条硬性验收项 | **4 条「实测通过」+ 1 条「仅单测覆盖 + 机制论证」**（逐条见 §3） |
| 发现的真 bug | **5 个**（全部已修）：拖拽守卫缺口、全屏守卫判不出、静默告警、dwell 计时未清、权限门槛挡零权限源 |

---

## 1. 本机环境事实（决定了哪些能测、哪些测不了）

这些不是猜测，都是探针/命令实测：

| 事实 | 证据 |
|---|---|
| 屏幕主屏 2048×1152，菜单栏高 **30pt**，可见区 Quartz `(0,30,2048,1033)` | `hf-probe check` |
| 坐标自洽：Cocoa↔Quartz 往返一致、鼠标两套读数一致 | `COORD_ROUNDTRIP_OK=1`、`MOUSE_SPACES_CONSISTENT=1` |
| 菜单栏区域判定正确：点 (500,10) 在菜单栏内 | `MENUBAR_HIT_500_10=1` |
| 授权后：`AX_TRUSTED=1`、`LISTEN_EVENT_ACCESS=1`、`POST_EVENT_ACCESS=1`、`AX_HIT_ERROR=0` | `hf-probe check` |
| 授权前（同一台机器早先）：`AX_TRUSTED=0`、`AX_HIT_ERROR=-25211`（kAXErrorAPIDisabled） | `hf-probe check` 历史输出 |
| 授权后命中测试模式自动升级为 `accessibility` | `HIT_TEST_MODE=accessibility`（授权前是 `windowListFallback`） |
| 私有符号可用：`_SLPSSetFrontProcessWithOptions`、`GetProcessForPID` 都能 dlsym 到 | `SKYLIGHT_SETFRONT_AVAILABLE=1`、`GETPROCESSFORPID_AVAILABLE=1` |
| **SwiftPM 坏了**：`swift build/test/package` 全部链接失败；CLT 里没有可用 XCTest | 见 `Scripts/test.sh` 顶部；所以本工程全部用 `swiftc` 单模块编译 |
| `screencapture` 无权限、菜单栏图标不是独立窗口（macOS 26+ 由 MenuBarAgent 合成） | 所以**看不到屏幕**，图标是否存在只能靠 `--selftest` 的 JSON |

---

## 2. 怎么跑（复现命令）

```bash
cd "…/hover-focus"

bash Scripts/test.sh               # 单元测试：94 用例 / 222 断言，失败即 exit 1
bash Scripts/build-probe.sh        # 构建探针 build/hf-probe，并自动跑一次环境自检
bash Scripts/verify-permissions.sh # 权限与运行状态体检（探针 vs App 分开报）
bash Scripts/e2e-hover-test.sh     # 端到端：自建靶子窗口 + 真实光标悬停
```

> ⚠️ **跑任何真机脚本之前，先读 §11「运行/测试注意事项」** —— 那里有一条因事故新增的硬规则：
> 绝不按进程名 kill HoverFocus（`/Applications` 那份是用户日常在用的工具）。

---

## 3. 5 条硬性验收项（逐条）

> 本轮更新：修饰键守卫、拖拽守卫、全屏守卫已由「仅单测覆盖」升级为**实测通过**
> （依据 Lead 的真机 harness 用**合成输入**在真机上注入场景；来源已逐条标注）。
> 「绝不跨 Space」**仍是**仅单测覆盖 —— 真机造场景会破坏用户环境，不做，也不写成实测。

### 3.1 防误抢（不在已聚焦窗口上重复动作）

- **怎么测**：注入假 probe/actuator/clock，让 `focusedWindow()` 与命中窗口相同，连续喂 7 个采样（跨 3 秒）；另测「动作后 0.1s 再悬停」应命中第 12 步而不是第 13 步。
- **测了什么**：第 12 步 `sameWindow` 必须**先于**第 13 步 `cooldown`、**先于**第 14 步 dwell 计时；命中 `sameWindow` 时 `pendingWindowID` 必须仍为 `nil`、`stats.actions == 0`。
- **结果**：4 用例 / 13 断言全绿。真机侧：`hf-probe pipeline` 一轮悬停里 `ACTIONS=1`、其余 200+ 次判定全是 `.sameWindow`。
- **状态**：**实测通过**（我的真机 pipeline + 我的单测）＋ Lead 真机 harness T2「停 2 秒零重复动作」、T6「快速划过零误抢」也通过（来源：Lead 的 `/tmp/hfx/e2e/main.swift`）。

### 3.2 不跨 Space

- **怎么测**：假 probe 返回 `isOnScreen=false`（模拟跨 Space 窗口）。
- **测了什么**：第 6 步 `notOnScreen` 的判定与优先级（第 6 步先于第 7 步）；`WindowProbe` 的两层保险（AX 命中拿到的 windowID 不在当前 Space 的可见列表里 → 标 `isOnScreen=false`）。
- **结果**：3 用例 / 3 断言全绿。
- **状态**：**仅单测覆盖 + 机制论证**。真机侧**未验证**：制造「另一个 Space 的窗口」需要切换用户工作区，会破坏用户当前的工作环境。**不写成实测。**

### 3.3 全屏守卫

- **怎么测（单测）**：假 probe `frontmostAppIsFullScreen()=true`；并测守卫关闭时行为反转、以及第 11 步先于第 12 步。
- **测了什么（单测）**：第 11 步 `fullScreenBlocked`；`respectFullScreen=false` 时不再阻挡。
- **结果（单测）**：3 用例 / 3 断言全绿。
- **真机实测**：Lead 的 harness **T12**：把一个铺满屏幕的前台 App 作为场景 → 引擎给出 `.fullScreenBlocked`，零动作。**通过**。
- **顺带修掉一个真 bug**（见 §8.3）：全屏几何判定原来容差写死 **2pt**，而真实铺满屏幕的窗口会**内缩 4–5pt** → 判不出来；同时「AX 属性读到 false 就 return」让几何兜底成了死代码。两条都在 `WindowProbe.swift`（Lead 的文件）修了。
- **状态**：**实测通过**（Lead harness T12）＋ 单测覆盖。

### 3.4 App 排除名单

- **怎么测**：假窗口带 `bundleID` / `appName`，名单命中/不命中；另测 `UserDefaultsSettingsStore` 的持久化与脏数据。
- **测了什么**：第 10 步 `excludedApp`（bundleID 主键、appName 兜底、未命中继续走 dwell、优先于第 11 步）；`excludedBundleIDs` 落盘后新实例能读回。
- **结果**：4 用例 / 4 断言 + 持久化 5 用例全绿。
- **状态**：**实测通过**（Lead 真机 harness T4「排除名单+持久化」）＋ 单测覆盖。

### 3.5 修饰键守卫

- **怎么测（单测）**：`CGEventFlags` 注入 cmd / shift / ctrl / option，以及 capsLock / fn 两个**不该**触发的。
- **测了什么（单测）**：第 3 步 `modifiersHeld`；capsLock/fn 不算意图修饰键；`requireNoModifiers=false` 时不压制；修饰键优先于菜单栏；拖拽+修饰键时第 2 步优先。
- **结果（单测）**：6 用例 / 9 断言全绿。
- **真机实测**：Lead 用**合成输入**在真机上注入「按住 cmd 的同时移动鼠标」→ 零动作。**通过**。
- **状态**：**实测通过**（Lead 真机合成输入）＋ 单测覆盖。

### 3.6 拖拽守卫

- **怎么测（单测）**：`isDragging=true` 注入；`suppressWhileDragging=false` 反转；「拖拽期间鼠标静止、只有 tick 在跑」的守卫。
- **测了什么（单测）**：第 2 步 `dragging`；拖拽优先于修饰键与菜单栏；拖拽期间 `tick()` **不许**产生 `.act`。
- **结果（单测）**：4 用例 / 4 断言全绿。
- **真机实测**：Lead 用**合成输入**在真机注入「按住左键拖拽」→ 零动作；修复后复测：鼠标拖拽 **0/10** 漏判、触控板拖拽 **0/10** 漏判、普通移动 **0/10** 误判。**通过**。
- **但这条曾经有缺口**，而且**纯单测抓不到** —— 详见 §8.1（这是本报告最重要的一节）。
- **状态**：**实测通过**（Lead 真机合成输入）＋ 单测覆盖。

---

## 4. 契约 16 步判定顺序覆盖矩阵

由 `bash Scripts/test.sh` 末尾自动打印（内置覆盖门：任何一步没有用例，脚本 exit 1）：

| 步骤 | 语义 | 用例 | 断言 |
|---|---|---|---|
| 1 | `!enabled → .disabled` | 4 | 7 |
| 2 | 拖拽 `→ .dragging` | 4 | 4 |
| 3 | 修饰键 `→ .modifiersHeld` | 6 | 9 |
| 4 | 菜单栏 `→ .inMenuBar` | 2 | 3 |
| 5 | 无窗口 `→ .noWindow` | 3 | 6 |
| 6 | 非普通窗口 / 不在当前 Space | 3 | 3 |
| 7 | `ownApp` | 2 | 2 |
| 8 | 系统 UI | 2 | 2 |
| 9 | 隐藏 App | 2 | 2 |
| 10 | 排除名单 | 4 | 4 |
| 11 | 全屏守卫 | 3 | 3 |
| 12 | 同一窗口（必须早于 13/14） | 4 | 13 |
| 13 | 冷却 | 4 | 10 |
| 14 | 换目标重置计时 | 5 | 13 |
| 15 | dwell 未到点 | 6 | 17 |
| 16 | 到点 `.act` | 11 | 36 |
| **17** | **3.5 文本编辑守卫 `→ .textEditing`** | **9** | **19** |

**合计 116 用例 / 279 断言 / 0 失败 / 1 跳过。**

> 步号 17 是「契约里的第 3.5 步」（文本编辑守卫）。它不是整数步号，这里用 17 表示，
> 好处是它同样受**覆盖门**约束（缺用例即 exit 1），不会变成没人管的孤儿行为。

另有 **15 条不计入步号矩阵**的用例（跨模块 / App 层行为，不绑单一步骤）：
- **13 条 `IconState` / `StatusIcon` 状态映射**（6 个分支各一条 + 判定顺序 4 条 + rawValue/displayName/symbolName 3 条，见 §12.3）
- 「driver：延迟补测确认被置顶 → 必须告警；未置顶 → 不许告警」（覆盖产品真实告警路径，见 §8.4）
- 「FocusController：动作路径不许阻塞（`raise=true` 50 次平均 < 5ms）」（防 33ms 回归的自动化闸门，见 §6.2）

跳过的 1 条是环境相关用例：「真实 `MouseMonitor` + 无授权 → 抛 `.permissionDenied`」——
本机现在**已经授权**了，构造不出「无授权」前提，所以跳过（跳过不计入通过）。
该行为改由一条与环境无关的用例覆盖：假事件源声明 `requiresAccessibilityPermission = true`
+ `permissionCheck = { false }` → 必须抛 `.permissionDenied` 且不留 tick Timer（已绿）。

### 4.1 关键边界（都在上表里，单独点名）

- dwell **到点**与**未到点**（含 `now - start == dwell` 的精确边界，用二进制可精确表示的 0.5/0.25 避免浮点污染）
- **中途换窗口重置计时**（A→B→A 都要重新计满）
- **鼠标静止靠 `tick()` 到点**（handle 之后不再喂采样）
- **`sameWindow` 优先于 dwell**（第 12 步在第 14 步之前，命中时不启动计时）
- **cooldown 压制**与边界（恰好等于 cooldown 不再压制）
- **`dwellDelay = 0`** → 同一次 handle 直接 `.act`
- **`cooldown` 下限 0.06**（契约 `sanitized()` 强制；用于盖过 `WindowProbe.focusedWindow()` 的 50ms 缓存）
- `perform()` 拿不到 `WindowRef` → 必须 `error != nil`、`didActivate == false`、**不计入** `stats.actions`、**不建立**冷却基准

### 4.2 判定语义契约（实现方定稿、测试据此守门）

这几条是「容易实现反、且反了不容易被发现」的语义，写死在这里供后续维护对照：

1. **dwell 计时统一规则**：第 **1–5 步任何 return 都清掉** dwell 计时；只有第 6–13 步确认
   「指针仍停在**正在计时的那个窗口**上」才保留 → 保证「连续停留 ≥ dwell 才动作」。
   （第 6 步的窗口与计时窗口不同时同样清掉。）
2. **cooldown 下限是 0.06，不是 0**：因为 `WindowProbe.focusedWindow()` 有 50ms 缓存，
   靠 cooldown 盖过「刚动作完、缓存还没刷新」的窗口，否则会出现同一窗口被反复聚焦的动作风暴。
3. **动作路径绝不允许阻塞**：`focus()` 只读一次 z 序、不做任何等待（见 §6.2 的真机数据与守门用例）。
4. **`didRaise` 分两层**：动作路径返回值是**临时值**（对会置顶的策略通常滞后为 `false`）；
   **权威值**来自 +0.18s 的非阻塞延迟补测（`onRaiseResolved` / `RaiseResolution`），
   且只在前后两次 z 序**都读得到**时才出结论（读不到通常是窗口已消失，不能当成「被置顶」）。
5. **权限门槛只在事件源声明需要授权时生效**（`MouseMonitor=true`、`MousePoller`/假实现=`false`）；
   `stop()` = tick Timer invalidate + `onSample` 摘除 + `monitor.stop()` + 补测回调摘除。
6. **SettingsStore**：key 前缀 `HoverFocus.`；读写都过 `sanitized()`（含 NaN/Inf 兜底）；
   **只在值真的变化时**回调观察者、**注册时不回调**。

---

## 5. 激活策略标定（「只切焦点不置顶」的唯一可信判据）

**怎么测**：`hf-probe calibrate` 用**独立实现**的 CGWindowList 读 z 序（0 = 最前），
对同一条链路分别在「施加策略前 / 后」各读一次；每次测前先把参照 App 切回前台，
保证每种策略都从同一初始状态出发。frontmost 一律**跑 RunLoop** 再读
（`NSWorkspace.frontmostApplication` 不跑 RunLoop 不刷新 —— 这是 Lead 踩过的坑）。

**测了什么**：本机自建的两个靶子 App（HFTargetA / HFTargetB，各一个普通窗口），
目标 B 的窗口 id=3874，参照 A 在前台时 B 的 z 序 = 1。

**结果（2026-10-18 18:15，AX 已授权）**：

| 策略 | CGError | 变成前台 | 置顶窗口 | z 序 |
|---|---|---|---|---|
| `skyLightNoRaise`（`_SLPSSetFrontProcessWithOptions`, mode 0x200） | 0 | ✅ 是 | ❌ **否** | **1 → 1** |
| `axFrontmost`（`AXUIElementSetAttributeValue(kAXFrontmost)`） | 0 | ✅ 是 | ✅ 是 | 1 → 0 |
| `publicActivate`（`NSRunningApplication.activate`） | 0 | ✅ 是 | ✅ 是 | 1 → 0 |
| **`FocusController.focus(raise: false)`（App 实际走的路径）** | 0 | ✅ 是 | ❌ **否** | **1 → 1** |

最后一行是关键：**App 在默认「只切焦点」模式下真的不会把窗口顶上来**，
实测策略字段 `strategy=skyLightNoRaise`、`didRaise=false`、`didActivate=true`、`error=nil`。

**授权前**（`AXIsProcessTrusted=false`）同一支探针的结果：`skyLightNoRaise` 仍然 `code=0`、
切前台成功、不置顶；而 `axFrontmost` 返回 `-25211`（无权限）。
→ 说明**私有 SkyLight 路径不依赖辅助功能权限**，这也是「零权限可用」的技术基础。

**第三方独立印证**（不是我测的，注明来源）：
- Lead 真机 harness：mode 0x200 / 0x100 / 0x0 都是「切前台不置顶」（z 1→1），`NSRunningApplication.activate()` 置顶（z 1→0）；harness **T1** 就是「悬停切焦点且不置顶」。
- core-engine 真机观测：`raise=false → strategy=skyLightNoRaise, didRaise=false, didActivate=true, error=nil`。
- **产品代码自己的日志**（我读 unified log 拿到的，最有说服力的一条，因为它来自产品本身）：
  ```
  [com.lunasama.HoverFocus:decision] 动作结果：目标=HFTargetB 策略=skyLightNoRaise 成为前台=是 置顶了=否
  ```
  Lead 的真实 .app 验收 run 里连打三条（A→B→A→B）全是「置顶了=否」。

**状态**：**实测通过**。

---

## 6. 端到端实测（真实 .app + 真实光标）

**怎么测**：`bash Scripts/e2e-hover-test.sh`

1. 前置检查：探针可用、AutoFocus 已退出（它会和 HoverFocus 互抢焦点；**只有本脚本允许退它，且不会自动重开**）
2. 起**自己的**两个靶子 App（一左一右），不让用户的窗口当实验品
3. 让 A 当前台、B 在它后面；记录 B 的窗口 id 与 z 序
4. 启动真实 `build/HoverFocus.app`
5. `CGWarpMouseCursorPosition` 把指针移到 B 窗口中心并停住，等 dwell + 余量
6. 断言：前台 App 是否变成 B；B 的 z 序是否**没变**
7. 恢复指针、`pkill -x HoverFocus`、关掉靶子

**结果**：

| 轮次 | 前台 | B 的 z 序 | 结果 |
|---|---|---|---|
| 1 | A(44330) → **B(44333)** | 1 → 1 | **PASS**（9 项通过 / 0 失败 / 0 未验证） |
| 2 | A(45480) → **B(45484)** | 1 → 1 | **PASS** |
| 3 | A(46190) → **B(46193)** | 1 → 1 | **PASS** |

**状态**：**实测通过**（连续 3 次）。

> 说明：第 1 次跑端到端之前的版本里，权限门槛判的是 `axTrusted`，曾在某一瞬间读到 `false`
> 而误报「无法验证」。已改成判 `driverStarted`（真正决定功能可用性的是「鼠标监听能不能起来」，
> 而不是「有没有辅助功能授权」——app-shell 现在默认用零权限的 `MousePoller`）。
> 改完复跑即稳定 PASS。

### 6.1 无权限时的降级链路（同样实测）

`hf-probe pipeline` 把**真实**的 `WindowProbe + FocusController + MousePoller + FocusEngine`
接成与 App 相同的链路（只少菜单栏 UI），在 `AXIsProcessTrusted=false` 时也跑通过一轮：

```
HIT_TEST_MODE=windowListFallback
SAMPLES=1  ACTIONS=1
Z_BEFORE=1  Z_AFTER=1
FRONT_BEFORE=HFTargetA  FRONT_AFTER=HFTargetB
OUTCOME_STRATEGY=skyLightNoRaise  OUTCOME_DID_RAISE=0  OUTCOME_DID_ACTIVATE=1  OUTCOME_ERROR=nil
PIPELINE_OK=1
```

→ **零权限下「悬停切焦点且不置顶」整条链路可用**。这条证据的价值在于它不含任何替身；
但它**不含菜单栏 App 本体**，所以不能替代 §6 的端到端结论。

### 6.2 动作路径性能（实测，来源：Lead；我另有守门断言）

背景：动作路径原来有一次阻塞式观测 `settle()`（`4×usleep(5ms)` + 4 次读 z 序），
在真机上表现为鼠标事件被卡 **33ms**（鼠标事件预算只有 16ms，会掉帧、拖拽会抖）。
现在改成「读一次 z 当临时值 + 排一次 +0.18s 的非阻塞延迟补测」。

| 指标 | 数值 |
|---|---|
| `focus(raise:false)` 稳态（n=30，预热后） | 中位 **0.737ms**（p90 1.731 / max 7.940） |
| `focus(raise:true)` 稳态 | 中位 **0.876ms**（p90 1.535 / max 4.721） |
| `probe.zOrderIndex()` 参考 | 中位 0.193ms（残差主要来自它） |
| **修复前** `focus(raise:true)` 同口径 | 中位 **33.31ms**（p90 34.40 / max 40.74）→ **38×** |
| 拆解证据 | `NSRunningApplication.activate()` 单独只要 **0.09ms**，那 33ms 全是 `settle()` 睡出来的 |
| 冷启动首次 `focus()` | ≈ **18ms**（首次 dlopen/dlsym + 首次 CGWindowList），**一次性**，不算进稳态 |
| 延迟补测可靠性 | 60 次动作 → **61 次** `onRaiseResolved` 回调 |

**第二个独立来源**：core-engine 用自己的口径（n=15）测得 `focus(raise:false)` 中位 **0.996ms**、
`focus(raise:true)` 中位 **1.054ms**，与 Lead 的 n=30 数据同量级 —— 两次独立测量互相印证
「动作路径已不再阻塞」。

**自动化守门**：我的用例 B（§4 那 2 条之一）断言 `focus(raise:true)` 假 probe 下 50 次平均 **< 5ms**，
旧实现必然被抓红 —— 这是防止 33ms 那个 bug 复发的唯一自动化闸门。
（`raise=false` 会真打一次 AX IPC，阈值随环境抖动，**故意不卡**，避免制造假红。）

**状态**：**实测通过**（Lead 的真机数据）＋ 我的单测守门。

---

## 7. 未验证清单（明确列出，不许当成通过）

| # | 项目 | 为什么没验证 |
|---|---|---|
| 1 | **跨 Space 不抢焦点** | 要制造第二个 Space 的窗口必须切换用户工作区，会打断用户。**仅单测覆盖 + 机制论证** |
| 2 | **菜单栏图标真的显示出来** | 本机 `screencapture` 被拒、菜单栏由 MenuBarAgent 合成、`CGWindowList` 查不到。只能靠 `--selftest` 的 `statusItemCreated/buttonWindowVisible=true` 间接判断（**不能**算「肉眼确认」） |
| 3 | **设置窗口 UI 交互** | 同上：看不到屏幕，无法点击验证。app-shell 新增的 `--selftest-ui`（`uiSmoke` 子对象）可以验「菜单 + 设置窗口构造不闪退」，但**不等于**交互可用 |
| 4 | **真实 `MouseMonitor`(CGEventTap) 长时间收事件** | 授权后可以建 tap（`EVENT_TAP_OK=1`），但「长时间稳定收事件、tap 被系统禁用后能恢复」需要真实使用观察 |
| 5 | **多显示器 / 不同分辨率** | 本机只有一块屏 2048×1152 |
| 6 | **`axFrontmost` 降级路径在 App 内的真实触发** | 需要人为制造 SkyLight 失败才能走到这条降级；探针单独测过它会置顶（§5），但 App 内部的降级触发未验证 |

> 已从本清单**移出**（升级为实测）：修饰键守卫、拖拽守卫、全屏守卫 —— 依据 Lead 的真机 harness（合成输入 / T12）。

**另有一条「已知不精确、故只作诊断」的项**：`FocusOutcome.didActivate` 可能**假阴性** ——
它依赖 `NSWorkspace.frontmostApplication`（不跑 RunLoop 不刷新）与 `focusedWindow()` 的 50ms 缓存，
所以动作返回瞬间可能读到旧值。因此它**只用于诊断展示，不驱动 `error`、也不驱动告警**
（告警只认 `error` 与延迟补测的 `didRaise`）。这不是缺陷，是刻意的口径收敛。

---

## 8. 发现的问题

### 8.1 拖拽守卫有缺口，触控板下完全失效（真机抓到，纯单测抓不到）★

**这是本报告最值得读的一节**：它证明「92 条纯逻辑单测全绿」**不等于**功能正确。

- **已证明的机制**：`isDragging` 原来由 `CGEventSource.buttonState` 推出。实测该状态
  **滞后于事件流**（普通拖拽的头 2–3 个事件仍为 `false`），且**触控板三指/轻点拖移全程为 `false`**。
  后果：拖拽守卫在**每次拖拽开头**存在缺口，在**触控板拖拽下完全失效** →
  拖拽期间触发聚焦 → macOS 在拖拽会话中改变窗口叠放会**取消拖拽**（用户感知为「窗口拖不动」）。
- **修法**：优先按**事件类型**判定拖拽，只在 `mouseMoved` / `flagsChanged` 上回退查按键状态。
- **修复后实测**：鼠标拖拽 **0/10** 漏判、触控板拖拽 **0/10** 漏判、普通移动 **0/10** 误判。
- **证据边界（不许夸大）**：**没有**「已复现出拖拽彻底失败」这个结论。用合成事件补齐正确前置条件后
  **8/8 都能拖动**；最初那次失败是**测试自身的缺陷**（目标窗口被别的窗口盖住），不是产品问题。
  结论只落在机制层面：**守卫存在缺口 / 触控板下完全失效**。
- **为什么单测抓不到**：假事件源永远复现不出「系统按键状态滞后于事件流」这件事 ——
  测试里 `isDragging` 是我们直接赋值的布尔量，天然正确。只有真机才有这个时序。
- **来源**：Lead 在 `MouseMonitor.swift`（Lead 的文件）发现并修复。

### 8.2 全屏守卫判不出真实全屏（真机抓到）

- **机制**：全屏几何判定的容差原来写死 **2pt**，而真实铺满屏幕的窗口会**内缩 4–5pt** → 判不出来；
  同时「AX 属性读到 `false` 就直接 return」使几何兜底逻辑成了**死代码**。
- **修法 + 实测**：两条都在 `WindowProbe.swift`（Lead 的文件）修掉；修复后 Lead 的 harness **T12**
  （铺满屏幕的前台 App）给出 `.fullScreenBlocked`、零动作。
- **来源**：Lead 发现并修复。

### 8.3 focusOnly 的「实际被置顶」告警曾经是**静默**的

- **机制**：旧实现用**动作路径上立刻读到**的 z 序判 `didRaise`。但窗口服务器把「置顶」反映到
  z 序上要 **~150ms**（Lead 实测 4/4 轮），所以在**会置顶的降级路径**上 `didRaise` 恒为 `false`
  → 这条告警**永远不会发出**（静默）。用户最在意的验收项「只切焦点不置顶」一旦降级，他看不到任何提示。
- **修法**：改为 **+0.18s 的非阻塞延迟补测**驱动（`FocusController.onRaiseResolved` /
  `RaiseResolution`，由 `FocusDriver.start()` 自动接线、`stop()` 摘掉）；
  只有 `!expectsRaise && didRaise` 才告警；若 actuator 不是 `FocusController`，回退用 `outcome.didRaise`。
  同时动作路径读到的 `didRaise` 明确降级为**临时值**（权威值只在补测里）。
- **我的守门测试**（本次新增，用例 A）：
  - 真 `FocusController` + 动作路径临时值刻意设为「看起来被置顶」（z `[3,0,…]`）→ **不许**提前告警；
  - 补测 `expectsRaise=false & didRaise=true` → **必须**告警；
  - `didRaise=false` → 不许告警；`expectsRaise=true & didRaise=true` → 不许告警；
  - `start()` 后 `onRaiseResolved != nil`，`stop()` 后必须变回 `nil`。
  - 与既有的 `FakeActuator` 用例构成一对：**接线缺失 → fallback 告警必须发；接线存在 → 只认补测结论**。
    删掉 `!hasRaiseResolutionWiring` 那个 guard，这条立刻红。
- **来源**：core-engine 实现变更；测试盲区由我识别并补齐。

### 8.4 已修复（更早一轮）

1. **第 1–5 步未清 dwell 计时 → 快速划过会误抢焦点（Lead harness 的 T6）**。
   症状是**多次短停留的时间被累加**，凑够 dwell 就动作：指针在窗口↔菜单栏/桌面之间来回划过时，
   每一次停留都不到 dwell，但计时从没被清掉，于是「总时长」够了就抢焦点。
   现在第 1–5 步任何 return 都重置计时；回归用例：窗口↔菜单栏来回 6 次（总 360ms > dwell 150ms）→ 零 act。
   **为什么单测容易漏**：如果测试只验「连续停留在同一窗口 ≥ dwell 会动作」，
   那它**永远发现不了**这条 —— 必须专门构造「多次短停留 + 中间离开」的组合。
   *来源：Lead / core-engine。*
2. **`FocusDriver` 无条件用 `AXIsProcessTrusted` 当启动门槛 → 把零权限事件源也挡掉**，
   与「零权限可用」的产品前提冲突。现在只在**事件源自己声明需要授权**时才检查。
   我的测试覆盖两侧：声明需要授权 + 无权限 → 抛 `.permissionDenied`；零权限源 → 正常启动。
3. **`requiresAccessibilityPermission` 只声明在 protocol extension → 静态派发陷阱**
   （存在类型上恒为 `false`，`MouseMonitor` 的 `true` 被静默忽略）。已挪进 protocol body。

### 8.5 潜伏缺陷（已修，但**不要写成曾导致故障**）

**app-shell 的 `pollPermissions()` 会在 `axTrusted` 变化时无条件 `stopDriver()`。**
轮询事件源零权限可用，所以抖到 `false` 时会把功能停掉；而 `stopDriver()` 不设 `driverError`、
`currentState()` 在轮询模式又不看 `axTrusted` → 图标显示「已开启」但功能已死。
**真机实测触发 0 次**：3 小时日志里「鼠标监听已停止」出现 **0 行**，同进程内 `axTrusted` 从未变化过。
所以这是**潜伏缺陷，不是线上故障**。已改为「连续 3 次同值才认定变化 + 只在事件源声明需要权限时才停驱动」。

**顺带更正一个口径**：`AXIsProcessTrusted()` 的取值**依赖「哪个二进制 / 哪种启动方式」，而不是时间抖动**。
日志直接抓到对照：`open build/HoverFocus.app`（我的 e2e）报「未授予」，
而 Lead 验收用的 `/tmp/hfx/final/HoverFocus.app` 报「已授予」。
→ 任何用 `axTrusted` 当门禁的脚本都有误判风险，门槛应判 `driverStarted`（我的 e2e 已这么改）。

### 8.6 「App 静默消失」的真因：并发按进程名 pkill ★（**推翻我早先的错误归因**）

- **现象**：`open build/HoverFocus.app` 之后，进程约 6 秒后消失。
- **我早先的归因（错的，此处明确推翻）**：我在 unified log 里看到 AppKit `AutomaticTermination`
  （`_kLSApplicationWouldBeTerminatedByTALKey=1`）相关记录，怀疑是**系统 TAL 自动终止**。
  当时做了三组对照（直接 exec 存活 ≥14s；`open` 原版存活 12s；另建的极简菜单栏 App 存活 ≥14s）
  **均未复现**，我写成了「疑似并发 pkill 的假阳性」——**但保留了 TAL 这个归因，这是错的**。
- **真因（已定论）**：**并发 teammate 执行 `pkill -x HoverFocus`**。
  `pkill` 默认发 **SIGTERM**，与当时观测到的 `Terminated: 15` **完全对应**；
  TAL 不走这个信号，且「极简菜单栏 App 存活 ≥14s」的对照已证明
  **无窗口的 LSUIElement 应用不会被自动终止**。
  具体触发：core-engine 在验证命令末尾按老习惯跑了 `pkill -x HoverFocus`，
  **把用户正在日常使用的 `/Applications/HoverFocus.app` 杀掉了**。
- **教训**：这不是「App 有 bug」，而是**我们的测试流程在按进程名杀别人的进程**。
  规则见 §11。TAL 相关加固保留，但属**防御性措施**，根因已排除。

### 8.7 我自己写错并修正的（留档，说明测试有效）

- 三条 cooldown 用例里我先用 `dwell=0.5` 却期望首个采样立刻 `.act` —— 改成「先 `dwell=0` 动作一次，
  再用 `store.update` 换成 `dwell=0.5` 断言剩余量」。**没有**为了让测试变绿而放宽断言。

---

## 9. 方法论：结果如何归因到确定版本

本工程有三个 agent 并行写同一个仓库，**源码会在你跑测试期间被别人改掉**。
所以「测试全绿」这句话本身不足以作为证据，必须能回答「绿的是哪个版本」。

做法：跑测试**前后**各取一次核心源码指纹并对比。

```bash
md5 -q Sources/HoverFocusCore/*.swift > /tmp/before.md5
bash Scripts/test.sh
md5 -q Sources/HoverFocusCore/*.swift > /tmp/after.md5
diff -q /tmp/before.md5 /tmp/after.md5 && echo "结果可归因"
```

最近一次（94 用例那轮）实测：跑前跑后 8 个核心源码 md5 **完全一致** → 结果可归因到该版本。
若不一致，说明 `swiftc` 可能编到一半的中间状态，那一轮结果作废、必须重跑。

**跨 agent 互认**（比自证更有力）：core-engine 独立复跑同一轮，给出他那 4 个文件的 md5，
与我跑测试前记录的值**逐一相同**：

| 文件 | md5 | 是否一致 |
|---|---|---|
| `FocusEngine.swift` | `c02082036ad544f7f1c3dcab447bb2ad` | ✅ |
| `FocusDriver.swift` | `d8a7ac9517235d980e4f727c69d8dc99` | ✅ |
| `FocusController.swift` | `9eaba789d2e2700bb5d337b2d7102686` | ✅ |
| `SettingsStore.swift` | `07f846656bb2d8b7cc2924b0da9169b9` | ✅ |

也就是说：**「94 用例 / 222 断言 / 0 失败」这个结论同时被两个 agent、在同一份源码上独立复现**，
不是某一方的一次性输出。

另外两条纪律：
- **测试红了不改实现绕过**，只报给实现者（`Sources/` 不是我的写作用域）。
- **不为了让测试变绿而放宽断言**；环境不满足时用「跳过」而不是「通过」（跳过在报告里单列，不计入绿）。

---

## 10. 交付物清单（verifier 写作用域内）

| 路径 | 作用 |
|---|---|
| `Tests/TestSupport/Harness.swift` | 手写断言 harness：失败不中断、跑完汇总、覆盖门（16 步缺一即 exit 1） |
| `Tests/TestSupport/Fakes.swift` | 纯逻辑替身：FakeClock / FakeSettingsStore / FakeProbe / FakeActuator / FakeMonitor / Scenario |
| `Tests/TestRunner/main.swift` | 顶层入口（Swift 规定顶层代码只能写在 `main.swift`） |
| `Tests/TestRunner/StepTests.swift` | 契约 16 步判定顺序 + 边界 + tick + perform + 性能预算 |
| `Tests/TestRunner/ContractTests.swift` | 坐标转换 / 修饰键 / 枚举 rawValue / `sanitized()` |
| `Tests/TestRunner/ControllerTests.swift` | `FocusController` 的 `didRaise` 三种取值、**动作路径无阻塞守门**、`UserDefaultsSettingsStore` 持久化与脏数据 |
| `Tests/TestRunner/DriverTests.swift` | `FocusDriver` 接线、真 Timer 到点、stop 干净性、权限门槛两侧、**延迟补测告警路径（两方向）** |
| `Tests/TestRunner/TextEditingGuardTests.swift` | **契约第 3.5 步**文本编辑守卫（9 用例：命中零动作 / `clearPending` 清零计时 / 顺序 / tick / 未命中不误伤） |
| `Tests/TestRunner/IconStateTests.swift` | **菜单栏图标 6 状态映射**与判定顺序、rawValue/displayName/symbolName（13 用例） |
| `Tools/hf-probe/main.swift` | 诊断探针：环境自检 / z 序 / 命中测试 / 指针 warp / 三策略标定 / 无权限核心链路 |
| `Tools/hf-target/main.swift` | 端到端用的最小靶子 App（不拿用户的窗口做实验） |
| `Scripts/test.sh` | 单模块 `swiftc` 编译 + 运行测试（不碰 SwiftPM/XCTest）。`APP_STATE_SRC` 单独列出「测试额外编入的 App 层文件」（`AppInfo` / `StatusIcon`），只加编译路径、不改逻辑 |
| `Scripts/build-probe.sh` | 编译 `build/hf-probe` 并自检 |
| `Scripts/e2e-hover-test.sh` | 端到端悬停验证（自建靶子、恢复指针、清理进程、不重开 AutoFocus） |
| `Scripts/verify-permissions.sh` | 权限体检（探针与 App 分开报，避免把环境事实误读成缺陷） |
| `docs/VERIFICATION.md` | 本文件 |

**安全约定**：所有真机脚本结束时都会恢复鼠标位置、关闭自己起的靶子 App、**只 kill 自己启动的 pid**；
`e2e-hover-test.sh` 是唯一允许退出 AutoFocus 的地方，且**不会**自动重开它。详见 §11。

---

## 11. 运行 / 测试注意事项 ★（事故后新增，务必遵守）

### 11.1 绝对不要按进程名 kill HoverFocus

```bash
pkill -x HoverFocus      # ⛔ 禁止
pkill -f HoverFocus      # ⛔ 禁止
```

**`/Applications/HoverFocus.app` 是用户日常在用的工具。** 按进程名杀会把用户那份一起杀掉。

**已发生的事故**：core-engine 在验证命令末尾按老习惯执行 `pkill -x HoverFocus`，
把用户正在使用的 `/Applications/HoverFocus.app` 杀掉了。
这同时也是「App 3–4 秒静默消失」的真正原因（**并发按进程名 pkill → SIGTERM**，
与 `Terminated: 15` 完全对应），**不是** AppKit 自动终止（我早先的归因已推翻，见 §8.6）。

**根因是流程错误，不是代码错误**：最初的团队任务指令里写了「每次测完执行 `pkill -x HoverFocus`」，
后来用户开始用安装版，那条规则没有同步更新。

### 11.2 三条硬规则

1. **要清理，只 kill 自己起的 pid。**
   启动时记住 `$!`（或按**自己的 build 路径** `pgrep -f "$APP_BIN"` 定位），结束时
   `kill "$PID"`。例如本工程 e2e 脚本：`HOVERFOCUS_PID=$(pgrep -f "$APP_BIN")` ——
   模式里带 `build/` 路径，**永远不会**匹配到 `/Applications` 那份。
2. **若确实需要整类清理**：先用 `pgrep -f` 拿到列表，**排除 `/Applications/HoverFocus.app` 的 pid**，
   只对 `build/` 路径下的实例动手；并且**不要**用 `pkill -x`。
3. **任何会停掉 App 的脚本，结束时必须把用户的实例还回去。**
   模式（照抄 `Scripts/lead-acceptance.sh`）：
   ```bash
   WAS_RUNNING=0
   pgrep -f "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus" >/dev/null 2>&1 && WAS_RUNNING=1
   cleanup() {
     kill "$MY_PID" 2>/dev/null            # 只杀自己的
     if [ "$WAS_RUNNING" = 1 ] && [ -x /Applications/HoverFocus.app/Contents/MacOS/HoverFocus ] \
        && ! pgrep -f "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus" >/dev/null 2>&1; then
       open /Applications/HoverFocus.app    # 还回去
     fi
   }
   ```
4. **匹配模式必须「非空且足够具体」**（含完整路径前缀），杀之前先断言。
   实测依据（本机，2026-10-18）：

   | 模式 | 结果 |
   |---|---|
   | `pgrep -f ""` | **exit 2，正则编译失败，0 匹配** —— macOS 会**拒绝**空模式，**不会**「匹配所有进程」 |
   | `pgrep -f "/"` | **786 个进程** —— 真正危险的是**过宽但非空**的模式 |

   所以「变量为空导致杀光全系统」这条在本平台**不成立**（这是好事），但「模式退化成过宽」
   仍然是真风险。稳妥做法：杀之前断言模式里含预期路径片段，例如
   ```bash
   case "$APP_BIN" in */build/HoverFocus.app/Contents/MacOS/HoverFocus) ;; *) echo "模式异常，拒绝执行"; exit 1 ;; esac
   ```
   本工程 e2e 脚本已做等效防护：`pgrep` 失败 → `HOVERFOCUS_PID` 为空 → 脚本在清理前就 `fail` 退出，
   且清理里的 `kill` 被 `[ -n "$HOVERFOCUS_PID" ] && kill -0 …` 双重守住。

### 11.3 另一条容易忽略的坑：自检进程也叫 HoverFocus

`HoverFocus --selftest` 起的进程**名字也叫 `HoverFocus`**。
所以 `pkill -x HoverFocus` 会**顺手把正在跑的自检也杀掉**，表现为「`--selftest` 没有输出」。
`Scripts/lead-acceptance.sh` 里已经为这个现象加了重试注释 —— 这就是同一个根因。

### 11.4 当前代码库里的违规点（供维护者清理）

> 状态：**已全部清理完毕**（下表保留作为记录）。代码库里现在只剩 `lead-acceptance.sh`
> 一处仍按进程名停实例；`make kill` 也已在 21:11:56 改成路径限定（见下表）。
>
> **核验方法（不要只读代码就下结论）**：对每个模式实际跑一次 `pgrep -f`，看它到底能匹配到谁。
> 本次核验时用户实例为 `/Applications/HoverFocus.app`，两种模式分别匹配：
> ```
> build 模式  "$PWD/build/HoverFocus.app/Contents/MacOS/HoverFocus"      → 匹配 0 个
> 安装版模式  "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus"   → 匹配到用户实例
> ```
> → 证明「按完整路径匹配」确实能区分两者，`build/` 模式**永远不会**命中用户那份。

| 位置 | 情况 | 状态 |
|---|---|---|
| `Scripts/e2e-hover-test.sh` | **verifier 已修**：改为只 kill `$HOVERFOCUS_PID`（按 build 路径定位）+ `WAS_RUNNING` 记录与还原；用户实例在跑时主动跳过（exit 3） | ✅ 已完成 |
| `Scripts/build.sh`（`--run` 路径） | **Lead 已修**：改为 `pkill -f "$APP/Contents/MacOS/HoverFocus"`，只停 `build/` 下的旧开发实例。模式内含写死字面量 `/Contents/MacOS/HoverFocus`，实测退化时匹配 **0 个**。**app-shell 已按要求补上显式 `case` 断言**（`bash -n` 绿、自测 4/4：正常值通过 / 过宽 `"/"` 被拒 / 正常值通过 / 别的 App 路径被拒） | ✅ 结果安全 + ✅ 显式模式断言 |
| `Scripts/install.sh` | **Lead 已修**：改为按 `$DEST_APP` 完整路径停「即将被替换的那一份」。同样含字面量后缀，实测退化后匹配 **0 个**。注意 `install.sh:45` 那个 `case "$DEST_APP"` 是 **AutoFocus 保护**，与新增的模式断言是两回事。**app-shell 已补显式 `case` 断言** | ✅ 结果安全 + ✅ 显式模式断言 |
| `Scripts/lead-acceptance.sh` | **Lead 的验收脚本**：已加 `WAS_RUNNING` + 自动还原（开始时用户在跑 → 结束时 `open` 还回去）—— 这套「记录 + 还原」纪律正是 §11.2 规则 3 的范本。它仍按名停实例，因为「停掉 App 再验证退出后不再抢焦点」是它的测试前提 | ⚠️ **半合规 + 验收专用**（Lead 裁决，2026-10-18）。按名杀的实测代价：①连带杀掉**同名**的 `--selftest` 进程（已用「无输出就重试 3 次」兜住）；②打断并发的 `build/` 实例。它**只在做真实 .app 验收时运行，不是日常命令**，所以「半合规」不等于「危险」。建议解冻后改路径限定、保留 `WAS_RUNNING` 逻辑 |
| `Makefile` 的 `make kill` / `make quit` | **Lead 已修（21:11:56）**：`make kill` 改为只停 `build/` 下的开发实例并提示「/Applications 那份不受影响」；新增 `make quit` 显式停安装版并打印恢复命令；文件头写明禁止按名杀 | ✅ 已完成 |

> ### 11.4.1 验证 `pkill -f` 模式时的两个测量坑（**实测踩出来的**）
>
> **(1) 调用者自己会被算进去。** 若模式字符串出现在**调用者自己的命令行**里
> （典型：命令文本直接写了**展开后的完整路径**，或被包在 `bash -c '…'` 里），
> `pgrep -f` 会把**调用它的 shell 自己**也匹配上，让计数虚高。
> 本机实测：同样的模式，写在临时脚本文件里跑（argv 不含该串）→ 0 个；
> 写在 `bash -c` 的命令文本里 → 会多出 1 个（就是那个 bash）。
> **规避**：把测量放在**独立命令**里（模式只存在于变量，不出现在 argv），
> 或排除调用者自身：`pgrep -f "$PAT" | grep -v "^$$\$"`。
>
> **(2) 用户实例没在跑时，怎么验判别力。** 别等用户开 App ——
> 用一个 **argv 伪装**的合成靶子即可（**不碰真 App**）：
> ```bash
> bash -c 'exec -a "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus" sleep 20' &
> sleep 0.4
> pgrep -f "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus"              # → 恰好命中它
> pgrep -f "$PWD/build/HoverFocus.app/Contents/MacOS/HoverFocus"                 # → 必须为空
> ```
> 本机实测：安装版模式命中合成靶子 1 个、build 模式 **0 个** → 判别力成立且**零副作用**。
> 这套方法也可以在真 App 没跑时复现「按名杀会误伤」的对照。
>
> **为什么「结果安全」仍建议补断言**：现在的安全性依赖「模式里**恰好**有写死的字面量后缀
> `/Contents/MacOS/HoverFocus`」这一巧合，而不是靠显式防御。一旦有人把它重构成
> `pkill -f "$APP"`（很自然的重构），模式就会退化得足够宽而开始误伤。
> 断言的价值是把「沉默地变危险」变成「**立刻报错**」。
>
> 实测对照：退化模式 `"/Contents/MacOS/HoverFocus"` → 匹配 **0 个**（安全）；
> 但 `pgrep -f "/"` → **786 个**（过宽即危险）。所以规则 4 的断言不是多余的。
>
> 另外：`Scripts/lead-acceptance.sh` 的「记录 + 还原」部分**是** §11.2 规则 3 让读者照抄的范本，
> 不要因为它被判「半合规」就整体否定它 —— 问题只在「按名杀」这一点。

### 11.5 跑真机测试前的自检清单

- [ ] 用户那份 `/Applications/HoverFocus.app` 是否在跑？在跑 → **不要**做完整端到端
      （两份实例互抢焦点；且用户配置可能是「置顶模式」，会让「z 序不变」的断言假红）。
      `e2e-hover-test.sh` 已自动检测并**主动跳过**（exit 3），绝不碰用户那份。
- [ ] 有没有别的 agent 正在跑真机测试？并发会互相干扰（§8.6 的事故就是这么来的）。
- [ ] 脚本结束时是否恢复了：鼠标位置、自己起的进程、用户的实例、AutoFocus 的状态（不自动重开）。

---

## 12. 今晚的三件修复：覆盖情况与取证方法（2026-10-18 深夜补）

> 本节记录三项「紧急修复时加的行为」现在到底有多少自动化保护，以及一件**不是我们的 bug**
> 但极容易被误判成我们的 bug 的现场问题。

### 12.1 文本编辑守卫：判定范围（只挡单行，故意不挡多行）

**修的是什么**：Finder 里选中文件按 Return 重命名、表格单元格编辑这类**行内单行输入框**，
一旦窗口失焦，**编辑会被直接取消**（用户白编辑）。这是 AutoFocus 的老 bug，用户明确要求不要重蹈。

**判定范围（故意收窄）**：`AXTextField` / `AXComboBox` / `AXSearchField`，且 `AXEditable` 为真
（拿不到时保守认为可编辑）。

**故意不管的**：多行文本区（聊天输入框、代码编辑器、网页 `textarea`）。
如果连多行也挡，那「在聊天框里打字时悬停永远不切窗口」—— 核心功能会被废掉。
**这是一条设计取舍，不是漏判**；做回归时不要「顺手补全」成多行。

**自动化覆盖**：**9 用例 / 19 断言**（`Tests/TestRunner/TextEditingGuardTests.swift`），
覆盖：命中 → `.textEditing` 且零动作、未命中 → 行为与改动前一致、**`clearPending()` 必须清零计时**、
3.5 在 4/5 之前、1/2/3 在 3.5 之前、tick 期间也要守。

> 其中「清零计时」那条最有价值：它防的是「编辑期间计时还在走，用户刚编辑完手一抖就被切走」。
> 变异测试证明它是**唯一**能抓住「只删 `clearPending()`」这个回归的断言（见 §12.5 M2）。

### 12.2 AX 命中测试不实现的 App + 兜底策略（**未自动化覆盖**）

- **已确认的真机事实**：部分 App **不实现 `accessibilityHitTest:`**，
  对它们调 `AXUIElementCopyElementAtPosition` 返回 **`kAXErrorNotImplemented`（-25208）**。
  已确认清单：**Telegram**（在其窗口可见区域实测 `err=-25208, element=nil`）。
- **修复前**：这里直接 `return nil` → 引擎判「鼠标下没有窗口」（`.noWindow`）→
  **这类 App 永远无法被悬停聚焦**，用户看到的现象就是「滑到那个窗口上没反应」。
- **修复后**：AX 路径的任何失败（错误码 / 找不到 AXWindow / 拿不到 pid）都**兜底到窗口列表命中测试**
  （`hitTestViaWindowList`）。注意**不是**所有分支都兜底：拿到了 windowID 但不在当前 Space 的可见列表里时，
  仍然返回 `isOnScreen=false`（走 `.notOnScreen`），那是「绝不跨 Space」的守卫，不能被兜底吞掉。

**自动化覆盖：无。原因（诚实标注）**：
`performHitTest` / `hitTestViaWindowList` 都是 `private`，且分支由**进程级静态**
`Permissions.isAccessibilityTrusted` 与**真实 AX 调用**共同决定 —— 当前架构下没有任何注入点
能造出「AX 返回 -25208」。本轮**不**为了覆盖率去改热路径（`WindowProbe` 每 33ms 被调一次，
且 UI 层正在并行改动，此时动热路径会同时拉高「测试红」和「装不上」两种风险）。

**可测的重构建议（已与 Lead 对齐，作为独立任务下一轮做）**：把**路由决策**抽成纯函数，
AX 调用留在外壳（不改任何行为）：

```swift
enum HitTestRoute {
    case useAX(windowElement: AXUIElement, pid: pid_t)
    case notOnScreen(windowElement: AXUIElement, pid: pid_t)
    case windowListFallback          // AX 失败 / 找不到 AXWindow / 拿不到 pid
}

static func route(axError: AXError,
                  elementFound: Bool,
                  windowElementFound: Bool,
                  pidAvailable: Bool) -> HitTestRoute
```

这样四条分支都能纯逻辑断言：`-25208 → fallback`、`-25211 → fallback`、
`找不到 AXWindow → fallback`、`成功 → useAX`。

### 12.3 菜单栏图标状态映射（本轮新增 13 条断言）

`StatusIcon.state(...)` 一个函数同时承载 5 个信号，判定顺序错了用户就会看到
「明明关了却显示已开启」或「明明异常却显示正常」。本轮钉死：

- **6 个分支各一条**：`on` / `onRaise` / `off` / `permissionMissing` / `inputMonitoringMissing` / `error`
- **顺序断言**：权限态优先于开关态（未授权 + 已关闭 → `permissionMissing`，引导用户去授权而不是以为被关了）；
  `off` 优先于 `error`（用户主动关掉时不该看到红色告警）；`error` 优先于模式；零权限事件源跳过权限判定
- **`rawValue` 稳定**：它被 `--selftest` 的 `iconState` 字段直接输出，是外部脚本解析的契约面
- **`displayName` 6 个互不相同**：用户靠文字分状态，重复就等于没分
- **`symbolName` 分组不丢**：正常态（on/onRaise/off）与异常态（权限/输入监控/错误）的标识**必须不重叠**

**已变更（记入变更清单）**：菜单栏图标**从 SF Symbol 改为自绘模板图**（`custom.badge.*`）。
原因：用户菜单栏里其他 App 都是彩色有辨识度的图标，SF Symbol 单色线条既没辨识度也「没意思」；
且 `on` / `onRaise` 原来分别用 `arrow.up.forward.app` / `arrow.up.forward.square`，
在 18pt 下几乎一模一样，用户反馈「没变」。现在：正常态用**模板图**（alpha 形状，颜色跟系统明暗走，
不会在彩色壁纸上糊掉），异常态用**彩色**（橙/红实心徽标）抢注意力。
**测试侧含义**：`symbolName` 已不是 SF Symbol 名，只是稳定 id；不要再按 SF Symbol 语义去断言它。

### 12.4 一个**不是我们的 bug**、但极易误判成我们的：WindowServer 拖拽

**现象**：用户报「窗口拖不动」。关键线索 —— **能拖边缘改大小、但不能移动窗口**，
且只影响部分 App（Edge / 微信 / DeepSeek Harness / 网易云），标准窗口 App 正常；
四个出问题的 App **恰好全是自定义标题栏**。

**已排除**：A/B 测试证明**关掉 HoverFocus 也一样拖不动** → 不是 HoverFocus 的拖拽守卫
（那个 bug 是真的、也已修，见 §8.1，但不是本次现象的原因）。另外逐一排除了
Magnet、Rosetta 架构、贴边平铺、AX 窗口结构、「前台但无主窗口」错位、按键残留、指针设置。

**当前判定**：坏的是「**App 自己发起的窗口移动**」这条路径（自定义标题栏的窗口由 App 自己
处理拖动），不是边缘 resize（那条由 WindowServer 直接处理，所以正常）。
**结论仍是未定论**，等用户做两步对照（退出 Snapzy + BetterDisplay；无效则重启后先不开 HoverFocus）。

**取证方法（这条方法论很重要，写下来避免后人重复踩）**：

```bash
# ✅ 正确：限定进程
log show --last 10m --predicate 'process == "WindowServer" AND eventMessage CONTAINS "no client initiated window drag trait gesture"' --style compact

# ⛔ 错误：不限定进程
log show --last 10m --predicate 'eventMessage CONTAINS "no client initiated window drag trait gesture"'
```

**为什么必须加进程谓词**：`logd` 会把**你这条 `log` 命令本身**也纳入可匹配的记录里 ——
命令的 argv 里就含那个搜索字符串，于是统计结果会**把你自己的查询也数进去**，
结论直接失真。这和团队里踩过的「`pgrep -f` 匹配到调用它的 shell 自己」是**同一个坑**
（见 §11.4.1）。**任何按内容搜索日志/进程的取证，都必须限定进程或排除自身。**

### 12.5 变异测试：证明新测试真的能捕获回归（不是走过场）

「测试全绿」本身不能证明测试有价值 —— 也可能是断言写得太松。所以在**仓库外的副本**上做了变异
（`cp -R Sources Tests Scripts /tmp/hf-mut`，改副本、跑副本，**仓库零改动**），看哪些断言会变红：

| 变异 | 改动 | 结果 |
|---|---|---|
| **M1** | 删掉整个 3.5 守卫块 | **9 条失败** —— 全部 9 条文本编辑用例外加边界断言都抓住了 |
| **M2** | 保留守卫、**只删 `clearPending()`** | **恰好 1 条失败**：「编辑期间计时必须归零」—— 精准命中，说明它就是那条回归的唯一守门人 |
| **M3** | `off` 与 `error` 判定顺序对调 | 目标断言红：「总开关关闭时不该显示 error：期望 off，实际 error」 |
| **M4** | 把开关态提到权限态之前 | 目标断言红：「权限态必须先于开关态判：期望 permissionMissing，实际 off」 |
| **M5** | 把 `error` 的 `symbolName` 偷偷改成和 `on` 一样 | 目标断言红 ×2：「错误用错误徽标」+「正常态与异常态的图标标识必须不重叠」 |

> 说明：M3–M5 是在 M2 的副本上继续做的（未回滚 FocusEngine），所以那几轮里
> 「计时归零」那条也会一起红 —— 这是**已知的残留变异**，不是假阳性。
> 每一轮里**被针对的那条断言都准确变红了**，这才是要证明的东西。
