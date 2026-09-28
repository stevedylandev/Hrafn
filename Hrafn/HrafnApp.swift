//
//  HrafnApp.swift
//  Hrafn
//
//  Created by Steve Simkins on 9/26/26.
//

import SwiftUI
import HrafnServices

@main
struct HrafnApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    private var app: AppModel { delegate.app }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .preferredColorScheme(app.appearance.mode.colorScheme)
                .fontDesign(app.appearance.font.design)
                .tint(app.appearance.accent)
                .task { await app.start() }
                .task(id: app.manager.accounts.isEmpty) {
                    // UI tests would meet the permission alert mid-flow.
                    guard !app.manager.accounts.isEmpty,
                          !ProcessInfo.processInfo.arguments.contains("--no-notification-prompt") else { return }
                    await AppDelegate.registerForNotifications()
                }
                .onOpenURL { app.handle($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            // XEP-0352 while nobody is looking; after a grace period, log out
            // and leave new messages to push. On return, log in again.
            switch phase {
            case .active: app.enterForeground()
            case .background: app.enterBackground()
            default: break
            }
        }
    }
}
