import SwiftUI

struct StartBlockView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var reminder = ReminderChoice.thirtyMinutes
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var suggestion: String? {
        NameCompletion.suggestion(for: name, usages: state.nameUsages)
    }

    private var suggestionSuffix: String? {
        guard let suggestion,
              suggestion.lowercased().hasPrefix(name.lowercased()),
              suggestion.count > name.count else { return nil }
        return String(suggestion.dropFirst(name.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(state.activeBlock == nil ? "Start Time Block" : "Start a New Time Block")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline)
                ZStack(alignment: .leading) {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(start)
                    if let suffix = suggestionSuffix {
                        HStack(spacing: 0) {
                            Text(name).foregroundStyle(.clear)
                            Text(suffix).foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.tab) {
                    guard let suggestion else { return .ignored }
                    name = suggestion
                    return .handled
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.subheadline)
                TextField("Optional details", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            HStack {
                Text("Remind me every")
                Spacer()
                Picker("Remind me every", selection: $reminder) {
                    ForEach(ReminderChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if state.activeBlock != nil {
                Text("Starting this block will stop the current block at the same time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Could not start time block: \(errorMessage)")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 410)
        .onAppear { nameFocused = true }
    }

    private func start() {
        switch state.startBlock(name: name, description: description, reminder: reminder) {
        case .started:
            errorMessage = nil
            dismiss()
        case .failed(let message):
            errorMessage = message
        }
    }
}
