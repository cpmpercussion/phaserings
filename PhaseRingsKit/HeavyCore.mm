//
//  HeavyCore.mm
//  PhaseRings
//
//  See HeavyCore.h. Extracted from HeavyAudioEngine so the DSP core can be
//  shared between the standalone app (RemoteIO driver) and the AUv3
//  extension (AUAudioUnit render block).
//

#import "HeavyCore.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import <atomic>
#import <cstdint>

#import "Heavy_PhaseRing.hpp"
#import "Heavy_CircleStrings.hpp"
#import "Heavy_SoundScraper.hpp"
#import "Heavy_SoundScraper.h"  // table enums

// Names match `read -resize <file> <table>` in the original
// load_sound_files.pd. The table-side names are what hvcc hashes; the file
// names are what AVAudioFile opens.
typedef struct {
    Hv_SoundScraper_Table table;
    NSString *filename;
} HeavySampleMapping;

static const HeavySampleMapping kSoundScraperSamples[] = {
    { HV_SOUNDSCRAPER_TABLE_BOWL,       @"bowl.wav" },
    { HV_SOUNDSCRAPER_TABLE_GONG,       @"gong.wav" },
    { HV_SOUNDSCRAPER_TABLE_CROTALE,    @"crotale.wav" },
    { HV_SOUNDSCRAPER_TABLE_ALMGLOCKEN, @"almglockenC-441.wav" },
    { HV_SOUNDSCRAPER_TABLE_MARIMBA,    @"marimba.wav" },
    { HV_SOUNDSCRAPER_TABLE_XYLO,       @"xylo.wav" },
};
static const int kNumSoundScraperSamples =
    sizeof(kSoundScraperSamples) / sizeof(kSoundScraperSamples[0]);

// Heavy routes [notein] through the __hv_notein receiver, expecting
// (pitch, velocity, channel) as a 3-float message.
static const hv_uint32_t kNoteinHash = 0x67E37CA3;

#pragma mark - Lock-free control-event queue

// Control messages (touch, MIDI, parameter changes) must reach Heavy on the
// SAME thread that runs ctx->process(), otherwise Heavy's message queue is
// mutated concurrently with the render — a data race. So the UI/MIDI side
// only ever *enqueues* small POD events here; the render callback drains them
// into Heavy immediately before process().
//
// The consumer (audio render thread) is wait-free: it never locks or
// allocates. Producers (main thread, network callbacks, …) serialise their
// enqueue with an os_unfair_lock — cheap, and only ever contended off the
// render thread. Receiver-name hashing happens producer-side so the render
// thread only does the hash-keyed send.

namespace {

struct HeavyEvent {
    enum Kind : uint8_t { Float, Bang, Note } kind;
    hv_uint32_t hash;
    float a, b, c;   // Float: a. Note: a=pitch, b=velocity, c=channel.
};

class HeavyEventQueue {
public:
    // Producer side. Safe from multiple threads (serialised by the lock).
    // Returns false (and counts a drop) if the queue is full.
    bool push(const HeavyEvent &e) {
        os_unfair_lock_lock(&_producerLock);
        const uint32_t w = _write.load(std::memory_order_relaxed);
        const uint32_t next = (w + 1) & kMask;
        if (next == _read.load(std::memory_order_acquire)) {
            _dropped.fetch_add(1, std::memory_order_relaxed);
            os_unfair_lock_unlock(&_producerLock);
            return false;
        }
        _buf[w] = e;
        _write.store(next, std::memory_order_release);
        os_unfair_lock_unlock(&_producerLock);
        return true;
    }

    // Consumer side. Call ONLY from the render thread. Wait-free.
    template <typename Fn>
    void drain(Fn &&fn) {
        uint32_t r = _read.load(std::memory_order_relaxed);
        const uint32_t w = _write.load(std::memory_order_acquire);
        while (r != w) {
            fn(_buf[r]);
            r = (r + 1) & kMask;
        }
        _read.store(r, std::memory_order_release);
    }

    uint32_t droppedCount() const { return _dropped.load(std::memory_order_relaxed); }

private:
    // ~5 ms of dense touch+MIDI bursts fit comfortably; 1024 * sizeof(event)
    // is a few tens of KB.
    static constexpr uint32_t kCapacity = 1024;  // power of two
    static constexpr uint32_t kMask = kCapacity - 1;

