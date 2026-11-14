//
//  ViewController.m
//  PhaseRings
//
//  Created by Charles Martin on 20/01/2014.
//  Copyright (c) 2014 Charles Martin. All rights reserved.
//
//  Thin app shell around the shared PhaseRingsKit InstrumentViewController.
//  This file owns only the app-only subsystems: OSC ensemble networking, Core
//  MIDI out, and the ensemble overlay. The playable surface, settings UI,
//  ring/touch logic and MIDI mapping all live in the Kit (shared with AUv3).
//

#define METATONE_NEWIDEA_MESSAGE @"new_idea"
#define ENSEMBLE_STATUS_MODE NO
#define NUMBER_COMPOSITIONS_AVAILABLE 5
// Issue #41: the UIBackgroundModes audio entitlement is gone (App Review
// 2.5.4 — background/inter-app rendering is the AUv3's job now). This flag no
// longer means background sound: it keeps the session active across
// *transient* focus loss (notification banners, control centre, app-switcher
// peek) so a held drone survives mid-performance. Once truly backgrounded,
// iOS interrupts the session itself and the interruption handler +
// SceneDelegate's sceneDidBecomeActive: restart path recovers on return.
#define KEEP_AUDIO_ON_RESIGN_ACTIVE YES
// Modern iPads run hardware at 48 kHz; asking for 44.1 forced libpd to log
// "could not set session sample rate". Match the hardware.
#define SAMPLE_RATE 48000
#define SOUND_OUTPUT_CHANNELS 2

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "MetatoneEnsembleView.h"
#import "HeavyAudioEngine.h"
#import <PhaseRingsKit/PhaseRingsKit.h>          // InstrumentViewController, PRSettings
#import "PRUserDefaultsStore.h"

@interface ViewController () <InstrumentViewControllerDelegate>
// Audio
@property (strong, nonatomic) HeavyAudioEngine *audioEngine;
// The shared instrument surface, embedded as a child view controller.
@property (strong, nonatomic) InstrumentViewController *instrument;
// Network
@property (strong, nonatomic) MetatoneNetworkManager *networkManager;
@property (strong, nonatomic) NSMutableDictionary *metatoneClients;
// Ensemble overlay (app-only; hidden unless ENSEMBLE_STATUS_MODE).
@property (weak, nonatomic) MetatoneEnsembleView *ensembleView;
// Settings (shared, host-agnostic store; NSUserDefaults-backed in the app).
@property (strong, nonatomic) id<PRSettingsStore> settingsStore;
@property (strong, nonatomic) NSDate *timeOfLastNewIdea;
// Classifier-driven distortion level (formerly held by a hidden slider).
@property (nonatomic) float currentDistortion;
// Last-sent engine settings, so openPdPatch only re-sends what changed (#34).
@property (nonatomic) BOOL hasPushedEngineSettings;
@property (nonatomic) HeavySynth lastPushedSynth;
@property (nonatomic) NSInteger lastPushedSoundScheme;
@property (nonatomic) float lastPushedMasterVolume;
@property (nonatomic) float lastPushedReverbVolume;
@property (nonatomic) float lastPushedProcessEffects;
@end

@implementation ViewController

#pragma mark - Lazy subsystems

- (id<PRSettingsStore>)settingsStore {
    if (!_settingsStore) {
        _settingsStore = [[PRUserDefaultsStore alloc] init];
    }
    return _settingsStore;
}

- (HeavyAudioEngine *)audioEngine {
    if (!_audioEngine) {
        _audioEngine = [[HeavyAudioEngine alloc] initWithSampleRate:SAMPLE_RATE
                                                           channels:SOUND_OUTPUT_CHANNELS];
    }
    return _audioEngine;
}

#pragma mark - Setup

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    [self setupAudioSession];
    [self startAudioEngine];

    // Core MIDI: input notes play the engine; output is emitted by the Kit
    // surface through its midiOutSink (wired in -embedInstrument).
    self.midiManager = [[MetatoneMidiManager alloc] init];
    __weak typeof(self) weakSelf = self;
    self.midiManager.noteOnHandler = ^(int pitch, int velocity) {
        [weakSelf.audioEngine sendNoteOn:1 pitch:pitch velocity:velocity];
        // Light the matching ring (#29). Fires from the Core MIDI read thread,
        // so hop to main for UIKit. Gated by the same `midi_in` default as the
        // audio above (MetatoneMidiManager only calls us when it's enabled).
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.instrument midiNoteIn:pitch velocity:velocity];
        });
    };
    // Sustain pedal (CC64) → gate the "sing" voice + ring sustain (#29). From
    // the MIDI thread, so hop to main.
    self.midiManager.sustainHandler = ^(BOOL down) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.instrument midiSustainPedal:down];
        });
    };
    // Other CCs → the continuous "sing" performance receivers (#29 follow-up).
    self.midiManager.controlChangeHandler = ^(int cc, int value) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.instrument midiControlChange:cc value:value];
        });
    };

    [self embedInstrument];
    [self setupEnsembleOverlay];

    // Network
    [self setupOSCLogging];
    self.timeOfLastNewIdea = [NSDate date];
    self.listenToMetatoneClassifierMessages = YES;

    // Push volume/effects changes to the engine whenever settings change (from
    // the in-app sheet or the iOS Settings.app). Composition / sound / labels
    // are handled by the embedded surface via its settings store. Observe only
    // the standard defaults — with object:nil this also fired for framework-
    // internal defaults domains (#34).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsChangedPushToEngine)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:[NSUserDefaults standardUserDefaults]];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

