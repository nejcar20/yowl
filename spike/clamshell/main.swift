import Foundation
import IOKit.pwr_mgt

var ids: [IOPMAssertionID] = []
for type in [kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep] {
    var id: IOPMAssertionID = 0
    let r = IOPMAssertionCreateWithName(type as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "clamshell spike" as CFString, &id)
    print("\(type): \(r == kIOReturnSuccess ? "granted" : "FAILED \(r)")")
    if r == kIOReturnSuccess { ids.append(id) }
}

let log = URL(fileURLWithPath: NSHomeDirectory() + "/clamshell-spike.log")
try? "start \(Date())\n".write(to: log, atomically: true, encoding: .utf8)
let handle = try! FileHandle(forWritingTo: log)
handle.seekToEndOfFile()

print("Heartbeat started. Close the lid for ~30s, then reopen.")
for i in 1...120 {
    handle.write("tick \(i) \(Date())\n".data(using: .utf8)!)
    try? handle.synchronize()
    Thread.sleep(forTimeInterval: 1)
}
ids.forEach { IOPMAssertionRelease($0) }
print("Done. Inspect ~/clamshell-spike.log")
