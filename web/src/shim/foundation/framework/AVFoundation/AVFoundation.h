// <AVFoundation/AVFoundation.h> — type-only stub for the CocosDenshion audio cluster.
//
// Reached from Classes/CDAudioManager.h, which is #imported by Classes/Resources.mm — an ORDINARY
// ENGINE file, not a seam-excluded one. So even though the audio implementation
// (SimpleAudioEngine.mm) is excluded until Stage P5, these declarations must exist for the engine
// to compile at all.
//
// Everything here is a declaration with no behavior. CDAudioManager uses AVFoundation for exactly
// one thing: iOS audio-session policy (interrupting/mixing with other apps' audio, handling phone
// calls). The browser has no equivalent concept and needs none — the page's AudioContext is
// already sandboxed and the platform arbitrates mixing — so this is one of the rare seams that
// Stage P5 will delete rather than implement.
//
// The inventory below is exactly what Classes/CDAudioManager.h and Classes/CocosDenshion.h name
// (grepped, not guessed): AVAudioPlayer, AVAudioPlayerDelegate, AVAudioSessionDelegate.
#ifndef EDEN_TRAMPOLINE_AVFOUNDATION_H
#define EDEN_TRAMPOLINE_AVFOUNDATION_H

#import <Foundation/Foundation.h>

@class AVAudioPlayer;

@protocol AVAudioPlayerDelegate <NSObject>
@optional
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag; // TODO P5
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(id)error;      // TODO P5
@end

// iOS audio-session interruption callbacks. CDAudioManager declares conformance so it can pause
// on an incoming call; there is no browser analogue (the closest is `visibilitychange`, which
// Stage P7 already wires for saving), so nothing will ever call these.
@protocol AVAudioSessionDelegate <NSObject>
@optional
- (void)beginInterruption;                       // TODO P5 — no web equivalent, likely deleted
- (void)endInterruption;                         // TODO P5 — no web equivalent, likely deleted
@end

@interface AVAudioPlayer : NSObject
- (id)initWithContentsOfURL:(NSURL *)url error:(id *)outError;  // TODO P5
- (BOOL)play;                                                   // TODO P5
- (void)pause;                                                  // TODO P5
- (void)stop;                                                   // TODO P5
@end

#endif
