// Offline keylocked time-stretch with Apple's AVAudioUnitTimePitch (the unit the phone uses),
// rendered with AVAudioEngine manual rendering. Usage: apple-stretch <in> <out.caf> <rate> [overlap] [exact]
//
// AVAudioUnitTimePitch truncates `rate` to a multiple of 1/512 (measured 2026-10-08: x1.01641 plays
// at 520/512, so kicks drift ~0.8 ms per second). With `exact`, the time-pitch unit gets the
// representable rate floor(rate*512)/512 and an AVAudioUnitVarispeed after it makes up the rest
// (under 0.2 %, at most 3.4 cents of pitch). Pass overlap 0 to keep the unit's default.
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 4, let rate = Float(args[3]) else { fatalError("usage: apple-stretch <in> <out> <rate> [overlap]") }
let input = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let format = input.processingFormat
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let pitch = AVAudioUnitTimePitch()
let exact = args.count >= 6 && args[5] == "exact"
// "varispeed": no time-pitch at all, only the resampler (for ratios within 0.2 %: at most 3.4 cents,
// and the phase vocoder would smear the kicks for nothing).
let varispeedOnly = args.count >= 6 && args[5] == "varispeed"
let representable = (rate * 512).rounded(.down) / 512
pitch.rate = exact ? representable : rate
pitch.pitch = 0
if args.count >= 5, let ov = Float(args[4]), ov > 0 { pitch.overlap = ov }
let varispeed = AVAudioUnitVarispeed()
varispeed.rate = varispeedOnly ? rate : (exact ? rate / representable : 1)
if varispeedOnly { pitch.rate = 1; pitch.bypass = true }
engine.attach(player); engine.attach(pitch); engine.attach(varispeed)
engine.connect(player, to: pitch, format: format)
engine.connect(pitch, to: varispeed, format: format)
engine.connect(varispeed, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
try engine.start()
player.scheduleFile(input, at: nil)
player.play()
let output = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: format.settings)
let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
let total = AVAudioFramePosition(Double(input.length) / Double(rate)) + AVAudioFramePosition(format.sampleRate)
while engine.manualRenderingSampleTime < total {
    let frames = min(AVAudioFrameCount(4096), AVAudioFrameCount(total - engine.manualRenderingSampleTime))
    let status = try engine.renderOffline(frames, to: buffer)
    if status == .success { try output.write(from: buffer) } else if status == .error { fatalError("render error") }
}
print("latency \(pitch.latency) s, rendered \(engine.manualRenderingSampleTime) frames")
