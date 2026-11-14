//
//  InstrumentViewController.m
//  PhaseRingsKit
//
//  See InstrumentViewController.h and auv3-plan.md (Phase F). The touch/sing
//  logic mirrors the standalone ViewController, with networking + MIDI-out
//  removed (those stay app-only).
//

#import "InstrumentViewController.h"
#import "SingingBowlView.h"
#import "SingingBowlSetup.h"
#import "GenerativeSetupComposition.h"
#import "PRSettings.h"
#import "PRCompositionFactory.h"
#import "PRMemoryStore.h"
#import <PhaseRingsKit/PhaseRingsKit-Swift.h>   // PRSettingsHostingController

// Diagonal used to normalise swirl translation into Heavy's panTranslation,
// matching the standalone app.
static const CGFloat kScreenDiagonal = 1280.0;

@interface InstrumentViewController ()
@property (nonatomic, strong) SingingBowlView *bowlView;
@property (nonatomic, strong) SingingBowlSetup *bowlSetup;
@property (nonatomic, strong) GenerativeSetupComposition *composition;
@property (nonatomic) UInt8 currentlyPanningPitch;
@property (nonatomic) CGSize lastDrawnSize;
@property (nonatomic) NSInteger soundScheme;
@property (nonatomic) BOOL showNoteLabels;
@property (nonatomic) BOOL showSetupLabel;
@property (nonatomic) int setupState;
// On-screen control bar.
@property (nonatomic, strong) UIStepper *setupStepper;
@property (nonatomic, strong) UILabel *setupDescriptionLabel;
// Last settings applied, so a settings change only rebuilds what actually moved.
@property (nonatomic, strong) PRSettings *appliedSettings;
// Token from the store's addSettingsObserver: (issue #37 — observers are
// token-registered now, so the settings sheet's model can't clobber ours).
@property (nonatomic, strong, nullable) id settingsObserverToken;
// Remote-OSC playback state (continuous "swirl" with a 1s auto-stop timer).
@property (nonatomic) int playbackPanGestureState;
@property (nonatomic, strong, nullable) NSTimer *playbackPanGestureTimeout;
// MIDI-in sustain pedal (#29): while the pedal is down, the first note-on lights
// a pulsing (held) ring until the pedal lifts; other notes flash as usual.
@property (nonatomic) BOOL midiSustainDown;
@property (nonatomic) int midiSustainedNote;   // -1 = none currently sustained
@end

// Playback pan states (matches the standalone app's PAN_STATE_* constants).
static const int kPlaybackStateNothing = 0;
static const int kPlaybackStateMoving  = 1;

@implementation InstrumentViewController

@synthesize settingsStore = _settingsStore;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.multipleTouchEnabled = YES;
    self.showNoteLabels = YES;
    self.midiSustainedNote = -1;

    // SingingBowlView is transparent in light mode (and paints the solarized
    // teal itself in dark mode), so it relies on a backdrop behind it. Provide
    // it here — light grey in light mode (matching the old storyboard root
    // view), the solarized teal in dark mode — so both the app and the AUv3
    // host show the instrument on the right background instead of black.
    self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:0.00 green:0.17 blue:0.21 alpha:1.0];  // solarized base
        }
        return [UIColor colorWithWhite:0.8 alpha:1.0];
    }];

    self.bowlView = [[SingingBowlView alloc] initWithFrame:self.view.bounds];
    self.bowlView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.bowlView.backgroundColor = [UIColor clearColor];
    // VoiceOver: the rings are a playing surface, not navigable controls —
    // AllowsDirectInteraction passes touches straight through (as in other
    // instrument apps) so taps and swirls play notes rather than being
    // intercepted by the screen reader.
    self.bowlView.isAccessibilityElement = YES;
    self.bowlView.accessibilityTraits = UIAccessibilityTraitAllowsDirectInteraction;
    self.bowlView.accessibilityLabel = @"Playing surface";
    self.bowlView.accessibilityHint = @"Rings of notes, lowest at the centre, rising outward. Tap a ring to play its note; move in circles to swell it.";
    [self.view addSubview:self.bowlView];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panGestureRecognized:)];
    // Issue #35: match the old storyboard recognizer (cancelsTouchesInView=NO,
    // delaysTouchesEnded=NO). With the default cancelsTouchesInView=YES, a
    // recognized pan claims every later touch, so no taps land while swirling —
    // these flags keep touchesBegan: firing, so a held swirl drone can have
    // tapped notes played over the top.
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:pan];

    [self buildControlBar];
    [self reloadComposition];
}

