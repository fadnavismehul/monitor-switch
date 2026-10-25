// monitor-switch: Cmd+PageUp -> HDMI 2, Cmd+PageDown -> DisplayPort 1 (DDC/CI over IOAVService).
// Usage: monitor-switch            run as hotkey daemon
//        monitor-switch <value>    send one input-source value and exit (15 = DP1, 18 = HDMI2)
import AppKit
import Carbon.HIToolbox
import IOKit

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

let inputDP1: UInt16 = 15
let inputHDMI2: UInt16 = 18

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
    var packet: [UInt8] = [0x84, 0x03, 0x60, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
    var ok = false
    for service in externalAVServices() {
        for _ in 0..<2 { // monitors sometimes drop the first write
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess { ok = true }
            usleep(10_000)
        }
    }
    print(ok ? "input -> \(value)" : "DDC write failed (input \(value))")
    return ok
}

if CommandLine.arguments.count > 1, let value = UInt16(CommandLine.arguments[1]) {
    exit(setInput(value) ? 0 : 1)
}

let hotkeys: [UInt32: (keyCode: Int, input: UInt16)] = [
    1: (kVK_PageUp, inputHDMI2),
    2: (kVK_PageDown, inputDP1),
]

var handlerSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
    var id = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    if let hk = hotkeys[id.id] { DispatchQueue.global().async { setInput(hk.input) } }
    return noErr
}, 1, &handlerSpec, nil, nil)

for (id, hk) in hotkeys {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(hk.keyCode), UInt32(cmdKey), EventHotKeyID(signature: OSType(0x4D535754), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr { print("failed to register hotkey \(id): \(status) (another app may own it)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
print("monitor-switch running")
app.run()
