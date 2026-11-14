//
//  PhaseRingsAudioUnit.mm
//  PhaseRingsKit
//
//  See PhaseRingsAudioUnit.h and auv3-plan.md (Phase C).
//

#import "PhaseRingsAudioUnit.h"
#import <atomic>

const OSType PhaseRingsAUType         = kAudioUnitType_MusicDevice;       // 'aumu'
const OSType PhaseRingsAUSubType      = 'phrg';
const OSType PhaseRingsAUManufacturer = 'CPMa';

// fullState key under which the non-parameter instrument settings ride
// alongside the auto-serialised parameter tree. (Issue #23, Phase F.4.)
static NSString *const kPhaseRingsInstrumentStateKey = @"PhaseRingsInstrumentState";

// Parameter addresses. The float-receiver params map 1:1 onto Heavy [r …]
// names; `synth` is special-cased to HeavyCore -selectSynth:.
typedef NS_ENUM(AUParameterAddress, PhaseRingsParam) {
    PhaseRingsParamMasterVolume = 0,
    PhaseRingsParamReverbVolume,
    PhaseRingsParamDistortLevel,
    PhaseRingsParamProcessEffects,
    PhaseRingsParamSound,
    // Continuous "sing" performance controls (#29 follow-up): exposed as
    // automatable / MIDI-learnable parameters so DAW hosts can replicate the
    // swirl performance. The standalone app drives the same receivers from a
    // fixed CC map instead (it has no host).
    PhaseRingsParamSingLevel,
    PhaseRingsParamPanAngle,
    PhaseRingsParamPanTranslation,
};

// Sound schemes 0..6 (matches the standalone app's Settings `sound`): 0/1 are
// the Phase / String synths, 2..6 are SoundScraper samples picked via the
// `selectsound` receiver.
static HeavySynth SynthForScheme(NSInteger scheme) {
    if (scheme <= 0) return HeavySynthPhase;
    if (scheme == 1) return HeavySynthCircleStrings;
    return HeavySynthSoundScraper;
}

// Receiver names for the float params (indexed by address; synth is handled
// separately).
static NSString *ReceiverForParam(AUParameterAddress addr) {
    switch (addr) {
        case PhaseRingsParamMasterVolume:  return @"mastervolume";
        case PhaseRingsParamReverbVolume:  return @"reverbvolume";
        case PhaseRingsParamDistortLevel:  return @"distortlevel";
        case PhaseRingsParamProcessEffects:return @"processeffects";
        case PhaseRingsParamSingLevel:     return @"singlevel";
        case PhaseRingsParamPanAngle:      return @"sinPanAngle";
        case PhaseRingsParamPanTranslation:return @"panTranslation";
        default: return nil;
    }
}

namespace {
// Capacity of the outgoing-MIDI FIFO (single-producer main thread → single-
// consumer render thread). Power of two so wrap is a mask.
constexpr uint32_t kMidiOutCap = 256;

// Capacity of the incoming-note FIFO (single-producer render thread → single-
// consumer main thread; #29 ring lights). Power of two. Smaller than the
// output ring: note-ons are sparse and the UI drains it every display frame.
constexpr uint32_t kMidiInCap = 64;

// One past the highest parameter address.
constexpr int kNumParams = PhaseRingsParamPanTranslation + 1;

// Stable, heap-owned state the render block captures. The host guarantees it
// will not call the render block while render resources are deallocated, so
// the block only ever sees a valid (or null) refCon. The atomic guards the
// allocate/deallocate publish against a late render.
struct AURenderCtx {
    std::atomic<void *> heavyRefCon{nullptr};  // HeavyCore.renderRefCon (HeavyRenderState*)
    float *scratch[2] = { nullptr, nullptr };  // fallback output when the host hands us null buffers
    uint32_t scratchFrames = 0;

    // Outgoing MIDI (B3a): the gesture→MIDI mapping runs on the main thread and
    // enqueues here; the render block drains and emits via the host's
    // MIDIOutputEventBlock. SPSC ring; 3-byte messages (the only kind we emit).
    uint8_t midiOut[kMidiOutCap][3];
    std::atomic<uint32_t> midiHead{0};  // producer (main)
    std::atomic<uint32_t> midiTail{0};  // consumer (render)
    // (__bridge) AUMIDIOutputEventBlock, kept alive by the AU's capturedMIDIOut.
    std::atomic<void *> midiSink{nullptr};

