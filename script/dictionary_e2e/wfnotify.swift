import Foundation
let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "agency.thatworks.WhiskerFlow.debug.dictation"
DistributedNotificationCenter.default().postNotificationName(.init(name), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
