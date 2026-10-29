// Lists the development build's on-screen windows from front to back, to check how many windows an open request
// produced. The Debug build is named Surimono Dev, so an installed release's windows are not counted.
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
// The window server can be unavailable, for example outside a GUI session; do not report that as zero windows.
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("Could not read the window list\n".utf8))
    exit(1)
}
let surimono = windows.filter { $0[kCGWindowOwnerName as String] as? String == "Surimono Dev" }
print("Surimono Dev windows: \(surimono.count)")
for info in surimono {
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    // Titles need the screen recording permission; without it they are empty.
    let title = info[kCGWindowName as String] as? String ?? ""
    let origin = "\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0))"
    let size = "\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))"
    print("  layer=\(layer) origin=\(origin) size=\(size) title=\(title)")
}
