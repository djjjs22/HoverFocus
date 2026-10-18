//  HoverFocus — 应用元信息（app-shell 所有）
//
//  版本号从 Info.plist 读；直接用裸二进制跑（不在 .app 里）时 infoDictionary 拿不到，
//  所以必须有 fallback —— 契约要求 --selftest 输出 "version":"0.1.0"。

import Foundation

enum AppInfo {
    /// 与 Resources/Info.plist 的 CFBundleShortVersionString 保持一致
    static let fallbackVersion = "0.1.0"

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.lunasama.HoverFocus"
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    static var appBundlePath: String {
        Bundle.main.bundlePath
    }

    /// 是否跑在真正的 .app bundle 里（而不是裸二进制）。
    /// 开机自启的 LaunchAgent 回退路径依赖这个：裸二进制没有 bundle 标识，装了也不该开机自启。
    static var isRunningFromBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 一行版本串，给菜单和诊断面板用
    static var versionLine: String {
        "HoverFocus \(version) (\(buildNumber))"
    }
}
