import ArgumentParser
import CoreLocation
import Foundation

struct LocationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location",
        abstract: "Get current GPS location via CoreLocation",
        subcommands: [Get.self]
    )

    // MARK: - Get
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get current location (requires Location Services permission)")

        @Flag(name: .long, help: "Output JSON")
        var json = false

        @Option(name: .long, help: "Timeout in seconds (default: 15)")
        var timeout: Double = 15

        func run() throws {
            let locator = OneShot()
            let result = locator.locate(timeout: timeout)

            switch result {
            case .success(let loc):
                if json {
                    var out: [String: Any] = [
                        "latitude":  loc.coordinate.latitude,
                        "longitude": loc.coordinate.longitude,
                        "accuracy_meters": loc.horizontalAccuracy,
                        "timestamp": ISO8601DateFormatter().string(from: loc.timestamp),
                    ]
                    if loc.altitude != 0 { out["altitude_meters"] = loc.altitude }
                    printJSON(out)
                } else {
                    print(String(format: "%.6f, %.6f (±%.0fm)", loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy))
                }
            case .failure(let err):
                throw ValidationError(err)
            }
        }
    }
}

// MARK: - CoreLocation one-shot helper

private enum LocationResult {
    case success(CLLocation)
    case failure(String)
}

private class OneShot: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var result: LocationResult?
    private var done = false

    func locate(timeout: Double) -> LocationResult {
        let mgr = CLLocationManager()
        self.manager = mgr
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBest

        let status = mgr.authorizationStatus
        switch status {
        case .denied, .restricted:
            return .failure("Location access denied — enable in System Settings > Privacy & Security > Location Services")
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
        default:
            break
        }

        mgr.startUpdatingLocation()

        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        mgr.stopUpdatingLocation()

        return result ?? .failure("Location timed out after \(Int(timeout))s — ensure Location Services is enabled and permission granted")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        result = .success(loc)
        done = true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        result = .failure("Location error: \(error.localizedDescription)")
        done = true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            result = .failure("Location access denied — enable in System Settings > Privacy & Security > Location Services")
            done = true
        default:
            break
        }
    }
}