// Build and embed the shared instrument surface, wiring it to the app-only
// subsystems (audio engine, OSC, Core MIDI out).
- (void)embedInstrument {
    InstrumentViewController *instrument = [[InstrumentViewController alloc] init];
    instrument.settingsStore = self.settingsStore;
    instrument.showsAppSettings = YES;   // app shows MIDI / Network sections
    instrument.screenshotMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"screenshotMode"];
    instrument.screenshotPattern = [[NSUserDefaults standardUserDefaults] stringForKey:@"screenshotPattern"];

    __weak typeof(self) weakSelf = self;
    // Audio sink: the standalone app drives a HeavyAudioEngine.
    instrument.coreProvider = ^id<HeavyEventSink> _Nullable {
        return weakSelf.audioEngine;
    };
    // MIDI-out transport: route the Kit's MIDI bytes to Core MIDI.
    instrument.midiOutSink = ^(const uint8_t *bytes, NSUInteger length) {
        [weakSelf.midiManager.midi sendBytes:bytes size:(UInt32)length];
    };
    instrument.delegate = self;   // OSC mirror + setup-change broadcast

    self.instrument = instrument;
    [self addChildViewController:instrument];
    instrument.view.frame = self.view.bounds;
    instrument.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:instrument.view];
    [instrument didMoveToParentViewController:self];

    // Initial sound + volumes to the engine (the surface owns sound-scheme
    // selection; the app owns the master/reverb/effects levels).
    [self openPdPatch];
}

- (void)setupEnsembleOverlay {
    MetatoneEnsembleView *ensemble = [[MetatoneEnsembleView alloc] initWithFrame:self.view.bounds];
    ensemble.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ensemble.backgroundColor = [UIColor clearColor];
    ensemble.userInteractionEnabled = NO;
    ensemble.hidden = !ENSEMBLE_STATUS_MODE;
    [self.view addSubview:ensemble];
    self.ensembleView = ensemble;
}

#pragma mark - Audio

- (void)setupAudioSession {
    // HeavyAudioEngine sets the session category when it builds the AudioUnit;
    // we just listen for interruptions here.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioSessionInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:[AVAudioSession sharedInstance]];
    // If the system's media server restarts, every audio object we hold is
    // dead: without a rebuild the app stays silent until relaunched.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMediaServicesReset:)
                                                 name:AVAudioSessionMediaServicesWereResetNotification
                                               object:[AVAudioSession sharedInstance]];
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"Media services were reset, rebuilding the audio engine.");
        // Dropping the engine disposes the dead RemoteIO; the lazy getter
        // builds a fresh one (session category + output unit). The new
        // contexts have heard nothing, so re-send every engine setting.
        self.audioEngine = nil;
        self.hasPushedEngineSettings = NO;
        [self startAudioEngine];
    });
}

- (void)startAudioEngine {
    [self openPdPatch];
    [self.audioEngine setActive:YES];
}

- (void)shutdownSoundProcessing {
    if (!KEEP_AUDIO_ON_RESIGN_ACTIVE) {
        [self.audioEngine setActive:NO];
    }
}

- (void)restartSoundProcessing {
    if (!self.audioEngine.isActive) {
        [self openPdPatch];
        [self.audioEngine setActive:YES];
    }
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification {
    NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        NSLog(@"Audio session interrupted, stopping audio.");
        [self.audioEngine setActive:NO];
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSUInteger options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if (options & AVAudioSessionInterruptionOptionShouldResume) {
            NSLog(@"Audio session interruption ended, restarting audio.");
            [self restartSoundProcessing];
        }
    }
}

