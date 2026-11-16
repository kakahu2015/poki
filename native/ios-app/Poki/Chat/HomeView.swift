import PokiCore
import SwiftUI

// The home page and the way from it into the conversation. The home page carries the Kaka mark;
// the conversation keeps only its navigation buttons in the top bar.

// MARK: Timing

/// The change from the home page to the conversation: the mark and greeting fade out together
/// (`flight`, 0.35 s); the pills fade and sink 14 points in 180 ms, the light takes from 60 to 510 ms to sink to the bottom
/// edge, the new-conversation button turns up on 300 to 480 ms, and your words rise out of the message
/// field on their own spring (response 0.45, damping 0.85). Every piece is driven by the
/// one fact "the conversation has begun", so the change can be turned round at any moment. With
/// Reduce Motion the page cross-fades in 200 ms.
enum HomeMotion {
    /// The side of the Kaka mark over the greeting on the home page.
    static let homeAvatar: CGFloat = 80
    static let button: CGFloat = 48
    private static let fade = Animation.easeInOut(duration: 0.2)
    /// The two rows of suggestions, in points a second: positive goes left, negative right. Slow, and
    /// a little apart, so the rows never move as one.
    static let pillSpeeds: (top: Double, bottom: Double) = (20, -18)
    /// `-pokiSlow 4` plays the whole change four times slower, for a slow-motion recording of it.
    static let slow = max(1, UserDefaults.standard.double(forKey: "pokiSlow"))
    /// Every animation of the change goes through here, delays included.
    static func paced(_ animation: Animation) -> Animation { slow > 1 ? animation.speed(1 / slow) : animation }

    /// The home mark and greeting fade as the conversation begins, and return for a new one.
    static func flight(_ reduce: Bool) -> Animation { paced(reduce ? fade : .smooth(duration: 0.35)) }
    /// The message field taking the home page up, or letting it down.
    static let lift = Animation.snappy(duration: 0.3)

    static func ground(_ reduce: Bool) -> Animation { paced(reduce ? fade : .easeInOut(duration: 0.45).delay(0.06)) }
    static func pills(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.25).delay(0.3) : .easeIn(duration: 0.18))
    }
}

// MARK: Kaka mark

/// The site's mark on the same round ground used by the welcome pages.
struct PokiPortrait: View {
    var mood: PokiMood
    var side: CGFloat = HomeMotion.homeAvatar

    var body: some View {
        ZStack {
            Circle().fill(Tint.portrait)
            Image("KakaMark").resizable().scaledToFit()
                .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// The Kaka mark over the home greeting, on a pale blue ground with a soft blue shadow.
struct PokiPicture: View {
    var side: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        PokiPortrait(mood: .ready, side: HomeMotion.homeAvatar)
            .scaleEffect(side / HomeMotion.homeAvatar)
            .frame(width: side, height: side)
            .shadow(color: dark ? Color(hex: 0x3C8DFF).opacity(0.35) : Color(hex: 0x0177FD).opacity(0.18), radius: dark ? 8 : 7, y: 4)
    }
}

/// The Kaka mark's place over the home greeting.
enum PicturePlace: Hashable { case home }

struct PicturePlaceKey: PreferenceKey {
    static let defaultValue: [PicturePlace: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PicturePlace: Anchor<CGRect>], nextValue: () -> [PicturePlace: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks where the home mark sits; the page draws it there (`PokiFlight`).
    func picturePlace(_ place: PicturePlace) -> some View {
        anchorPreference(key: PicturePlaceKey.self, value: .bounds) { [place: $0] }
    }
}

/// The home mark over the greeting. It leaves the screen when the conversation begins; tapping it
/// opens the status card.
struct PokiFlight: View {
    var home: Bool
    var writing = false
    var places: [PicturePlace: CGRect]
    var tap: () -> Void
    /// The bottom of the mark over the greeting, in global points, for the status card to open under it.
    var landed: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if home, let place = places[.home] {
                Button(action: tap) {
                    PokiPicture(side: HomeMotion.homeAvatar).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "kaka"))
                .accessibilityIdentifier("home.poki")
                .onGeometryChange(for: CGFloat?.self) { $0.frame(in: .global).maxY } action: {
                    if let bottom = $0 { landed(bottom) }
                }
                .position(x: place.midX, y: place.midY)
                .animation(reduceMotion ? nil : HomeMotion.lift, value: writing)
                .transition(.opacity)
            }
        }
        .animation(HomeMotion.flight(reduceMotion), value: home)
    }
}