    // Incoming MIDI for ring lights (#29): the render thread parses host MIDI
    // and enqueues raw {status, data1, data2} here (note-ons + sustain CC); the
    // UI drains on the main thread and interprets. SPSC ring, render = producer,
    // main = consumer. Drop-on-full (the UI lag, not the note, is what's lost).
    uint8_t midiIn[kMidiInCap][3];
    std::atomic<uint32_t> midiInHead{0};  // producer (render)
    std::atomic<uint32_t> midiInTail{0};  // consumer (main)

    // Receiver hashes, precomputed off the render thread so host parameter
    // automation (AURenderEventParameter/Ramp) and the sustain-pedal sing
    // gate can be applied straight to the active context. 0 = no receiver.
    uint32_t paramHash[kNumParams] = {};
    uint32_t hashSing = 0, hashSingPitch = 0, hashSingLevel = 0, hashSelectSound = 0;

    // Latest value of each parameter, from either the main-thread setter or
    // render-thread automation, so a synth switch can re-send every level to
    // the newly active context (each synth is its own Heavy context).
    std::atomic<float> paramValue[kNumParams];

    // Sustain-pedal "sing" voice (#29), owned by the render thread so it works
    // with the plugin UI closed and in offline bounces. Pedal down arms the
    // next note-on to become the sing voice; either pedal edge releases it.
    bool sustainDown = false;
    int heldNote = -1;

    // Last `sound` scheme applied, by either the main-thread setter or render
    // automation; -1 forces the next one. Hosts and PRAudioUnitStore rewrite
    // every parameter on any edit, and a repeated `selectsound` retriggers
    // SoundScraper sample selection — the audible grind of #34.
    std::atomic<long> appliedScheme{-1};
};
}

@interface PhaseRingsAudioUnit () {
    AURenderCtx *_rc;
}
@property (nonatomic, strong, nullable) HeavyCore *core;
@property (nonatomic, strong) AUAudioUnitBus *outputBus;
@property (nonatomic, strong) AUAudioUnitBusArray *outputBusArray;
@property (nonatomic, strong) AUParameterTree *parameterTree;
// Strong copy of the host's MIDI-output block; keeps it alive while the render
// block holds a __bridge pointer to it in _rc->midiSink.
@property (nonatomic, copy, nullable) AUMIDIOutputEventBlock capturedMIDIOut;
@end

@implementation PhaseRingsAudioUnit

@synthesize parameterTree = _parameterTree;

+ (AudioComponentDescription)componentDescription {
    AudioComponentDescription d = {0};
    d.componentType = PhaseRingsAUType;
    d.componentSubType = PhaseRingsAUSubType;
    d.componentManufacturer = PhaseRingsAUManufacturer;
    d.componentFlags = 0;
    d.componentFlagsMask = 0;
    return d;
}

+ (void)registerAUComponent {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self registerSubclass:[PhaseRingsAudioUnit class]
        asComponentDescription:[self componentDescription]
                          name:@"Charles Martin: PhaseRings"
                       version:0x00020000];  // 2.0.0
    });
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (!self) return nil;

    _rc = new AURenderCtx();
    for (int a = 0; a < kNumParams; ++a) {
        NSString *receiver = ReceiverForParam(a);
        _rc->paramHash[a] = receiver ? HeavyCoreReceiverHash(receiver.UTF8String) : 0;
        _rc->paramValue[a].store(0.0f, std::memory_order_relaxed);
    }
    _rc->hashSing        = HeavyCoreReceiverHash("sing");
    _rc->hashSingPitch   = HeavyCoreReceiverHash("singpitch");
    _rc->hashSingLevel   = HeavyCoreReceiverHash("singlevel");
    _rc->hashSelectSound = HeavyCoreReceiverHash("selectsound");
    _instrumentSettingsState = @{};  // empty -> store falls back to defaults

    // Stereo, non-interleaved float32 — matches HeavyCore's split-channel out.
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0
                                                                          channels:2];
    NSError *busErr = nil;
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:&busErr];
    if (!_outputBus) {
        if (outError) *outError = busErr;
        return nil;
    }
    _outputBus.maximumChannelCount = 2;
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                            busType:AUAudioUnitBusTypeOutput
                                                             busses:@[_outputBus]];

    self.maximumFramesToRender = 4096;

    [self buildParameterTree];

    return self;
}

