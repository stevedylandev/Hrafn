import SwiftUI
import HrafnServices

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.manager.accounts.isEmpty {
            NavigationStack {
                AccountSetupView(isOnboarding: true)
            }
        } else {
            @Bindable var app = app
            TabView(selection: $app.tab) {
                ConversationListView()
                    .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                    .tag(AppTab.chats)
                ContactListView()
                    .tabItem { Label("Contacts", systemImage: "person.2") }
                    .tag(AppTab.contacts)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gear") }
                    .tag(AppTab.settings)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