// MARK: Top bar

/// The chat's top: conversations on the left and a new conversation on the right. The message list
/// passes behind the floating buttons through the system's scroll edge effect.
struct ChatTopBar: View {
    var home: Bool
    /// A task is under way: no new conversation until it ends or is stopped.
    var busy: Bool
    /// Opens the conversations (the drawer on iPhone); nil where the list is always beside the chat.
    var openThreads: (() -> Void)?
    var newConversation: () -> Void
    /// Taps on New Conversation on the home page, for a light tap in the hand.
    @State private var homeTaps = 0

    var body: some View {
        HStack {
            if let openThreads {
                Button(action: openThreads) { glyph("line.3.horizontal") }
                    .buttonStyle(.plain)
                    .glassSurface(in: Circle(), interactive: true)
                    .accessibilityLabel(Text("Conversations"))
                    .accessibilityIdentifier("chat.threads")
            }
            Spacer(minLength: 8)
            Button {
                if home { homeTaps += 1 }
                newConversation()
            } label: {
                glyph("square.and.pencil", dim: busy)
            }
            .buttonStyle(.plain)
            .glassSurface(in: Circle(), interactive: !busy)
            .allowsHitTesting(!busy)
            .sensoryFeedback(.impact(weight: .light), trigger: homeTaps)
            .accessibilityLabel(Text("New Conversation"))
            .accessibilityIdentifier("home.newChat")
        }
        .padding(.top, 4)
        .glassGroup()
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 4)
        .frame(maxWidth: 720)
        // A bar's controls stop growing where the system's bars do.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func glyph(_ symbol: String, dim: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.label).opacity(dim ? 0.35 : 1))
            .frame(width: HomeMotion.button, height: HomeMotion.button)
            .contentShape(.circle)
    }
}

// MARK: Home page

/// The default quick actions, until the owner's own take their place (`HomeShortcuts`): each an app
/// and what to do in it, the shape every pill on the home page has.
@MainActor
enum HomeIdea {
    private static func idea(_ app: String, _ text: String) -> HomeShortcut? {
        guard let capsule = AppCapsule.catalog.first(where: { $0.names.contains(app) }), let shown = ShortcutApp.named(capsule.id) else { return nil }
        return HomeShortcut(key: HomeShortcuts.normalize(text), app: shown.id, appName: shown.name, text: text,
                            prompt: CapsuleText.prefill(app: app, sentence: text))
    }
    /// An app by its bundle ID, the action its pill shows and the whole request a tap puts in the field.
    private static func idea(app: String, _ text: String, prompt: String) -> HomeShortcut? {
        guard let shown = ShortcutApp.named(app) else { return nil }
        return HomeShortcut(key: HomeShortcuts.normalize(prompt), app: shown.id, appName: shown.name, text: text, prompt: prompt)
    }

    static var examples: [HomeShortcut] { examples(for: .current) }

    /// The fixed key keeps Forget stable across language changes. The carried mark also appears
    /// when GitHub is not installed, so the task can explain how to install it.
    static var star: HomeShortcut {
        HomeShortcut(key: "starpokiongithub", app: "", appName: "GitHub", text: AppLocalization.text(LocalizedStringResource("Star this repo")),
                     prompt: AppLocalization.text(LocalizedStringResource("Open the GitHub app on this iPhone, go to the JosssphZhou/poki repository, and star it. If the app is not installed, stop and ask me to install it from the App Store. Do not use a browser. If I am not signed in, stop on the login screen and let me sign in myself. If I have already starred the repository, tell me and leave it starred.")), icon: "github")
    }

    static func examples(for language: AppLanguage) -> [HomeShortcut] {
        language == .simplifiedChinese ? simplifiedChinese : english
    }

    private static var english: [HomeShortcut] {
        [idea("Slack", AppLocalization.text(LocalizedStringResource("Tell the team I’m late"))),
         idea("Messages", AppLocalization.text(LocalizedStringResource("Text Mom I’m on my way"))),
         idea("Uber", AppLocalization.text(LocalizedStringResource("Book a ride home"))),
         idea("Starbucks", AppLocalization.text(LocalizedStringResource("Order my usual coffee"))),
         idea("Notes", AppLocalization.text(LocalizedStringResource("Add milk to my list"))),
         idea("Instagram", AppLocalization.text(LocalizedStringResource("Post today’s photo")))].compactMap { $0 }
    }

