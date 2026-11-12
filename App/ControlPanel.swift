import SwiftUI
import UIKit

/// The ScrollGuard panel: a native sheet over Instagram, opened by touching and holding the top
/// edge of the screen.
struct ControlPanel: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var youtube: YouTubeModel
    @EnvironmentObject private var notifier: Notifier
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusHeader(isProtecting: store.settings.isProtecting,
                                 blocked: browser.blockedCount, hidden: browser.hiddenCount)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    Picker("Site", selection: $store.platform) {
                        ForEach(Platform.allCases) { platform in
                            Label(platform.title, systemImage: platform.symbol).tag(platform)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Or swipe left or right across the top edge of the screen.")
                }

                Section {
                    FilterToggle(title: "Hide Shorts",
                                 detail: "Removes the Shorts tab, shelves and cards, and stops the Shorts viewer.",
                                 isOn: $store.settings.hideShorts)
                    Button {
                        youtube.reload()
                        dismiss()
                    } label: {
                        Label("Reload YouTube", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("YouTube")
                } footer: {
                    Text("Normal videos stay, however short. Hidden so far: \(youtube.hiddenCount), stopped: \(youtube.blockedCount).")
                }

                Section {
                    FilterToggle(title: "Hide Reels",
                                 detail: "Removes the Reels tab and suggested reels.",
                                 isOn: $store.settings.hideReels)
                    FilterToggle(title: "Block the Reels viewer",
                                 detail: "Stops every way into endless scrolling.",
                                 isOn: $store.settings.blockReelsFeed)
                    FilterToggle(title: "One clip at a time",
                                 detail: "An opened clip stays alone: no swiping on to other reels.",
                                 isOn: $store.settings.singleClip)
                } header: {
                    Text("Instagram")
                } footer: {
                    Text("Clips posted by people you follow stay in your feed.")
                }

                Section {
                    FilterToggle(title: "Instagram messages",
                                 detail: "When the count of unread conversations rises.",
                                 isOn: $store.settings.notifyInstagram)
                    FilterToggle(title: "YouTube activity",
                                 detail: "When the count on YouTube's bell rises (signed in).",
                                 isOn: $store.settings.notifyYouTube)
                    if notifier.authorization == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Allow notifications in Settings", systemImage: "bell.slash")
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Only while ScrollGuard is open: the sites are read as they are on screen, never fetched in the background. Counts only, no names or text.")
                }
                .onChange(of: store.settings.notifyInstagram) { _, on in if on { notifier.requestPermission() } }
                .onChange(of: store.settings.notifyYouTube) { _, on in if on { notifier.requestPermission() } }

                Section {
                    FilterToggle(title: "Native tab bar",
                                 detail: "A bar that stays put, in place of Instagram's own.",
                                 isOn: $store.settings.nativeBar)
                    FilterToggle(title: "Page transitions",
                                 detail: "A short slide when a page opens.",
                                 isOn: $store.settings.pageTransitions)
                } header: {
                    Text("Feel")
                }

                Section {
                    Button {
                        browser.loadHome()
                        dismiss()
                    } label: {
                        Label("Go to feed", systemImage: "house")
                    }
                    Button {
                        browser.reload()
                        dismiss()
                    } label: {
                        Label("Reload page", systemImage: "arrow.clockwise")
                    }
                }

                Section {
                    LabeledContent("Instagram account", value: accountText)
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear browsing data", systemImage: "trash")
                    }
                } footer: {
                    Text("You sign in on Instagram's own page. ScrollGuard never sees or stores your password.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("ScrollGuard \(DeviceInfo.appVersion)")
                }
            }
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle("ScrollGuard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear browsing data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear and sign out", role: .destructive) {
                    Task { await browser.clearBrowsingData() }
                    dismiss()
                }
            } message: {
                Text("Removes cookies, caches and site data. You will have to sign in to Instagram again.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear {
            browser.refreshSignInState()
            notifier.refreshAuthorization()
        }
    }

    private var accountText: String {
        switch browser.isSignedIn {
        case true?: return "Signed in"
        case false?: return "Signed out"
        case nil: return "Checking…"
        }
    }
}

private struct StatusHeader: View {
    let isProtecting: Bool
    let blocked: Int
    let hidden: Int

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isProtecting ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isProtecting ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(isProtecting ? "Reels are hidden" : "Protection is reduced")
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                StatTile(value: blocked, label: "Blocked")
                StatTile(value: hidden, label: "Hidden")
            }
            Text("Since the app was opened")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct StatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct FilterToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color.accentColor)
    }
}

/// The log of what the app did, with one button to copy all of it. This is what to send when
/// something does not work on the phone.
struct DiagnosticsView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var log: DiagnosticsLog
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        UIPasteboard.general.string = await browser.makeReport()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        copied = true
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy report", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } footer: {
                Text("The report describes the kinds of pages opened, errors, what was blocked and the structure of the page on screen. It has no account names, no conversation or post ids, no text from pages, no passwords and no cookie values. It leaves the phone only if you send it.")
            }

            if !log.previousSession.isEmpty {
                Section("Previous session") {
                    ForEach(Array(log.previousSession.enumerated()), id: \.offset) { item in
                        LogLine(text: item.element)
                    }
                }
            }

            Section("This session") {
                ForEach(log.entries.reversed()) { entry in
                    LogLine(text: log.line(entry))
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LogLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
