import Foundation

public enum SessionDiagnostics {
    public static func inputPermissionDenied(_ output: String) -> Bool {
        // scrcpy logs this and continues rendering; it does not necessarily exit.
        // A generic SecurityException may instead concern audio or the clipboard.
        output.localizedCaseInsensitiveContains("INJECT_EVENTS permission")
    }
}