    /// The apps people in mainland China use every day, written in Chinese rather than translated from
    /// the English set. A tap only fills the field and the caret lands at the end, so a request that
    /// needs a contact, a topic, a product or a place ends where that goes, for the owner to finish.
    private static var simplifiedChinese: [HomeShortcut] {
        [idea(app: "com.tencent.xin", "发消息", prompt: "用微信发一条消息给"),
         idea(app: "com.taobao.taobao4iphone", "查物流", prompt: "打开淘宝，看看我最近一单的物流到哪了"),
         idea(app: "com.dianping.dpscope", "找附近餐厅", prompt: "用大众点评找附近评分高的餐厅"),
         idea(app: "com.meituan.itakeaway", "点外卖", prompt: "打开美团外卖，帮我看看附近有什么好吃的"),
         idea(app: "com.xunmeng.pinduoduo", "查订单", prompt: "打开拼多多，看看我的订单到哪了"),
         idea(app: "com.xingin.discover", "搜攻略", prompt: "在小红书搜一下攻略："),
         idea(app: "com.taobao.fleamarket", "看我的闲置", prompt: "打开闲鱼，看看我发布的闲置有没有新消息"),
         idea(app: "com.360buy.jdmobile", "查价格", prompt: "在京东查一下价格："),
         idea(app: "com.baidu.map", "导航回家", prompt: "打开百度地图，导航回家"),
         idea(app: "com.autonavi.amap", "查路线", prompt: "打开高德地图，查一下路线，目的地是")].compactMap { $0 }
    }
}

/// The home page's greeting (ESP-474): a hello for the time of day, as a chat app greets you (morning
/// from 5, afternoon from 11, evening from 18, late from 23), and what you would like done.
enum HomeGreeting {
    /// The two lines as VoiceOver reads them: the hello and the question, as one sentence.
    static func spoken(at date: Date = .now) -> String {
        let first = hello(at: date)
        return first + (first.hasSuffix("，") ? "" : " ") + ask
    }

    static func hello(at date: Date = .now, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<11: AppLocalization.text(LocalizedStringResource("Good morning."))
        case 11..<18: AppLocalization.text(LocalizedStringResource("Good afternoon."))
        case 18..<23: AppLocalization.text(LocalizedStringResource("Good evening."))
        default: AppLocalization.text(LocalizedStringResource("Up late."))
        }
    }

    /// The line under the hello, the same at any hour.
    static var ask: String { AppLocalization.text(LocalizedStringResource("What can I do for you?")) }
}

/// The greeting as the home page draws it, for the time `date` falls in: the hello in ink and the
/// question in grey under it, centred under the Kaka mark. System Semibold 28 tracked in by 0.6,
/// with no space between the lines.
struct HomeGreetingView: View {
    var date: Date
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 28

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) {
            Text(verbatim: HomeGreeting.hello(at: date))
                .foregroundStyle(dark ? Color(hex: 0xF4F4F1) : Color(hex: 0x111110))
            // One line at any type size: at the largest sizes two lines of it reach down to the pills.
            Text(verbatim: HomeGreeting.ask)
                .foregroundStyle(dark ? Color(hex: 0x8D8D87) : Color(hex: 0x6F6F69))
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .font(.system(size: size, weight: .semibold))
        .tracking(-0.6 * size / 28)
        .multilineTextAlignment(.center)
        // Read as one sentence: in Chinese the hello's comma runs on into the question.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: HomeGreeting.spoken(at: date)))
        .accessibilityAddTraits(.isHeader)
    }
}

