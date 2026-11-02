// monitor-switch: Cmd+PageUp -> HDMI 2, Cmd+PageDown -> DisplayPort 1 (DDC/CI over IOAVService).
// Usage: monitor-switch            run as hotkey daemon
//        monitor-switch <value>    send one input-source value and exit (15 = DP1, 18 = HDMI2)
//        monitor-switch read       print the monitor's current input-source value and exit
//
// Switching to the Mac's input (HDMI 2) is verified: after ~15 s the input is read back over DDC.
// If the monitor has fallen back to another input, the Mac's HDMI link came up unusable (seen after
// display sleep: "HDMIRX does not support scrambling", HDCP failure, monitor finds no signal and
// auto-switches away). Recovery: write 18, sleep the display, wake it, write 18 again. That makes
// macOS re-train the HDMI link while the monitor is listening on HDMI 2.
import AppKit
import Carbon.HIToolbox
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

let inputDP1: UInt16 = 15
let inputHDMI2: UInt16 = 18
let macInput = inputHDMI2            // the input this Mac is plugged into; only switches to it are verified
let vcpInputSource: UInt8 = 0x60

let readBackDelay: TimeInterval = 15 // monitor auto-switches away within ~20 s when HDMI has no signal
let recoverySleepDelay: TimeInterval = 4
let recoveryWakeDelay: TimeInterval = 3
let recoveryVerifyDelay: TimeInterval = 5

// MARK: - Logging (line-buffered so /tmp/monitor-switch.log is readable while the daemon runs)

setvbuf(stdout, nil, _IOLBF, 0)
let timestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    print("\(timestampFormatter.string(from: Date())) \(message)")
    fflush(stdout)
}

// MARK: - DDC/CI

func externalAVServices() -> [CFTypeRef] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var services: [CFTypeRef] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if location == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) {
            services.append(av.takeRetainedValue())
        }
    }
    return services
}

