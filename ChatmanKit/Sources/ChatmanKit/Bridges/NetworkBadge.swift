#if canImport(UIKit)
import SwiftUI

/// The mark that says which service a conversation lives on.
///
/// Prefers the service's own icon, added to the app's asset catalogue as `brand-signal` and
/// `brand-whatsapp`. Those are other companies' trademarks, so they aren't shipped here — drop
/// the files in and this picks them up. Until then it draws the service's initial on its own
/// colour, which is legible without them.
public struct NetworkBadge: View {

    private let network: ChatNetwork
    private let size: CGFloat

    public init(network: ChatNetwork, size: CGFloat = 15) {
        self.network = network
        self.size = size
    }

    public var body: some View {
        Group {
            if let icon = UIImage(named: "brand-\(network.rawValue)") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            } else {
                // Colour alone would ask people to memorise a legend, and says nothing at all
                // to anyone who can't tell these two apart.
                Text(network.initials)
                    .font(.system(size: size * (network.initials.count > 2 ? 0.34 : 0.5),
                                  weight: .bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(colour, in: Circle())
            }
        }
        .frame(width: size, height: size)
    }

    private var colour: Color {
        let brand = network.brandColour
        return Color(red: brand.red, green: brand.green, blue: brand.blue)
    }
}
#endif
