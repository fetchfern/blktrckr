import Sparkle
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var state: AppState
    @State private var sidebarSelection = MainWindowSection.timeBlocks
    let updater: SPUUpdater

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("Time Blocks", systemImage: "clock")
                    .tag(MainWindowSection.timeBlocks)
                Label("Summaries", systemImage: "chart.bar.xaxis")
                    .tag(MainWindowSection.summaries)
                Label("Settings", systemImage: "gearshape")
                    .tag(MainWindowSection.settings)
            }
            .navigationTitle("blktrckr")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch sidebarSelection {
            case .timeBlocks:
                TimeBlocksScreen()
                    .environmentObject(state)
            case .summaries:
                SummariesView()
                    .environmentObject(state)
            case .settings:
                SettingsView(updater: updater)
                    .environmentObject(state)
            }
        }
        .sheet(isPresented: $state.isStartPresented) {
            StartBlockView()
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTimeBlocksWindow)) { _ in
            sidebarSelection = .timeBlocks
        }
        .onChange(of: sidebarSelection) { _, section in
            if section != .timeBlocks {
                state.selectedBlockID = nil
            }
        }
    }
}

private enum MainWindowSection: Hashable {
    case timeBlocks
    case summaries
    case settings
}

private struct TimeBlocksScreen: View {
    @EnvironmentObject private var state: AppState
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        VStack(spacing: 0) {
            if !state.warnings.isEmpty {
                VStack(spacing: 1) {
                    ForEach(state.warnings) { warning in
                        WarningBanner(warning: warning)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 22) {
                DateNavigationView()

                TimelineView()
                    .environmentObject(state)
                    .frame(minHeight: 260, idealHeight: 360, maxHeight: .infinity)

                Divider()

                HStack(alignment: .top, spacing: 40) {
                    SelectedBlockDetails()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Total worked today")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(TimeText.duration(state.totalForSelectedDay(calendar: calendar)))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                    }
                    .frame(minWidth: 180, alignment: .trailing)
                }
            }
            .padding(24)
        }
        .navigationTitle("Time Blocks")
        .onChange(of: state.selectedDate) { _, _ in
            guard let selected = state.selectedBlock else { return }
            let day = calendar.dayInterval(containing: state.selectedDate)
            if selected.intersection(with: day, now: state.now) == nil {
                state.selectedBlockID = nil
            }
        }
    }
}

private struct WarningBanner: View {
    @EnvironmentObject private var state: AppState
    let warning: AppWarning

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(warning.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if warning.kind == .notifications {
                Button("Notification Settings") { state.openNotificationSettings() }
            }
            if warning.kind == .action {
                Button {
                    state.dismissWarning(warning.kind)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.yellow.opacity(0.12))
    }
}

private struct DateNavigationView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDatePickerPresented = false
    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        HStack(spacing: 14) {
            Button {
                state.selectedDate = calendar.date(byAdding: .day, value: -1, to: state.selectedDate) ?? state.selectedDate
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(DateNavigationButtonStyle())
            .help("Previous day")

            HStack(spacing: 8) {
                Text(state.selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.title2.weight(.semibold))
                    .fixedSize()

                Button {
                    isDatePickerPresented.toggle()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(DateNavigationButtonStyle())
                .help("Choose date")
                .popover(isPresented: $isDatePickerPresented, arrowEdge: .bottom) {
                    DatePicker("Date", selection: $state.selectedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                }
            }

            Button {
                state.selectedDate = calendar.date(byAdding: .day, value: 1, to: state.selectedDate) ?? state.selectedDate
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(DateNavigationButtonStyle())
            .help("Next day")

            Spacer()

            if !calendar.isDateInToday(state.selectedDate) {
                Button("Today") { state.selectedDate = Date() }
            }
        }
    }
}

private struct DateNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 28)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.18 : 0.10),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SelectedBlockDetails: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var eventAppearances: EventAppearanceStore
    @State private var editedName = ""
    @State private var editedDescription = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        Group {
            if let block = state.selectedBlock {
                VStack(alignment: .leading, spacing: 8) {
                    if block.isActive {
                        HStack(spacing: 7) {
                            if let icon = eventAppearances.icon(for: block.name) {
                                Image(systemName: icon)
                            }
                            Text(block.name)
                        }
                        .font(.title3.weight(.semibold))
                    } else {
                        HStack(spacing: 7) {
                            if let icon = eventAppearances.icon(for: block.name) {
                                Image(systemName: icon)
                            }
                            TextField("Name", text: $editedName)
                                .textFieldStyle(.plain)
                                .focused($nameFocused)
                                .onSubmit(commitName)
                                .onChange(of: nameFocused) { _, focused in
                                    if !focused { commitName() }
                                }
                        }
                        .font(.title3.weight(.semibold))
                    }

                    TextField("Add description", text: $editedDescription, axis: .vertical)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .focused($descriptionFocused)
                        .onSubmit(commitDescription)
                        .onChange(of: descriptionFocused) { _, focused in
                            if !focused { commitDescription() }
                        }

                    Text(block.stopLabel)
                        .foregroundStyle(.secondary)
                }
                .id(block.id)
                .onAppear {
                    editedName = block.name
                    editedDescription = block.description ?? ""
                }
                .onChange(of: block.name) { _, newValue in editedName = newValue }
                .onChange(of: block.description) { _, newValue in
                    editedDescription = newValue ?? ""
                }
            } else {
                Text("Select a time block to see its details.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let block = state.selectedBlock else { return }
        guard !trimmed.isEmpty else { editedName = block.name; return }
        if trimmed != block.name, !state.renameSelected(to: trimmed) { editedName = block.name }
    }

    private func commitDescription() {
        guard let block = state.selectedBlock else { return }
        let normalized = BlockDescription.normalized(editedDescription)
        guard normalized != block.description else { return }
        if !state.updateSelectedDescription(normalized) {
            editedDescription = block.description ?? ""
        }
    }
}
