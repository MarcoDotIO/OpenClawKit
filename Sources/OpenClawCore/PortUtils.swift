import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Error thrown when attempting to bind to an occupied port.
public struct PortInUseError: Error, LocalizedError, Sendable {
    /// Port that failed availability check.
    public let port: Int

    /// Creates a port-in-use error.
    /// - Parameter port: Port that could not be bound.
    public init(port: Int) {
        self.port = port
    }

    public var errorDescription: String? {
        "Port \(self.port) is already in use"
    }
}

/// Utilities for checking local TCP port availability.
public enum PortUtils {
    /// Ensures a TCP port can be bound on the local host.
    /// - Parameter port: Port to probe.
    public static func ensurePortAvailable(_ port: Int) throws {
        #if os(Linux)
        let streamSocketType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamSocketType = Int32(SOCK_STREAM)
        #endif
        let fd = socket(AF_INET, streamSocketType, 0)
        guard fd >= 0 else {
            throw OpenClawCoreError.unavailable("Unable to create socket for port check")
        }
        defer { _ = close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPtr in
                bind(fd, rawPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            throw PortInUseError(port: port)
        }
    }
}