/// The home page, before your first message: under the Kaka mark at the top, two
/// lines of greeting a little above the middle, and things you could ask as two
/// rows of glass pills over the message field. A pill fills the message field; nothing is sent until
/// you send it.
struct HomePage<Footer: View>: View {
    var home: Bool
    /// Suggestions yield their space while the message field has focus.
    var writing = false
    var pick: (String) -> Void
    @ViewBuilder var footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.coveredByDrawer) private var covered
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private let shortcutStore = HomeShortcutStore.shared
    /// Picked as the page comes in, so it does not change while you look at it.
    @State private var greetedAt = Date.now
    /// The pill whose menu is open, and where it is on the screen: both rows stand still under it.
    @State private var held: HeldShortcut?
    /// The pill whose Edit popup is open.
    @State private var editing: HomeShortcut?
    /// Edit was picked from the menu: its popup opens once the menu has gone.
    @State private var editNext: HomeShortcut?
    /// The Edit popup's sentence has the keyboard: the suggestions yield their space, as they do to the
    /// message field's, which rises over that keyboard too.
    @State private var editorTyping = false
    /// The page's place on the screen, for the menu's anchor.
    @State private var page = CGRect.zero
    /// Counts the long presses, for a tap in the hand.
    @State private var holds = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        // The mark sits 16 points over the greeting.
                        Color.clear.frame(width: HomeMotion.homeAvatar, height: HomeMotion.homeAvatar)
                            .picturePlace(.home)
                            .padding(.bottom, 4)
                        HomeGreetingView(date: greetedAt)
                        footer()
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    // Keep the greeting in the same vertical position under the navigation buttons.
                    .padding(.top, writing ? 24 : max(24, min(112, geometry.size.height * 0.29 - 72)))
                    .opacity(home ? 1 : 0)
                    .animation(HomeMotion.flight(reduceMotion), value: home)
                    .onChange(of: home) { _, shown in if shown { greetedAt = .now } }

                    Spacer(minLength: 24)
                    if !writing, !editorTyping {
                        VStack(spacing: 8) {
                            let shortcuts = shortcutStore.shortcuts
                            // Three on top, or the larger half of more than six.
                            let top = max(3, (shortcuts.count + 1) / 2)
                            row(Array(shortcuts.prefix(top)), at: 0, speed: HomeMotion.pillSpeeds.top, start: 64)
                            if shortcuts.count > top { row(Array(shortcuts.dropFirst(top)), at: 1, speed: HomeMotion.pillSpeeds.bottom, start: 0) }
                        }
                        .padding(.top, 2)
                        // A sideways drag on the rows scrolls them; it does not pull the drawer out.
                        .scrollsSideways(home)
                        .opacity(home ? 1 : 0)
                        .offset(y: home || reduceMotion ? 0 : 14)
                        .animation(HomeMotion.pills(home, reduceMotion), value: home)
                    }
                    Spacer().frame(height: 34)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(HomeMotion.lift, value: writing)
        .animation(HomeMotion.lift, value: editorTyping)
        .task(id: SessionStore.shared.sessions.count) {
            shortcutStore.refresh(sessions: SessionStore.shared.sessions, routines: RoutineStore.shared.routines)
        }
        .onChange(of: AppLocalization.language) { _, _ in
            shortcutStore.refresh(sessions: SessionStore.shared.sessions, routines: RoutineStore.shared.routines)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { page = $0 }
        // The menu, over the pill (the owner: it opened under the pill, on the message field). The
        // system's context menu chooses its own side and took the lower one, so the menu is a popover,
        // which takes the side it is given, stays on the screen and points at the pill. The arrow is on
        // the popover's bottom edge, so the popover is over the pill (seen on iOS 27: `.top` put it under).
        .popover(item: $held, attachmentAnchor: .rect(.rect(menuAnchor)), arrowEdge: .bottom) { held in
            ShortcutMenu(edit: { editNext = held.shortcut; self.held = nil },
                         forget: { self.held = nil; shortcutStore.forget(held.shortcut) })
                // One presentation at a time: the popup waits for the menu to go.
                .onDisappear { if let next = editNext { editNext = nil; edit(next) } }
        }
        .fullScreenCover(item: $editing) { shortcut in
            ShortcutEditor(shortcut: shortcut, typing: { editorTyping = $0 }) { sentence, app in
                shortcutStore.edit(shortcut, sentence: sentence, app: app)
            }
        }
        .onChange(of: editing) { _, open in if open == nil { editorTyping = false } }
        .sensoryFeedback(.impact(weight: .medium), trigger: holds)
    }

    /// The part of the pressed pill that shows, in the page's own points: a pill at an end of a row is
    /// partly off the screen, and the menu's arrow points at what can be seen of it.
    private var menuAnchor: CGRect {
        guard let frame = held?.frame else { return .zero }
        let seen = frame.intersection(page.insetBy(dx: 16, dy: 0))
        return (seen.isNull ? frame : seen).offsetBy(dx: -page.minX, dy: -page.minY)
    }

    /// The Edit popup comes without the cover's slide; its card fades in itself (`ShortcutEditor`).
    private func edit(_ shortcut: HomeShortcut) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { editing = shortcut }
    }

    /// One row of pills that goes by on its own, slowly and without an end, and that a finger stops,
    /// moves and flicks (`Marquee`). It stands still with Reduce Motion, in Low Power Mode, while the
    /// phone runs hot and while the keyboard is up, and its clock stops when the page is not in front or the drawer is open. With VoiceOver it is a plain row, each pill
    /// once. The two ends fade out over 32 points, glass included. The first row starts a little way
    /// along, so the two rows do not line up.
    private func row(_ ideas: [HomeShortcut], at index: Int, speed: Double, start: CGFloat) -> some View {
        Marquee(speed: speed, spacing: 8, start: start, edgeFade: 32, running: !reduceMotion && !DeviceStrain.shared.resting && !writing && !PerfSwitch.on(.pillsStill),
                active: home && scenePhase == .active && !covered, loops: !voiceOver, stopped: busy) {
            ForEach(ideas) { idea in
                ShortcutPill(idea: idea, row: index, locked: busy, pick: { pick(idea.prompt) },
                             hold: { frame in
                                 guard home, !busy else { return }
                                 holds += 1
                                 held = HeldShortcut(shortcut: idea, frame: frame)
                             },
                             edit: { edit(idea) }, forget: { shortcutStore.forget(idea) })
            }
        }
    }

    /// A pill's menu or its Edit popup is open, or about to: the rows stand still, and no pill is tapped.
    private var busy: Bool { held != nil || editing != nil || editNext != nil }
}