#pragma mark - Settings store

- (id<PRSettingsStore>)settingsStore {
    if (!_settingsStore) {
        self.settingsStore = [[PRMemoryStore alloc] init];  // through setter -> registers observer
    }
    return _settingsStore;
}

- (void)setSettingsStore:(id<PRSettingsStore>)settingsStore {
    [_settingsStore removeSettingsObserver:_settingsObserverToken];
    _settingsStore = settingsStore;
    __weak typeof(self) weakSelf = self;
    _settingsObserverToken = [settingsStore addSettingsObserver:^(PRSettings *settings) {
        [weakSelf settingsDidChange:settings];
    }];
    if (self.isViewLoaded) {
        [self reloadComposition];
    }
}

- (void)dealloc {
    [_settingsStore removeSettingsObserver:_settingsObserverToken];
}

#pragma mark - Control bar

- (void)buildControlBar {
    // Bottom-centre, like the old storyboard: a top-left bar blocked tapping the
    // top of the screen and sat under the window traffic lights when the app is
    // windowed on iPadOS. Layout is label | stepper | gear with the *stepper*
    // pinned to the screen centre, so the variable-width label can't shove it
    // around.

    // Setup stepper — steps through the composition's setups (replaces the old
    // "New Setup" pill; matches the standalone app's compositionStepper).
    self.setupStepper = [[UIStepper alloc] init];
    self.setupStepper.wraps = YES;
    self.setupStepper.minimumValue = 0;
    [self.setupStepper addTarget:self action:@selector(setupStepperChanged)
                forControlEvents:UIControlEventValueChanged];
    self.setupStepper.translatesAutoresizingMaskIntoConstraints = NO;
    self.setupStepper.accessibilityLabel = @"Ring setup";
    self.setupStepper.accessibilityHint = @"Changes the notes on the rings.";
    // accessibilityValue (the current setup's description) is kept fresh in
    // updateSetupDescription.
    [self.view addSubview:self.setupStepper];

    // Settings gear — presents the shared PhaseRingsKit settings screen. Sound
    // scheme + note labels now live there rather than as on-screen pills.
    // labelColor so it tracks light/dark like the stepper (which ignores
    // tintColor and adapts on its own).
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];
    settingsButton.tintColor = [UIColor labelColor];
    [settingsButton addTarget:self action:@selector(showSettingsTapped)
             forControlEvents:UIControlEventTouchUpInside];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    settingsButton.accessibilityLabel = @"Settings";
    settingsButton.accessibilityHint = @"Opens sound, composition and audio settings.";
    [self.view addSubview:settingsButton];

    // Setup description label — shown when the setup_label setting is on.
    self.setupDescriptionLabel = [[UILabel alloc] init];
    self.setupDescriptionLabel.textColor = [UIColor secondaryLabelColor];
    self.setupDescriptionLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.setupDescriptionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.setupDescriptionLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.setupStepper.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.setupStepper.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.setupDescriptionLabel.centerYAnchor constraintEqualToAnchor:self.setupStepper.centerYAnchor],
        [self.setupDescriptionLabel.trailingAnchor constraintEqualToAnchor:self.setupStepper.leadingAnchor constant:-12],
        [self.setupDescriptionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [settingsButton.centerYAnchor constraintEqualToAnchor:self.setupStepper.centerYAnchor],
        [settingsButton.leadingAnchor constraintEqualToAnchor:self.setupStepper.trailingAnchor constant:12],
        // Keep the gear on-screen on narrow widths (PR #40 review).
        [settingsButton.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
    ]];
}

