//
//  HeavyCoreBlockSizeTests.m
//  PhaseRingsTests
//
//  Regression tests for HeavyCoreRenderCallback with frame counts that are
//  not a multiple of Heavy's SIMD width. iOS hosts (AUM, Logic) deliver such
//  counts whenever the session rate differs from the hardware rate — e.g.
//  44.1 kHz on a 48 kHz iPad alternates 235/236-frame cycles — and Heavy's
//  generated process() silently rounds the count down, which used to leave
//  stale samples at the tail of every block (a click per buffer in hosts).
//
//  Uses the CircleStrings synth rather than the default Phase synth so the
//  tests stay clear of the first-block vd~ OOB tracked in #25.
//

#import <XCTest/XCTest.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdlib.h>
#import <PhaseRingsKit/PhaseRingsKit.h>

@interface HeavyCoreBlockSizeTests : XCTestCase
@end

@implementation HeavyCoreBlockSizeTests {
    HeavyCore *_core;
    AudioBufferList *_abl;
    AudioTimeStamp _ts;
}

static const double kSampleRate = 44100.0;
static const UInt32 kMaxFrames = 1024;

- (void)setUp {
    _core = [[HeavyCore alloc] initWithSampleRate:kSampleRate channels:2];
    [_core selectSynth:HeavySynthCircleStrings];
    [_core sendFloat:1.0f toReceiver:@"mastervolume"];
    [_core sendFloat:0.5f toReceiver:@"reverbvolume"];

    _abl = malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));
    _abl->mNumberBuffers = 2;
    for (int i = 0; i < 2; ++i) {
        _abl->mBuffers[i].mNumberChannels = 1;
        _abl->mBuffers[i].mData = calloc(kMaxFrames, sizeof(float));
    }
    memset(&_ts, 0, sizeof(_ts));
    _ts.mFlags = kAudioTimeStampSampleTimeValid;
}

- (void)tearDown {
    free(_abl->mBuffers[0].mData);
    free(_abl->mBuffers[1].mData);
    free(_abl);
    _core = nil;
}

// Render `frames` frames into the buffer list, poisoning the buffers first so
// any frame the callback fails to write is detectable.
- (float *)render:(UInt32)frames {
    for (int i = 0; i < 2; ++i) {
        float *p = _abl->mBuffers[i].mData;
        for (UInt32 n = 0; n < kMaxFrames; ++n) p[n] = 1000.0f;  // sentinel
        _abl->mBuffers[i].mDataByteSize = frames * sizeof(float);
    }
    AudioUnitRenderActionFlags flags = 0;
    OSStatus st = HeavyCoreRenderCallback(_core.renderRefCon, &flags, &_ts, 0, frames, _abl);
    XCTAssertEqual(st, noErr);
    _ts.mSampleTime += frames;
    return _abl->mBuffers[0].mData;
}

// Every requested frame must be written, for aligned and unaligned counts.
- (void)testUnalignedFrameCountsAreFullyWritten {
    [_core sendNoteOn:1 pitch:60 velocity:100];
    const UInt32 counts[] = { 256, 235, 236, 1, 3, 37, 100, 1024, 1023, 5 };
    for (size_t k = 0; k < sizeof(counts) / sizeof(counts[0]); ++k) {
        const UInt32 frames = counts[k];
        [self render:frames];
        for (int c = 0; c < 2; ++c) {
            const float *p = _abl->mBuffers[c].mData;
            for (UInt32 n = 0; n < frames; ++n) {
                XCTAssertNotEqual(p[n], 1000.0f,
                                  @"frame %u of %u (ch %d) left unwritten", (unsigned)n,
                                  (unsigned)frames, c);
                XCTAssertFalse(isnan(p[n]));
            }
        }
    }
}

// Alternating 235/236-frame cycles (44.1 kHz session on 48 kHz hardware)
// must produce a continuous signal: no sample-to-sample jumps beyond what the
// synth itself produces, and audible output.
- (void)testAlternating235And236FramesIsContinuous {
    [_core sendNoteOn:1 pitch:57 velocity:110];
    float prev = 0.0f, peak = 0.0f;
    NSUInteger jumps = 0;
    for (int block = 0; block < 400; ++block) {  // ~2.1 s
        const UInt32 frames = (block & 1) ? 236 : 235;
        const float *p = [self render:frames];
        for (UInt32 n = 0; n < frames; ++n) {
            if (fabsf(p[n] - prev) > 0.5f) ++jumps;
            if (fabsf(p[n]) > peak) peak = fabsf(p[n]);
            prev = p[n];
        }
    }
    XCTAssertGreaterThan(peak, 0.01f, @"synth should be audible");
    XCTAssertEqual(jumps, 0u, @"discontinuities across unaligned block boundaries");
}

// A mono host buffer list must not crash and must receive the left channel.
- (void)testMonoBufferListRenders {
    [_core sendNoteOn:1 pitch:64 velocity:100];
    _abl->mNumberBuffers = 1;
    float peak = 0.0f;
    for (int block = 0; block < 100; ++block) {
        const float *p = [self render:235];
        for (UInt32 n = 0; n < 235; ++n) {
            XCTAssertNotEqual(p[n], 1000.0f);
            if (fabsf(p[n]) > peak) peak = fabsf(p[n]);
        }
    }
    XCTAssertGreaterThan(peak, 0.01f);
}

@end
