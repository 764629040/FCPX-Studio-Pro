import AppKit

// ─────────────────────────────────────────
//  AppDelegate
// ─────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // R51: 运行时主动注入官方高分辨率应用图标，确保程序坞 (Dock) 与系统任务切换器 100% 点亮
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let iconImg = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = iconImg
        } else if let iconImg = NSImage(contentsOfFile: "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/FCPX Studio Pro.app/Contents/Resources/AppIcon.icns") {
            NSApp.applicationIconImage = iconImg
        }

        buildMainMenu()

        let wc = MainWindowController()
        self.windowController = wc
        wc.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // TR-006: 进程退出前显式释放 52888 监听端口与 Bonjour 广播（内核回收之外的双保险）。
    // 关看板 / 切换窗口不触发这里，用户手动控制不被打断。
    func applicationWillTerminate(_ notification: Notification) {
        TeamP2PSyncManager.shared.stopServer()
        TeamP2PSyncManager.shared.stopBrowsing()
    }

    @objc func showSettings(_ sender: Any?) {
        if let wc = windowController {
            wc.openSettings(sender)
        } else {
            SettingsWindowController.shared.show()
        }
    }

    // ── 菜单构建 ──────────────────────────────
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 FCPX Studio Pro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        // R31 / A-64：原生壳此前没有设置界面，这里新建入口（与素材库 ⚙️ 同一面板）
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 FCPX Studio Pro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        // 文件菜单：单文件（⌘O）与目录（⇧⌘O）分开，语义清晰
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")

        let openFiles = NSMenuItem(title: "打开 PSD 文件…",
                                   action: #selector(MainWindowController.openPsdFiles(_:)),
                                   keyEquivalent: "o")
        openFiles.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(openFiles)

        let openDir = NSMenuItem(title: "打开 PSD 目录…",
                                 action: #selector(MainWindowController.openPsdDirectory(_:)),
                                 keyEquivalent: "O")
        openDir.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openDir)

        fileItem.submenu = fileMenu

        // 图层菜单（R36 / D-74: ⌘L 锁定，⌘H 隐藏）
        let layerItem = NSMenuItem()
        mainMenu.addItem(layerItem)
        let layerMenu = NSMenu(title: "图层")
        let lockItem = NSMenuItem(title: "切换锁定状态",
                                  action: #selector(MainWindowController.toggleLayerLockMenuAction(_:)),
                                  keyEquivalent: "l")
        lockItem.keyEquivalentModifierMask = [.command]
        layerMenu.addItem(lockItem)

        let hideItem = NSMenuItem(title: "切换显示/隐藏",
                                  action: #selector(MainWindowController.toggleLayerVisibilityMenuAction(_:)),
                                  keyEquivalent: "h")
        hideItem.keyEquivalentModifierMask = [.command]
        layerMenu.addItem(hideItem)
        layerItem.submenu = layerMenu

        // 窗口菜单
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        winMenu.addItem(NSMenuItem(title: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        winItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }
}

// ─────────────────────────────────────────
//  Entry Point
// ─────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.regular)
if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
   let iconImg = NSImage(contentsOfFile: iconPath) {
    app.applicationIconImage = iconImg
} else if let iconImg = NSImage(contentsOfFile: "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/FCPX Studio Pro.app/Contents/Resources/AppIcon.icns") {
    app.applicationIconImage = iconImg
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
