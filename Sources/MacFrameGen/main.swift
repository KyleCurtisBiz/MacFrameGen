// MacFrameGen: shows a capture card's picture with a generated frame between every pair of real frames,
// turning a 30 fps console game into 60 fps on a Mac. See README.md.
import AppKit
import AVFoundation

let options = Options()

if options.has("--help") || options.has("-h") {
    print(Options.usage)
    exit(0)
}
if options.has("--list-devices") {
    let devices = CardSource.devices(includeBuiltIn: options.has("--include-built-in"))
    if devices.isEmpty { print("no capture devices found") }
    for d in devices {
        print("\(d.localizedName)  [model \(d.modelID)]")
        let best = CardSource.bestFormat(for: d)
        for f in CardSource.formats(of: d) { print("  \(f.description)\(f.format == best?.format ? "   <- would be used" : "")") }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)    // stays alive: run() does not return
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
