#if canImport(UIKit)
import MapKit
import SwiftUI

/// The map that shows what you're about to send.
///
/// Apple's own map view, not a picture of one. It costs a line of code, it draws the same
/// streets the recipient will see when they tap the link, and it can be pushed around and
/// zoomed — which is how you check that the blue dot really is your street and not the one
/// behind it. Building anything here would be building a worse map.
public struct LocationPreview: View {

    private let place: SharedLocation

    public init(_ place: SharedLocation) {
        self.place = place
    }

    private var point: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    public var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: point,
            // About three hundred metres across: close enough to recognise the street, wide
            // enough to see which one it is.
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        ))) {
            // How sure the device is, drawn rather than described. Indoors this circle is
            // the size of a block, and seeing that is the difference between sending your
            // address and sending your postcode.
            if let accuracy = place.accuracy, accuracy > 20 {
                MapCircle(center: point, radius: accuracy)
                    .foregroundStyle(.blue.opacity(0.15))
                    .stroke(.blue.opacity(0.4), lineWidth: 1)
            }

            Marker("", systemImage: "person.fill", coordinate: point)
                .tint(.blue)
        }
    }
}
#endif
