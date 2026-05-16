import ArgumentParser
import Contacts
import Foundation

struct ContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search and manage Apple Contacts",
        subcommands: [Search.self, Get.self]
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
}
