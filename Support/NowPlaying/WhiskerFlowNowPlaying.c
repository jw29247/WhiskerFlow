// Asks macOS's Now Playing service (MediaRemote) what's playing, and pauses
// or resumes it. Since macOS 15.4 MediaRemote answers only Apple-signed
// processes, so WhiskerFlow loads this into /usr/bin/perl rather than calling
// it in-process (see NowPlayingBridge.swift). Each entry point is an XSUB
// with the (interpreter, CV) signature perl's dl_install_xsub expects; they
// ignore both and print `key=value` lines.

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*IsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*PIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);

enum { kPlay = 0, kPause = 1 };

static void *media_remote(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle;
}

static const int64_t kWait = 800 * NSEC_PER_MSEC;

void wf_now_playing_status(void *interpreter, void *cv) {
    IsPlayingFn is_playing = (IsPlayingFn)dlsym(media_remote(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    PIDFn pid = (PIDFn)dlsym(media_remote(), "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!is_playing || !pid) return;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int playing = -1, process = 0;
    is_playing(queue, ^(Boolean value) { playing = value ? 1 : 0; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kWait)) != 0) return;
    pid(queue, ^(int value) { process = value; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kWait));
    printf("playing=%d\npid=%d\n", playing, process);
    fflush(stdout);
}

static void send_command(int command) {
    SendCommandFn send = (SendCommandFn)dlsym(media_remote(), "MRMediaRemoteSendCommand");
    printf("sent=%d\n", send && send(command, NULL) ? 1 : 0);
    fflush(stdout);
}

void wf_now_playing_pause(void *interpreter, void *cv) { send_command(kPause); }
void wf_now_playing_play(void *interpreter, void *cv) { send_command(kPlay); }
