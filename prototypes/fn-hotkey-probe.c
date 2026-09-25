// Throwaway macOS event probe. Build: clang prototypes/fn-hotkey-probe.c -framework Carbon -framework ApplicationServices -o /tmp/fn-hotkey-probe
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned carbon_down[3], carbon_up[3];
static unsigned tap_fn_down, tap_fn_up, tap_combo_down, tap_combo_up, tap_disabled;
static bool fn_held;
static struct {
    unsigned type, key, reenabled;
    unsigned long long flags;
} tap_events[256];
static unsigned tap_events_seen;

static void remember_tap_event(unsigned type, unsigned key,
                               unsigned long long flags, unsigned reenabled) {
    if (tap_events_seen < 256) {
        tap_events[tap_events_seen].type = type;
        tap_events[tap_events_seen].key = key;
        tap_events[tap_events_seen].flags = flags;
        tap_events[tap_events_seen].reenabled = reenabled;
    }
    tap_events_seen++;
}

static OSStatus hotkey_event(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next;
    (void)context;
    EventHotKeyID id = {0};
    OSStatus status = GetEventParameter(event, kEventParamDirectObject,
                                      typeEventHotKeyID, NULL, sizeof(id), NULL, &id);
    if (status == noErr) {
        if (id.id > 0 && id.id < 3) {
            if (GetEventKind(event) == kEventHotKeyPressed) carbon_down[id.id]++;
            else carbon_up[id.id]++;
        }
        printf("carbon id=%u %s\n", (unsigned)id.id,
               GetEventKind(event) == kEventHotKeyPressed ? "down" : "up");
        fflush(stdout);
    }
    return noErr;
}

static CGEventRef tap_event(CGEventTapProxy proxy, CGEventType type,
                           CGEventRef event, void *context) {
    (void)proxy;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        tap_disabled++;
        CFMachPortRef tap = *(CFMachPortRef *)context;
        if (tap) CGEventTapEnable(tap, true);
        remember_tap_event((unsigned)type, 0, 0,
                           (unsigned)(tap && CGEventTapIsEnabled(tap)));
    } else {
        CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags combo = kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
        bool combo_event = key == kVK_ANSI_M &&
            ((flags & combo) == combo || (type == kCGEventKeyUp && tap_combo_down > tap_combo_up));
        if (type == kCGEventFlagsChanged) {
            if (key == kVK_Function) {
                bool down = (flags & kCGEventFlagMaskSecondaryFn) != 0;
                if (down != fn_held) {
                    if (down) tap_fn_down++;
                    else tap_fn_up++;
                    fn_held = down;
                }
            }
        } else if (combo_event) {
            if (type == kCGEventKeyDown &&
                !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) tap_combo_down++;
            else if (type == kCGEventKeyUp) tap_combo_up++;
        }
        if (type == kCGEventFlagsChanged || combo_event) {
            remember_tap_event((unsigned)type, (unsigned)key,
                               (unsigned long long)flags, 0);
        }
    }
    return event;
}

int main(int argc, char **argv) {
    double seconds = argc > 1 ? atof(argv[1]) : 12.0;
    if (seconds <= 0 || seconds > 120) {
        fprintf(stderr, "usage: %s [seconds: 1..120]\n", argv[0]);
        return 2;
    }

    bool listen = CGPreflightListenEventAccess();
    printf("setup listen_permission=%d\n", listen);

    EventTypeSpec types[] = {
        {kEventClassKeyboard, kEventHotKeyPressed},
        {kEventClassKeyboard, kEventHotKeyReleased},
    };
    EventHandlerRef handler = NULL;
    OSStatus handler_status = InstallEventHandler(GetApplicationEventTarget(), hotkey_event,
                                                 2, types, NULL, &handler);
    printf("setup carbon_handler_status=%d\n", (int)handler_status);

    EventHotKeyRef combo = NULL;
    EventHotKeyRef fn = NULL;
    EventHotKeyID combo_id = {'QDic', 1};
    EventHotKeyID fn_id = {'QDic', 2};
    OSStatus combo_exclusive = RegisterEventHotKey(kVK_ANSI_M, cmdKey | shiftKey,
                                                   combo_id, GetApplicationEventTarget(),
                                                   kEventHotKeyExclusive, &combo);
    OSStatus combo_status = combo_exclusive;
    if (combo_status != noErr) {
        combo_status = RegisterEventHotKey(kVK_ANSI_M, cmdKey | shiftKey,
                                           combo_id, GetApplicationEventTarget(), 0, &combo);
    }
    OSStatus fn_status = RegisterEventHotKey(kVK_Function, 0, fn_id,
                                             GetApplicationEventTarget(), 0, &fn);
    printf("setup register_cmd_shift_m_exclusive=%d effective=%d register_fn_alone=%d (registration only)\n",
           (int)combo_exclusive, (int)combo_status, (int)fn_status);

    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) |
                       CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    CFMachPortRef tap = NULL;
    CFRunLoopSourceRef tap_source = NULL;
    if (listen) {
        tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                               kCGEventTapOptionListenOnly, mask, tap_event, &tap);
        if (tap) {
            tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), tap_source, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
        }
    }
    printf("setup listen_only_session_tap=%s (key 63 is Fn on Apple keyboards; observe actual events)\n",
           tap && CGEventTapIsEnabled(tap) ? "active" : "unavailable");
    printf("Press Fn/Globe and Command-Shift-M on a physical keyboard during %.0f seconds.\n",
           seconds);
    fflush(stdout);

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        EventRef event = NULL;
        EventTimeout remaining = deadline - CFAbsoluteTimeGetCurrent();
        EventTimeout wait = remaining < 0.25 ? remaining : 0.25;
        OSStatus status = ReceiveNextEvent(2, types, wait, true, &event);
        if (status == noErr && event) {
            SendEventToEventTarget(event, GetApplicationEventTarget());
            ReleaseEvent(event);
        }
    }
    unsigned retained = tap_events_seen < 256 ? tap_events_seen : 256;
    for (unsigned i = 0; i < retained; i++) {
        printf("tap type=%u key=%u fn=%u reenabled=%u flags=0x%llx\n",
               tap_events[i].type, tap_events[i].key,
               (unsigned)((tap_events[i].flags & kCGEventFlagMaskSecondaryFn) != 0),
               tap_events[i].reenabled, tap_events[i].flags);
    }
    if (tap_events_seen > retained) printf("tap_records_dropped=%u\n", tap_events_seen - retained);
    printf("observed tap_fn_down=%u tap_fn_up=%u tap_combo_down=%u tap_combo_up=%u carbon_combo_down=%u carbon_combo_up=%u carbon_fn_down=%u carbon_fn_up=%u tap_disabled=%u tap_enabled_at_end=%u\n",
           tap_fn_down, tap_fn_up, tap_combo_down, tap_combo_up,
           carbon_down[1], carbon_up[1], carbon_down[2], carbon_up[2], tap_disabled,
           (unsigned)(tap && CGEventTapIsEnabled(tap)));
    if (!(tap_fn_down || tap_fn_up || tap_combo_down || tap_combo_up ||
          carbon_down[1] || carbon_up[1] || carbon_down[2] || carbon_up[2])) {
        puts("WARN: no physical key event observed; trigger behavior is unverified");
    }

    if (combo) UnregisterEventHotKey(combo);
    if (fn) UnregisterEventHotKey(fn);
    if (handler) RemoveEventHandler(handler);
    if (tap_source) CFRelease(tap_source);
    if (tap) CFRelease(tap);
    return 0;
}
