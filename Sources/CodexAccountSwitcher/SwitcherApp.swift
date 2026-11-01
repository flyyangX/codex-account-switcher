import SwitcherCore
import AppKit
import SwiftUI

@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(SwitcherAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("API 用量与赠额", id: "api-usage") {
            APIUsageWindowRoot(delegate: appDelegate)
        }
        .defaultSize(width: 940, height: 820)

        MenuBarExtra {
            if APIAppMode.usesIsolatedStartup {
                APIMonitorMenu(model: appDelegate.apiUsage)
            } else {
                MenuBarPopover(model: appDelegate.model, updater: appDelegate.updater,
                               tiboForecast: appDelegate.tiboForecast)
            }
        } label: {
            MenuBarStatusLabel(model: appDelegate.model, updater: appDelegate.updater)
        }
        .menuBarExtraStyle(.window)
        .commands {
            QuitApplicationCommands(model: appDelegate.model)
        }
    }
}

private struct APIUsageWindowRoot: View {
    let delegate: SwitcherAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        APIUsageView(model: delegate.apiUsage)
            .onAppear {
                delegate.reopenAPIWindow = { openWindow(id: "api-usage") }
            }
    }
}

private struct APIMonitorMenu: View {
    @ObservedObject var model: APIUsageModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Codex API Monitor", systemImage: "chart.bar.xaxis").font(.headline)
            Text(model.organization?.name ?? "尚未连接 API 组织").font(.caption).foregroundStyle(.secondary)
            Button("API 用量与赠额") {
                openWindow(id: "api-usage")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }.padding(16).frame(width: 260, alignment: .leading)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater

    var body: some View {
        HStack(spacing: 4) {
            MenuBarLogo()
                .overlay(alignment: .topTrailing) {
                    if updater.availableVersion != nil {
                        Circle().fill(.blue).frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }
            if model.settings.showsMenuBarPercentage,
               let remainingPercent = model.activeRemainingPercent {
                Text("\(remainingPercent)%")
                    .monospacedDigit()
            }
        }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(menuBarAccessibilityLabel)
    }

    private var menuBarAccessibilityLabel: String {
        let updateStatus = updater.availableVersion.map { ", " + model.format("update_available", $0) } ?? ""
        guard model.settings.showsMenuBarPercentage,
              let remainingPercent = model.activeRemainingPercent
        else {
            return "Codex Account Switcher" + updateStatus
        }
        return "Codex Account Switcher, \(remainingPercent)%" + updateStatus
    }
}

private struct MenuBarLogo: View {
    private static let logicalSize = NSSize(width: 17.5, height: 17.5)

    private static let image: NSImage = {
        let resourceBundleName = "CodexAccountSwitcher_CodexAccountSwitcher.bundle"
        let resourceBundle = [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .compactMap { $0 }
            .map { $0.appending(path: resourceBundleName) }
            .compactMap { Bundle(url: $0) }
            .first
        guard let url = resourceBundle?.url(
            forResource: "account-switcher-logo",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing account-switcher-logo.png")
        }
        image.size = logicalSize
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .frame(width: 17.5, height: 17.5)
            .accessibilityHidden(true)
    }
}

private struct QuitApplicationCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button(model.text("quit")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
