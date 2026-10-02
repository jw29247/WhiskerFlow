import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; let r = AXUIElementCopyAttributeValue(e, k as CFString, &v); return r == .success ? v : nil }
let ids = CommandLine.arguments.dropFirst()
for id in ids {
  guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { print(id, "not running"); continue }
  let a = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(a, 0.5)
  let f = attr(a, kAXFocusedUIElementAttribute)
  guard let f, CFGetTypeID(f) == AXUIElementGetTypeID() else { print(id, "no focused element; manualAX=", attr(a, "AXManualAccessibility") as Any); continue }
  let e = f as! AXUIElement
  let role = attr(e, kAXRoleAttribute) as? String
  let sub = attr(e, kAXSubroleAttribute) as? String
  let val = attr(e, kAXValueAttribute)
  var sel = "nil"
  if let r = attr(e, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() { var cr = CFRange(); AXValueGetValue(r as! AXValue, .cfRange, &cr); sel = "\(cr.location),\(cr.length)" }
  let s = val as? String
  print(id, "role=\(role ?? "nil") sub=\(sub ?? "nil") valueType=\(val.map { CFCopyTypeIDDescription(CFGetTypeID($0)) as String } ?? "nil") len=\(s?.utf16.count ?? -1) sel=\(sel) tail=\(s.map { String($0.suffix(40)).debugDescription } ?? "")")
}