- (void)showSettingsTapped {
    // Edits flow through the store live (observer -> -settingsDidChange:), so no
    // reload-on-dismiss is needed here.
    PRSettingsHostingController *settings =
        [[PRSettingsHostingController alloc] initWithStore:self.settingsStore];
    settings.showsAppSettings = self.showsAppSettings;
    __weak typeof(self) weakSelf = self;
    settings.onDone = ^{ [weakSelf dismissViewControllerAnimated:YES completion:nil]; };
    [self presentViewController:settings animated:YES completion:nil];
}

#pragma mark - Sound scheme

- (void)applySoundScheme:(NSInteger)scheme {
    [self setDisplayedSoundScheme:scheme];
    if (self.soundSchemeHandler) {
        self.soundSchemeHandler(scheme);
    } else {
        // No host wiring: drive the core directly.
        id<HeavyEventSink> core = [self core];
        HeavySynth synth = (scheme == 0) ? HeavySynthPhase
                         : (scheme == 1) ? HeavySynthCircleStrings
                                         : HeavySynthSoundScraper;
        [core selectSynth:synth];
        [core sendFloat:(float)scheme toReceiver:@"selectsound"];
    }
}

- (void)setDisplayedSoundScheme:(NSInteger)scheme {
    if (scheme < 0) scheme = 0;
    if (scheme > 6) scheme = 6;
    self.soundScheme = scheme;
}

#pragma mark - Setups

- (void)setupStepperChanged {
    int state = (int)lround(self.setupStepper.value);
    [self applySetupForState:state];
    if ([self.delegate respondsToSelector:@selector(instrument:didChangeSetupState:)]) {
        [self.delegate instrument:self didChangeSetupState:state];
    }
}

- (void)applySetupForState:(int)state {
    // Screenshot mode forces a fixed 9-pitch spread so App Store captures show a
    // consistent, busier display (rings lit per screenshotPattern, below).
    NSArray *pitches = self.screenshotMode
        ? @[@48, @50, @52, @55, @57, @60, @62, @64, @67]
        : [self.composition setupForState:state];
    if (pitches.count == 0) return;
    self.setupState = state;
    self.bowlSetup = [[SingingBowlSetup alloc] initWithPitches:[NSMutableArray arrayWithArray:pitches]];
    self.lastDrawnSize = CGSizeZero;  // force redraw at current size
    [self.view setNeedsLayout];
    [self updateSetupDescription];
}

- (void)updateSetupDescription {
    NSArray *descriptions = self.composition.setupDescriptions;
    NSString *text = (self.setupState >= 0 && self.setupState < (int)descriptions.count)
                   ? descriptions[self.setupState] : @"";
    self.setupDescriptionLabel.text = text;
    self.setupDescriptionLabel.hidden = !self.showSetupLabel;
    // VoiceOver reads the stepper as "Ring setup, <description>" even when the
    // visual label is switched off.
    self.setupStepper.accessibilityValue = text.length ? text
        : [NSString stringWithFormat:@"Setup %d", self.setupState + 1];
}

