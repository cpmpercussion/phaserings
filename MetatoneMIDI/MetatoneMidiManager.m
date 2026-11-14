//
//  MetatoneMidiManager.m
//  SnowMusic
//
//  Created by Charles Martin on 16/10/2014.
//  Copyright (c) 2014 Charles Martin Percussion. All rights reserved.
//

#import "MetatoneMidiManager.h"

@implementation MetatoneMidiManager

- (MetatoneMidiManager *) init {
    self = [super init];
    [self setupMidi];
    return self;
}

- (void) setupMidi {
    self.midi = [[PGMidi alloc] init];
    self.midi.networkEnabled = YES;
}

#pragma mark Midi
-(void) attachToAllExistingSources
{
    for (PGMidiSource *source in self.midi.sources)
    {
        [source addDelegate:self];
    }
}

-(void) setMidi:(PGMidi*)m {
    _midi = m;
    self.midi.delegate = self;
    [self attachToAllExistingSources];
    NSLog(@"MIDI: Setting up.");
}

-(void) midi:(PGMidi*)midi sourceAdded:(PGMidiSource *)source {
    [source addDelegate:self];
    NSLog(@"Midi Source Added: %@", source.name);
}

-(void) midi:(PGMidi*)midi sourceRemoved:(PGMidiSource *)source {
    NSLog(@"Midi Source Removed: %@", source.name);
}

-(void) midi:(PGMidi*)midi destinationAdded:(PGMidiDestination *)destination{
    NSLog(@"Midi Destination Added: %@", destination.name);
}

-(void) midi:(PGMidi*)midi destinationRemoved:(PGMidiDestination *)destination {
    NSLog(@"Midi Destination Removed: %@", destination.name);
}

// Number of data bytes that follow a status byte, or -1 for SysEx / undefined.
static int MIDIDataLength(UInt8 status) {
    switch (status & 0xF0) {
        case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 2;
        case 0xC0: case 0xD0: return 1;
    }
    switch (status) {
        case 0xF1: case 0xF3: return 1;
        case 0xF2: return 2;
        case 0xF6: return 0;
        default:   return -1;  // 0xF0 SysEx, undefined 0xF4/0xF5
    }
}

-(void) handleMessageStatus:(UInt8)status data1:(UInt8)d1 data2:(UInt8)d2 {
    switch (status & 0xF0) {
        case 0x90:                                          // note on (vel 0 = off)
            if (d2 != 0 && self.noteOnHandler) self.noteOnHandler(d1, d2);
            break;
        case 0xB0:                                          // control change
            if (d1 == 64) {
                if (self.sustainHandler) self.sustainHandler(d2 >= 64);  // sustain pedal
            } else if (self.controlChangeHandler) {
                self.controlChangeHandler(d1, d2);
            }
            break;
    }
}

// A packet can carry several messages (e.g. a whole chord from a USB or
// network-MIDI keyboard) and may use running status, so walk it byte by byte
// rather than assuming one 3-byte message per packet.
-(void) midiSource:(PGMidiSource *)input midiReceived:(const MIDIPacketList *)packetList
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"midi_in"]) return;
    UInt8 running = 0;       // current channel-voice status (running status)
    UInt8 data[2] = {0, 0};
    int have = 0, need = 0;
    BOOL inSysEx = NO;
    const MIDIPacket *packet = &packetList->packet[0];
    for (UInt32 i = 0; i < packetList->numPackets; ++i) {
        for (UInt16 j = 0; j < packet->length; ++j) {
            const UInt8 byte = packet->data[j];
            if (byte >= 0xF8) continue;                     // realtime: interleaves anywhere
            if (byte & 0x80) {                              // status byte
                inSysEx = (byte == 0xF0);
                if (byte == 0xF7) { inSysEx = NO; running = 0; continue; }
                const int len = MIDIDataLength(byte);
                // System messages cancel running status; we only act on
                // channel-voice messages.
                running = (byte < 0xF0) ? byte : 0;
                need = (len < 0) ? 0 : len;
                have = 0;
                continue;
            }
            if (inSysEx || running == 0) continue;          // data with no status we care about
            data[have++] = byte;
            if (have == need) {
                [self handleMessageStatus:running data1:data[0] data2:(need > 1 ? data[1] : 0)];
                have = 0;                                   // stay in running status
            }
        }
        packet = MIDIPacketNext(packet);
    }
}
@end