/// A pill under a long press: the quick action, and where its pill is on the screen.
private struct HeldShortcut: Identifiable {
    var shortcut: HomeShortcut
    var frame: CGRect
    var id: String { shortcut.id }
}

/// One pill of a row: the app's icon, its name and the action, the name and the action in one size and
/// told apart by weight and shade (the owner: the name and the words after it did not match). An edited
/// one with no app this iPhone knows is Poki's icon and the words. A tap picks it and a long press
/// opens its menu. `Marquee` lays every pill out several times over, so where the one under the
/// finger is on the screen is kept here, by each copy.
private struct ShortcutPill: View {
    var idea: HomeShortcut
    /// 0 for the top row, 1 for the bottom one.
    var row: Int
    /// A menu or the Edit popup is open: the finger lifting after the long press is not a tap.
    var locked: Bool
    var pick: () -> Void
    /// A long press, with the pill's frame on the screen.
    var hold: (CGRect) -> Void
    var edit: () -> Void
    var forget: () -> Void
    @State private var place = ScreenPlace.Probe()

    var body: some View {
        Button { if !locked { pick() } } label: {
            HStack(spacing: 8) {
                AppIconView(app: idea.app, size: 24, alwaysLight: true, carried: idea.icon)
                HStack(spacing: 5) {
                    if !idea.appName.isEmpty {
                        Text(verbatim: idea.appName).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label))
                    }
                    Text(verbatim: idea.text).font(.subheadline).foregroundStyle(Color(.label).opacity(0.7))
                }
                .lineLimit(1)
            }
            .padding(.leading, 12).padding(.trailing, 18).frame(minHeight: 48)
            .contentShape(.capsule)
        }
        .pillButtonStyle(row: row)
        .background(ScreenPlace(probe: place))
        // Under the glass: on the outside, the glass took the long press and the pill fired as a tap.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in hold(place.frame) })
        .livePillGlass()
        .accessibilityLabel(Text(verbatim: [idea.appName, idea.text].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityHint(Text("Puts this in the message field"))
        // What the menu offers, for VoiceOver, which has no long press.
        .accessibilityAction(named: Text("Edit"), edit)
        .accessibilityAction(named: Text("Forget"), forget)
        .accessibilityIdentifier("home.idea." + (idea.app.isEmpty ? idea.icon ?? "poki" : idea.app))
        // Said here and not on the row: the pills live in the scroll view's own hosting view.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// Where a view is on the screen at this moment, asked of UIKit: a row goes by on a transform of its
/// hosting view and on its scroll view's position (`Marquee`), and SwiftUI's own geometry follows neither.
private struct ScreenPlace: UIViewRepresentable {
    final class Probe {
        weak var view: UIView?
        var frame: CGRect { view.map { $0.convert($0.bounds, to: nil) } ?? .zero }
    }

    var probe: Probe

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probe.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { probe.view = view }
}

/// A pill's menu: Edit and Forget, listed as a system menu lists them, in a popover over the pill.
private struct ShortcutMenu: View {
    var edit: () -> Void
    var forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("Edit", symbol: "pencil", ink: Color(.label), action: edit)
                .accessibilityIdentifier("shortcut.menu.edit")
            item("Forget", symbol: "eye.slash", ink: Color(.systemRed), action: forget)
                .accessibilityIdentifier("shortcut.menu.forget")
        }
        .padding(.vertical, 6)
        .frame(minWidth: 190)
        .presentationCompactAdaptation(.popover)
    }

    private func item(_ title: LocalizedStringKey, symbol: String, ink: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body).foregroundStyle(ink)
            .padding(.horizontal, 18).frame(minHeight: 46).contentShape(.rect)
        }
        .buttonStyle(ShortcutRowStyle())
    }
}