// drawSetup: lays the rings out for the view size at call time, so (re)draw
// once the host has given us a real size, and again whenever it changes.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.bowlView.frame = self.view.bounds;
    CGSize size = self.view.bounds.size;
    if (self.bowlSetup && size.width > 0 && size.height > 0 &&
        !CGSizeEqualToSize(size, self.lastDrawnSize)) {
        // drawSetup: reads note_labels from NSUserDefaults; drive it from our
        // setting (the extension has its own defaults domain). Only write when it
        // actually differs, so the app's NSUserDefaults observer isn't churned on
        // every relayout.
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        if ([d boolForKey:@"note_labels"] != self.showNoteLabels) {
            [d setBool:self.showNoteLabels forKey:@"note_labels"];
        }
        [self.bowlView setSelectedColourScheme];
        [self.bowlView drawSetup:self.bowlSetup];
        self.lastDrawnSize = size;
        // Screenshot mode re-lights the rings after a (re)draw wipes the layer
        // dictionaries, and mutes the master so captures are silent.
        if (self.screenshotMode) {
            [[self core] sendFloat:0.0 toReceiver:@"mastervolume"];
            NSArray<NSNumber *> *pattern;
            if ([self.screenshotPattern isEqualToString:@"varied"]) {
                pattern = @[@1, @0, @1, @1, @0];   // 1 on, 1 off, 2 on, 1 off
            } else if ([self.screenshotPattern isEqualToString:@"none"]) {
                pattern = @[@0];   // preview video: rings light from touches only
            } else {
                pattern = @[@1, @0];
            }
            [self.bowlView lightRingsForScreenshotWithPattern:pattern];
        }
    }
}

- (void)reloadComposition {
    if (!self.isViewLoaded) return;
    PRSettings *settings = [self.settingsStore currentSettings];
    self.appliedSettings = settings;
    self.composition = [PRCompositionFactory compositionForSettings:settings];
    self.showNoteLabels = settings.noteLabels;
    self.showSetupLabel = settings.setupLabel;
    [self setDisplayedSoundScheme:settings.sound];  // reflect only; caller applies

    int count = [self.composition numberOfSetups];
    self.setupStepper.maximumValue = MAX(0, count - 1);
    self.setupStepper.value = 0;

    [self applySetupForState:0];
}

- (void)applyCurrentSettings {
    if (!self.isViewLoaded) return;
    [self settingsDidChange:[self.settingsStore currentSettings]];
}

// Apply only what changed between the last-applied settings and the new ones,
// so e.g. toggling a label doesn't reset the player back to the first setup.
- (void)settingsDidChange:(PRSettings *)settings {
    PRSettings *prev = self.appliedSettings;
    BOOL compositionChanged = !prev
        || prev.composition != settings.composition
        || prev.note1 != settings.note1 || prev.note2 != settings.note2 || prev.note3 != settings.note3
        || prev.scale1 != settings.scale1 || prev.scale2 != settings.scale2 || prev.scale3 != settings.scale3;
    BOOL soundChanged  = !prev || prev.sound != settings.sound;
    BOOL labelsChanged = !prev || prev.noteLabels != settings.noteLabels
        || prev.setupLabel != settings.setupLabel;

    self.appliedSettings = settings;

    if (compositionChanged) {
        [self reloadComposition];  // rebuilds + re-reads labels/sound display
    } else if (labelsChanged) {
        self.showNoteLabels = settings.noteLabels;
        self.showSetupLabel = settings.setupLabel;
        self.lastDrawnSize = CGSizeZero;
        [self.view setNeedsLayout];
        [self updateSetupDescription];
    }
    if (soundChanged) {
        [self applySoundScheme:settings.sound];
    }
}

#pragma mark - Geometry

