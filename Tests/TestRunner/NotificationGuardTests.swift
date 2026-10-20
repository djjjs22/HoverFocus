//  HoverFocus — 通知类窗口守卫测试
//  ─────────────────────────────────────────────────────────────────────────
//  为什么单独测这条：开关开着的时候，**一次误判 = 用户未读消息被标成已读**，
//  而且不可逆（未读小红点再也回不来了）。用户把鼠标移到通知横幅上只是
//  想看看谁发了什么 —— 这时候替他切焦点，等于替他把消息「读掉」。
//
//  这条规则有两种错法，代价都很高：
//    · 漏判 → 悬停横幅仍然切焦点 → 消息被读掉（用户抱怨的那种情况）
//    · 误判 → 把「通知中心的全屏不可见背板」当成横幅 → **所有悬停都不工作了**
//  所以两个方向都写用例，尤其是「背板必须放过」那条。
//
//  规则本身抽成了纯函数（WindowProbe.isNotificationOverlay），
//  因为真实的通知横幅在测试环境里造不出来。
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreGraphics

/// 一块 2048×1152 的屏幕（本机实测尺寸）
private let screenArea: CGFloat = 2048 * 1152

/// 实测的真实横幅：通知中心，1680,64，360×180
private let bannerBounds = CGRect(x: 1680, y: 64, width: 360, height: 180)

func runNotificationGuardTests() {
    TestHarness.shared.beginSuite("通知类窗口守卫（未读消息保护）")

    test("通知守卫：横幅内部 → 挡住（不漏判）") {
        let inside = CGPoint(x: bannerBounds.midX, y: bannerBounds.midY)
        expectTrue(WindowProbe.isNotificationOverlay(ownerName: "通知中心",
                                                     bounds: bannerBounds,
                                                     isOnScreen: true,
                                                     screenArea: screenArea,
                                                     point: inside),
                   "指针在通知横幅内必须挡住，否则聚焦会把未读消息标成已读")
}

    test("通知守卫：横幅外部 → 不挡（不误伤正常功能）") {
        let outside = CGPoint(x: 600, y: 500)
        expectTrue(!WindowProbe.isNotificationOverlay(ownerName: "通知中心",
                                                      bounds: bannerBounds,
                                                      isOnScreen: true,
                                                      screenArea: screenArea,
                                                      point: outside),
                   "指针不在横幅上时不能挡，否则正常悬停切焦点就废了")
}

    test("通知守卫：全屏背板 → 必须放过（否则所有悬停都失效）") {
        // 通知中心除横幅外还有一个铺满屏幕的不可见背板窗口。
        // 它同样 owner=通知中心、同样包含任意一个点 —— 如果被当成横幅，
        // **整个屏幕上任何位置都会被挡住，悬停切焦点彻底不工作**。
        let backdrop = CGRect(x: 0, y: 0, width: 2048, height: 1152)
        let anywhere = CGPoint(x: 600, y: 500)
        expectTrue(!WindowProbe.isNotificationOverlay(ownerName: "通知中心",
                                                      bounds: backdrop,
                                                      isOnScreen: true,
                                                      screenArea: screenArea,
                                                      point: anywhere),
                   "铺满屏幕的背板窗口必须放过，否则所有悬停都会被挡掉")
}

    test("通知守卫：普通 App 的窗口 → 不挡") {
        let edgeWindow = CGRect(x: 284, y: 69, width: 1116, height: 1024)
        expectTrue(!WindowProbe.isNotificationOverlay(ownerName: "Microsoft Edge",
                                                      bounds: edgeWindow,
                                                      isOnScreen: true,
                                                      screenArea: screenArea,
                                                      point: CGPoint(x: 600, y: 500)),
                   "普通 App 窗口不该被通知守卫挡住")
}

    test("通知守卫：不在屏上的通知窗口 → 不挡") {
        let inside = CGPoint(x: bannerBounds.midX, y: bannerBounds.midY)
        expectTrue(!WindowProbe.isNotificationOverlay(ownerName: "通知中心",
                                                      bounds: bannerBounds,
                                                      isOnScreen: false,
                                                      screenArea: screenArea,
                                                      point: inside),
                   "不在屏上的窗口不该挡")
}

    test("通知守卫：owner 名字为空 → 不挡（宁可放过也别误挡）") {
        let inside = CGPoint(x: bannerBounds.midX, y: bannerBounds.midY)
        expectTrue(!WindowProbe.isNotificationOverlay(ownerName: nil,
                                                      bounds: bannerBounds,
                                                      isOnScreen: true,
                                                      screenArea: screenArea,
                                                      point: inside),
                   "owner 未知时保守地不挡 —— 误挡会让整个工具不工作，代价比漏判更大")
}
}
