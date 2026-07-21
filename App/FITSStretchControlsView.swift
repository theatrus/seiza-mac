import SwiftUI

struct FITSStretchControlsView: View {
    @Binding var configuration: FITSStretchConfiguration
    let supportsColor: Bool
    let appliedStages: [FITSStretchConfiguration]
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let pickSymmetryPoint: () -> Void
    let replace: () -> Void
    let apply: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FITS Stretch")
                    .font(.headline)
                Spacer()
                Button("Reset") {
                    configuration = .default
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
                            Text("Applied Stages")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
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

                        ForEach(Array(appliedStages.enumerated()), id: \.offset) { index, stage in
                            HStack(spacing: 8) {
                                Image(systemName: index == 0 ? "photo" : "plus.circle.fill")
                                    .foregroundStyle(
                                        index == 0 ? Color.secondary : Color.accentColor
                                    )
                                Text(stage.type.title)
                                Spacer()
                                if index == 0 {
                                    Text("Base")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }

                        Text("Each new stage operates on the previous stage at full floating-point precision.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    LabeledContent("Method") {
                        Picker("Method", selection: $configuration.type) {
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
                            Picker("Color handling", selection: $configuration.colorStrategy) {
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
                }
                .padding(16)
            }
            .frame(maxHeight: 520)

            Divider()

            HStack {
                Button("Replace Stack", action: replace)
                    .help("Discard the current stages and use this stretch as the new base")
                    .disabled(configuration.validationMessage != nil)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Stretch", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(configuration.validationMessage != nil)
            }
            .padding(12)
        }
        .frame(width: 430)
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
                value: $configuration.targetMedian,
                range: 0.01...0.95,
                step: 0.01
            )
            StretchParameterRow(
                title: "Shadows clipping",
                value: $configuration.shadowsClip,
                range: -10...0,
                step: 0.1
            )
        case .percentileAsinh:
            StretchParameterRow(
                title: "Black percentile",
                value: $configuration.blackPercentile,
                range: 0...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "White percentile",
                value: $configuration.whitePercentile,
                range: 0.01...1,
                step: 0.001
            )
            StretchParameterRow(
                title: "Strength",
                value: $configuration.strength,
                range: 0.1...50,
                step: 0.1
            )
        case .linear:
            blackAndWhiteControls
        case .asinh:
            blackAndWhiteControls
            StretchParameterRow(
                title: "Strength",
                value: $configuration.strength,
                range: 0.1...50,
                step: 0.1
            )
        case .mtf:
            StretchParameterRow(
                title: "Shadows",
                value: $configuration.shadows,
                range: 0...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "Midtone",
                value: $configuration.midtone,
                range: 0.01...0.99,
                step: 0.001
            )
            StretchParameterRow(
                title: "Highlights",
                value: $configuration.highlights,
                range: 0.01...1,
                step: 0.001
            )
        case .ghs:
            StretchParameterRow(
                title: "Stretch factor",
                value: $configuration.stretchFactor,
                range: 0...20,
                step: 0.1
            )
            StretchParameterRow(
                title: "Local intensity",
                value: $configuration.localIntensity,
                range: -5...15,
                step: 0.1
            )
            VStack(alignment: .trailing, spacing: 6) {
                StretchParameterRow(
                    title: "Symmetry point",
                    value: $configuration.symmetryPoint,
                    range: 0...1,
                    step: 0.001
                )
                Button("Pick from Image…", systemImage: "eyedropper", action: pickSymmetryPoint)
                    .controlSize(.small)
            }
            StretchParameterRow(
                title: "Shadow protection",
                value: $configuration.protectShadows,
                range: 0...max(configuration.symmetryPoint, 0.001),
                step: 0.001
            )
            StretchParameterRow(
                title: "Highlight protection",
                value: $configuration.protectHighlights,
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
            value: $configuration.black,
            range: 0...0.99,
            step: 0.001
        )
        StretchParameterRow(
            title: "White point",
            value: $configuration.white,
            range: 0.01...1,
            step: 0.001
        )
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