- (CGFloat)maximumRadius {
    CGFloat halfW = CGRectGetWidth(self.view.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(self.view.bounds) / 2.0;
    return sqrt((halfW * halfW) + (halfH * halfH));
}

- (CGFloat)distanceFromCenter:(CGPoint)point {
    CGFloat dx = point.x - CGRectGetMidX(self.view.bounds);
    CGFloat dy = point.y - CGRectGetMidY(self.view.bounds);
    return sqrt((dx * dx) + (dy * dy));
}

- (int)noteFromPosition:(CGPoint)point {
    CGFloat radius = [self distanceFromCenter:point] / [self maximumRadius];
    return [self.bowlSetup pitchAtRadius:radius];
}

- (id<HeavyEventSink>)core {
    return self.coreProvider ? self.coreProvider() : nil;
}

#pragma mark - Tap (note on)
// The UIResponder / gesture entry points just extract plain values from UIKit
// objects and forward to the input* methods, which carry the audio + MIDI +
// OSC-delegate logic and are unit-testable without synthesising touches.

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self.view];
        int velocity = floorf(15 + (110 * (touch.majorRadius / 125.0)));
        if (velocity > 127) velocity = 127;
        if (velocity < 0) velocity = 0;
        [self inputTapAtPoint:point velocity:velocity];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self.view];
        CGPoint prev  = [touch previousLocationInView:self.view];
        CGFloat dx = point.x - prev.x, dy = point.y - prev.y;
        [self inputMoveAtPoint:point pixelVelocity:sqrt((dx * dx) + (dy * dy))];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        [self inputEndAtPoint:[touch locationInView:self.view]];
    }
}

// A tap: strike the note (audio), emit a momentary MIDI note (on+off, matching
// the standalone app), and mirror to the delegate (OSC) at velocity 0.
- (void)inputTapAtPoint:(CGPoint)point velocity:(int)velocity {
    int pitch = [self noteFromPosition:point];
    [[self core] sendNoteOn:1 pitch:pitch velocity:velocity];
    [self emitMIDIStatus:0x90 data1:(uint8_t)pitch data2:(uint8_t)velocity];
    [self emitMIDIStatus:0x80 data1:(uint8_t)pitch data2:(uint8_t)velocity];
    if ([self.delegate respondsToSelector:@selector(instrument:touchBeganAtPoint:pitch:velocity:)]) {
        [self.delegate instrument:self touchBeganAtPoint:point pitch:pitch velocity:velocity];
    }
    // SingingBowlView animates the tapped ring in its own touchesBegan.
}

- (void)inputMoveAtPoint:(CGPoint)point pixelVelocity:(CGFloat)pixelVelocity {
    if ([self.delegate respondsToSelector:@selector(instrument:touchMovedToPoint:velocity:)]) {
        [self.delegate instrument:self touchMovedToPoint:point velocity:pixelVelocity];
    }
}

- (void)inputEndAtPoint:(CGPoint)point {
    int pitch = [self noteFromPosition:point];
    [self emitMIDIStatus:0x80 data1:(uint8_t)pitch data2:0];   // MIDI note-off
    if ([self.delegate respondsToSelector:@selector(instrumentTouchEnded:)]) {
        [self.delegate instrumentTouchEnded:self];
    }
}

// Hand a 3-byte MIDI message to the host's transport, if any.
- (void)emitMIDIStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2 {
    if (!self.midiOutSink) return;
    const uint8_t bytes[] = { status, data1, data2 };
    self.midiOutSink(bytes, sizeof(bytes));
}

#pragma mark - Pan (continuous "sing")

- (void)panGestureRecognized:(UIPanGestureRecognizer *)sender {
    CGPoint point = [sender locationInView:self.view];
    CGFloat xVel = [sender velocityInView:self.view].x;
    CGFloat yVel = [sender velocityInView:self.view].y;
    CGFloat velHyp = sqrt((xVel * xVel) + (yVel * yVel));
    CGFloat velocity = log(velHyp) / 10.0;
    if (velocity < 0) velocity = 0;
    if (velocity > 1) velocity = 1;
    CGFloat angle = (velHyp > 0) ? yVel / velHyp : 0;
    CGFloat xTrans = [sender translationInView:self.view].x;
    CGFloat yTrans = [sender translationInView:self.view].y;
    CGFloat translation = sqrt((xTrans * xTrans) + (yTrans * yTrans)) / kScreenDiagonal;
    [self inputSwirlState:sender.state atPoint:point velocity:velocity angle:angle translation:translation];
}

