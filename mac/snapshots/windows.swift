import CoreGraphics
// Prints the window number of the given process's window with that title.
let pid = Int32(CommandLine.arguments[1])!, title = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int32) == pid && (w["kCGWindowName"] as? String) == title {
    print(w["kCGWindowNumber"]!); break
}