    HeavyEvent _buf[kCapacity];
    std::atomic<uint32_t> _write{0};
    std::atomic<uint32_t> _read{0};
    std::atomic<uint32_t> _dropped{0};
    os_unfair_lock _producerLock = OS_UNFAIR_LOCK_INIT;
};

// Everything the render callback touches, behind one stable pointer
// (HeavyCore.renderRefCon). The active context is published through an atomic
// so a synth switch never tears down an in-flight render.
struct HeavyRenderState {
    std::atomic<HeavyContextInterface *> current{nullptr};
    HeavyEventQueue queue;

    // Heavy's generated process() only renders whole SIMD vectors: it rounds
    // the frame count DOWN to a multiple of HV_N_SIMD and never writes the
    // remainder. iOS hosts routinely ask for counts that aren't multiples of
    // 4 — whenever the session rate differs from the hardware rate (AUM /
    // Logic at 44.1 kHz on a 48 kHz iPad) the I/O cycle alternates e.g.
    // 235/236 frames — so rendering straight into the host buffer left up
    // to 3 stale samples at the end of every block: a click per buffer.
    //
    // Fix: when the request isn't vector-aligned, render a rounded-UP block
    // into `scratch`, hand the host what it asked for, and carry the (≤3)
    // surplus frames into the next call. Aligned requests with nothing
    // carried still render straight into the host buffer.
    //
    // `scratch` is hv_malloc'd by HeavyCore (SIMD-aligned: Heavy's
    // __hv_store_f is an aligned store on SSE/AVX, and an inline array in an
    // ObjC ivar carries no such guarantee). Never allocated on the render
    // thread. `carry` is only ever accessed scalar-wise.
    static constexpr int kScratchFrames = 1024;  // multiple of HV_N_SIMD
    float *scratch[2] = { nullptr, nullptr };
    float carry[2][HV_N_SIMD];
    int carryCount = 0;  // frames in `carry` not yet delivered
};

static_assert(HeavyRenderState::kScratchFrames % HV_N_SIMD == 0,
              "scratch must be a whole number of SIMD vectors");

}  // namespace

@interface HeavyCore () {
    // Three preconstructed contexts; we keep them all live so synth switches
    // never tear down an in-flight render block.
    HeavyContextInterface *_phase;
    HeavyContextInterface *_strings;
    HeavyContextInterface *_soundscraper;

    HeavyRenderState _render;  // current context + the control-event queue

    int _channels;

    // Decoded mono float32 PCM at engine sample rate, keyed by table enum.
    NSMutableDictionary<NSNumber *, NSData *> *_sampleCache;
}
@end

#pragma mark - Render callback

OSStatus HeavyCoreRenderCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    auto *state = (HeavyRenderState *)inRefCon;
    HeavyContextInterface *ctx = state->current.load(std::memory_order_acquire);
    if (!ctx || !ioData || ioData->mNumberBuffers == 0) {
        for (UInt32 i = 0; i < (ioData ? ioData->mNumberBuffers : 0); ++i) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    // Apply queued control events to the active context, on this thread,
    // before processing this block.
    state->queue.drain([ctx](const HeavyEvent &e) {
        switch (e.kind) {
            case HeavyEvent::Float:
                ctx->sendFloatToReceiver(e.hash, e.a);
                break;
            case HeavyEvent::Bang:
                ctx->sendBangToReceiver(e.hash);
                break;
            case HeavyEvent::Note:
                ctx->sendMessageToReceiverV(e.hash, 0.0, "fff", e.a, e.b, e.c);
                break;
        }
    });

    // Non-interleaved float32, one buffer per channel. A mono host buffer
    // list gets the left channel; the right is rendered into scratch.
    float *outs[2] = { nullptr, nullptr };
    for (UInt32 i = 0; i < ioData->mNumberBuffers && i < 2; ++i) {
        outs[i] = (float *)ioData->mBuffers[i].mData;
    }
    if (!outs[0]) return noErr;
    const bool stereoHost = (outs[1] != nullptr);
    const int frames = (int)inNumberFrames;

    // Fast path: vector-aligned request, nothing carried over.
    if (stereoHost && state->carryCount == 0 && (frames % HV_N_SIMD) == 0) {
        ctx->process(nullptr, outs, frames);
        return noErr;
    }

    // Slow path (see HeavyRenderState): deliver carried frames first, then
    // render rounded-up chunks through scratch and carry the surplus.
    int done = 0;
    while (state->carryCount > 0 && done < frames) {
        const int idx = HV_N_SIMD - state->carryCount;
        outs[0][done] = state->carry[0][idx];
        if (stereoHost) outs[1][done] = state->carry[1][idx];
        ++done;
        --state->carryCount;
    }
    float *scratch[2] = { state->scratch[0], state->scratch[1] };
    if (!scratch[0] || !scratch[1]) {  // cannot happen after init; stay safe
        memset(outs[0] + done, 0, (frames - done) * sizeof(float));
        if (stereoHost) memset(outs[1] + done, 0, (frames - done) * sizeof(float));
        return noErr;
    }
    while (done < frames) {
        int want = frames - done;
        if (want > HeavyRenderState::kScratchFrames) want = HeavyRenderState::kScratchFrames;
        const int n4 = (want + HV_N_SIMD - 1) & ~(HV_N_SIMD - 1);  // ≤ kScratchFrames
        ctx->process(nullptr, scratch, n4);
        memcpy(outs[0] + done, scratch[0], want * sizeof(float));
        if (stereoHost) memcpy(outs[1] + done, scratch[1], want * sizeof(float));
        const int surplus = n4 - want;  // 0..HV_N_SIMD-1, only on the last chunk
        if (surplus > 0) {
            const int at = HV_N_SIMD - surplus;
            memcpy(state->carry[0] + at, scratch[0] + want, surplus * sizeof(float));
            memcpy(state->carry[1] + at, scratch[1] + want, surplus * sizeof(float));
            state->carryCount = surplus;
        }
        done += want;
    }
    return noErr;
}

