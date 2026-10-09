// Gravação: áudio do sistema (a outra pessoa) via Core Audio tap + microfone (você) via AVAudioEngine.
// Faixas separadas, direto em AAC. Permissões: "Áudio do sistema" e "Microfone" (pedidos com botão Permitir).
import AVFoundation
import CoreAudio

struct Meta: Codable {
    var started_at: String
    var duration_s: Double
    var me_first_pts: Double?
    var them_first_pts: Double?
}

/// Escreve buffers PCM num .m4a (AAC) fora da thread de áudio
final class Track {
    let url: URL
    private var file: AVAudioFile?
    private(set) var firstTime: Double?
    private let queue: DispatchQueue

    init(_ url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    private var framesWritten: AVAudioFramePosition = 0

    func write(_ sb: CMSampleBuffer) {
        guard sb.isValid, sb.numSamples > 0,
              var asbd = sb.formatDescription?.audioStreamBasicDescription,
              let fmt = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sb.numSamples))
        else { return }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(sb.numSamples), into: pcm.mutableAudioBufferList) == noErr else { return }
        write(pcm, hostTime: AVAudioTime.hostTime(forSeconds: sb.presentationTimeStamp.seconds))
    }

    func write(_ buf: AVAudioPCMBuffer, hostTime: UInt64) {
        guard buf.frameLength > 0, let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength)
        else { return }
        copy.frameLength = buf.frameLength
        let n = Int(buf.format.streamDescription.pointee.mBytesPerFrame) * Int(buf.frameLength)
        let src = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData { memcpy(d, s, min(n, Int(src[i].mDataByteSize))) }
        }
        queue.async { [self] in
            if file == nil {
                let f = copy.format
                let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: f.sampleRate,
                                          AVNumberOfChannelsKey: f.channelCount, AVEncoderBitRateKey: 48000 * f.channelCount]
                file = try? AVAudioFile(forWriting: url, settings: aac, commonFormat: f.commonFormat,
                                        interleaved: f.isInterleaved)
                firstTime = AVAudioTime.seconds(forHostTime: hostTime)
            }
            guard let file, let first = firstTime, let copy = conform(copy, to: file.processingFormat) else { return }
            // silêncio entre um trecho e outro: completa com zeros para o tempo bater com a gravação real
            let expected = AVAudioFramePosition((AVAudioTime.seconds(forHostTime: hostTime) - first) * copy.format.sampleRate)
            var gap = expected - framesWritten
            if gap > AVAudioFramePosition(copy.format.sampleRate * 0.05) {
                while gap > 0, let z = AVAudioPCMBuffer(pcmFormat: copy.format, frameCapacity: AVAudioFrameCount(min(gap, 48000))) {
                    z.frameLength = z.frameCapacity  // buffer novo já vem zerado
                    try? file.write(from: z)
                    framesWritten += AVAudioFramePosition(z.frameLength)
                    gap -= AVAudioFramePosition(z.frameLength)
                }
            }
            try? file.write(from: copy)
            framesWritten += AVAudioFramePosition(copy.frameLength)
        }
    }

    private var converter: AVAudioConverter?

    private func conform(_ buf: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buf.format == target { return buf }
        if converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: target) }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 256
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        return out
    }

    func close() { queue.sync { file?.close(); file = nil } }
}

/// formato atual do áudio do sistema; troca quando a taxa do dispositivo muda
final class FormatBox: @unchecked Sendable {
    private let base: AVAudioFormat
    private let lock = NSLock()
    private var current: AVAudioFormat

    init(base: AVAudioFormat, rate: Double) {
        self.base = base
        current = base
        set(rate: rate)
    }

    var format: AVAudioFormat { lock.lock(); defer { lock.unlock() }; return current }

    func set(rate: Double) {
        guard rate > 0, let f = AVAudioFormat(commonFormat: base.commonFormat, sampleRate: rate,
                                               channels: base.channelCount, interleaved: base.isInterleaved) else { return }
        lock.lock(); current = f; lock.unlock()
    }
}

final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let dir: URL
    private let them: Track
    private let me: Track
    private let session = AVCaptureSession()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "callrec.io", qos: .userInitiated)
    private let startedAt = Date()

    func nominalRate(_ dev: AudioObjectID) -> Double {
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
        return r
    }

    init(dir: URL) {
        self.dir = dir
        them = Track(dir.appendingPathComponent("them.m4a"), queue: DispatchQueue(label: "callrec.them"))
        me = Track(dir.appendingPathComponent("me.m4a"), queue: DispatchQueue(label: "callrec.me"))
    }

    func start() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw err("Sem permissão de microfone") }
        try startSystemTap()
        try startMic()
    }

    // MARK: áudio do sistema (tudo que toca no Mac, menos o próprio CallRec)

    private func startSystemTap() throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess().map { [$0] } ?? [])
        tap.uuid = UUID()
        tap.name = "CallRec"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "criar tap de áudio")

        // agregado só com o tap (sem a saída como relógio): a taxa fica em 48 kHz mesmo quando
        // um fone Bluetooth entra em modo chamada e derruba a saída para 16 kHz
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallRec",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID), "criar dispositivo agregado")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "ler formato do tap")
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw err("formato de áudio inválido") }

        let them = self.them
        let box = FormatBox(base: fmt, rate: nominalRate(aggID))
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        let agg = aggID
        AudioObjectAddPropertyListenerBlock(aggID, &rateAddr, ioQueue) { [weak self] _, _ in
            if let r = self?.nominalRate(agg) { box.set(rate: r) }
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, input, time, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: box.format, bufferListNoCopy: input, deallocator: nil) else { return }
            them.write(buf, hostTime: time.pointee.mHostTime)
        }, "abrir leitura do tap")
        try check(AudioDeviceStart(aggID, procID), "iniciar tap")
    }

    // MARK: microfone

    private func startMic() throws {
        guard let dev = AVCaptureDevice.default(for: .audio) else { throw err("Nenhum microfone") }
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "callrec.mic"))
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        me.write(sb)
    }

    func stop() async -> Meta {
        session.stopRunning()
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        them.close()
        me.close()
        let meta = Meta(started_at: ISO8601DateFormatter().string(from: startedAt),
                        duration_s: Date().timeIntervalSince(startedAt),
                        me_first_pts: me.firstTime, them_first_pts: them.firstTime)
        try? JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        return meta
    }

    // MARK: helpers Core Audio

    private func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw err("Falha ao \(what) (\(st))") }
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "callrec", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