- (void)dealloc {
    [self freeScratch];
    delete _rc;
}

#pragma mark - Parameters

- (void)buildParameterTree {
    AUParameter *master = [AUParameterTree createParameterWithIdentifier:@"masterVolume"
        name:@"Master Volume" address:PhaseRingsParamMasterVolume
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_LinearGain unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    master.value = 1.0;

    AUParameter *reverb = [AUParameterTree createParameterWithIdentifier:@"reverbVolume"
        name:@"Reverb" address:PhaseRingsParamReverbVolume
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_LinearGain unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    reverb.value = 0.5;

    AUParameter *distort = [AUParameterTree createParameterWithIdentifier:@"distortLevel"
        name:@"Distortion" address:PhaseRingsParamDistortLevel
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_LinearGain unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    distort.value = 0.0;

    AUParameter *effects = [AUParameterTree createParameterWithIdentifier:@"processEffects"
        name:@"Effects" address:PhaseRingsParamProcessEffects
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_Boolean unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    effects.value = 0.0;

    AUParameter *sound = [AUParameterTree createParameterWithIdentifier:@"sound"
        name:@"Sound" address:PhaseRingsParamSound
        min:0.0 max:6.0 unit:kAudioUnitParameterUnit_Indexed unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:@[@"Phase Synthesis", @"String Synthesis", @"Singing Bowls",
                       @"Gongs", @"Crotales", @"Terracotta Pots", @"Marimba"]
        dependentParameters:nil];
    sound.value = 0.0;

    // Continuous "sing" performance controls (#29 follow-up). singLevel is the
    // voice intensity; panAngle (bipolar) and panTranslation are the swirl
    // timbre morph. Defaults: a mid level so the voice is audible when gated,
    // neutral timbre. The `sing` gate + `singpitch` are event-driven (sustain
    // pedal + note), not parameters.
    AUParameter *singLevel = [AUParameterTree createParameterWithIdentifier:@"singLevel"
        name:@"Sing Level" address:PhaseRingsParamSingLevel
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_LinearGain unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    singLevel.value = 0.7;

    AUParameter *panAngle = [AUParameterTree createParameterWithIdentifier:@"panAngle"
        name:@"Sing Angle" address:PhaseRingsParamPanAngle
        min:-1.0 max:1.0 unit:kAudioUnitParameterUnit_Generic unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    panAngle.value = 0.0;

    AUParameter *panTranslation = [AUParameterTree createParameterWithIdentifier:@"panTranslation"
        name:@"Sing Morph" address:PhaseRingsParamPanTranslation
        min:0.0 max:1.0 unit:kAudioUnitParameterUnit_Generic unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    panTranslation.value = 0.0;

    self.parameterTree = [AUParameterTree createTreeWithChildren:@[master, reverb, distort, effects, sound,
                                                                   singLevel, panAngle, panTranslation]];

    // Apply parameter changes to the core. Called off the render thread (the
    // setter side); HeavyCore's send paths just enqueue, so this is safe.
    __weak PhaseRingsAudioUnit *weakSelf = self;
    self.parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        [weakSelf applyParameter:param.address value:value];
    };
}

- (void)applyParameter:(AUParameterAddress)address value:(AUValue)value {
    if (address < kNumParams) _rc->paramValue[address].store(value, std::memory_order_relaxed);
    HeavyCore *core = self.core;
    if (!core) return;  // re-applied in full on allocateRenderResources
    if (address == PhaseRingsParamSound) {
        NSInteger scheme = lroundf(value);
        if (scheme < 0) scheme = 0;
        if (scheme > 6) scheme = 6;
        if (_rc->appliedScheme.exchange(scheme, std::memory_order_relaxed) == scheme) return;
        HeavySynth before = core.activeSynth;
        [core selectSynth:SynthForScheme(scheme)];
        [core sendFloat:(float)scheme toReceiver:@"selectsound"];
        if (core.activeSynth != before) {
            // The newly active context has never heard our levels.
            for (AUParameter *p in self.parameterTree.allParameters) {
                NSString *receiver = ReceiverForParam(p.address);
                if (receiver) [core sendFloat:p.value toReceiver:receiver];
            }
        }
        return;
    }
    NSString *receiver = ReceiverForParam(address);
    if (receiver) {
        [core sendFloat:value toReceiver:receiver];
    }
}

- (void)pushAllParametersToCore {
    _rc->appliedScheme.store(-1, std::memory_order_relaxed);
    for (AUParameter *p in self.parameterTree.allParameters) {
        [self applyParameter:p.address value:p.value];
    }
}

#pragma mark - Full state (session save/restore)

// Carry the non-parameter instrument settings alongside the parameter tree
// that AUAudioUnit's default fullState already serialises. fullStateForDocument
// builds on fullState, so overriding here covers both.
- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary<NSString *, id> *state = [[super fullState] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];
    state[kPhaseRingsInstrumentStateKey] = self.instrumentSettingsState ?: @{};
    return state;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];  // restores the parameter tree
    id inst = fullState[kPhaseRingsInstrumentStateKey];
    if ([inst isKindOfClass:[NSDictionary class]]) {
        self.instrumentSettingsState = inst;
    }
    void (^handler)(void) = self.instrumentStateRestoredHandler;
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(); });
    }
}

#pragma mark - Busses

- (AUAudioUnitBusArray *)outputBusses {
    return _outputBusArray;
}

#pragma mark - MIDI out (B3a)

// Advertise a single MIDI output port so hosts expose us as a MIDI source and
// install a MIDIOutputEventBlock.
- (NSArray<NSString *> *)MIDIOutputNames {
    return @[@"PhaseRings"];
}

// Main-thread producer: enqueue a 3-byte message for the render thread to emit.
// Drops the message if the FIFO is full (rather than block the UI).
- (void)sendMIDIOutBytes:(const uint8_t *)bytes length:(NSUInteger)length {
    if (length < 1 || !bytes) return;
    uint32_t head = _rc->midiHead.load(std::memory_order_relaxed);
    uint32_t next = (head + 1) & (kMidiOutCap - 1);
    if (next == _rc->midiTail.load(std::memory_order_acquire)) return;  // full
    _rc->midiOut[head][0] = bytes[0];
    _rc->midiOut[head][1] = (length > 1) ? bytes[1] : 0;
    _rc->midiOut[head][2] = (length > 2) ? bytes[2] : 0;
    _rc->midiHead.store(next, std::memory_order_release);
}

// Main-thread consumer: hand the UI each MIDI message the render thread
// enqueued since last call, for ring lights (#29). Mirrors the render block's
// drain of the outgoing ring.
- (void)drainIncomingMIDI:(void (^)(uint8_t status, uint8_t data1, uint8_t data2))handler {
    if (!handler) return;
    uint32_t tail = _rc->midiInTail.load(std::memory_order_relaxed);
    uint32_t head = _rc->midiInHead.load(std::memory_order_acquire);
    while (tail != head) {
        handler(_rc->midiIn[tail][0], _rc->midiIn[tail][1], _rc->midiIn[tail][2]);
        tail = (tail + 1) & (kMidiInCap - 1);
    }
    _rc->midiInTail.store(tail, std::memory_order_release);
}

#pragma mark - Render resources

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) {
        return NO;
    }

    double sampleRate = self.outputBus.format.sampleRate;

    // (Re)build the core at the host's sample rate. Decodes the SoundScraper
    // samples — fine here, this is not the render thread.
    self.core = [[HeavyCore alloc] initWithSampleRate:sampleRate channels:2];
    // Build all three synths now so `sound` automation can switch between
    // them on the render thread without constructing anything there.
    [self.core preloadAllSynths];
    _rc->sustainDown = false;
    _rc->heldNote = -1;

    // Fallback output buffers for hosts that hand us null buffer pointers.
    [self freeScratch];
    uint32_t frames = (uint32_t)self.maximumFramesToRender;
    _rc->scratchFrames = frames;
    _rc->scratch[0] = (float *)calloc(frames, sizeof(float));
    _rc->scratch[1] = (float *)calloc(frames, sizeof(float));

    // Select the synth for the chosen sound scheme, then push all current
    // param values, before publishing the refCon to the render block.
    AUParameter *soundParam = [self.parameterTree parameterWithAddress:PhaseRingsParamSound];
    NSInteger scheme = soundParam ? lroundf(soundParam.value) : 0;
    [self.core selectSynth:SynthForScheme(scheme)];
    [self pushAllParametersToCore];

    // Capture the host's MIDI-output block (set before render begins). The
    // strong property keeps it alive; the render block reads the bridged
    // pointer. Cleared in deallocateRenderResources.
    self.capturedMIDIOut = self.MIDIOutputEventBlock;
    _rc->midiSink.store((__bridge void *)self.capturedMIDIOut, std::memory_order_release);

    _rc->heavyRefCon.store(self.core.renderRefCon, std::memory_order_release);
    return YES;
}

