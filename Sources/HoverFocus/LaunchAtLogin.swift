//  HoverFocus — 开机自启（app-shell 所有）
//
//  验收标准第 5 条：SMAppService.mainApp 优先，注册失败退回 ~/Library/LaunchAgents plist，
//  并且要在 UI 上**如实**告诉用户当前用的是哪种、成功没有。不许静默失败。
//
//  为什么要有回退：SMAppService 要求 App 有正常的 bundle 且通常已装到 /Applications；
//  在 build/ 里直接跑时注册经常失败。这时候如果只报一句「失败」用户就没法用了，
//  所以退回 LaunchAgent。两种方式的差别（用户可见）：
//    - SMAppService：系统「设置 → 通用 → 登录项」里能看到，可被用户随时关掉
//    - LaunchAgent：一个 plist 文件，不出现在登录项列表里（用户可能觉得「没生效」）
//  所以 UI 必须显示当前到底是哪种，不能含糊。

import Foundation
import ServiceManagement

enum LaunchMechanism: String {
    case smAppService = "SMAppService"
    case launchAgent  = "LaunchAgent"
    case none         = "未启用"

    var displayName: String {
        switch self {
        case .smAppService: return "系统登录项（SMAppService）"
        case .launchAgent:  return "LaunchAgent 回退"
        case .none:         return "未启用"
        }
    }
}

enum LaunchState: String {
    case enabled
    case disabled
    case pendingApproval
    case failed
}

struct LaunchAtLoginStatus {
    var state: LaunchState
    var mechanism: LaunchMechanism
    /// 一句人话，直接显示在菜单里
    var detail: String
    /// 失败原因（成功为 nil）。不许吞。
    var error: String?
    /// LaunchAgent 的 plist 路径（用回退方式时）
    var agentPath: String?

    var isOn: Bool { state == .enabled }
    var needsApproval: Bool { state == .pendingApproval }
    var didFail: Bool { state == .failed }
}

enum LaunchAtLoginError: LocalizedError {
    case noExecutablePath
    case plistWriteFailed(String)
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .noExecutablePath:
            return "拿不到当前可执行文件路径，无法写 LaunchAgent"
        case .plistWriteFailed(let s):
            return "写 LaunchAgent plist 失败：\(s)"
        case .launchctlFailed(let s):
            return "launchctl 加载 LaunchAgent 失败：\(s)"
        }
    }
}

enum LaunchAtLogin {
    static let agentLabel = "com.lunasama.HoverFocus"

    static var agentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    // MARK: - 查询

