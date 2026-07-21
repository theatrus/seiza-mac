import SwiftUI

struct FITSStretchControlsView: View {
    @Binding var stages: [FITSStretchConfiguration]
    @Binding var selectedStageIndex: Int
    @Binding var extractsBackground: Bool
    let supportsColor: Bool
    let canUndo: Bool
    let canRedo: Bool
    let isPreviewRendering: Bool
    let previewError: String?
    let undo: () -> Void
    let redo: () -> Void
    let pickSymmetryPoint: () -> Void
    let preview: (FITSStretchStack, Bool) -> Void
    let clearPreview: () -> Void
    let save: (FITSStretchStack, Bool) -> Void
    let cancel: () -> Void

    @State private var previewTask: Task<Void, Never>?
    @State private var handledDismissal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FITS Stretch")
                    .font(.headline)
                Spacer()
                Button("Reset Stage") {
                    stages[selectedStageIndex] = .default
                }
                .controlSize(.small)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Stretch Stages")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(action: addStage) {
                                Label("Add Stage", systemImage: "plus")
                            }
                            .help("Add another stretch stage")
                            Button(action: undo) {
                                Label("Undo Stretch", systemImage: "arrow.uturn.backward")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!canUndo)
                            .help("Undo last stretch")
                            Button(action: redo) {
                                Label("Redo Stretch", systemImage: "arrow.uturn.forward")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!canRedo)
                            .help("Redo stretch")
                        }

                        ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                            HStack(spacing: 4) {
                                Button {
                                    selectedStageIndex = index
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("\(index + 1)")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16, alignment: .trailing)
                                        Text(stage.type.title)
                                            .lineLimit(1)
                                        Spacer()
                                        if index == 0 {
                                            Text("First")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                index == selectedStageIndex
                                                    ? Color.accentColor.opacity(0.18)
                                                    : .clear
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Stage \(index + 1), \(stage.type.title)")
                                .accessibilityValue(
                                    index == selectedStageIndex ? "Selected" : ""
                                )

                                Button {
                                    moveStage(at: index, by: -1)
                                } label: {
                                    Label("Move Stage Up", systemImage: "chevron.up")
                                        .labelStyle(.iconOnly)
                                }
                                .disabled(index == 0)
                                .help("Move stage earlier")

                                Button {
                                    moveStage(at: index, by: 1)
                                } label: {
                                    Label("Move Stage Down", systemImage: "chevron.down")
                                        .labelStyle(.iconOnly)
                                }
                                .disabled(index == stages.count - 1)
                                .help("Move stage later")

                                Button(role: .destructive) {
                                    removeStage(at: index)
                                } label: {
                                    Label("Remove Stage", systemImage: "xmark")
                                        .labelStyle(.iconOnly)
                                }
                                .disabled(stages.count == 1)
                                .help("Remove stage")
                            }
                            .controlSize(.small)
                            .font(.caption)
                        }

                        Text("Stages run from top to bottom at full floating-point precision. Select one to edit it; add, remove, or reorder without closing this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Remove background gradient", isOn: $extractsBackground)
                        Text("Fit and subtract a smooth background from linear FITS samples before the first stretch stage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    LabeledContent("Method") {
                        Picker("Method", selection: configurationBinding.type) {
                            Section("Automatic") {
                                stretchChoices(FITSStretchType.automatic)
                            }
                            Section("Manual") {
                                stretchChoices(FITSStretchType.manual)
                            }
                            Section("Utility") {
                                stretchChoices(FITSStretchType.utility)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    Text(configuration.type.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration.type.title)
                            .font(.subheadline.weight(.semibold))
                        parameterControls
                    }

                    if supportsColor {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Color")
                                .font(.subheadline.weight(.semibold))
                            Picker("Color handling", selection: configurationBinding.colorStrategy) {
                                ForEach(FITSStretchColorStrategy.allCases) { strategy in
                                    Text(strategy.title)
                                        .tag(strategy)
                                        .help(strategy.help)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            Text(configuration.colorStrategy.help)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let validationMessage = configuration.validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isPreviewRendering {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating live preview…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let previewError {
                        Label(previewError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 520)

            Divider()

            HStack {
                Button("Cancel") {
                    handledDismissal = true
                    cancel()
                }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Changes") {
                    handledDismissal = true
                    save(FITSStretchStack(stages: stages), extractsBackground)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(stages.contains { $0.validationMessage != nil })
            }
            .padding(12)
        }
        .frame(width: 430)
        .onAppear {
            selectedStageIndex = min(max(selectedStageIndex, 0), stages.count - 1)
            schedulePreview()
        }
        .onChange(of: stages) { _, _ in
            schedulePreview()
        }
        .onChange(of: extractsBackground) { _, _ in
            schedulePreview()
        }
        .onDisappear {
            previewTask?.cancel()
            if !handledDismissal {
                clearPreview()
            }
        }
    }

    @ViewBuilder
    private func stretchChoices(_ choices: [FITSStretchType]) -> some View {
        ForEach(choices) { type in
            Text(type.title)
                .tag(type)
                .help(type.help)
        }
    }

    @ViewBuilder
    private var parameterControls: some View {
        switch configuration.type {
        case .autoMtf:
            StretchParameterRow(
                title: "Target median",
                value: configurationBinding.targetMedian,
                range: 0.01...0.95,
                step: 0.01
            )
            StretchParameterRow(
                title: "Shadows clipping",
                value: configurationBinding.shadowsClip,
                range: -10...0,
                step: 0.1
            )
        case .percentileAsinh:
            StretchParameterRow(
                title: "Black percentile",
                value: configurationBinding.blackPercentile,
                range: 0...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "White percentile",
                value: configurationBinding.whitePercentile,
                range: 0.01...1,
                step: 0.001
            )
            StretchParameterRow(
                title: "Strength",
                value: configurationBinding.strength,
                range: 0.1...50,
                step: 0.1
            )
        case .linear:
            blackAndWhiteControls
        case .asinh:
            blackAndWhiteControls
            StretchParameterRow(
                title: "Strength",
                value: configurationBinding.strength,
                range: 0.1...50,
                step: 0.1
            )
        case .mtf:
            StretchParameterRow(
                title: "Shadows",
                value: configurationBinding.shadows,
                range: 0...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "Midtone",
                value: configurationBinding.midtone,
                range: 0.01...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "Highlights",
                value: configurationBinding.highlights,
                range: 0.01...1,
                step: 0.001
            )
        case .ghs:
            StretchParameterRow(
                title: "Stretch factor",
                value: configurationBinding.stretchFactor,
                range: 0...20,
                step: 0.1
            )
            StretchParameterRow(
                title: "Local intensity",
                value: configurationBinding.localIntensity,
                range: -5...15,
                step: 0.1
            )
            VStack(alignment: .trailing, spacing: 6) {
                StretchParameterRow(
                    title: "Symmetry point",
                    value: configurationBinding.symmetryPoint,
                    range: 0...1,
                    step: 0.001
                )
                Button("Pick from Image…", systemImage: "eyedropper", action: pickSymmetryPoint)
                    .controlSize(.small)
            }
            StretchParameterRow(
                title: "Shadow protection",
                value: configurationBinding.protectShadows,
                range: 0...max(configuration.symmetryPoint, 0.001),
                step: 0.001
            )
            StretchParameterRow(
                title: "Highlight protection",
                value: configurationBinding.protectHighlights,
                range: min(configuration.symmetryPoint, 0.999)...1,
                step: 0.001
            )
            blackAndWhiteControls
        case .identity:
            Text("Normalized samples are clamped directly to the display range.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var blackAndWhiteControls: some View {
        StretchParameterRow(
            title: "Black point",
            value: configurationBinding.black,
            range: 0...0.99,
            step: 0.001
        )
        StretchParameterRow(
            title: "White point",
            value: configurationBinding.white,
            range: 0.01...1,
            step: 0.001
        )
    }

    private var configuration: FITSStretchConfiguration {
        stages[selectedStageIndex]
    }

    private var configurationBinding: Binding<FITSStretchConfiguration> {
        Binding(
            get: { stages[selectedStageIndex] },
            set: { stages[selectedStageIndex] = $0 }
        )
    }

    private func addStage() {
        stages.append(.identity)
        selectedStageIndex = stages.count - 1
    }

    private func removeStage(at index: Int) {
        guard stages.count > 1, stages.indices.contains(index) else { return }
        stages.remove(at: index)
        if selectedStageIndex > index {
            selectedStageIndex -= 1
        } else if selectedStageIndex == index {
            selectedStageIndex = min(index, stages.count - 1)
        }
    }

    private func moveStage(at index: Int, by offset: Int) {
        let destination = index + offset
        guard stages.indices.contains(index), stages.indices.contains(destination) else { return }
        stages.swapAt(index, destination)
        if selectedStageIndex == index {
            selectedStageIndex = destination
        } else if selectedStageIndex == destination {
            selectedStageIndex = index
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard stages.allSatisfy({ $0.validationMessage == nil }) else {
            clearPreview()
            return
        }
        let stack = FITSStretchStack(stages: stages)
        let background = extractsBackground
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                preview(stack, background)
            }
        }
    }
}

private struct StretchParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 118, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            TextField(
                title,
                value: $value,
                format: .number.precision(.fractionLength(0...4))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 68)
        }
        .controlSize(.small)
    }
}