// Selects the Heavy synth for the current sound scheme and pushes the level
// settings. Sound schemes 0/1 map to Phase / CircleStrings; 2..6 use
// SoundScraper and pick a sample via `selectsound`.
//
// Only sends what actually changed since the last push: re-sending
// `selectsound` retriggers sample-selection logic in the SoundScraper patch,
// which is the audible grind of #34. The three synths are separate Heavy
// contexts, so a synth switch marks everything dirty — the newly active
// context has never heard our levels.
- (void)openPdPatch {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger soundScheme = [d integerForKey:@"sound"];
    float master  = [d floatForKey:@"master_volume"];
    float reverb  = [d floatForKey:@"reverb_volume"];
    float effects = [d boolForKey:@"process_effects"] ? 1 : 0;
    HeavySynth synth;
    switch (soundScheme) {
        case 0:  synth = HeavySynthPhase;         break;
        case 1:  synth = HeavySynthCircleStrings; break;
        default: synth = HeavySynthSoundScraper;  break;
    }

    BOOL allDirty = !self.hasPushedEngineSettings || synth != self.lastPushedSynth;
    [self.audioEngine selectSynth:synth];  // no-ops when unchanged
    if (allDirty || soundScheme != self.lastPushedSoundScheme) {
        [self.audioEngine sendFloat:soundScheme toReceiver:@"selectsound"];
    }
    if (allDirty || master != self.lastPushedMasterVolume) {
        [self.audioEngine sendFloat:master toReceiver:@"mastervolume"];
    }
    if (allDirty || reverb != self.lastPushedReverbVolume) {
        [self.audioEngine sendFloat:reverb toReceiver:@"reverbvolume"];
    }
    if (allDirty || effects != self.lastPushedProcessEffects) {
        [self.audioEngine sendFloat:effects toReceiver:@"processeffects"];
    }

    self.hasPushedEngineSettings = YES;
    self.lastPushedSynth = synth;
    self.lastPushedSoundScheme = soundScheme;
    self.lastPushedMasterVolume = master;
    self.lastPushedReverbVolume = reverb;
    self.lastPushedProcessEffects = effects;
}

// Any NSUserDefaults change (in-app sheet or the iOS Settings.app pane): push
// the volume/effects levels to the engine, and let the surface re-apply
// composition / sound / labels non-disruptively. For in-app-sheet edits the
// surface already updated via its store observer, so this is a cheap no-op.
//
// NSUserDefaultsDidChangeNotification fires once per set* call, and
// PRUserDefaultsStore writes all 14 keys per edit — so a single sheet edit
// fired this 14×, and a slider drag hundreds of times a second, grinding
// audio on older iPads (#34). Coalesce to one push per main-runloop turn.
- (void)settingsChangedPushToEngine {
    if (![NSThread isMainThread]) {
        // performSelector:afterDelay: needs a running runloop; defaults writes
        // can land on arbitrary threads.
        dispatch_async(dispatch_get_main_queue(), ^{ [self settingsChangedPushToEngine]; });
        return;
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(pushSettingsToEngine)
                                               object:nil];
    [self performSelector:@selector(pushSettingsToEngine) withObject:nil afterDelay:0];
}

- (void)pushSettingsToEngine {
    [self openPdPatch];
    [self.instrument applyCurrentSettings];
}

- (void)setDistortion:(float)level {
    [self.audioEngine sendFloat:level toReceiver:@"distortlevel"];
}

#pragma mark - InstrumentViewControllerDelegate (local input → app-only OSC)

- (void)instrument:(InstrumentViewController *)vc touchBeganAtPoint:(CGPoint)point pitch:(int)pitch velocity:(int)velocity {
    [self.networkManager sendMessageWithTouch:point Velocity:0.0];
}

- (void)instrument:(InstrumentViewController *)vc touchMovedToPoint:(CGPoint)point velocity:(CGFloat)pixelVelocity {
    [self.networkManager sendMessageWithTouch:point Velocity:pixelVelocity];
}

- (void)instrumentTouchEnded:(InstrumentViewController *)vc {
    [self.networkManager sendMessageTouchEnded];
}

- (void)instrument:(InstrumentViewController *)vc didChangeSetupState:(int)state {
    [self.networkManager sendMetatoneMessage:@"CompositionStep"
                                   withState:[NSString stringWithFormat:@"%d", state]];
}

#pragma mark - Network setup

- (void)stopOSCLogging {
    NSLog(@"VC: stopOSCLogging was called");
}

- (void)setupOSCLogging {
    NSLog(@"VC: setupOSCLogging was called");
    self.metatoneClients = [[NSMutableDictionary alloc] init];
    self.networkManager = [[MetatoneNetworkManager alloc] initWithDelegate:self shouldOscLog:YES];
}

