import Foundation

/// A reminder's location trigger, the Reminders app's "When arriving" / "When leaving":
/// the pure decisions behind `reminders create|update --when-arriving|--when-leaving`.
/// The executable turns a `LocationTrigger` into an EKAlarm with an EKStructuredLocation.
public struct LocationTrigger: Equatable {
    public enum Proximity: String, Equatable { case arriving, leaving }

    /// Where: the Me card's home or work address, or an address typed on the command line.
    public enum Place: Equatable {
        case home
        case work
        case address(String)

        /// `home` and `work` (any case) name the Me card's addresses; anything else is an address.
        public init(_ argument: String) {
            switch argument.trimmingCharacters(in: .whitespaces).lowercased() {
            case "home": self = .home
            case "work": self = .work
            default: self = .address(argument.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    public static let defaultRadius: Double = 150

    public let place: Place
    public let proximity: Proximity
    public let radius: Double

    public init(place: Place, proximity: Proximity, radius: Double = LocationTrigger.defaultRadius) {
        self.place = place
        self.proximity = proximity
        self.radius = radius
    }

    /// What the command line asks of the reminder's location alarm.
    public enum Change: Equatable {
        case none
        case set(LocationTrigger)
        case clear
    }

    /// Read `--when-arriving`, `--when-leaving`, `--radius` and `--clear-location` together.
    /// Throws a usage message: both directions, a radius with no place, a radius that is not
    /// positive, an empty place, or a place and `--clear-location` at once.
    public static func change(whenArriving: String?, whenLeaving: String?,
                              radius: Double?, clearLocation: Bool) throws -> Change {
        if whenArriving != nil && whenLeaving != nil {
            throw UsageError("Use one of --when-arriving and --when-leaving, not both.")
        }
        let given = whenArriving.map { ($0, Proximity.arriving) } ?? whenLeaving.map { ($0, Proximity.leaving) }
        if clearLocation {
            if given != nil { throw UsageError("--clear-location cannot be combined with --when-arriving or --when-leaving.") }
            if radius != nil { throw UsageError("--radius needs --when-arriving or --when-leaving.") }
            return .clear
        }
        guard let (argument, proximity) = given else {
            if radius != nil { throw UsageError("--radius needs --when-arriving or --when-leaving.") }
            return .none
        }
        guard !argument.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw UsageError("Name a place: home, work or an address.")
        }
        let r = radius ?? defaultRadius
        guard r > 0, r.isFinite else { throw UsageError("--radius is in metres and must be more than 0.") }
        return .set(LocationTrigger(place: Place(argument), proximity: proximity, radius: r))
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    // MARK: - The Me card

    /// The labels Contacts gives a home and a work address (`CNLabelHome`, `CNLabelWork`).
    public static let contactsHomeLabel = "_$!<Home>!$_"
    public static let contactsWorkLabel = "_$!<Work>!$_"

    /// What went wrong finding a place on the Me card. The message names what is missing,
    /// never the address.
    public enum LookupError: Error, Equatable, CustomStringConvertible {
        case noMeCard
        case noLabelledAddress(String)

        public var description: String {
            switch self {
            case .noMeCard:
                return "There is no Me card in Contacts, so there is no home or work address to use."
            case .noLabelledAddress(let label):
                return "The Me card in Contacts has no address labelled \(label)."
            }
        }

        public var hint: String {
            switch self {
            case .noMeCard:
                return "In Contacts, choose your own card and Card > Make This My Card, or pass an address instead."
            case .noLabelledAddress(let label):
                return "Add a \(label) address to your card in Contacts, or pass an address instead."
            }
        }
    }

    /// Pick the Me card's address for `home` or `work`: the first postal address with that
    /// label. `meCardAddressLabels` is nil when there is no Me card. Returns the index of
    /// the chosen address. `place` must be `.home` or `.work`.
    public static func meCardAddressIndex(for place: Place, meCardAddressLabels: [String?]?) throws -> Int {
        guard let labels = meCardAddressLabels else { throw LookupError.noMeCard }
        let (wanted, word): (String, String)
        switch place {
        case .home: (wanted, word) = (contactsHomeLabel, "home")
        case .work: (wanted, word) = (contactsWorkLabel, "work")
        case .address: preconditionFailure("an address is not looked up on the Me card")
        }
        guard let index = labels.firstIndex(where: { $0 == wanted }) else {
            throw LookupError.noLabelledAddress(word)
        }
        return index
    }

    /// The title the alarm's location carries, what Reminders shows: "Home", "Work", or
    /// the typed address.
    public var locationTitle: String {
        switch place {
        case .home: return "Home"
        case .work: return "Work"
        case .address(let a): return a
        }
    }

    // MARK: - Alarms

    /// The reminder's alarms after the change: every location alarm goes (a new trigger
    /// replaces it, never stacks a second), time alarms stay, and `new` is added last.
    public static func alarms<A>(_ existing: [A], isLocation: (A) -> Bool, adding new: A?) -> [A] {
        existing.filter { !isLocation($0) } + (new.map { [$0] } ?? [])
    }

    /// The `location` object `list` and `export` print: title, direction and radius, never
    /// coordinates. `proximityRaw` is `EKAlarmProximity.rawValue` (1 enter, 2 leave);
    /// nil for anything else.
    public static func locationJSON(title: String?, proximityRaw: Int, radius: Double) -> [String: Any]? {
        let proximity: String
        switch proximityRaw {
        case 1: proximity = Proximity.arriving.rawValue
        case 2: proximity = Proximity.leaving.rawValue
        default: return nil
        }
        return ["title": title ?? "", "proximity": proximity, "radius": radius]
    }
}