- (void)inputSwirlState:(UIGestureRecognizerState)state
                atPoint:(CGPoint)point
               velocity:(CGFloat)velocity
                  angle:(CGFloat)angle
            translation:(CGFloat)translation {
    id<HeavyEventSink> core = [self core];
    [core sendFloat:velocity toReceiver:@"singlevel"];
    [self.bowlView changeBowlVolumeTo:velocity];

    if (state == UIGestureRecognizerStateBegan) {
        [core sendFloat:1 toReceiver:@"sing"];
        [core sendFloat:(float)[self noteFromPosition:point] toReceiver:@"singpitch"];
        self.currentlyPanningPitch = (UInt8)[self noteFromPosition:point];
        [self.bowlView continuouslyAnimateBowlAtRadius:[self distanceFromCenter:point]];
        [self emitMIDIStatus:0x90 data1:self.currentlyPanningPitch data2:(uint8_t)(velocity * 127)];

    } else if (state == UIGestureRecognizerStateChanged) {
        [core sendFloat:angle toReceiver:@"sinPanAngle"];
        [self.bowlView changeContinuousColour:angle forRadius:[self distanceFromCenter:point]];
        [core sendFloat:translation toReceiver:@"panTranslation"];
        [self.bowlView changeContinuousAnimationSpeed:(3 * translation) + 0.1];
        [self emitMIDIStatus:0xA0 data1:self.currentlyPanningPitch data2:(uint8_t)(velocity * 127)];

    } else if (state == UIGestureRecognizerStateEnded ||
               state == UIGestureRecognizerStateCancelled) {
        [core sendFloat:0 toReceiver:@"singlevel"];
        [core sendFloat:0 toReceiver:@"sing"];
        [self.bowlView stopAnimatingBowl];
        [self emitMIDIStatus:0x80 data1:self.currentlyPanningPitch data2:(uint8_t)(velocity * 127)];
    }
}

#pragma mark - Setup state (remote-driven)

- (NSInteger)numberOfSetups {
    return [self.composition numberOfSetups];
}

- (int)currentSetupState {
    return self.setupState;
}

- (void)showSetupState:(int)state {
    int count = (int)[self numberOfSetups];
    if (count <= 0) return;
    if (state < 0) state = 0;
    if (state > count - 1) state = count - 1;
    self.setupStepper.value = state;   // programmatic set does not fire the action
    [self applySetupForState:state];
}

- (int)pitchAtPoint:(CGPoint)point {
    return [self noteFromPosition:point];
}

#pragma mark - MIDI-in (ring lights)

// Visual only: the host already drives audio for incoming MIDI (the app's
// engine in its noteOnHandler; the AU's render block via HeavyCoreSendMIDINote).
// We just light the matching ring, so we never touch `core` here.
- (void)midiNoteIn:(int)pitch velocity:(int)velocity {
    if (velocity <= 0) return;   // note-off arrives via the sustain pedal, not here
    if (self.midiSustainDown && self.midiSustainedNote < 0) {
        // First note-on since the pedal went down: hold it as a pulsing ring
        // AND start the continuous "sing" voice at that pitch. The struck note
        // (notein) still fires via the host, independently — taps and sing are
        // separate (issue #29).
        self.midiSustainedNote = pitch;
        [self.bowlView continuouslyAnimateBowlForNote:pitch];
        if (self.hostHandlesMIDISing) return;
        id<HeavyEventSink> core = [self core];
        [core sendFloat:(float)pitch toReceiver:@"singpitch"];
        [core sendFloat:(float)velocity / 127.0f toReceiver:@"singlevel"];  // initial level; CC11 / Sing Level param then modulates
        [core sendFloat:1 toReceiver:@"sing"];
    } else {
        [self.bowlView animateBowlForNote:pitch];
    }
}