void HeavyCoreSendMIDINote(void *inRefCon, int pitch, int velocity, int channel) {
    auto *state = (HeavyRenderState *)inRefCon;
    HeavyContextInterface *ctx = state->current.load(std::memory_order_acquire);
    if (!ctx) return;
    ctx->sendMessageToReceiverV(kNoteinHash, 0.0, "fff",
                                (float)pitch, (float)velocity, (float)channel);
}

// Heavy's print hook fires on the audio render thread. Anything that takes
// a lock, allocates, or hits Objective-C runtime will glitch audio. Leave
// the hook unset so [print] objects in the patches discard silently.

#pragma mark -

@implementation HeavyCore

- (instancetype)initWithSampleRate:(double)sampleRate channels:(int)channels {
    self = [super init];
    if (!self) return nil;

    _sampleRate = sampleRate;
    _channels = channels;
    _activeSynth = (HeavySynth)-1;  // forces a real switch on first selectSynth:
    _sampleCache = [NSMutableDictionary dictionary];

    // SIMD-aligned scratch for unaligned-frame-count renders (see
    // HeavyRenderState). Zeroed so a mono/carry path never reads garbage.
    for (int c = 0; c < 2; ++c) {
        _render.scratch[c] = (float *)hv_malloc(HeavyRenderState::kScratchFrames * sizeof(float));
        memset(_render.scratch[c], 0, HeavyRenderState::kScratchFrames * sizeof(float));
    }

    [self decodeSoundScraperSamples];

    return self;
}

- (void)dealloc {
    hv_free(_render.scratch[0]);
    hv_free(_render.scratch[1]);
    delete _phase;
    delete _strings;
    delete _soundscraper;
}

- (void *)renderRefCon {
    return &_render;
}

#pragma mark - Sample decoding (SoundScraper)

- (void)decodeSoundScraperSamples {
    for (int i = 0; i < kNumSoundScraperSamples; ++i) {
        HeavySampleMapping m = kSoundScraperSamples[i];
        NSData *pcm = [self decodeWavToMonoFloat32:m.filename];
        if (pcm) {
            _sampleCache[@(m.table)] = pcm;
        } else {
            NSLog(@"HeavyCore: failed to decode sample %@", m.filename);
        }
    }
}

