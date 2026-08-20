import AppKit
import SwiftUI

struct ProviderBrandIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 16
    var color: Color = .secondary

    var body: some View {
        Group {
            if let image = ProviderBrandImages.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum ProviderBrandImages {
    private static var cache: [AgentProvider: NSImage] = [:]

    static func image(for provider: AgentProvider) -> NSImage? {
        if let cached = cache[provider] { return cached }
        guard let url = Bundle.module.url(
            forResource: provider == .claude ? "ProviderIcon-claude" : "ProviderIcon-codex",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }
}
