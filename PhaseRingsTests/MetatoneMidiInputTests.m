//
//  MetatoneMidiInputTests.m
//  PhaseRingsTests
//
//  MIDI-in packet parsing in the standalone app. A single CoreMIDI packet can
//  carry several messages (a chord from a USB / network-MIDI keyboard) and
//  can use running status; the old parser only accepted exactly-3-byte
//  packets and dropped the rest.
//

#import <XCTest/XCTest.h>
#import <CoreMIDI/CoreMIDI.h>
#import "MetatoneMidiManager.h"

@interface MetatoneMidiInputTests : XCTestCase
@property (nonatomic, strong) MetatoneMidiManager *manager;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic) id savedMidiIn;
@end

@implementation MetatoneMidiInputTests

- (void)setUp {
    self.savedMidiIn = [[NSUserDefaults standardUserDefaults] objectForKey:@"midi_in"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"midi_in"];
    self.manager = [[MetatoneMidiManager alloc] init];
    self.events = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    self.manager.noteOnHandler = ^(int pitch, int velocity) {
        [weakSelf.events addObject:[NSString stringWithFormat:@"on %d %d", pitch, velocity]];
    };
    self.manager.sustainHandler = ^(BOOL down) {
        [weakSelf.events addObject:down ? @"pedal down" : @"pedal up"];
    };
    self.manager.controlChangeHandler = ^(int cc, int value) {
        [weakSelf.events addObject:[NSString stringWithFormat:@"cc %d %d", cc, value]];
    };
}

- (void)tearDown {
    [[NSUserDefaults standardUserDefaults] setObject:self.savedMidiIn forKey:@"midi_in"];
}

// Deliver each NSData as one packet in a single packet list.
- (void)deliver:(NSArray<NSData *> *)packets {
    Byte buffer[1024];
    MIDIPacketList *list = (MIDIPacketList *)buffer;
    MIDIPacket *p = MIDIPacketListInit(list);
    MIDITimeStamp t = 0;
    for (NSData *d in packets) {
        p = MIDIPacketListAdd(list, sizeof(buffer), p, t++, d.length, d.bytes);
        XCTAssert(p != NULL);
    }
    [self.manager midiSource:nil midiReceived:list];
}

static NSData *Bytes(NSArray<NSNumber *> *a) {
    NSMutableData *d = [NSMutableData data];
    for (NSNumber *n in a) { uint8_t b = n.unsignedCharValue; [d appendBytes:&b length:1]; }
    return d;
}

- (void)testSingleThreeByteNoteOn {
    [self deliver:@[Bytes(@[@0x90, @60, @100])]];
    XCTAssertEqualObjects(self.events, (@[@"on 60 100"]));
}

- (void)testChordInOnePacket {
    [self deliver:@[Bytes(@[@0x90, @60, @100, @0x90, @64, @90, @0x90, @67, @80])]];
    XCTAssertEqualObjects(self.events, (@[@"on 60 100", @"on 64 90", @"on 67 80"]));
}

- (void)testRunningStatus {
    [self deliver:@[Bytes(@[@0x90, @60, @100, @64, @90, @67, @0])]];  // last is a note-off
    XCTAssertEqualObjects(self.events, (@[@"on 60 100", @"on 64 90"]));
}

- (void)testRealtimeBytesInterleavedAndPedal {
    [self deliver:@[Bytes(@[@0xB0, @0xF8, @64, @127]),           // clock inside a CC
                    Bytes(@[@0xFE]),                                // active sensing
                    Bytes(@[@0xB0, @1, @64, @0xB0, @64, @0])]];
    XCTAssertEqualObjects(self.events, (@[@"pedal down", @"cc 1 64", @"pedal up"]));
}

- (void)testSysExAndProgramChangeSkipped {
    [self deliver:@[Bytes(@[@0xF0, @0x7E, @0x01, @0x60, @0xF7, @0xC0, @5, @0x90, @62, @70])]];
    XCTAssertEqualObjects(self.events, (@[@"on 62 70"]));
}

- (void)testMidiInDisabledIgnoresEverything {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"midi_in"];
    [self deliver:@[Bytes(@[@0x90, @60, @100])]];
    XCTAssertEqual(self.events.count, 0u);
}

@end