- (NSData *)decodeWavToMonoFloat32:(NSString *)filename {
    // bundleForClass: resolves the resource in whatever bundle HeavyCore
    // ships in — the framework bundle today, the extension bundle once the
    // AUv3 work lands. mainBundle would be wrong inside an extension.
    NSBundle *bundle = [NSBundle bundleForClass:[HeavyCore class]];
    NSURL *url = [bundle URLForResource:[filename stringByDeletingPathExtension]
                          withExtension:[filename pathExtension]];
    if (!url) return nil;

    NSError *err = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url
                                                      error:&err];
    if (!file) {
        NSLog(@"HeavyCore: open %@ failed: %@", filename, err);
        return nil;
    }

    AVAudioFormat *outFmt = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:_sampleRate
                    channels:1
                 interleaved:NO];

    AVAudioConverter *converter = [[AVAudioConverter alloc]
        initFromFormat:file.processingFormat toFormat:outFmt];
    if (!converter) return nil;

    AVAudioFrameCount inFrames = (AVAudioFrameCount)file.length;
    AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:file.processingFormat frameCapacity:inFrames];
    if (![file readIntoBuffer:inBuf error:&err]) {
        NSLog(@"HeavyCore: read %@ failed: %@", filename, err);
        return nil;
    }

    double ratio = _sampleRate / file.processingFormat.sampleRate;
    AVAudioFrameCount outCap = (AVAudioFrameCount)ceil(inBuf.frameLength * ratio) + 16;
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:outFmt frameCapacity:outCap];

    __block BOOL consumed = NO;
    AVAudioConverterInputBlock input = ^AVAudioBuffer *(AVAudioPacketCount inNumberOfPackets,
                                                        AVAudioConverterInputStatus *outStatus) {
        if (consumed) {
            *outStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        consumed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inBuf;
    };
    AVAudioConverterOutputStatus status = [converter convertToBuffer:outBuf
                                                                error:&err
                                                   withInputFromBlock:input];
    if (status == AVAudioConverterOutputStatus_Error) {
        NSLog(@"HeavyCore: convert %@ failed: %@", filename, err);
        return nil;
    }

    NSUInteger byteCount = outBuf.frameLength * sizeof(float);
    return [NSData dataWithBytes:outBuf.floatChannelData[0] length:byteCount];
}

- (void)loadSamplesIntoContext:(HeavyContextInterface *)ctx {
    // The tables are declared [table NAME 200000 @hv_table] in the patch and
    // the percsampler ramps a line~ across the full allocation with hard-coded
    // sample-rate constants. Shrinking the table via setLengthForTable made
    // tabread4~ read past the new (smaller) bound and trip its assert in
    // debug builds. Keep the 200k allocation; just memcpy the decoded PCM
    // into the head of the buffer and leave the tail zeroed.
    for (int i = 0; i < kNumSoundScraperSamples; ++i) {
        Hv_SoundScraper_Table tbl = kSoundScraperSamples[i].table;
        NSData *pcm = _sampleCache[@(tbl)];
        if (!pcm) continue;
        float *dst = ctx->getBufferForTable((hv_uint32_t)tbl);
        if (!dst) {
            NSLog(@"HeavyCore: getBufferForTable nil for 0x%X", tbl);
            continue;
        }
        int allocFrames = ctx->getLengthForTable((hv_uint32_t)tbl);
        NSUInteger bytes = pcm.length;
        if ((int)(bytes / sizeof(float)) > allocFrames) {
            bytes = allocFrames * sizeof(float);
        }
        memcpy(dst, pcm.bytes, bytes);
    }
}

#pragma mark - Synth selection

- (void)selectSynth:(HeavySynth)synth {
    if (synth == _activeSynth &&
        _render.current.load(std::memory_order_relaxed) != nullptr) {
        return;
    }

    HeavyContextInterface *ctx = nullptr;
    switch (synth) {
        case HeavySynthPhase:
            if (!_phase) {
                _phase = new Heavy_PhaseRing(_sampleRate);
            }
            ctx = _phase;
            break;
        case HeavySynthCircleStrings:
            if (!_strings) {
                _strings = new Heavy_CircleStrings(_sampleRate);
            }
            ctx = _strings;
            break;
        case HeavySynthSoundScraper:
            if (!_soundscraper) {
                _soundscraper = new Heavy_SoundScraper(_sampleRate);
                [self loadSamplesIntoContext:_soundscraper];
            }
            ctx = _soundscraper;
            break;
    }
    if (!ctx) return;

    _activeSynth = synth;
    _render.current.store(ctx, std::memory_order_release);
}

#pragma mark - Message sends (producer side — enqueue only)

- (void)sendFloat:(float)value toReceiver:(NSString *)receiver {
    HeavyEvent e{ HeavyEvent::Float, hv_stringToHash(receiver.UTF8String), value, 0, 0 };
    _render.queue.push(e);
}

- (void)sendBangToReceiver:(NSString *)receiver {
    HeavyEvent e{ HeavyEvent::Bang, hv_stringToHash(receiver.UTF8String), 0, 0, 0 };
    _render.queue.push(e);
}

- (void)sendNoteOn:(int)channel pitch:(int)pitch velocity:(int)velocity {
    HeavyEvent e{ HeavyEvent::Note, kNoteinHash,
                  (float)pitch, (float)velocity, (float)channel };
    _render.queue.push(e);
}

@end
