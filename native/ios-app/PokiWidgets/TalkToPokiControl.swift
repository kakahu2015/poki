import AppIntents
import SwiftUI
import WidgetKit

/// Talk to kaka as a control: in Control Center, on the Lock Screen and under the Action Button's
/// Controls. It runs TalkToPokiIntent, which opens kaka.
struct TalkToPokiControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PokiTalk") {
            ControlWidgetButton(action: TalkToPokiIntent()) {
                Label(String(localized: "Talk to kaka", table: "Entry"), systemImage: "waveform.circle")
            }
        }
        .displayName(LocalizedStringResource("Talk to kaka", table: "Entry"))
        .description(LocalizedStringResource("Opens kaka and starts talking.", table: "Entry"))
    }
}
