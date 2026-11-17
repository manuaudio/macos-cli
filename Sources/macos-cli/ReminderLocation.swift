import ArgumentParser
import Contacts
import CoreLocation
import EventKit
import Foundation
import MacCLICore

/// "When arriving" / "When leaving" for a reminder: the Me card's home or work address, or a
/// typed one, geocoded and set as an EKAlarm on an EKStructuredLocation, the way the Reminders
/// app does it. The address is never printed: only the location's title ("Home", "Work", or
/// what was typed) appears in the output.
enum ReminderLocation {
    /// Parse the four flags into a change, as a usage error (exit 64) when they do not fit.
    static func change(whenArriving: String?, whenLeaving: String?, radius: Double?,
                       clearLocation: Bool) throws -> LocationTrigger.Change {
        do {
            return try LocationTrigger.change(whenArriving: whenArriving, whenLeaving: whenLeaving,
                                              radius: radius, clearLocation: clearLocation)
        } catch let e as LocationTrigger.UsageError {
            throw ValidationError(e.message)
        }
    }

    /// The alarm for a trigger: finds the place (Me card or typed address), geocodes it and
    /// builds the alarm. Writes nothing, so a failure here leaves the reminder as it was.
    static func alarm(for trigger: LocationTrigger, timeout: Double = 20) throws -> EKAlarm {
        let location = try geocode(trigger.place, timeout: timeout)
        let structured = EKStructuredLocation(title: trigger.locationTitle)
        structured.geoLocation = location
        structured.radius = trigger.radius
        let alarm = EKAlarm()
        alarm.structuredLocation = structured
        alarm.proximity = trigger.proximity == .arriving ? .enter : .leave
        return alarm
    }

    /// Apply a change to the reminder's alarms: a location alarm replaces any other, a clear
    /// removes it, time alarms stay.
    static func apply(_ change: LocationTrigger.Change, alarm: EKAlarm?, to reminder: EKReminder) {
        switch change {
        case .none: return
        case .clear, .set:
            let next = LocationTrigger.alarms(reminder.alarms ?? [], isLocation: isLocationAlarm,
                                              adding: alarm)
            reminder.alarms = next.isEmpty ? nil : next
        }
    }

    static func isLocationAlarm(_ alarm: EKAlarm) -> Bool { alarm.structuredLocation != nil }

    /// `{"title", "proximity": "arriving|leaving", "radius"}` for the reminder's location
    /// alarm, nil when it has none. Never coordinates.
    static func json(_ reminder: EKReminder) -> [String: Any]? {
        for alarm in reminder.alarms ?? [] {
            guard let loc = alarm.structuredLocation,
                  let out = LocationTrigger.locationJSON(title: loc.title,
                                                         proximityRaw: Int(alarm.proximity.rawValue),
                                                         radius: loc.radius)
            else { continue }
            return out
        }
        return nil
    }

    // MARK: - Finding the place

    private static func geocode(_ place: LocationTrigger.Place, timeout: Double) throws -> CLLocation {
        let geocoder = CLGeocoder()
        var result: Result<CLLocation, Error>?
        let finish: ([CLPlacemark]?, Error?) -> Void = { marks, error in
            if let loc = marks?.first?.location { result = .success(loc) }
            else { result = .failure(error ?? CocoaError(.fileNoSuchFile)) }
        }
        switch place {
        case .home, .work:
            geocoder.geocodePostalAddress(try meCardAddress(place), completionHandler: finish)
        case .address(let text):
            geocoder.geocodeAddressString(text, completionHandler: finish)
        }
        // The completion arrives on the main run loop, which this command is running on.
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        switch result {
        case .success(let loc)?:
            return loc
        case .failure?:
            throw CLIFailure.notFound("That place could not be found on the map.",
                                      hint: "Check the address (on the Me card, or as typed) and that this Mac is online.")
        case nil:
            geocoder.cancelGeocode()
            throw CLIFailure.timeout("Finding the place on the map took longer than \(Int(timeout))s.",
                                     hint: "Check that this Mac is online and try again.")
        }
    }

    private static func meCardAddress(_ place: LocationTrigger.Place) throws -> CNPostalAddress {
        try Auth.check("contacts.read")
        let store = try PrivacyAccess.contactsStore()
        let me: CNContact?
        do {
            me = try store.unifiedMeContactWithKeys(toFetch: [CNContactPostalAddressesKey as CNKeyDescriptor])
        } catch let e as CNError where e.code == .recordDoesNotExist {
            me = nil
        } catch {
            throw CLIFailure.appError("Contacts could not read the Me card: \(error.localizedDescription)")
        }
        let addresses = me?.postalAddresses
        do {
            let index = try LocationTrigger.meCardAddressIndex(for: place,
                                                               meCardAddressLabels: addresses.map { $0.map(\.label) })
            return addresses![index].value
        } catch let e as LocationTrigger.LookupError {
            throw CLIFailure.notFound(e.description, hint: e.hint)
        }
    }
}
