#  HoverFocus 构建入口
#
#  注意：不要用 swift build / swift test —— 本机 SwiftPM 已损坏（见 Scripts/build.sh 顶部说明）。

.PHONY: all app run test probe install clean kill quit dmg dmg-verify

all: app

## 构建 build/HoverFocus.app
app:
	@bash Scripts/build.sh

## 构建并启动
run:
	@bash Scripts/build.sh --run

## 跑单元测试（手写测试运行器，不依赖 XCTest）
test:
	@bash Scripts/test.sh

## 构建权限/命中测试探针 build/hf-probe
probe:
	@bash Scripts/build-probe.sh

## 安装到 /Applications 并启动
install:
	@bash Scripts/install.sh

## 端到端悬停验证（需要已授予辅助功能权限）
e2e:
	@bash Scripts/e2e-hover-test.sh

# ── 关于停止实例：绝对不要按进程名 kill ────────────────────────────────────
#  用户的 /Applications/HoverFocus.app 进程名也叫 HoverFocus。`pkill -x HoverFocus`
#  会把用户日常在用的那份一起杀掉，而且不还回来 —— 这件事真实发生过（见
#  docs/VERIFICATION.md §11）。所以下面两个 target 都按**完整路径**精确定位。

## 只停「build/ 下的开发实例」；/Applications 里那份不受影响
kill:
	@PIDS="$$(pgrep -f "$(CURDIR)/build/HoverFocus.app/Contents/MacOS/HoverFocus" || true)"; \
	if [ -n "$$PIDS" ]; then \
	  kill $$PIDS 2>/dev/null; echo "已停止 build/ 下的 HoverFocus（pid: $$PIDS）"; \
	else \
	  echo "build/ 下没有在跑的 HoverFocus；/Applications 那份不受影响（要停它请用 make quit）"; \
	fi

## 停掉「已安装到 /Applications 的那份」——这是显式操作，会明确告诉你怎么恢复
quit:
	@if [ -x /Applications/HoverFocus.app/Contents/MacOS/HoverFocus ]; then \
	  PIDS="$$(pgrep -f "/Applications/HoverFocus.app/Contents/MacOS/HoverFocus" || true)"; \
	  if [ -n "$$PIDS" ]; then \
	    kill $$PIDS 2>/dev/null; echo "已停止已安装的 HoverFocus（pid: $$PIDS）"; \
	    echo "要重新启动：open /Applications/HoverFocus.app"; \
	  else \
	    echo "已安装的 HoverFocus 没有在运行"; \
	  fi; \
	else \
	  echo "/Applications 下没有 HoverFocus.app（还没安装？用 make install）"; \
	fi

clean:
	rm -rf build

# ── 打包 ────────────────────────────────────────────────────────────────
#  打 dmg 到 dist/。默认不重新构建（先跑 make app），要一步到位用 make dmg-build。
#  覆盖已存在的 dmg 需要加 --yes，所以这里默认传 --yes —— 打包是可重复动作，
#  旧产物被覆盖是预期行为，不值得为此加交互确认。

## 打包 dist/HoverFocus-<版本>.dmg
dmg:
	@bash Scripts/make-dmg.sh --yes

## 重新构建 + 打包，一步到位
dmg-build:
	@bash Scripts/make-dmg.sh --build --yes

## 挂载 dmg 验证内容（结构 / 隐藏标记 / 签名 / 能不能跑）
dmg-verify:
	@bash Tools/verify-dmg.sh
