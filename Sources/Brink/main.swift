import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var accounts: AccountStore!
    private var store: UsageStore!
    private var themeStore: ThemeStore!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        accounts = AccountStore()
        store = UsageStore(accounts: accounts)
        themeStore = ThemeStore(defaultMenuBarAccount: accounts.accounts.first?.id.uuidString ?? "")
        Notifier.shared.requestAuthorizationIfNeeded()
        menuBar = MenuBarController(store: store, accounts: accounts, themeStore: themeStore)
        store.startAutoRefresh(interval: 120)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon: Brink lives in the menu bar
let delegate = AppDelegate()
app.delegate = delegate
app.run()
