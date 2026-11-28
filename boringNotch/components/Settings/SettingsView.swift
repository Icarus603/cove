//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AVFoundation
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import Sparkle
import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    @State private var selectedTab = ProcessInfo.processInfo.environment["COVE_SETTINGS_TAB"] ?? "General"
    @State private var accentColorUpdateTrigger = UUID()

    let updaterController: SPUStandardUpdaterController?

    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updaterController = updaterController
    }

    private static let sidebarGroups: [(title: LocalizedStringKey, items: [(id: String, title: LocalizedStringKey, icon: String)])] = [
        ("Notch", [
            ("General", "General", "gear"),
            ("Appearance", "Appearance", "eye"),
            ("Modules", "Modules", "square.grid.2x2"),
        ]),
        ("Features", [
            ("Media", "Media", "play.laptopcomputer"),
            ("Calendar", "Calendar", "calendar"),
            ("HUD", "HUDs", "dial.medium.fill"),
            ("Battery", "Battery", "battery.100.bolt"),
            ("Shelf", "Shelf", "books.vertical"),
            ("Player", "Player", "play.rectangle"),
            ("Photos", "Photos", "photo.on.rectangle"),
            ("Notes", "Notes", "note.text"),
            ("Markets", "Markets", "chart.line.uptrend.xyaxis"),
        ]),
        ("Agents", [
            ("Agents", "Connections", "sparkles"),
            ("AgentDisplay", "Agent Display", "rectangle.3.group"),
            ("AgentMascots", "Mascots", "face.smiling"),
            ("AgentSound", "Sounds", "speaker.wave.2"),
            ("AgentAutomation", "Automation", "bolt.badge.automatic"),
            ("AgentRemote", "Remote Hosts", "network"),
            ("AgentBuddy", "Buddy", "dot.radiowaves.left.and.right"),
            ("AgentHooks", "Hooks", "link"),
        ]),
        ("More", [
            ("Shortcuts", "Shortcuts", "keyboard"),
            ("Advanced", "Advanced", "gearshape.2"),
            ("About", "About", "info.circle"),
        ]),
    ]

    /// The sidebar can be made narrower or wider, within 190 to 300 pt (as in the Player library window), and stays as it was left.
    @AppStorage("settings.sidebarWidth") private var sidebarWidth: Double = 220

    private var pageTitle: LocalizedStringKey {
        Self.sidebarGroups.flatMap(\.items).first { $0.id == selectedTab }?.title ?? "General"
    }

    private var sidebar: some View {
            List {
                ForEach(Self.sidebarGroups.indices, id: \.self) { index in
                    Section(Self.sidebarGroups[index].title) {
                        ForEach(Self.sidebarGroups[index].items, id: \.id) { item in
                            let selected = selectedTab == item.id
                            Button {
                                selectedTab = item.id
                            } label: {
                                Label {
                                    Text(item.title)
                                        .foregroundStyle(selected ? Color.white : Color.primary)
                                } icon: {
                                    Image(systemName: item.icon)
                                        .foregroundStyle(selected ? Color.white : Color.effectiveAccent)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? Color.effectiveAccent : Color.clear)
                                    .padding(.horizontal, 6)
                            )
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
    }

    /// The page's name. It sits in the title bar's own band, level with the window buttons,
    /// while the Quit button lives in the window's NSToolbar so AppKit hit-testing always reaches it on every page.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(pageTitle).font(.system(size: 17, weight: .bold)).lineLimit(1)
            Spacer()
        }
        .frame(height: ToolbarMetrics.height)
        .padding(.horizontal, 16)
        .frame(height: ImmersiveChrome.titleBarBand, alignment: .center)
    }

    private var detail: some View {
        Group {
                switch selectedTab {
                case "General":
                    GeneralSettings()
                case "Appearance":
                    Appearance()
                case "Media":
                    Media()
                case "Calendar":
                    CalendarSettings()
                case "HUD":
                    HUD()
                case "Battery":
                    Charge()
                case "Shelf":
                    Shelf()
                case "Player":
                    PlayerSettings()
                case "Photos":
                    PhotoSettings()
                case "Notes":
                    NotesSettings()
                case "Markets":
                    MarketsSettings()
                case "Shortcuts":
                    Shortcuts()
                case "Modules":
                    ModulesSettings()
                case "Agents":
                    AgentsSettings()
                case "AgentDisplay", "AgentMascots", "AgentSound", "AgentAutomation", "AgentRemote", "AgentBuddy", "AgentHooks":
                    AgentSettingsPage(id: selectedTab)
                case "Advanced":
                    Advanced()
                case "About":
                    if let controller = updaterController {
                        About(updaterController: controller)
                    } else {
                        // Fallback with a default controller
                        About(
                            updaterController: SPUStandardUpdaterController(
                                startingUpdater: false, updaterDelegate: nil,
                                userDriverDelegate: nil))
                    }
                default:
                    GeneralSettings()
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        // Laid out by hand rather than with a system split view: that one lets the sidebar be dragged away entirely, and with no button to
        // bring it back it is gone for good. This one has a width between 190 and 300 pt and cannot leave it.
        HStack(spacing: 0) {
            sidebar
                .frame(width: CGFloat(sidebarWidth))
                .sidebarBackground()
            SidebarDivider(width: $sidebarWidth)
                .ignoresSafeArea(.container, edges: .top)
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 0.5)
                detail
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .formStyle(.grouped)
        // Fills the window: a fixed width left the content as a 700 pt column in the middle of a zoomed or enlarged window.
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CoveSelectSettingsTab"))) { note in
            if let id = note.object as? String { selectedTab = id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}