- (void)deallocateRenderResources {
    _rc->heavyRefCon.store(nullptr, std::memory_order_release);
    _rc->midiSink.store(nullptr, std::memory_order_release);
    self.capturedMIDIOut = nil;
    self.core = nil;
    [self freeScratch];
    [super deallocateRenderResources];
}

- (void)freeScratch {
    free(_rc->scratch[0]);
    free(_rc->scratch[1]);
    _rc->scratch[0] = _rc->scratch[1] = nullptr;
    _rc->scratchFrames = 0;
}

#pragma mark - Render

- (AUInternalRenderBlock)internalRenderBlock {
    AURenderCtx *rc = _rc;  // captured by value (stable pointer for the AU's lifetime)
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount,
                              NSInteger outputBusNumber,
                              AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
        // Hosts may hand us a buffer list with null mData and expect us to
        // provide the memory. Point any null buffers at our scratch.
        for (UInt32 i = 0; i < outputData->mNumberBuffers; ++i) {
            if (outputData->mBuffers[i].mData == NULL && i < 2 && rc->scratch[i]) {
                outputData->mBuffers[i].mData = rc->scratch[i];
                outputData->mBuffers[i].mDataByteSize = frameCount * sizeof(float);
            }
        }

        // Emit any queued outgoing MIDI through the host's block (B3a). Drains
        // regardless of audio state so UI gestures still produce MIDI.
        AUMIDIOutputEventBlock midiSink =
            (__bridge AUMIDIOutputEventBlock)rc->midiSink.load(std::memory_order_acquire);
        if (midiSink) {
            uint32_t tail = rc->midiTail.load(std::memory_order_relaxed);
            uint32_t head = rc->midiHead.load(std::memory_order_acquire);
            while (tail != head) {
                midiSink((AUEventSampleTime)timestamp->mSampleTime, 0 /*cable*/, 3, rc->midiOut[tail]);
                tail = (tail + 1) & (kMidiOutCap - 1);
            }
            rc->midiTail.store(tail, std::memory_order_release);
        }

        void *refCon = rc->heavyRefCon.load(std::memory_order_acquire);
        if (refCon == NULL) {
            for (UInt32 i = 0; i < outputData->mNumberBuffers; ++i) {
                if (outputData->mBuffers[i].mData) {
                    memset(outputData->mBuffers[i].mData, 0, outputData->mBuffers[i].mDataByteSize);
                }
            }
            return noErr;
        }

        // Apply incoming host events (MIDI notes, the sustain-pedal sing gate,
        // parameter automation) to the active context, on this thread, before
        // the FIFO drain + process() in HeavyCoreRenderCallback. Sub-block
        // timing is ignored — fine for these decaying/sustained voices, and
        // the patches smooth their level receivers. Legacy AURenderEventMIDI
        // (MIDI 1.0); MIDIEventList (UMP) is not handled.
        for (const AURenderEvent *e = realtimeEventListHead; e != NULL; e = e->head.next) {
            if (e->head.eventType == AURenderEventParameter ||
                e->head.eventType == AURenderEventParameterRamp) {
                // Ramps jump straight to their end value.
                const AUParameterAddress addr = e->parameter.parameterAddress;
                const AUValue value = e->parameter.value;
                if (addr >= kNumParams) continue;
                rc->paramValue[addr].store(value, std::memory_order_relaxed);
                if (addr == PhaseRingsParamSound) {
                    long scheme = lroundf(value);
                    if (scheme < 0) scheme = 0;
                    if (scheme > 6) scheme = 6;
                    if (rc->appliedScheme.exchange(scheme, std::memory_order_relaxed) == scheme) continue;
                    // Release a held sing voice first, or it resumes when
                    // the old context next becomes active.
                    if (rc->heldNote >= 0) {
                        HeavyCoreSendFloat(refCon, rc->hashSing, 0.0f);
                        rc->heldNote = -1;
                    }
                    if (HeavyCoreSelectSynthRealtime(refCon, SynthForScheme(scheme))) {
                        for (int a = 0; a < kNumParams; ++a) {
                            if (rc->paramHash[a]) {
                                HeavyCoreSendFloat(refCon, rc->paramHash[a],
                                                   rc->paramValue[a].load(std::memory_order_relaxed));
                            }
                        }
                    }
                    HeavyCoreSendFloat(refCon, rc->hashSelectSound, (float)scheme);
                } else if (rc->paramHash[addr]) {
                    HeavyCoreSendFloat(refCon, rc->paramHash[addr], value);
                }
                continue;
            }
            if (e->head.eventType != AURenderEventMIDI) continue;
            const AUMIDIEvent *m = &e->MIDI;
            if (m->length < 2) continue;
            const uint8_t status = m->data[0] & 0xF0;
            const int channel = (m->data[0] & 0x0F) + 1;  // 1-based, matches the app
            const uint8_t d1 = m->data[1];
            const uint8_t d2 = (m->length >= 3) ? m->data[2] : 0;
            if (status == 0x90) {  // note on (velocity 0 == note off)
                HeavyCoreSendMIDINote(refCon, d1, d2, channel);
            } else if (status == 0x80) {  // note off
                HeavyCoreSendMIDINote(refCon, d1, 0, channel);
            }
            // Sustain-pedal sing voice (#29). Mirrors InstrumentViewController's
            // standalone-app logic, which the AU UI now uses for visuals only.
            if (status == 0x90 && d2 > 0 && rc->sustainDown && rc->heldNote < 0) {
                rc->heldNote = d1;
                HeavyCoreSendFloat(refCon, rc->hashSingPitch, (float)d1);
                HeavyCoreSendFloat(refCon, rc->hashSingLevel, (float)d2 / 127.0f);
                HeavyCoreSendFloat(refCon, rc->hashSing, 1.0f);
            } else if (status == 0xB0 && d1 == 64) {
                const bool down = (d2 >= 64);
                if (down != rc->sustainDown) {
                    rc->sustainDown = down;
                    if (rc->heldNote >= 0) {
                        HeavyCoreSendFloat(refCon, rc->hashSing, 0.0f);
                        rc->heldNote = -1;
                    }
                }
            }
            // Surface note-ons and the sustain pedal (CC64) to the UI for ring
            // lights (#29). Note-offs aren't needed (flashes self-fade; sustain
            // holds until the pedal lifts).
            const bool wantUI = (status == 0x90 && d2 > 0) ||
                                (status == 0xB0 && d1 == 64);
            if (wantUI) {
                uint32_t h = rc->midiInHead.load(std::memory_order_relaxed);
                uint32_t n = (h + 1) & (kMidiInCap - 1);
                if (n != rc->midiInTail.load(std::memory_order_acquire)) {  // not full
                    rc->midiIn[h][0] = m->data[0];   // full status byte (with channel)
                    rc->midiIn[h][1] = d1;
                    rc->midiIn[h][2] = d2;
                    rc->midiInHead.store(n, std::memory_order_release);
                }
            }
        }

        return HeavyCoreRenderCallback(refCon, actionFlags, timestamp,
                                       (UInt32)outputBusNumber, frameCount, outputData);
    };
}

@end
