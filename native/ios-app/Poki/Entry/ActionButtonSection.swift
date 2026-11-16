import SwiftUI

/// Settings › Models › Voice: where to put kaka on the Action Button, in Control Center and on the Lock Screen.
struct ActionButtonSection: View {
    var body: some View {
        Section {
            Label {
                Text("Settings › Action Button › Controls › Talk to kaka", tableName: "Entry")
            } icon: {
                Image(systemName: "button.programmable")
            }
        } header: {
            Text("Action Button", tableName: "Entry")
        } footer: {
            Text("Press and hold the Action button to open kaka and start talking. To type a task instead, choose Shortcut there, then Send Task. Control Center and the Lock Screen can hold Talk to kaka too.", tableName: "Entry")
        }
    }
}
