import ArgumentParser
import Foundation
import IOBluetooth

struct BluetoothCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bluetooth",
        abstract: "Bluetooth device management — list paired devices, connect, disconnect",
        subcommands: [ListCmd.self, ConnectCmd.self, DisconnectCmd.self]
    )

    struct ListCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List paired Bluetooth devices")
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            let rawDevices = IOBluetoothDevice.pairedDevices() ?? []
            let devices = rawDevices.compactMap { $0 as? IOBluetoothDevice }
            let items: [[String: Any]] = devices.map { device in
                [
                    "name": device.name ?? "Unknown",
                    "address": device.addressString ?? "",
                    "connected": device.isConnected(),
                ]
            }
            if json {
                let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                if items.isEmpty { print("No paired Bluetooth devices."); return }
                print(String(format: "%-30s %-20s %s", "NAME", "ADDRESS", "CONNECTED"))
                print(String(repeating: "-", count: 60))
                for item in items {
                    let connected = (item["connected"] as? Bool == true) ? "yes" : "no"
                    print(String(format: "%-30s %-20s %s",
                        String((item["name"] as? String ?? "").prefix(28)),
                        String((item["address"] as? String ?? "").prefix(18)),
                        connected))
                }
            }
        }
    }

    struct ConnectCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "connect", abstract: "Connect a paired Bluetooth device")
        @Argument(help: "Device name or Bluetooth address (e.g. 00-11-22-33-44-55)") var nameOrAddress: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard let device = bluetoothFindDevice(nameOrAddress) else {
                throw ValidationError("Device not found: \(nameOrAddress). Use 'bluetooth list' to see paired devices.")
            }
            let result = device.openConnection()
            guard result == kIOReturnSuccess else {
                throw ValidationError("Failed to connect '\(device.name ?? nameOrAddress)': IOReturn 0x\(String(result, radix: 16))")
            }
            if json {
                print("{\"connected\": true, \"name\": \"\(device.name ?? nameOrAddress)\"}")
            } else {
                print("Connected: \(device.name ?? nameOrAddress)")
            }
        }
    }

    struct DisconnectCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disconnect", abstract: "Disconnect a Bluetooth device")
        @Argument(help: "Device name or Bluetooth address") var nameOrAddress: String
        @Flag(name: .long, help: "Output JSON") var json = false

        func run() throws {
            guard let device = bluetoothFindDevice(nameOrAddress) else {
                throw ValidationError("Device not found: \(nameOrAddress). Use 'bluetooth list' to see paired devices.")
            }
            let result = device.closeConnection()
            guard result == kIOReturnSuccess else {
                throw ValidationError("Failed to disconnect '\(device.name ?? nameOrAddress)': IOReturn 0x\(String(result, radix: 16))")
            }
            if json {
                print("{\"disconnected\": true, \"name\": \"\(device.name ?? nameOrAddress)\"}")
            } else {
                print("Disconnected: \(device.name ?? nameOrAddress)")
            }
        }
    }
}

private func bluetoothFindDevice(_ nameOrAddress: String) -> IOBluetoothDevice? {
    let rawDevices = IOBluetoothDevice.pairedDevices() ?? []
    let devices = rawDevices.compactMap { $0 as? IOBluetoothDevice }
    let query = nameOrAddress.lowercased()
    return devices.first { device in
        (device.name?.lowercased() == query) ||
        (device.addressString?.lowercased() == query)
    }
}
