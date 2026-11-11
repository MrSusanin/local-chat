import SwiftUI

struct MediaActionBar: View {
    let capabilities: [ModelCapability]
    let onSelect: (ModelCapability) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(capabilities.filter { $0 != .text }) { capability in
                Button {
                    onSelect(capability)
                } label: {
                    Label(capability.title, systemImage: capability.systemImage)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
    }
}
