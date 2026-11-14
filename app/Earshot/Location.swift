import CoreLocation

/// Where the device was at one moment of a call: the coordinates, and the address if one could be looked up.
struct Place: Codable, Equatable {
    var latitude: Double, longitude: Double
    var accuracy: Double            // metres: the true position is within this far of the coordinates
    var street: String? = nil, city: String? = nil, county: String? = nil, state: String? = nil, zip: String? = nil

    var coordinates: String { String(format: "%.5f, %.5f", latitude, longitude) }

    /// The place in words: the address when there is one, the coordinates when there is not.
    var line: String {
        let cityLine = [city, county, [state, zip].compactMap { $0 }.joined(separator: " ")].compactMap { $0 }.filter { !$0.isEmpty }
        let parts = ([street].compactMap { $0 } + cityLine)
        return parts.isEmpty ? coordinates : parts.joined(separator: ", ")
    }
}

/// Follows the device's location while a recording runs, and reports it only when it has moved.
///
/// Once a minute it compares where the device is with the last place it reported. Under `moved` metres apart counts as
/// the same place and nothing is reported, so a call spent at one address logs it once. GPS wanders by tens of metres
/// while standing still, which is why "the same" is a distance and not an exact match.
/// ponytail: the address lookup needs a network. Without one the place is reported as coordinates only.
final class Locator: NSObject, CLLocationManagerDelegate {
    static let every: TimeInterval = 60          // how often it checks
    static let moved: CLLocationDistance = 50    // metres from the last reported place that count as somewhere new

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var latest: CLLocation?
    private var reported: CLLocation?
    private var timer: Timer?
    private var running = false

    var onPlace: ((Place, Date) -> Void)?
    var onLevel: ((Level) -> Void)?

    /// How far the person has allowed location. Only `always` lets a check run while the app is off screen or the device is locked.
    enum Level { case unasked, refused, whileUsing, always }

    var level: Level {
        switch manager.authorizationStatus {
        case .notDetermined: .unasked
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whileUsing
        default: .refused
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Asks for location, aiming for "Always". The system only offers that in two steps: first "While Using the App",
    /// then a second question to change it to "Always Allow". Each question is shown once; after that the person has to
    /// change it in the Settings app.
    func ask() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()   // step one; step two follows from the answer
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Forgets the last reported place, so a new call logs where it starts.
    func reset() { reported = nil }

    /// Starts following. The first fix is reported straight away if the device has moved since the last report.
    func start() {
        guard level == .always || level == .whileUsing, !running else { return }
        running = true
        latest = nil
        manager.allowsBackgroundLocationUpdates = true   // a recording carries on when the app is not on screen
        manager.startUpdatingLocation()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// True when `now` is far enough from `last` to be a new place.
    static func isNew(_ now: CLLocation, since last: CLLocation?) -> Bool {
        guard let last else { return true }
        return now.distance(from: last) >= moved
    }

    private func check() {
        // A fix that is old or vague says nothing about where the device is now.
        guard running, let now = latest, now.horizontalAccuracy >= 0, now.horizontalAccuracy <= 100,
              Date().timeIntervalSince(now.timestamp) < 120, Self.isNew(now, since: reported) else { return }
        reported = now
        let at = Date()
        var place = Place(latitude: now.coordinate.latitude, longitude: now.coordinate.longitude, accuracy: now.horizontalAccuracy)
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(now) { [weak self] found, _ in
            if let mark = found?.first {
                place.street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                if place.street?.isEmpty == true { place.street = nil }
                place.city = mark.locality
                place.county = mark.subAdministrativeArea
                place.state = mark.administrativeArea
                place.zip = mark.postalCode
            }
            DispatchQueue.main.async { self?.onPlace?(place, at) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let first = latest == nil
        latest = fix
        if first { check() }   // do not wait a minute for the first one
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("location: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onLevel?(level)
        if level == .whileUsing { manager.requestAlwaysAuthorization() }   // step two, straight after step one is granted
        if level == .refused { stop() }
    }
}
