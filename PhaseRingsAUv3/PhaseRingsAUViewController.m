//
//  PhaseRingsAUViewController.m
//  PhaseRingsAUv3
//
//  See PhaseRingsAUViewController.h and auv3-plan.md (Phase E).
//

#import "PhaseRingsAUViewController.h"
#import <PhaseRingsKit/PhaseRingsKit.h>

@interface PhaseRingsAUViewController ()
@property (nonatomic, strong) PhaseRingsAudioUnit *audioUnit;
@property (nonatomic, strong) InstrumentViewController *instrument;
// Polls the AU's incoming-note ring each frame to light rings on host MIDI
// (#29). Live only while the view is on screen (avoids a CADisplayLink retain
// cycle and idle ticks when the plugin UI is closed).
@property (nonatomic, strong, nullable) CADisplayLink *midiInLink;
@end

@implementation PhaseRingsAUViewController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1024, 1024)];
    self.view.backgroundColor = [UIColor blackColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.preferredContentSize = CGSizeMake(1024, 1024);
    [self embedInstrument];
}

// Drive the incoming-note → ring-light polling off the view's lifecycle. The
// link retains its target, so we create it on appear and tear it down on
// disappear rather than leaking the controller.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Discard whatever queued up while the UI was closed (the render thread
    // already handled its audio) and clear any stale held ring, so reopening
    // doesn't replay a burst of old note flashes and pedal edges.
    [self.audioUnit drainIncomingMIDI:^(uint8_t status, uint8_t d1, uint8_t d2) {}];
    [self.instrument midiSustainPedal:NO];
    if (!self.midiInLink) {
        self.midiInLink = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(drainIncomingMIDI)];
        [self.midiInLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.midiInLink invalidate];
    self.midiInLink = nil;
}

- (void)drainIncomingMIDI {
    __weak PhaseRingsAUViewController *weakSelf = self;
    [self.audioUnit drainIncomingMIDI:^(uint8_t status, uint8_t d1, uint8_t d2) {
        InstrumentViewController *instrument = weakSelf.instrument;
        switch (status & 0xF0) {
            case 0x90:  // note on (the AU only enqueues velocity > 0)
                [instrument midiNoteIn:d1 velocity:d2];
                break;
            case 0xB0:  // control change
                if (d1 == 64) [instrument midiSustainPedal:(d2 >= 64)];
                break;
        }
    }];
}

- (void)embedInstrument {
    if (self.instrument) return;

    InstrumentViewController *instrument = [[InstrumentViewController alloc] init];
    // The AU render thread gates the sustain-pedal sing voice; the surface
    // only lights the rings for it.
    instrument.hostHandlesMIDISing = YES;
    __weak PhaseRingsAUViewController *weakSelf = self;
    instrument.coreProvider = ^id<HeavyEventSink> _Nullable {
        return weakSelf.audioUnit.core;
    };
    // Route sound-scheme changes through the AU's `sound` parameter so the
    // choice is saved with the AU session and applied to the core.
    instrument.soundSchemeHandler = ^(NSInteger scheme) {
        AUParameter *p = [weakSelf.audioUnit.parameterTree parameterWithAddress:4 /* sound */];
        p.value = (AUValue)scheme;
    };
    // MIDI-out: queue the surface's MIDI for the host (drained on the render
    // thread and emitted via MIDIOutputEventBlock).
    instrument.midiOutSink = ^(const uint8_t *bytes, NSUInteger length) {
        [weakSelf.audioUnit sendMIDIOutBytes:bytes length:length];
    };
    self.instrument = instrument;

    [self wireSettingsStore];

    [self addChildViewController:instrument];
    instrument.view.frame = self.view.bounds;
    instrument.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:instrument.view];
    [instrument didMoveToParentViewController:self];

    [self syncDisplayedSound];
}

// The AU and the view can be created in either order; reflect the AU's
// current `sound` value in the control bar once both exist.
- (void)syncDisplayedSound {
    if (!self.instrument || !self.audioUnit) return;
    AUParameter *p = [self.audioUnit.parameterTree parameterWithAddress:4 /* sound */];
    [self.instrument setDisplayedSoundScheme:(NSInteger)(p.value + 0.5f)];
}

// Back the shared instrument surface with an AU-backed settings store (params
// in the tree, composition/notes/scales/labels in the AU's fullState), once
// both the AU and the instrument exist. (Issue #23, Phase F.4.)
- (void)wireSettingsStore {
    if (!self.instrument || !self.audioUnit) return;
    if ([self.instrument.settingsStore isKindOfClass:[PRAudioUnitStore class]]) return;
    self.instrument.settingsStore = [[PRAudioUnitStore alloc] initWithAudioUnit:self.audioUnit];
}

#pragma mark - AUAudioUnitFactory

- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                                   error:(NSError **)error {
    self.audioUnit = [[PhaseRingsAudioUnit alloc] initWithComponentDescription:desc
                                                                       options:0
                                                                         error:error];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self wireSettingsStore];
        [self syncDisplayedSound];
    });
    return self.audioUnit;
}

@end
