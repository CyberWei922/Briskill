import SwiftUI

struct FeatureCard: View {
    let feature: FeatureItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: feature.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(feature.tint)
                        .frame(width: 38, height: 38)
                        .background(feature.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(feature.executionExample)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? feature.tint.opacity(0.55) : Color.primary.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    }
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