#pragma mark - MetatoneNetworkManagerDelegate

- (void)searchingForLoggingServer {
    NSLog(@"VC: Searching for logging server.");
}

- (void)stoppedSearchingForLoggingServer {
    NSLog(@"VC: Stopped searching for logging server.");
}

- (void)loggingServerFoundWithAddress:(NSString *)address andPort:(int)port andHostname:(NSString *)hostname {
    NSLog(@"VC: Connected to logging server: %@", hostname);
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"remote_control_enabled"]) {
        [self.networkManager sendMessageRemoteControl];
    }
}

- (void)metatoneClientFoundWithAddress:(NSString *)address andPort:(int)port andHostname:(NSString *)hostname {
    [self.metatoneClients setObject:address forKey:hostname];
    [self.ensembleView drawEnsemble:self.metatoneClients];
}

- (void)metatoneClientRemovedwithAddress:(NSString *)address andPort:(int)port andHostname:(NSString *)hostname {}

// Remote composition-step: jump the surface to a given setup index.
- (void)didReceiveMetatoneMessageFrom:(NSString *)device withName:(NSString *)name andState:(NSString *)state {
    NSLog(@"METATONE: Received app message from:%@ with state:%@", device, state);
    if ([name isEqualToString:@"CompositionStep"]) {
        [self.instrument showSetupState:[state intValue]];
    }
}

// Remote "new idea": advance to the next setup (wrapping).
- (void)didReceiveEnsembleEvent:(NSString *)event forDevice:(NSString *)device withMeasure:(NSNumber *)measure {
    NSLog(@"EnsembleEvent: %@", event);
    if (!self.listenToMetatoneClassifierMessages) return;
    if ([event isEqualToString:METATONE_NEWIDEA_MESSAGE] &&
        [self.timeOfLastNewIdea timeIntervalSinceNow] < -10.0) {
        int next = self.instrument.currentSetupState + 1;
        if (next >= (int)self.instrument.numberOfSetups) next = 0;
        [self.instrument showSetupState:next];
        self.timeOfLastNewIdea = [NSDate date];
    }
}

- (void)didReceiveGestureMessageFor:(NSString *)device withClass:(NSString *)class {
    NSLog(@"Gesture: %@", class);
}

// Classifier ensemble state drives a subtle distortion swell on divergence.
- (void)didReceiveEnsembleState:(NSString *)state withSpread:(NSNumber *)spread withRatio:(NSNumber *)ratio {
    if (!self.listenToMetatoneClassifierMessages) return;
    if ([state isEqualToString:@"divergence"] && [spread floatValue] < 10.0 && [spread floatValue] > -10.0) {
        // `distortlevel` is a 0..1 control; clamp (the old hidden UISlider used
        // to do this implicitly via its min/max).
        float d = [spread floatValue];
        if (d < 0) d = 0;
        if (d > 1) d = 1;
        self.currentDistortion = d;
        [self setDistortion:self.currentDistortion];
    } else {
        float newDistort = self.currentDistortion * 0.5;
        if (newDistort <= 1 && newDistort >= 0) {
            self.currentDistortion = newDistort;
            [self setDistortion:newDistort];
        }
    }
}

// Ensemble performance start: everyone moves to the same composition.
- (void)didReceivePerformanceStartEvent:(NSString *)event forDevice:(NSString *)device withType:(NSNumber *)type andComposition:(NSNumber *)composition {
    NSLog(@"PERFORMANCE: Received Performance Event: %@, %@, %@", event, device, composition);
    NSInteger newComposition = [composition intValue] % NUMBER_COMPOSITIONS_AVAILABLE;
    [self.settingsStore updateSettings:^(PRSettings *settings) {
        settings.composition = newComposition;
    }];
    self.listenToMetatoneClassifierMessages = YES;
}

- (void)didReceivePerformanceEndEvent:(NSString *)event forDevice:(NSString *)device {
    NSLog(@"PERFORMANCE: Ended, going back to default state");
    self.listenToMetatoneClassifierMessages = YES;
}

- (void)didReceiveGesturePlayMessageFor:(NSString *)device withClass:(NSString *)cla {}

// Remote-OSC playback: animate the rings + play audio as a peer touches.
- (void)didReceiveTouchPlayMessageFor:(NSString *)device X:(NSNumber *)x Y:(NSNumber *)y vel:(NSNumber *)vel {
    CGPoint point = CGPointMake(x.floatValue, y.floatValue);
    if (vel.floatValue > 0.0) {
        [self.instrument playbackSwirlAtPoint:point velocity:vel.floatValue];
    } else {
        [self.instrument playbackTapAtPoint:point];
    }
}

@end
