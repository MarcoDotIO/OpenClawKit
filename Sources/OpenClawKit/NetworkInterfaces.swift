import Foundation

/// Network interface helpers shared by gateway and discovery surfaces.
public enum NetworkInterfaces {
    /// Returns the preferred primary IPv4 address, preferring `en0` when available.
    public static func primaryIPv4Address() -> String? {
        var fallback: String?
        var en0: String?
        for entry in NetworkInterfaceIPv4.addresses() {
            if entry.name == "en0" {
                en0 = entry.ip
                break
            }
            if fallback == nil { fallback = entry.ip }
        }

        return en0 ?? fallback
    }
}