// CC64 gates the "sing" voice. A pedal transition (either edge) ends whatever
// is currently held; pressing then arms the next note-on to become the held
// sing voice + pulsing ring.
- (void)midiSustainPedal:(BOOL)down {
    if (down == self.midiSustainDown) return;
    self.midiSustainDown = down;
    if (self.midiSustainedNote >= 0) {
        [self.bowlView stopContinuousAnimationForNote:self.midiSustainedNote];
        if (!self.hostHandlesMIDISing) [[self core] sendFloat:0 toReceiver:@"sing"];
        self.midiSustainedNote = -1;
    }
}

// Standard CC modulators → the continuous "sing" receivers (issue #29 follow-up,
// standalone app only; the AUv3 exposes these as host-mappable AU parameters).
- (void)midiControlChange:(int)cc value:(int)value {
    id<HeavyEventSink> core = [self core];
    float v = (float)value / 127.0f;
    switch (cc) {
        case 11: [core sendFloat:v toReceiver:@"singlevel"]; break;                    // expression
        case 1:  [core sendFloat:(v * 2.0f - 1.0f) toReceiver:@"sinPanAngle"]; break;  // mod wheel (bipolar)
        case 74: [core sendFloat:v toReceiver:@"panTranslation"]; break;               // brightness
        default: break;
    }
}

#pragma mark - Remote-OSC playback

- (void)playbackTapAtPoint:(CGPoint)point {
    id<HeavyEventSink> core = [self core];
    int velocity = 110;
    [core sendNoteOn:1 pitch:[self noteFromPosition:point] velocity:velocity];
    [self.bowlView animateBowlAtRadius:[self distanceFromCenter:point]];
    [self stopPlayback];   // any tap stops an in-progress swirl
}

- (void)playbackSwirlAtPoint:(CGPoint)point velocity:(CGFloat)vel {
    id<HeavyEventSink> core = [self core];
    CGFloat angle = 0.5;
    CGFloat velHyp = vel;
    CGFloat velocity = log(velHyp) / 10.0;
    if (velocity < 0) velocity = 0;
    if (velocity > 1) velocity = 1;
    CGFloat trans = velocity / kScreenDiagonal;
    [core sendFloat:velocity toReceiver:@"singlevel"];
    [self.bowlView changeBowlVolumeTo:velocity];

    if (self.playbackPanGestureState == kPlaybackStateNothing) {
        // Starting a playback swirl.
        [core sendFloat:1 toReceiver:@"sing"];
        [core sendFloat:(float)[self noteFromPosition:point] toReceiver:@"singpitch"];
        self.currentlyPanningPitch = (UInt8)[self noteFromPosition:point];
        [self.bowlView continuouslyAnimateBowlAtRadius:[self distanceFromCenter:point]];
        self.playbackPanGestureState = kPlaybackStateMoving;
        self.playbackPanGestureTimeout =
            [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                           selector:@selector(stopPlayback) userInfo:nil repeats:NO];
    } else {
        // Continuing a playback swirl; extend the auto-stop timer.
        [core sendFloat:velocity toReceiver:@"singlevel"];
        [core sendFloat:angle toReceiver:@"sinPanAngle"];
        [self.bowlView changeContinuousColour:angle forRadius:[self distanceFromCenter:point]];
        [self.bowlView changeContinuousAnimationSpeed:(3 * trans) + 0.1];
        [core sendFloat:trans toReceiver:@"panTranslation"];
        [self.playbackPanGestureTimeout invalidate];
        self.playbackPanGestureTimeout =
            [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                           selector:@selector(stopPlayback) userInfo:nil repeats:NO];
    }
}

- (void)stopPlayback {
    id<HeavyEventSink> core = [self core];
    [core sendFloat:0 toReceiver:@"singlevel"];
    [core sendFloat:0 toReceiver:@"sing"];
    [self.bowlView stopAnimatingBowl];
    self.playbackPanGestureState = kPlaybackStateNothing;
    [self.playbackPanGestureTimeout invalidate];
    self.playbackPanGestureTimeout = nil;
}

@end
