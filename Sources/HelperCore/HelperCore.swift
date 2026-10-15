#if os(macOS)
/// Mac side of App Mode. Every OS-facing piece sits behind a protocol with a fake, so logic is testable without
/// permissions. See docs/app-mode-implementation-plan.md M3.
public enum HelperCoreInfo {
    public static let minimumMacOS = "15.0"
}
#endif
