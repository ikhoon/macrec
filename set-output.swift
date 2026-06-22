// set-output.swift — set the macOS default OUTPUT device by (partial) name.
// Usage:  swift set-output.swift "Audioengine"     (lists devices if no/!match)
import CoreAudio
import Foundation

func sysObj() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func allDevices() -> [AudioDeviceID] {
    var size = UInt32(0)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyDataSize(sysObj(), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(sysObj(), &a, 0, nil, &size, &ids)
    return ids
}

func name(_ id: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf)
    return cf as String
}

func outputChannels(_ id: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
    guard size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf)
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

let target = CommandLine.arguments.dropFirst().joined(separator: " ")
let outputs = allDevices().filter { outputChannels($0) > 0 }
if target.isEmpty {
    print("output devices:"); outputs.forEach { print("  - \(name($0))") }; exit(0)
}
guard let dev = outputs.first(where: { name($0).localizedCaseInsensitiveContains(target) }) else {
    print("no output device matching \"\(target)\". available:"); outputs.forEach { print("  - \(name($0))") }; exit(1)
}
var id = dev
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
let st = AudioObjectSetPropertyData(sysObj(), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
print(st == noErr ? "✅ default output → \(name(dev))" : "❌ failed (status \(st))")
exit(st == noErr ? 0 : 1)
