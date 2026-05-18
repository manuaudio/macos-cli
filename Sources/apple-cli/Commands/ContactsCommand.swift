import ArgumentParser
import Contacts
import Foundation

struct ContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search and manage Apple Contacts",
        subcommands: [Search.self, Get.self, Create.self, Update.self, Delete.self]
    )

    // MARK: - Search
    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search contacts by name, phone, or email")

        @Argument(help: "Search query")
        var query: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        @Option(name: .long, help: "Max results (default: 20)")
        var limit: Int = 20

        func run() throws {
            let store = CNContactStore()

            let sema = DispatchSemaphore(value: 0)
            var authGranted = false
            store.requestAccess(for: .contacts) { granted, _ in
                authGranted = granted
                sema.signal()
            }
            sema.wait()
            guard authGranted else {
                throw ValidationError("Contacts access denied — grant in Privacy & Security")
            }

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]

            let pred = CNContact.predicateForContacts(matchingName: query)
            let contacts = try store.unifiedContacts(matching: pred, keysToFetch: keys)
            let results = Array(contacts.prefix(limit))

            if json {
                let out = results.map { c -> [String: Any] in
                    let d: [String: Any] = [
                        "id": c.identifier,
                        "name": "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces),
                        "organization": c.organizationName,
                        "phones": c.phoneNumbers.map { ["label": $0.label ?? "", "number": $0.value.stringValue] },
                        "emails": c.emailAddresses.map { ["label": $0.label ?? "", "email": $0.value as String] },
                    ]
                    return d
                }
                printJSON(out)
            } else {
                for c in results {
                    let name = "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)
                    let phones = c.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
                    let emails = c.emailAddresses.map { $0.value as String }.joined(separator: ", ")
                    print("\(name) — \(phones) \(emails)")
                }
                print("\(results.count) contacts")
            }
        }
    }

    // MARK: - Get
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a contact by ID")

        @Argument(help: "Contact identifier")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = CNContactStore()

            let sema = DispatchSemaphore(value: 0)
            var authGranted = false
            store.requestAccess(for: .contacts) { granted, _ in
                authGranted = granted
                sema.signal()
            }
            sema.wait()
            guard authGranted else {
                throw ValidationError("Contacts access denied")
            }

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactBirthdayKey as CNKeyDescriptor,
            ]

            guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else {
                throw ValidationError("Contact '\(id)' not found")
            }

            if json {
                var d: [String: Any] = [
                    "id": contact.identifier,
                    "name": "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces),
                    "organization": contact.organizationName,
                    "phones": contact.phoneNumbers.map { ["label": $0.label ?? "", "number": $0.value.stringValue] },
                    "emails": contact.emailAddresses.map { ["label": $0.label ?? "", "email": $0.value as String] },
                ]
                if let bday = contact.birthday {
                    d["birthday"] = "\(bday.year ?? 0)-\(String(format: "%02d", bday.month ?? 0))-\(String(format: "%02d", bday.day ?? 0))"
                }
                printJSON(d)
            } else {
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                print(name)
                contact.phoneNumbers.forEach { print("  tel: \($0.value.stringValue)") }
                contact.emailAddresses.forEach { print("  email: \($0.value as String)") }
            }
        }
    }

    // MARK: - Create
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new contact")

        @Option(name: .long, help: "First name") var firstName: String = ""
        @Option(name: .long, help: "Last name")  var lastName: String = ""
        @Option(name: .long, help: "Organization/company") var organization: String?
        @Option(name: .long, help: "Phone (can repeat: --phone '+13105550100' --phone-label 'mobile')") var phone: [String] = []
        @Option(name: .long, help: "Phone label for last --phone (default: mobile)") var phoneLabel: String = "mobile"
        @Option(name: .long, help: "Email (can repeat)") var email: [String] = []
        @Option(name: .long, help: "Email label for last --email (default: work)") var emailLabel: String = "work"
        @Option(name: .long, help: "Note") var note: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard !firstName.isEmpty || !lastName.isEmpty || organization != nil else {
                throw ValidationError("Provide at least --first-name, --last-name, or --organization")
            }
            let store = CNContactStore()
            try requestAccess(store)

            let contact = CNMutableContact()
            contact.givenName  = firstName
            contact.familyName = lastName
            if let org = organization { contact.organizationName = org }
            if let n = note { contact.note = n }

            contact.phoneNumbers = phone.enumerated().map { idx, num in
                CNLabeledValue(label: idx == phone.count - 1 ? cnLabel(phoneLabel) : CNLabelPhoneNumberMobile,
                               value: CNPhoneNumber(stringValue: num))
            }
            contact.emailAddresses = email.enumerated().map { idx, addr in
                CNLabeledValue(label: idx == email.count - 1 ? cnLabel(emailLabel) : CNLabelWork,
                               value: addr as NSString)
            }

            let req = CNSaveRequest()
            req.add(contact, toContainerWithIdentifier: nil)
            try store.execute(req)

            if json {
                printJSON(["id": contact.identifier, "name": "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)])
            } else {
                print("Created: \(contact.givenName) \(contact.familyName) (\(contact.identifier))")
            }
        }
    }

    // MARK: - Update
    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update fields on an existing contact")

        @Argument(help: "Contact identifier (from contacts get --json or contacts search --json)") var id: String
        @Option(name: .long, help: "New first name") var firstName: String?
        @Option(name: .long, help: "New last name")  var lastName: String?
        @Option(name: .long, help: "New organization") var organization: String?
        @Option(name: .long, help: "Add phone number") var addPhone: String?
        @Option(name: .long, help: "Label for --add-phone (default: mobile)") var addPhoneLabel: String = "mobile"
        @Option(name: .long, help: "Add email address") var addEmail: String?
        @Option(name: .long, help: "Label for --add-email (default: work)") var addEmailLabel: String = "work"
        @Option(name: .long, help: "Note") var note: String?
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let store = CNContactStore()
            try requestAccess(store)

            let allKeys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactNoteKey as CNKeyDescriptor,
            ]
            guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: allKeys) else {
                throw ValidationError("Contact '\(id)' not found")
            }
            let mutable = contact.mutableCopy() as! CNMutableContact

            if let v = firstName     { mutable.givenName        = v }
            if let v = lastName      { mutable.familyName       = v }
            if let v = organization  { mutable.organizationName = v }
            if let v = note          { mutable.note             = v }

            if let p = addPhone {
                var phones = mutable.phoneNumbers
                phones.append(CNLabeledValue(label: cnLabel(addPhoneLabel), value: CNPhoneNumber(stringValue: p)))
                mutable.phoneNumbers = phones
            }
            if let e = addEmail {
                var emails = mutable.emailAddresses
                emails.append(CNLabeledValue(label: cnLabel(addEmailLabel), value: e as NSString))
                mutable.emailAddresses = emails
            }

            let req = CNSaveRequest()
            req.update(mutable)
            try store.execute(req)

            if json {
                printJSON(["id": id, "updated": true])
            } else {
                print("Updated: \(mutable.givenName) \(mutable.familyName)")
            }
        }
    }

    // MARK: - Delete
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a contact by ID")

        @Argument(help: "Contact identifier (from contacts search --json or contacts get --json)")
        var id: String

        @Flag(name: .long, help: "Output JSON")
        var json = false

        func run() throws {
            let store = CNContactStore()
            try requestAccess(store)

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
            ]
            guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else {
                throw ValidationError("Contact '\(id)' not found")
            }
            let mutable = contact.mutableCopy() as! CNMutableContact
            let req = CNSaveRequest()
            req.delete(mutable)
            try store.execute(req)

            if json {
                printJSON(["id": id, "deleted": true])
            } else {
                print("Deleted: \(contact.givenName) \(contact.familyName)")
            }
        }
    }
}

// MARK: - Contacts helpers

private func requestAccess(_ store: CNContactStore) throws {
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    store.requestAccess(for: .contacts) { ok, _ in granted = ok; sema.signal() }
    sema.wait()
    guard granted else { throw ValidationError("Contacts access denied — grant in Privacy & Security") }
}

private func cnLabel(_ label: String) -> String {
    switch label.lowercased() {
    case "mobile", "cell":  return CNLabelPhoneNumberMobile
    case "home":            return CNLabelHome
    case "work":            return CNLabelWork
    case "main":            return CNLabelPhoneNumberMain
    case "iphone":          return CNLabelPhoneNumberiPhone
    default:                return label
    }
}