    static func status() -> LaunchAtLoginStatus {
        let agentExists = FileManager.default.fileExists(atPath: agentPlistURL.path)

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return LaunchAtLoginStatus(
                    state: .enabled, mechanism: .smAppService,
                    detail: "已启用（系统登录项；可在「系统设置 → 通用 → 登录项」里查看/关闭）",
                    error: nil, agentPath: agentExists ? agentPlistURL.path : nil)
            case .requiresApproval:
                return LaunchAtLoginStatus(
                    state: .pendingApproval, mechanism: .smAppService,
                    detail: "已在系统里注册，但需要你批准：打开「系统设置 → 通用 → 登录项」，把 HoverFocus 打开",
                    error: nil, agentPath: agentExists ? agentPlistURL.path : nil)
            case .notFound:
                if !agentExists {
                    return LaunchAtLoginStatus(
                        state: .disabled, mechanism: .none,
                        detail: "未启用（系统没找到本 App 的登录项注册；把 App 装到 /Applications 后更可靠）",
                        error: nil, agentPath: nil)
                }
            case .notRegistered:
                break
            @unknown default:
                break
            }
        }

        if agentExists {
            let loaded = isAgentLoaded()
            return LaunchAtLoginStatus(
                state: .enabled, mechanism: .launchAgent,
                detail: loaded
                    ? "已启用（LaunchAgent 回退方式，已加载；不在系统「登录项」列表里）"
                    : "已写入 LaunchAgent plist，但 launchctl 未确认加载（下次登录可能不生效）",
                error: loaded ? nil : "launchctl 未确认加载 \(agentPlistURL.path)",
                agentPath: agentPlistURL.path)
        }

        return LaunchAtLoginStatus(
            state: .disabled, mechanism: .none,
            detail: "未启用", error: nil, agentPath: nil)
    }

    // MARK: - 开关

    static func setEnabled(_ on: Bool) -> LaunchAtLoginStatus {
        on ? enable() : disable()
    }

    private static func enable() -> LaunchAtLoginStatus {
        var smError: String?

        if #available(macOS 13.0, *) {
            let before = SMAppService.mainApp.status
            if before == .enabled {
                return status()
            }
            if before == .requiresApproval {
                // 已经注册过，只是还没批准 —— 再 register 一次没意义，如实告诉用户
                return status()
            }
            do {
                try SMAppService.mainApp.register()
                let after = status()
                if after.state == .enabled || after.state == .pendingApproval {
                    Log.info("开机自启已启用（SMAppService）")
                    return after
                }
                smError = "register() 未抛错但状态仍是 \(SMAppService.mainApp.status.rawValue)"
            } catch {
                smError = error.localizedDescription
                Log.warn("SMAppService 注册失败，改用 LaunchAgent 回退：\(error.localizedDescription)")
            }
        } else {
            smError = "系统版本低于 macOS 13，没有 SMAppService"
        }

        // 回退：写 LaunchAgent
        do {
            try writeAgentPlist()
            try loadAgent()
            Log.warn("开机自启已启用（LaunchAgent 回退）；SMAppService 失败原因：\(smError ?? "未知")")
            return LaunchAtLoginStatus(
                state: .enabled, mechanism: .launchAgent,
                detail: "已启用（LaunchAgent 回退：SMAppService 不可用 —— \(smError ?? "未知原因")）",
                error: nil, agentPath: agentPlistURL.path)
        } catch {
            let combined = "SMAppService：\(smError ?? "未知原因")；LaunchAgent：\(error.localizedDescription)"
            Log.error("开机自启启用失败 —— \(combined)")
            return LaunchAtLoginStatus(
                state: .failed, mechanism: .none,
                detail: "启用失败，两种方式都没成功", error: combined, agentPath: nil)
        }
    }

    private static func disable() -> LaunchAtLoginStatus {
        var errors: [String] = []

        if #available(macOS 13.0, *) {
            let s = SMAppService.mainApp.status
            if s == .enabled || s == .requiresApproval {
                do {
                    try SMAppService.mainApp.unregister()
                    Log.info("已注销 SMAppService 登录项")
                } catch {
                    errors.append("SMAppService 注销失败：\(error.localizedDescription)")
                }
            }
        }

        if FileManager.default.fileExists(atPath: agentPlistURL.path) {
            do { try unloadAgent() } catch { errors.append("launchctl 卸载失败：\(error.localizedDescription)") }
            do {
                try FileManager.default.removeItem(at: agentPlistURL)
                Log.info("已删除 LaunchAgent plist")
            } catch {
                errors.append("删除 plist 失败：\(error.localizedDescription)")
            }
        }

        var st = status()
        if !errors.isEmpty {
            st.state = .failed
            st.detail = "关闭开机自启时出错"
            st.error = errors.joined(separator: "；")
            Log.error("关闭开机自启出错 —— \(st.error ?? "")")
        }
        return st
    }

    // MARK: - LaunchAgent 实现

    private static func writeAgentPlist() throws {
        let exe = AppInfo.executablePath
        guard !exe.isEmpty else { throw LaunchAtLoginError.noExecutablePath }

        let dir = agentPlistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw LaunchAtLoginError.plistWriteFailed(error.localizedDescription)
        }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
        } catch {
            throw LaunchAtLoginError.plistWriteFailed(error.localizedDescription)
        }
        Log.info("已写入 LaunchAgent：\(agentPlistURL.path) → \(exe)")
    }

    private static func loadAgent() throws {
        let uid = getuid()
        let domain = "gui/\(uid)"

        // 先试现代的 bootstrap；已经加载过会返回非 0，那种情况不算失败
        let boot = run("/bin/launchctl", ["bootstrap", domain, agentPlistURL.path])
        if boot.code == 0 || isAgentLoaded() { return }

        // 退回老式 load（新系统上已 deprecated 但仍可用）
        let load = run("/bin/launchctl", ["load", "-w", agentPlistURL.path])
        if load.code == 0 || isAgentLoaded() { return }

        let detail = [boot.stderr, load.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        throw LaunchAtLoginError.launchctlFailed(detail.isEmpty ? "launchctl 退出码 \(load.code)" : detail)
    }

    private static func unloadAgent() throws {
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)", agentPlistURL.path])
        _ = run("/bin/launchctl", ["unload", "-w", agentPlistURL.path])
    }

    private static func isAgentLoaded() -> Bool {
        let uid = getuid()
        let r = run("/bin/launchctl", ["print", "gui/\(uid)/\(agentLabel)"])
        return r.code == 0
    }

    // MARK: - 跑命令

    private struct CommandResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(code: -1, stdout: "", stderr: "无法执行 \(launchPath)：\(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            code: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
