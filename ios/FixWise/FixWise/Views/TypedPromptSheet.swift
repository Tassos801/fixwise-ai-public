import SwiftUI

struct TypedPromptSheet: View {
    @Binding var promptText: String
    let mode: GuidanceMode
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speech isn't available right now, so you can type a \(mode.title.lowercased()) question instead.")
                    .font(.headline)

                TextField(
                    mode.typedPromptPlaceholder,
                    text: $promptText,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Examples")
                        .font(.subheadline.weight(.semibold))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(mode.promptExamples, id: \.self) { example in
                                Button(example) {
                                    promptText = example
                                }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Ask \(mode.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSubmit(trimmed)
                        dismiss()
                    }
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