// DDC "Set VCP Feature": VCP 0x60 = input source.
@discardableResult
func setInput(_ value: UInt16) -> Bool {
    var packet: [UInt8] = [0x84, 0x03, vcpInputSource, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
    var ok = false
    for service in externalAVServices() {
        for _ in 0..<2 { // monitors sometimes drop the first write
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
            usleep(10_000)
        }
    }
    log(ok ? "input -> \(value)" : "DDC write failed (input \(value))")
    return ok
}

// DDC "Get VCP Feature" for one service, the way m1ddc does it: write the request, pause, read the
// 11-byte reply, check the checksum. Returns the current value or nil.
func readVCP(_ service: CFTypeRef, _ vcp: UInt8) -> UInt16? {
    var request: [UInt8] = [0x82, 0x01, vcp, 0]
    request[3] = request[0..<3].reduce(0x6E ^ 0x51, ^)
    guard IOAVServiceWriteI2C(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else { return nil }
    usleep(50_000)
    var reply = [UInt8](repeating: 0, count: 11)
    guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else { return nil }
    // reply: 6E 88 02 rc vcp type maxHi maxLo curHi curLo checksum; checksum = XOR of 0x50 and bytes 0..9
    let checksum = reply[0..<10].reduce(0x50, ^)
    guard reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02, reply[4] == vcp, checksum == reply[10] else {
        log("DDC read reply rejected: " + reply.map { String(format: "%02X", $0) }.joined(separator: " "))
        return nil
    }
    return UInt16(reply[8]) << 8 | UInt16(reply[9])
}

// Current input source (VCP 0x60) from the first external display that answers, with retries.
func readInput() -> UInt16? {
    for attempt in 1...3 {
        for service in externalAVServices() {
            if let value = readVCP(service, vcpInputSource) { return value }
        }
        if attempt < 3 { usleep(200_000) }
    }
    return nil
}

// MARK: - HDMI link recovery

var retainedProcesses: [Process] = []

func run(_ path: String, _ arguments: [String], wait: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    do {
        try p.run()
        if wait { p.waitUntilExit(); log("ran \(path) \(arguments.joined(separator: " ")) -> exit \(p.terminationStatus)") }
        else { retainedProcesses.append(p); log("started \(path) \(arguments.joined(separator: " "))") }
    } catch {
        log("failed to run \(path): \(error)")
    }
}

// Write the Mac's input, sleep and wake the display so macOS re-trains the HDMI link while the
// monitor is on HDMI 2, write again, and read back.
func recoverHDMILink() {
    log("recovery: writing \(macInput), then display sleep/wake to re-train the HDMI link")
    setInput(macInput)
    run("/usr/bin/pmset", ["displaysleepnow"], wait: true)
    Thread.sleep(forTimeInterval: recoverySleepDelay)
    run("/usr/bin/caffeinate", ["-u", "-t", "5"], wait: false)
    Thread.sleep(forTimeInterval: recoveryWakeDelay)
    setInput(macInput)
    Thread.sleep(forTimeInterval: recoveryVerifyDelay)
    if let value = readInput() {
        log(value == macInput ? "recovery: read-back 0x60 = \(value), monitor is on the Mac" : "recovery: read-back 0x60 = \(value), still not on the Mac (giving up, one recovery per switch)")
    } else {
        log("recovery: read-back failed")
    }
}

// Read 0x60 back after the fallback window; recover once if the monitor is not on the Mac's input.
// Returns true when the monitor is on the Mac's input (with or without recovery).
@discardableResult
func checkMacInput() -> Bool {
    guard let value = readInput() else {
        log("read-back 0x60 failed, skipping recovery")
        return false
    }
    if value == macInput {
        log("read-back 0x60 = \(value), monitor is on the Mac, link healthy")
        return true
    }
    log("read-back 0x60 = \(value): monitor fell back, HDMI link to the Mac is not usable")
    recoverHDMILink()
    return readInput() == macInput
}

// Every switch goes through this serial queue. A switch to the Mac's input is verified ~15 s later;
// if another switch happens first the stale verification is dropped so it cannot fight the user.
let switchQueue = DispatchQueue(label: "monitor-switch.ddc")
var switchGeneration = 0

func requestSwitch(_ value: UInt16) {
    switchQueue.async {
        switchGeneration += 1
        let generation = switchGeneration
        setInput(value)
        guard value == macInput else { return }
        switchQueue.asyncAfter(deadline: .now() + readBackDelay) {
            guard generation == switchGeneration else { log("read-back for input \(value) skipped, newer switch happened"); return }
            checkMacInput()
        }
    }
}

// MARK: - CLI

if CommandLine.arguments.count > 1 {
    let arg = CommandLine.arguments[1]
    if arg == "read" {
        if let value = readInput() { log("input = \(value)"); exit(0) }
        log("DDC read failed"); exit(1)
    }
    guard let value = UInt16(arg) else { log("usage: monitor-switch [<input value>|read]"); exit(2) }
    let wrote = setInput(value)
    if value == macInput {
        Thread.sleep(forTimeInterval: readBackDelay)
        exit(checkMacInput() ? 0 : 1)
    }
    exit(wrote ? 0 : 1)
}

// MARK: - Hotkey daemon

let hotkeys: [UInt32: (keyCode: Int, input: UInt16)] = [
    1: (kVK_PageUp, inputHDMI2),
    2: (kVK_PageDown, inputDP1),
]

var handlerSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    if let hk = hotkeys[id.id] { log("hotkey \(id.id) -> input \(hk.input)"); requestSwitch(hk.input) }
    return noErr
}, 1, &handlerSpec, nil, nil)

for (id, hk) in hotkeys {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(hk.keyCode), UInt32(cmdKey), EventHotKeyID(signature: OSType(0x4D535754), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr { log("failed to register hotkey \(id): \(status) (another app may own it)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
log("monitor-switch running (Cmd+PageUp -> \(inputHDMI2), Cmd+PageDown -> \(inputDP1); switches to \(macInput) are verified after \(Int(readBackDelay)) s)")
app.run()
