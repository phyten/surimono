// Prints the window ID of the frontmost on-screen Surimono window, for `screencapture -l`.
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { info in
    info[kCGWindowOwnerName as String] as? String == "Surimono" && info[kCGWindowLayer as String] as? Int == 0
}
guard let windowID = match?[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write(Data("Surimono window not found\n".utf8))
    exit(1)
}
print(windowID)
