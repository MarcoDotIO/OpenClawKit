import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Measures how much thread stack a synchronous closure uses.
///
/// The closure runs on a new pthread whose stack this helper maps itself: a guard page at the
/// bottom (so an overflow faults instead of corrupting memory), and every other byte filled with a
/// pattern. After the thread exits, the lowest overwritten byte is the deepest point the stack
/// reached, measured from the closure's entry frame.
enum StackUsageProbe {
    private static let pattern: UInt64 = 0xA5A5_A5A5_A5A5_A5A5

    private final class Context {
        let body: @Sendable () -> Void
        var entryAddress: UInt = 0

        init(body: @escaping @Sendable () -> Void) {
            self.body = body
        }
    }

    /// Runs `body` on a thread with a `stackSize`-byte stack and returns the peak bytes it used.
    /// - Parameters:
    ///   - stackSize: Thread stack size; rounded up to whole pages.
    ///   - body: Synchronous work to measure.
    /// - Returns: Peak stack bytes below the thread's entry frame.
    static func peakBytes(stackSize: Int, _ body: @escaping @Sendable () -> Void) throws -> Int {
        let pageSize = Int(sysconf(Int32(_SC_PAGESIZE)))
        let size = (stackSize + pageSize - 1) / pageSize * pageSize
        #if os(Linux)
        let anonymous = MAP_ANONYMOUS
        #else
        let anonymous = MAP_ANON
        #endif
        guard let mapping = mmap(nil, size + pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | anonymous, -1, 0),
              mapping != MAP_FAILED
        else {
            throw ProbeError.system("mmap", errno)
        }
        defer { munmap(mapping, size + pageSize) }
        guard mprotect(mapping, pageSize, PROT_NONE) == 0 else {
            throw ProbeError.system("mprotect", errno)
        }
        let stack = mapping + pageSize
        let words = stack.bindMemory(to: UInt64.self, capacity: size / 8)
        words.initialize(repeating: Self.pattern, count: size / 8)

        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        var status = pthread_attr_setstack(&attributes, stack, size)
        guard status == 0 else { throw ProbeError.system("pthread_attr_setstack", status) }

        let context = Context(body: body)
        let unmanaged = Unmanaged.passRetained(context)
        #if os(Linux)
        var thread = pthread_t()
        #else
        var thread: pthread_t?
        #endif
        // The start routine's argument is optional on Linux and non-optional on Darwin.
        status = pthread_create(&thread, &attributes, { StackUsageProbe.threadMain($0) }, unmanaged.toOpaque())
        guard status == 0 else {
            unmanaged.release()
            throw ProbeError.system("pthread_create", status)
        }
        #if os(Linux)
        pthread_join(thread, nil)
        #else
        pthread_join(thread!, nil)
        #endif
        unmanaged.release()

        var lowest = 0
        while lowest < size / 8, words[lowest] == Self.pattern {
            lowest += 1
        }
        let deepest = UInt(bitPattern: stack) + UInt(lowest * 8)
        return Int(context.entryAddress) - Int(deepest)
    }

    private static func threadMain(_ argument: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        guard let argument else { return nil }
        let context = Unmanaged<Context>.fromOpaque(argument).takeUnretainedValue()
        var marker: UInt8 = 0
        context.entryAddress = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        context.body()
        return nil
    }

    enum ProbeError: Error, CustomStringConvertible {
        case system(String, Int32)

        var description: String {
            switch self {
            case .system(let call, let code):
                "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }
}