/// The suggestion pills' surface. They go by over the home light, which is never still, so live glass
/// on them sampled and refracted a changing picture every frame they moved. Here the surface is drawn
/// as that glass looks over the light (a sheet of the light's own colour, a bright rim inside the edge) and it
/// samples nothing, so a pill that only moves is not drawn again. A press lifts the pill a little, as
/// the glass's own reaction to a touch did. Reduce Transparency makes the sheet opaque and Increase
/// Contrast gives it a firmer edge.
///
/// Not yet the default: laid beside the live glass it shows (the glass bends the light at a pill's ends
/// and, in dark mode, has a fine dark edge), so the owner chooses from the two side by side first. Until
/// then the pills stay live glass. `drawnByDefault` turns the drawn surface on for every build;
/// `-pokiPerf drawnPills` turns it on in a debug build, and `pillsNoGlass` draws no surface at all.
enum PillLook {
    static let drawnByDefault = false
    static var drawn: Bool { (drawnByDefault || PerfSwitch.on(.drawnPills)) && !PerfSwitch.on(.pillsNoGlass) }
    static var live: Bool { !drawn && !PerfSwitch.on(.pillsNoGlass) }
}

extension View {
    @ViewBuilder fileprivate func pillButtonStyle(row: Int) -> some View {
        if PillLook.drawn { buttonStyle(PillButtonStyle(row: row)) } else { buttonStyle(.plain) }
    }

    @ViewBuilder fileprivate func livePillGlass() -> some View {
        if PillLook.live { glassSurface(in: Capsule(), interactive: true) } else { self }
    }
}

private struct PillButtonStyle: ButtonStyle {
    /// 0 for the top row, 1 for the bottom one: they sit over different parts of the light.
    var row: Int

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { PillSheet(row: row, pressed: configuration.isPressed) }
            .scaleEffect(configuration.isPressed ? PillSheet.pressScale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// The numbers are read off the live glass over the home light in the simulator (iOS 27, the light
/// held at one moment): the sheet as the colour and share that, laid over the light, gives the glass's
/// colour inside the pill; a bright rim three pixels wide inside the edge; in light mode a darker line
/// two pixels wide just outside it.
private struct PillSheet: View {
    var row: Int
    var pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let pressScale: CGFloat = 1.04
    /// Light: one sheet for both rows. Dark: the glass brightens the deeper blue under the bottom row more.
    static let light = (sheet: Color(red: 221 / 255, green: 252 / 255, blue: 1), share: 0.55)
    static let dark = [(sheet: Color(red: 57 / 255, green: 134 / 255, blue: 1), share: 0.32),
                       (sheet: Color(red: 24 / 255, green: 109 / 255, blue: 1), share: 0.74)]
    static let rim = (light: Color.white.opacity(0.75), dark: Color(red: 80 / 255, green: 170 / 255, blue: 1).opacity(0.55))
    static let outline = Color.black.opacity(0.13)

    var body: some View {
        let dark = scheme == .dark, shape = Capsule()
        let tone = dark ? Self.dark[min(max(row, 0), 1)] : Self.light
        let share = min(1, tone.share + (pressed ? 0.15 : 0))
        ZStack {
            if reduceTransparency {
                shape.fill(Color(.secondarySystemBackground))
            } else {
                shape.fill(tone.sheet.opacity(share))
            }
            shape.strokeBorder(contrast == .increased ? Color(.separator) : dark ? Self.rim.dark : Self.rim.light, lineWidth: 1)
            if !dark { shape.inset(by: -1 / 3).stroke(Self.outline, lineWidth: 2 / 3) }
        }
    }
}

