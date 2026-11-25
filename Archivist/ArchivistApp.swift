import AppKit
import ArchivistCore
import SwiftUI

@main
struct ArchivistApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = AppDelegate.store

    init() {
        AppDelegate.neverRestoreWindows()
        #if DEBUG
        if let dir = Snapshot.requestedDirectory { Snapshot.render(to: dir); exit(0) }
        #endif
        if Scheduler.requested { Scheduler.runDue(); exit(0) }   // launched by macOS: no window
        // After the window is the one running: the scheduled helper (every 5 min) must never
        // remove an update the window has staged, or the old copy mid-swap.
        _ = AppSwap.clearLeftovers(for: Bundle.main.bundleURL)
    }

    var body: some Scene {
        WindowGroup("Archivist") {
            RootView()
                .environment(store)
                .modifier(AppearanceChoice())
                .frame(width: 860).frame(minHeight: 417)   // width fixed; smallest holds exactly four source rows (measured: the window adds 32 for its title bar)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 580)
        .windowResizability(.contentSize)   // the window takes the content's limits: only taller or shorter
    }
}

/// No sidebar: the backups sit as titles across the top. Switching backups (the titles) and
/// changing where one goes (the Destination panel) are two separate controls, never one menu.
struct RootView: View {
    @Environment(JobStore.self) private var store
    @State private var selection: Job.ID?

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(selection: $selection)
            if let id = selection, store.jobs.contains(where: { $0.id == id }) {
                JobView(jobID: id).id(id)
            } else {
                Color.clear
                    .onAppear { selection = store.jobs.first?.id }   // a deleted tab: the first one left opens
            }
        }
        .background(Palette.ground.ignoresSafeArea())   // paper to every edge: no strip at the smallest size
        .onChange(of: store.jobs.map(\.id)) { _, ids in
            if let id = selection, ids.contains(id) { return }
            selection = ids.first ?? store.add().id   // never a blank window: the first tab left, or a new one
        }
        .ignoresSafeArea(.container, edges: .top)   // the strip makes room for the traffic lights itself; a changing inset jumped the layout
        .tint(Palette.accent)
        .task {   // scheduled backups, while Archivist is open
            while !Task.isCancelled {
                Scheduler.runDueInApp(store)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .onAppear {
            if store.jobs.isEmpty { store.add() }
            selection = selection ?? store.jobs.first?.id
            DevLog.write("app open: \(store.jobs.count) backups")
            for w in NSApp.windows { w.backgroundColor = NSColor(Palette.ground) }   // the window's own fill, under everything
            Scheduler.sync(store.jobs)   // removes the retired background helper if an older build left one
            #if DEBUG
            DevControl.start(store) { selection = $0 }
            #endif
        }
    }
}

/// The backups as pills across the top: their picture and name, nothing to edit here
/// (name and picture are edited in the Destination panel).
struct TitleStrip: View {
    @Environment(JobStore.self) private var store
    @Binding var selection: Job.ID?
    var drawn = false   // snapshots: no traffic lights to clear
    var previewUpdate: UpdateInfo? = nil   // snapshots: show the pill
    @State private var firstShown: Job.ID?
    private static let roomy = 12   // more backups than this: arrows scroll the tabs

