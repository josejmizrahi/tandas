import SwiftUI
import RuulCore
import RuulUI

struct MediaStripLayout: View {
    let media: [CapabilityBlock.MediaRef]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: RuulSpacing.sm) {
                ForEach(media) { item in
                    AsyncImage(url: item.url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: item.placeholder)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
