import AppKit
import ArchivistCore
import SwiftUI

@main
struct ArchivistApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = AppDelegate.store

    init() {
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
                .frame(minWidth: 780, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 580)
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
            }
        }
        .background(Palette.ground)
        .ignoresSafeArea(.container, edges: .top)   // the strip makes room for the traffic lights itself; a changing inset jumped the layout
        .tint(Palette.accent)
        .onAppear {
            if store.jobs.isEmpty { store.add() }
            selection = selection ?? store.jobs.first?.id
            DevLog.write("app open: \(store.jobs.count) backups")
            Scheduler.sync(store.jobs)   // a new build re-registers the helper (or removes a stale one)
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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(store.jobs) { job in
                let on = job.id == selection
                HStack(spacing: 8) {
                    Badge(icon: job.icon, hex: job.color, size: 26)
                    Text(job.title.isEmpty ? "Untitled" : job.title)
                        .font(Typeface.title(16))
                        .offset(y: -1.5)   // Bonum's letters sit low in their line: centre them on the picture
                        .foregroundStyle(on ? Palette.ink : Palette.soft)
                        .fontWeight(.regular)
                    if store.runners[job.id]?.running == true {
                        Circle().fill(Palette.accent).frame(width: 7, height: 7).help("Backing up")
                    }
                }
                .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                .background(Capsule().fill(on ? Palette.accent.opacity(0.32) : .clear))   // fill only: an outline left stray lines at the ends
                .contentShape(Capsule())
                .onTapGesture { selection = job.id }
                .contextMenu {
                    Button("Remove backup", role: .destructive) {
                        store.remove(job.id)
                        if selection == job.id { selection = store.jobs.first?.id }
                    }
                }
            }
            Button { selection = store.add().id } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.soft).padding(8)
                .help("New backup")
            Spacer()
            UpdatePill(preset: previewUpdate)
            AppearanceSwitch()
        }
        .padding(.leading, 24)                // the pills' inner padding puts their pictures on Sources' 28 pt edge
        .padding(.trailing, 16)
        .padding(.top, drawn ? 0 : 28)        // under the window's traffic lights, so the left edge can line up
        .padding(.bottom, 9)
        .frame(height: drawn ? 52 : 80, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.store.anyRunning }
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