    var body: some View {
        let many = store.jobs.count > Self.roomy
        HStack(alignment: .bottom, spacing: 6) {
            if many { arrow("chevron.left", by: -1) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(store.jobs) { job in tab(job, compact: job.id != selection).id(job.id) }   // only the open tab shows its name
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $firstShown, anchor: .leading)
            .fixedSize(horizontal: !many, vertical: false)
            if many { arrow("chevron.right", by: 1) }
            Button { selection = store.add().id } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.soft).padding(8).padding(.bottom, 2)
                .help("New backup")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                UpdatePill(preset: previewUpdate)
                AppearanceSwitch()
            }
            .padding(.bottom, 8)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.top, drawn ? 0 : 28)        // under the window's traffic lights, so the left edge can line up
        .frame(height: drawn ? 52 : 80, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }   // drawn over the tabs: their bottom edge
    }

    /// A folder tab: rounded on top, square at the bottom, standing on the hairline. The open one is
    /// the colour of its picture's circle, outlined up its sides and over its top, and covers the
    /// hairline under it, so it runs into the page.
    private func tab(_ job: Job, compact: Bool) -> some View {
        let on = job.id == selection
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 10)
        let running = store.runners[job.id]?.running == true
        return HStack(spacing: 8) {
            Badge(icon: job.icon, hex: job.color, size: 26)
                .overlay {   // a running backup: a ring round its picture fills as it copies
                    if running, let r = store.runners[job.id] {
                        Circle().trim(from: 0, to: max(0.03, r.fraction(at: .now)))
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(1)   // hugs the picture
                    }
                }
                .help(running ? "Backing up" : "")
            if !compact {
                Text(job.title.isEmpty ? "Untitled" : job.title)
                    .font(Typeface.title(16))
                    .offset(y: -1.5)   // Bonum's letters sit low in their line: centre them on the picture
                    .foregroundStyle(Color(red: 0.13, green: 0.11, blue: 0.09))   // dark on the light tab, in light and dark mode
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, 8).padding(.trailing, compact ? 8 : 14).padding(.top, 6).padding(.bottom, 7)
        .background(shape.fill(on ? Nippon.soft(job.color) : Nippon.soft(job.color).opacity(0.35)))
        .overlay(shape.stroke(on ? Palette.rule : .clear, lineWidth: 1))
        .zIndex(on ? 1 : 0)
        .contentShape(shape)
        .onTapGesture { selection = job.id }
        .help(compact ? job.title : "")
        .contextMenu {
            Button("Remove backup", role: .destructive) {
                store.remove(job.id)
                if selection == job.id { selection = store.jobs.first?.id }
            }
        }
    }

    private func arrow(_ symbol: String, by step: Int) -> some View {
        Button {
            let ids = store.jobs.map(\.id)
            let i = firstShown.flatMap { ids.firstIndex(of: $0) } ?? 0
            withAnimation(.easeOut(duration: 0.2)) { firstShown = ids[max(0, min(ids.count - 1, i + step))] }
        } label: { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            .buttonStyle(.plain).foregroundStyle(Palette.soft).padding(.horizontal, 4).padding(.bottom, 12)
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.text(14, .semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(Capsule().fill(Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .contentShape(Capsule())
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.text(13, .medium))
            .foregroundStyle(Palette.ink.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().strokeBorder(Palette.rule, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Quitting mid-backup asks first; "Stop and Quit" lets the files in flight finish whole.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let store = JobStore()

    /// The window always opens at launch. The app stays running when its window closes (schedules
    /// need it), so macOS would otherwise remember "no windows" and start with nothing on screen.
    static func neverRestoreWindows() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")   // read by AppKit before the first window
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Self.store
        guard store.anyRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A backup is running"
        alert.informativeText = "Stop it and quit? Files being copied right now finish first; the next backup picks up the rest."
        alert.addButton(withTitle: "Keep Backing Up")
        alert.addButton(withTitle: "Stop and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        store.runners.values.forEach { $0.stop() }
        DevLog.write("quit: stopping running backups")
        // Never wait forever (a slow drive kept the old build from quitting at all): quit when
        // the backups stop or after 5 s. A cut-off file only ever lives under a temp name; the
        // next backup removes it and picks up the rest.
        let deadline = Date().addingTimeInterval(5)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            if !store.anyRunning || Date() > deadline {
                t.invalidate()
                DevLog.write(store.anyRunning ? "quit: 5 s passed, quitting anyway" : "quit: backups stopped")
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Closing the window keeps Archivist running: scheduled backups need it open (no background helper).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// A two-way switch: a circle sliding in a pill, sun on the left, moon on the right. It shows
/// what is on screen now; "Follow the Mac" lives in Settings.
struct AppearanceSwitch: View {
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        Button { appearance = dark ? "light" : "dark" } label: {
            ZStack(alignment: dark ? .trailing : .leading) {
                Capsule().fill(Palette.raised).overlay(Capsule().strokeBorder(Palette.rule, lineWidth: 1))
                    .frame(width: 54, height: 28)
                Emoji(name: dark ? "hoh_mode_dark" : "hoh_mode_light", size: 18)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.accent))   // the app colour
                    .padding(2)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dark)
        }
        .buttonStyle(.plain)
        .help(dark ? "Switch to light" : "Switch to dark")
        .accessibilityLabel(dark ? "Dark mode on" : "Light mode on")
    }
}

struct AppearanceChoice: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}

/// The update road: checks GitHub at launch (retrying while offline), then hourly; a
/// newer signed build is fetched and staged quietly; the green pill offers it, and turns into
/// "Installing… N%" once pressed.
struct UpdatePill: View {
    @State private var update: UpdateInfo?
    @State private var showing = false
    private let preset: Bool
    init(preset: UpdateInfo? = nil) { _update = State(initialValue: preset); self.preset = preset != nil }
    private let updater = Updater.shared
    static let green = Color(red: 0x7B / 255, green: 0xA0 / 255, blue: 0x5B / 255)
    private var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var body: some View {
        ZStack {   // a real view even with nothing to show: an empty Group never runs its .task
            Color.clear.frame(width: 0, height: 0)
            if updater.installing != nil {
                HStack(spacing: 8) {
                    ProgressView(value: updater.progress).progressViewStyle(.circular).controlSize(.small).tint(Self.green)
                    Text("Installing… \(Int(updater.progress * 100))%").font(Typeface.text(12.5, .semibold)).foregroundStyle(Palette.ink)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Self.green.opacity(0.2)))
            } else if let u = update {
                Button { showing = true } label: {
                    HStack(spacing: 6) {
                        Emoji(name: "inbox_tray", size: 16)
                        Text("Update to \(u.version)").font(Typeface.text(12.5, .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Self.green))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showing) {
                    UpdateSheet(update: u, current: current, onLater: { showing = false },
                                onInstall: { showing = false; updater.install(u) })
                }
            }
        }
        .padding(.trailing, 8)
        .task {
            if preset { return }
            for _ in 0..<6 {   // GitHub may be unreachable for a moment at launch
                let status = await Updater.check(current: current)
                if let u = status.update { update = u; updater.prepare(u) }
                guard case .offline = status else { break }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            while !Task.isCancelled {   // then every 15 minutes
                try? await Task.sleep(nanoseconds: 900_000_000_000)
                let status = await Updater.check(current: current)
                if let u = status.update { update = u; updater.prepare(u) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !preset else { return }
            Task {   // coming back to the app asks again
                let status = await Updater.check(current: current)
                if let u = status.update { update = u; updater.prepare(u) }
            }
        }
    }
}
