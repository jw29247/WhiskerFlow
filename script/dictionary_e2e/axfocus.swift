// Focuses the first editable text area in the app's focused window.
import AppKit
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first!
let a = AXUIElementCreateApplication(app.processIdentifier)
guard let w = attr(a, kAXFocusedWindowAttribute) else { print("no window"); exit(1) }
var queue: [AXUIElement] = [w as! AXUIElement]; var n = 0
while !queue.isEmpty, n < 5000 {
  let e = queue.removeFirst(); n += 1
  if attr(e, kAXRoleAttribute) as? String == kAXTextAreaRole {
    print("focus:", AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue); exit(0)
  }
  if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
}
print("no text area"); exit(2)
