import Foundation

// Shim for an Xcode and macOS mismatch.
//
// Xcode 27.2 compiles `date1 >= date2` and `date1 <= date2` as calls to new Foundation functions
// that appeared in the final macOS 27.2. The 27.2 beta (build 26B5091g) does not have them: the system calls
// itself 27.2, the program calls a null address and crashes at launch. Here are the same two functions under the same
// names: the linker takes them from the program itself, so the build works the same on the beta and on the final system.
//
// To check that the shim is no longer needed and that nothing else is missing: codexbar-fork/check_symbols.py.

@_silgen_name("$s10Foundation4DateV2geoiySbAC_ACtFZ")
public func lemelsonDateGreaterOrEqual(_ lhs: Date, _ rhs: Date) -> Bool {
    lhs.timeIntervalSinceReferenceDate >= rhs.timeIntervalSinceReferenceDate
}

@_silgen_name("$s10Foundation4DateV2leoiySbAC_ACtFZ")
public func lemelsonDateLessOrEqual(_ lhs: Date, _ rhs: Date) -> Bool {
    lhs.timeIntervalSinceReferenceDate <= rhs.timeIntervalSinceReferenceDate
}
