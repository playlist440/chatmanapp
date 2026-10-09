#if canImport(CoreLocation)
import CoreLocation
import Foundation
import MapKit

/// Asking the device where it is, once.
///
/// One fix and then stop. Nothing here tracks anybody: the app has no reason to know where
/// you are except in the second you decide to tell someone, and a location service that keeps
/// running is a battery cost and a promise this app shouldn't be making.
@MainActor
public enum LocationFix {

    public enum Failure: LocalizedError {
        case denied
        case unavailable
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .denied:
                String(localized: "Chatman isn't allowed to use your location. You can change that in Settings.", bundle: .module)
            case .unavailable:
                String(localized: "Your location couldn't be worked out.", bundle: .module)
            case .timedOut:
                String(localized: "That took too long. Try again somewhere with a clearer view of the sky.", bundle: .module)
            }
        }
    }

    /// Where the device is now.
    ///
    /// - Parameter timeout: How long to wait before giving up. Indoors a first fix can take
    ///   ten seconds or more, and on a watch longer still.
    public static func current(timeout: Duration = .seconds(25)) async throws -> SharedLocation {
        // Asking has to happen through a manager; the stream below reports the answer but
        // won't raise the question.
        let manager = CLLocationManager()
        // Kept alive until the end, not just until its last mention. The permission question
        // is shown on behalf of this manager, and an optimised build may let it go straight
        // after asking — which takes the question off the screen again, so the first time
        // anyone shared a location it flashed and vanished, and the wait ran out.
        defer { withExtendedLifetime(manager) {} }

        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw Failure.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        let place = try await withThrowingTaskGroup(of: SharedLocation.self) { group in
            group.addTask { try await waitForFix() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.unavailable }
            return first
        }

        return place.naming(await name(of: place))
    }

    /// What the map calls this spot.
    ///
    /// Best effort and nothing more: it needs the network, and the whole point of sharing a
    /// location is that it works when you are somewhere with poor reception. A place with no
    /// name still sends perfectly well.
    private static func name(of place: SharedLocation) async -> String? {
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }

        guard let items = try? await request.mapItems, let item = items.first else { return nil }

        if let address = item.address?.shortAddress, !address.isEmpty { return address }
        if let full = item.address?.fullAddress, !full.isEmpty { return full }
        return item.name
    }

    private static func waitForFix() async throws -> SharedLocation {
        for try await update in CLLocationUpdate.liveUpdates(.default) {
            if update.authorizationDenied || update.authorizationRestricted {
                throw Failure.denied
            }

            if let location = update.location {
                return SharedLocation(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    accuracy: location.horizontalAccuracy > 0
                        ? location.horizontalAccuracy
                        : nil
                )
            }
        }

        throw Failure.unavailable
    }
}
#endif
