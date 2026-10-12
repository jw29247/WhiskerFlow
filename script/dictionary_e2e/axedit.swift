// Usage: axedit <bundle-id> value            -> prints focused field value
//        axedit <bundle-id> fix <find> <replacement>  -> selects <find> and types <replacement>
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
let args = CommandLine.arguments
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else { print("ERR not running"); exit(1) }
let a = AXUIElementCreateApplication(app.processIdentifier)
guard let f = attr(a, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { print("ERR no focus"); exit(1) }
let e = f as! AXUIElement
let value = (attr(e, kAXValueAttribute) as? String) ?? ""
if args[2] == "value" { print(value); exit(0) }
let find = args[3], replacement = args[4]
guard let r = value.range(of: find, options: .backwards) else { print("ERR find not in value: \(value.debugDescription)"); exit(2) }
let ns = NSRange(r, in: value)
var cr = CFRange(location: ns.location, length: ns.length)
let rv = AXValueCreate(.cfRange, &cr)!
let res = AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, rv)
guard res == .success else { print("ERR select \(res.rawValue)"); exit(3) }
usleep(300_000)
let src = CGEventSource(stateID: .hidSystemState)
// Delete the selection, then type the fix one character at a time like a person.
for down in [true, false] { let ev = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down)!; ev.postToPid(app.processIdentifier) }
usleep(150_000)
for ch in replacement.utf16 {
  for down in [true, false] {
    let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
    var c = ch; ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
    ev.postToPid(app.processIdentifier)
  }
  usleep(90_000)
}
usleep(300_000)
print((attr(e, kAXValueAttribute) as? String) ?? "")
