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
#include <time.h>
#include <unistd.h>

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

/// 1 playing, 0 not playing, -1 unknown.
static int read_playing(void) {
    IsPlayingFn is_playing = (IsPlayingFn)dlsym(media_remote(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!is_playing) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int playing = -1;
    is_playing(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(Boolean value) {
        playing = value ? 1 : 0;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kWait)) != 0) return -1;
    return playing;
}

void wf_now_playing_status(void *interpreter, void *cv) {
    PIDFn pid = (PIDFn)dlsym(media_remote(), "MRMediaRemoteGetNowPlayingApplicationPID");
    int playing = read_playing();
    if (!pid || playing < 0) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int process = 0;
    pid(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(int value) {
        process = value;
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kWait));
    printf("playing=%d\npid=%d\n", playing, process);
    fflush(stdout);
}

// MediaRemote delivers the command asynchronously, and it is lost if this
// process exits first: `sent=1` alone paused nothing. So wait until the app
// reports the new state (the command has then arrived), for up to a second.
static void send_command(int command) {
    SendCommandFn send = (SendCommandFn)dlsym(media_remote(), "MRMediaRemoteSendCommand");
    int sent = send && send(command, NULL) ? 1 : 0;
    int want = command == kPlay ? 1 : 0, confirmed = 0;
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + NSEC_PER_SEC;
    while (sent && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < deadline) {
        usleep(50000);
        if (read_playing() == want) { confirmed = 1; break; }
    }
    printf("sent=%d\nconfirmed=%d\n", sent, confirmed);
    fflush(stdout);
}

void wf_now_playing_pause(void *interpreter, void *cv) { send_command(kPause); }
void wf_now_playing_play(void *interpreter, void *cv) { send_command(kPlay); }
