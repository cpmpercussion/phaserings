//
//  HeavyAudioEngine.mm
//
//  Standalone-app audio driver: AVAudioSession + RemoteIO around a
//  HeavyCore. See HeavyAudioEngine.h and auv3-plan.md (Phase A).
//

#import "HeavyAudioEngine.h"
#import <AVFoundation/AVFoundation.h>

@interface HeavyAudioEngine () {
    HeavyCore *_core;
    AudioUnit _audioUnit;
    int _channels;
}
@end

@implementation HeavyAudioEngine

- (instancetype)initWithSampleRate:(double)sampleRate channels:(int)channels {
    self = [super init];
    if (!self) return nil;

    _channels = channels;
    // The core decodes samples and owns the Heavy contexts. Construct it
    // before buildAudioUnit so its renderRefCon is available to wire in.
    _core = [[HeavyCore alloc] initWithSampleRate:sampleRate channels:channels];

    [self configureSession];
    [self buildAudioUnit];

    return self;
}

- (void)dealloc {
    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
    }
}

#pragma mark - Pass-through properties

- (double)sampleRate { return _core.sampleRate; }
- (HeavySynth)activeSynth { return _core.activeSynth; }

#pragma mark - Audio session

- (void)configureSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    // Playback + MixWithOthers, so PhaseRings can play alongside other music
    // apps (a drone under a backing track, say). On hardware iPads since
    // iOS 17 the session is sometimes pre-touched by other subsystems, so we
    // best-effort and log any failure rather than asserting.
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
        NSLog(@"HeavyAudioEngine: setCategory failed: %@", err);
    }
    err = nil;
    if (![session setPreferredSampleRate:_core.sampleRate error:&err]) {
        NSLog(@"HeavyAudioEngine: setPreferredSampleRate failed: %@", err);
    }
    err = nil;
    // ~5.3 ms buffer: 256 frames at 48 kHz. Leaves comfortable headroom for
    // Heavy's per-block work without being so long that touch responsiveness
    // suffers. iOS may still pick something nearby.
    if (![session setPreferredIOBufferDuration:256.0/_core.sampleRate error:&err]) {
        NSLog(@"HeavyAudioEngine: setPreferredIOBufferDuration failed: %@", err);
    }
    err = nil;
    if (![session setActive:YES error:&err]) {
        NSLog(@"HeavyAudioEngine: session activate failed: %@", err);
    }
}

#pragma mark - AudioUnit setup

- (void)buildAudioUnit {
    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    NSAssert(comp, @"RemoteIO component not found");
    OSStatus err = AudioComponentInstanceNew(comp, &_audioUnit);
    NSAssert(err == noErr, @"AudioComponentInstanceNew: %d", (int)err);

    // Non-interleaved float32 so Heavy's split-channel output maps directly
    // to the AudioBufferList we hand it.
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = _core.sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat
                    | kAudioFormatFlagIsNonInterleaved
                    | kAudioFormatFlagsNativeEndian
                    | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = sizeof(float);
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = sizeof(float);
    fmt.mChannelsPerFrame = _channels;
    fmt.mBitsPerChannel = 32;

    err = AudioUnitSetProperty(_audioUnit,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0,
                               &fmt, sizeof(fmt));
    NSAssert(err == noErr, @"set stream format: %d", (int)err);

    // The render callback reads the core's atomic active-context slot.
    AURenderCallbackStruct cb = { HeavyCoreRenderCallback, _core.renderRefCon };
    err = AudioUnitSetProperty(_audioUnit,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0,
                               &cb, sizeof(cb));
    NSAssert(err == noErr, @"set render callback: %d", (int)err);

    err = AudioUnitInitialize(_audioUnit);
    NSAssert(err == noErr, @"AudioUnitInitialize: %d", (int)err);
}

#pragma mark - Active state

- (BOOL)isActive {
    UInt32 running = 0, size = sizeof(running);
    AudioUnitGetProperty(_audioUnit,
                         kAudioOutputUnitProperty_IsRunning,
                         kAudioUnitScope_Global, 0,
                         &running, &size);
    return running != 0;
}

- (void)setActive:(BOOL)active {
    if (active) {
        // Reactivate explicitly: after an interruption (call, Siri, another
        // app taking the session) the session is inactive, and relying on
        // AudioOutputUnitStart's implicit activation isn't guaranteed.
        NSError *sessionErr = nil;
        if (![[AVAudioSession sharedInstance] setActive:YES error:&sessionErr]) {
            NSLog(@"HeavyAudioEngine: session reactivate failed: %@", sessionErr);
        }
    }
    OSStatus err = active ? AudioOutputUnitStart(_audioUnit) : AudioOutputUnitStop(_audioUnit);
    if (err != noErr) {
        NSLog(@"HeavyAudioEngine: %@ failed: %d", active ? @"start" : @"stop", (int)err);
    }
}

#pragma mark - Pass-through to core

- (void)selectSynth:(HeavySynth)synth {
    [_core selectSynth:synth];
}

- (void)sendFloat:(float)value toReceiver:(NSString *)receiver {
    [_core sendFloat:value toReceiver:receiver];
}

- (void)sendBangToReceiver:(NSString *)receiver {
    [_core sendBangToReceiver:receiver];
}

- (void)sendNoteOn:(int)channel pitch:(int)pitch velocity:(int)velocity {
    [_core sendNoteOn:channel pitch:pitch velocity:velocity];
}

@end
