import Foundation

/// Command-line options. None are needed for normal use.
struct Options {
    static let usage = """
    MacFrameGen [options]

      --list-devices          print the capture devices and their video modes, then quit
      --device <text>         use the first capture device whose name contains <text>
      --include-built-in      also offer the Mac's own camera (to try the app without a capture card)
      --selftest              run the pipeline on a synthetic 30 fps picture for 6 s, print timings, quit
      --selftest-file <path>  use real footage for the self-test (a 60 fps recording of a 30 fps game)
      --selftest-fps <n>      game frame rate inside the 60 Hz test stream: 30 (default), 60, 40, 20
      --selftest-size <WxH>   size of the test stream (default 1920x1080)
      --selftest-seconds <n>  how long the self-test runs (default 6)
      --selftest-stress       restart the pipeline twice a second during the self-test
      --no-upscale            start with the upscaler off
      --no-turbo              start with fast generation off (saves one CPU core, generation takes twice as long)
      --pacing immediate      start with even frame pacing off
      --log <path>            where to write the stats log (default ~/Library/Logs/MacFrameGen/macframegen.log)
      --frames <path>         also write per-frame timings as CSV (see scripts/analyze-frames.py)
      --help                  show this
    """

    private let args = CommandLine.arguments
    func has(_ name: String) -> Bool { args.contains(name) }
    func value(_ name: String) -> String? {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return nil
    }
}
