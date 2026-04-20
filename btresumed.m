/*
 * btresumed — event-driven BLE HID recovery daemon (CoreBluetooth + log watchdog)
 *
 * Problem: macOS's BLE stack sometimes fails to re-encrypt paired LE peripherals.
 * Triggers include S3 resume and the peripheral's own idle-sleep cycle.
 * Symptom: HCI reason 762 / MIC failure 0x3D, repeated connect/disconnect loop
 * (bluetoothd keeps trying; CoreBluetooth does not always deliver these events
 * to third-party clients). Manual workaround is a Bluetooth toggle. This daemon
 * automates the toggle only when needed, without touching pairing keys
 * (quad-boot safe).
 *
 * Detection is two-pronged:
 *
 *   1. **Event-driven via CBCentralManager** for the happy path: classify
 *      peripherals, watch for disconnects that don't recover naturally.
 *      Fast and precise when CB delivers events.
 *
 *   2. **Log watchdog via `/usr/bin/log stream`** for the broken path: when
 *      CB stays silent but bluetoothd is thrashing with reason 762, we tail
 *      bluetoothd's unified log with a predicate matching the bug signature.
 *      Any line through = toggle within <1s. Zero idle cost (pipe blocks).
 *      This matches Linux/Windows reconnect latency (1-5s) and beats polling
 *      for both responsiveness and power.
 *
 * Toggle itself uses the blueutil-canonical pattern:
 *   SetPowerState(0) → poll Get*PowerState until 0 → settle 1.5s →
 *   SetPowerState(1) → poll until 1. The SPI is asynchronous (void return),
 *   so a fixed usleep is insufficient: the stack coalesces off+on into a
 *   no-op if issued before the controller actually powers down.
 *
 * State file: ~/Library/Application Support/btresumed/hids.plist
 *
 * Build:
 *   clang -arch x86_64 -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
 *     -o btresumed btresumed.m \
 *     -framework Foundation -framework IOBluetooth -framework CoreBluetooth
 */

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <unistd.h>
#import <signal.h>

/* IOBluetooth SPI — same calls System Settings' toggle uses. */
extern int IOBluetoothPreferenceSetControllerPowerState(int powerState);
extern int IOBluetoothPreferenceGetControllerPowerState(void);

/* Tunables */
static const NSTimeInterval kRecoveryWindow   = 5.0;   /* wait before concluding stuck */
static const NSTimeInterval kToggleDebounce   = 5.0;   /* min gap between our toggles (was 10) */
static const NSTimeInterval kToggleResetAfter = 60.0;  /* consecutive counter reset if toggle was this long ago */
static const NSTimeInterval kRescanInterval   = 60.0;  /* discover newly-paired devices */
static const useconds_t     kTogglePollIntvUs = 100 * 1000;   /* 100 ms per poll */
static const int            kToggleOffMaxPolls = 50;           /* 5 s */
static const int            kToggleOnMaxPolls  = 100;          /* 10 s */
static const NSTimeInterval kLogRelaunchDelay = 5.0;   /* if log stream dies */

/* Progressive off-phase duration: empirically the off-poll returns too early
 * (getter flips to 0 before stack quiesces). Enforce minimum total off-phase
 * time, increasing on consecutive failed attempts. Stage index is
 * min(_consecutiveToggles, count-1). */
static const NSTimeInterval kOffPhaseMinByStage[] = {3.0, 5.0, 8.0};
static const int            kOffPhaseStageCount   = 3;

/* Forward decl for the main's cleanup path. */
@class BTResumed;
static __weak BTResumed *gShared;

@interface BTResumed : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
- (void)start;
- (void)shutdown;
@end

/* Name heuristic — classify by peripheral advertised name. Apple's CoreBluetooth
 * hides the standard HID service (0x1812) from third-party CB clients, so we
 * can't use service discovery. Covers common mice/keyboards/trackpads/pointers
 * across vendors (Microsoft, Apple, Logitech, Razer, …). Adjust if your device
 * has an unusual name. */
static BOOL nameLooksLikeHID(NSString *name) {
    if (!name) return NO;
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *keywords = @[
        @"mouse", @"mice", @"keyboard", @"trackpad", @"pointing",
        @"magic ",     /* Magic Mouse / Magic Keyboard / Magic Trackpad */
        @"mx ",        /* Logitech MX Master / MX Keys */
        @"k380", @"k120", @"k860",  /* Logitech keyboards */
        @"pebble",     /* Logitech Pebble mouse */
        @"hid",
    ];
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

/* Broad service filter for retrieveConnectedPeripheralsWithServices:.
 * GAP (0x1800) is mandatory for all BLE peripherals — matches everything. */
static NSArray<CBUUID *> *connectedPeripheralUUIDs(void) {
    static NSArray<CBUUID *> *uuids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uuids = @[
            [CBUUID UUIDWithString:@"1812"], /* HID over GATT */
            [CBUUID UUIDWithString:@"180F"], /* Battery Service */
            [CBUUID UUIDWithString:@"180A"], /* Device Information */
            [CBUUID UUIDWithString:@"1800"], /* GAP (mandatory) */
        ];
    });
    return uuids;
}

@implementation BTResumed {
    CBCentralManager                              *_cm;
    NSMutableDictionary<NSUUID *, CBPeripheral *> *_peripherals;      /* strong refs */
    NSMutableDictionary<NSUUID *, NSDate *>       *_pending;          /* check tickets */
    NSMutableSet<NSUUID *>                        *_hidPeripherals;   /* classified HID-like */
    NSMutableSet<NSUUID *>                        *_loggedNonHID;     /* avoid log spam */
    NSDate                                        *_lastToggle;
    NSDateFormatter                               *_fmt;
    CBManagerState                                 _lastCBState;
    NSURL                                         *_stateFileURL;
    int                                            _consecutiveToggles;  /* resets on HID reconnect */

    /* Log watchdog */
    NSTask                                        *_logTask;
    NSMutableData                                 *_logLineBuf;
}

- (instancetype)init {
    if ((self = [super init])) {
        _peripherals     = [NSMutableDictionary dictionary];
        _pending         = [NSMutableDictionary dictionary];
        _hidPeripherals  = [NSMutableSet set];
        _loggedNonHID    = [NSMutableSet set];
        _lastToggle      = [NSDate distantPast];
        _fmt             = [[NSDateFormatter alloc] init];
        _fmt.dateFormat  = @"yyyy-MM-dd HH:mm:ss.SSS";
        _fmt.locale      = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _lastCBState     = CBManagerStateUnknown;
        _logLineBuf      = [NSMutableData data];
    }
    return self;
}

- (void)log:(NSString *)msg {
    NSString *ts = [_fmt stringFromDate:[NSDate date]];
    fprintf(stderr, "[%s] %s\n", ts.UTF8String, msg.UTF8String);
    fflush(stderr);
}

- (void)start {
    [self log:[NSString stringWithFormat:@"btresumed starting (pid=%d)", getpid()]];
    _cm = [[CBCentralManager alloc]
              initWithDelegate:self
                         queue:dispatch_get_main_queue()
                       options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
    [self log:@"CBCentralManager created, waiting for state update..."];
    [self scheduleNextRescan];
    [self startLogWatchdog];
}

- (void)shutdown {
    if (_logTask && _logTask.isRunning) {
        [_logTask terminate];
    }
}

#pragma mark - Persistent state

- (NSURL *)stateFileURL {
    if (_stateFileURL) return _stateFileURL;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:YES
                                      error:&err];
    if (!appSupport) {
        [self log:[NSString stringWithFormat:@"no App Support dir: %@", err]];
        return nil;
    }
    NSURL *dir = [appSupport URLByAppendingPathComponent:@"btresumed" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    _stateFileURL = [dir URLByAppendingPathComponent:@"hids.plist"];
    return _stateFileURL;
}

- (void)persistHIDs {
    NSURL *url = [self stateFileURL];
    if (!url) return;
    NSMutableArray<NSString *> *strings =
        [NSMutableArray arrayWithCapacity:_hidPeripherals.count];
    for (NSUUID *u in _hidPeripherals) {
        [strings addObject:u.UUIDString];
    }
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:strings
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&err];
    if (!data) {
        [self log:[NSString stringWithFormat:@"persist serialize failed: %@", err]];
        return;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        [self log:[NSString stringWithFormat:@"persist write failed: %@", err]];
    }
}

- (void)loadPersistedHIDs {
    NSURL *url = [self stateFileURL];
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;

    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                          options:NSPropertyListImmutable
                                                           format:NULL
                                                            error:NULL];
    if (![plist isKindOfClass:[NSArray class]]) {
        [self log:@"persisted file not a valid array, ignoring"];
        return;
    }

    NSMutableArray<NSUUID *> *uuids = [NSMutableArray array];
    NSUInteger restored = 0;
    for (id s in (NSArray *)plist) {
        if (![s isKindOfClass:[NSString class]]) continue;
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:(NSString *)s];
        if (u) {
            [uuids addObject:u];
            if (![_hidPeripherals containsObject:u]) {
                [_hidPeripherals addObject:u];
                restored++;
            }
        }
    }
    if (uuids.count == 0) return;

    NSArray<CBPeripheral *> *peripherals = [_cm retrievePeripheralsWithIdentifiers:uuids];
    [self log:[NSString stringWithFormat:
               @"persist: %lu UUID(s) loaded (restored %lu classification(s)), CB returned %lu peripheral(s)",
               (unsigned long)uuids.count,
               (unsigned long)restored,
               (unsigned long)peripherals.count]];
    for (CBPeripheral *p in peripherals) {
        [self adoptPeripheral:p];
    }
}

#pragma mark - Log watchdog

- (void)startLogWatchdog {
    /* Clear any partial line residue from a previous task incarnation. */
    [_logLineBuf setLength:0];

    _logTask = [[NSTask alloc] init];
    _logTask.launchPath = @"/usr/bin/log";
    _logTask.arguments = @[
        @"stream",
        @"--predicate", @"process == \"bluetoothd\" AND eventMessage CONTAINS \"reason 762\"",
        @"--style", @"compact"
    ];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    _logTask.standardOutput = outPipe;
    _logTask.standardError  = errPipe;

    __weak typeof(self) weakSelf = self;

    /* Dispatch chunks back to main queue for serial processing. */
    outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *chunk = [fh availableData];
        if (chunk.length == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleLogChunk:chunk];
        });
    };
    /* Drain stderr to avoid pipe-full deadlock; we don't act on stderr content. */
    errPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *fh) {
        (void)[fh availableData];
    };

    _logTask.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = weakSelf;
            if (!s) return;
            [s log:[NSString stringWithFormat:
                    @"log stream exited (status=%d); relaunching in %.0fs",
                    t.terminationStatus, kLogRelaunchDelay]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kLogRelaunchDelay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf startLogWatchdog];
            });
        });
    };

    NSError *err = nil;
    if (![_logTask launchAndReturnError:&err]) {
        [self log:[NSString stringWithFormat:@"log stream launch failed: %@", err]];
        _logTask = nil;
        return;
    }
    [self log:[NSString stringWithFormat:
               @"log watchdog started (log pid=%d), predicate: reason 762",
               _logTask.processIdentifier]];
}

- (void)handleLogChunk:(NSData *)chunk {
    [_logLineBuf appendData:chunk];
    NSData *nl = [NSData dataWithBytes:"\n" length:1];
    while (YES) {
        NSRange sr = NSMakeRange(0, _logLineBuf.length);
        NSRange nlRange = [_logLineBuf rangeOfData:nl options:0 range:sr];
        if (nlRange.location == NSNotFound) break;
        NSData *lineData = [_logLineBuf subdataWithRange:NSMakeRange(0, nlRange.location)];
        [_logLineBuf replaceBytesInRange:NSMakeRange(0, nlRange.location + 1)
                               withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData
                                                encoding:NSUTF8StringEncoding];
        if (!line) continue;

        /* Filter out `log`'s own header line, which echoes the predicate text
         * and therefore matches "bluetoothd" and "762". Real log lines contain
         * `bluetoothd[<pid>:<tid>]`; the bracket is the reliable discriminator. */
        if ([line containsString:@"bluetoothd["] && [line containsString:@"762"]) {
            [self watchdogFiredForLogLine:line];
        }
    }
}

- (void)watchdogFiredForLogLine:(NSString *)line {
    /* Respect user intent — if BT was manually turned off, don't touch it. */
    if (IOBluetoothPreferenceGetControllerPowerState() == 0) return;

    NSTimeInterval sinceLast = -[_lastToggle timeIntervalSinceNow];
    if (sinceLast < kToggleDebounce) {
        /* Silent on bursts; bluetoothd often logs 762 many times per second in
         * the stuck state and a single toggle is the right fix. */
        return;
    }
    [self log:@"watchdog: reason 762 detected in bluetoothd log → toggling BT"];
    [self performToggle];
}

#pragma mark - Toggle

- (void)performToggle {
    /* Reset consecutive-attempt counter if enough time has passed since last
     * toggle — the current trigger is a fresh issue, not a retry. */
    if (-[_lastToggle timeIntervalSinceNow] > kToggleResetAfter) {
        _consecutiveToggles = 0;
    }
    int stage = MIN(_consecutiveToggles, kOffPhaseStageCount - 1);
    NSTimeInterval minOffPhase = kOffPhaseMinByStage[stage];

    [self log:[NSString stringWithFormat:
               @"toggle: set(0)  (attempt #%d, min off-phase %.1fs)",
               _consecutiveToggles + 1, minOffPhase]];

    NSDate *offStart = [NSDate date];
    IOBluetoothPreferenceSetControllerPowerState(0);

    int polls = 0;
    while (polls < kToggleOffMaxPolls &&
           IOBluetoothPreferenceGetControllerPowerState() != 0) {
        usleep(kTogglePollIntvUs);
        polls++;
    }
    NSTimeInterval getterElapsed = -[offStart timeIntervalSinceNow];
    [self log:[NSString stringWithFormat:@"toggle: off-getter returned 0 after %.2fs",
               getterElapsed]];

    /* The getter can report 0 before the stack has actually quiesced — a false
     * positive that led to ineffective toggles in practice. Enforce the stage's
     * minimum off-phase duration regardless of what the getter says. */
    if (getterElapsed < minOffPhase) {
        useconds_t extraUs = (useconds_t)((minOffPhase - getterElapsed) * 1e6);
        [self log:[NSString stringWithFormat:@"toggle: enforcing min off-phase, sleeping %.2fs more",
                   extraUs / 1e6]];
        usleep(extraUs);
    }

    [self log:@"toggle: set(1)"];
    IOBluetoothPreferenceSetControllerPowerState(1);
    polls = 0;
    while (polls < kToggleOnMaxPolls &&
           IOBluetoothPreferenceGetControllerPowerState() != 1) {
        usleep(kTogglePollIntvUs);
        polls++;
    }
    [self log:[NSString stringWithFormat:@"toggle: on confirmed after %d poll(s) (%.1fs)",
               polls, polls * kTogglePollIntvUs / 1e6]];

    _lastToggle = [NSDate date];
    _consecutiveToggles++;
}

#pragma mark - Periodic rescan (discover newly paired devices)

- (void)scheduleNextRescan {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kRescanInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        [s rescanForNewPeripherals];
        [s scheduleNextRescan];
    });
}

- (void)rescanForNewPeripherals {
    if (_lastCBState != CBManagerStatePoweredOn) return;
    NSUInteger before = _peripherals.count;
    NSArray<CBPeripheral *> *connected =
        [_cm retrieveConnectedPeripheralsWithServices:connectedPeripheralUUIDs()];
    for (CBPeripheral *p in connected) {
        [self adoptPeripheral:p];
    }
    NSUInteger added = _peripherals.count - before;
    if (added > 0) {
        [self log:[NSString stringWithFormat:@"periodic rescan: %lu new peripheral(s) adopted",
                   (unsigned long)added]];
    }
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *stateStr = @"?";
    switch (central.state) {
        case CBManagerStatePoweredOn:   stateStr = @"PoweredOn"; break;
        case CBManagerStatePoweredOff:  stateStr = @"PoweredOff"; break;
        case CBManagerStateUnauthorized:stateStr = @"Unauthorized"; break;
        case CBManagerStateUnsupported: stateStr = @"Unsupported"; break;
        case CBManagerStateResetting:   stateStr = @"Resetting"; break;
        case CBManagerStateUnknown:     stateStr = @"Unknown"; break;
    }
    [self log:[NSString stringWithFormat:@"CB state: %@", stateStr]];

    CBManagerState prev = _lastCBState;
    _lastCBState = central.state;

    if (central.state != CBManagerStatePoweredOn) return;

    if (prev != CBManagerStateUnknown &&
        prev != CBManagerStatePoweredOn &&
        _pending.count > 0) {
        [self log:[NSString stringWithFormat:
                   @"clearing %lu pending check(s) (transition-from-%ld artifacts)",
                   (unsigned long)_pending.count, (long)prev]];
        [_pending removeAllObjects];
    }

    [self loadPersistedHIDs];

    NSArray<CBPeripheral *> *connected =
        [central retrieveConnectedPeripheralsWithServices:connectedPeripheralUUIDs()];
    [self log:[NSString stringWithFormat:@"found %lu currently connected BLE peripheral(s)",
               (unsigned long)connected.count]];
    for (CBPeripheral *p in connected) {
        [self adoptPeripheral:p];
    }

    for (CBPeripheral *p in _peripherals.allValues) {
        [central connectPeripheral:p options:nil];
    }
}

- (void)adoptPeripheral:(CBPeripheral *)p {
    BOOL isNew = (_peripherals[p.identifier] == nil);
    p.delegate = self;
    _peripherals[p.identifier] = p;
    if (isNew) {
        [self log:[NSString stringWithFormat:@"adopt: %@ (%@) state=%ld",
                   p.identifier.UUIDString, p.name ?: @"?", (long)p.state]];
    }
    [_cm connectPeripheral:p options:nil];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    [self log:[NSString stringWithFormat:@"connect: %@ (%@)",
               peripheral.identifier.UUIDString, peripheral.name ?: @"?"]];
    if (_pending[peripheral.identifier]) {
        [self log:@"  pending check canceled (natural recovery)"];
        [_pending removeObjectForKey:peripheral.identifier];
    }
    if (!_peripherals[peripheral.identifier]) {
        [self adoptPeripheral:peripheral];
    }
    [self classifyPeripheral:peripheral];

    /* If a classified HID reconnects, prior toggle(s) worked — reset the
     * progressive off-phase counter. Next issue starts fresh at stage 0. */
    if (_consecutiveToggles > 0 &&
        [_hidPeripherals containsObject:peripheral.identifier]) {
        [self log:[NSString stringWithFormat:
                   @"HID reconnected — resetting consecutive toggle counter (was %d)",
                   _consecutiveToggles]];
        _consecutiveToggles = 0;
    }
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    [self log:[NSString stringWithFormat:@"connect FAIL: %@ err=%@",
               peripheral.name ?: @"?", error.localizedDescription ?: @"?"]];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    [self classifyPeripheral:peripheral];

    NSUUID *key = peripheral.identifier;
    NSDate *ticket = [NSDate date];
    _pending[key] = ticket;

    NSString *errStr = error ? error.localizedDescription : @"(no error)";
    [self log:[NSString stringWithFormat:@"disconnect: %@ (%@) err=%@, check in %.0fs",
               key.UUIDString, peripheral.name ?: @"?", errStr, kRecoveryWindow]];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kRecoveryWindow * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        NSDate *stored = s->_pending[key];
        if (stored != ticket) {
            [s log:[NSString stringWithFormat:@"check %@: superseded or canceled",
                    key.UUIDString]];
            return;
        }
        [s->_pending removeObjectForKey:key];
        [s evaluateAndMaybeToggle:peripheral];
    });

    [central connectPeripheral:peripheral options:nil];
}

#pragma mark - Classification

- (void)classifyPeripheral:(CBPeripheral *)peripheral {
    if ([_hidPeripherals containsObject:peripheral.identifier]) return;

    if (nameLooksLikeHID(peripheral.name)) {
        [_hidPeripherals addObject:peripheral.identifier];
        [_loggedNonHID removeObject:peripheral.identifier];
        [self log:[NSString stringWithFormat:@"classified HID-like: %@ (%@)",
                   peripheral.identifier.UUIDString, peripheral.name ?: @"?"]];
        [self persistHIDs];
        return;
    }

    if (![_loggedNonHID containsObject:peripheral.identifier]) {
        [_loggedNonHID addObject:peripheral.identifier];
        [self log:[NSString stringWithFormat:
                   @"classified non-HID: %@ (%@) — won't trigger toggle (re-checkable)",
                   peripheral.identifier.UUIDString, peripheral.name ?: @"?"]];
    }
}

#pragma mark - CB-driven evaluation

- (void)evaluateAndMaybeToggle:(CBPeripheral *)peripheral {
    [self classifyPeripheral:peripheral];

    if (![_hidPeripherals containsObject:peripheral.identifier]) {
        [self log:[NSString stringWithFormat:@"check: %@ not HID, no toggle",
                   peripheral.name ?: @"?"]];
        return;
    }

    if (peripheral.state == CBPeripheralStateConnected) {
        [self log:[NSString stringWithFormat:@"check: %@ connected now, no action",
                   peripheral.name ?: @"?"]];
        return;
    }

    if (IOBluetoothPreferenceGetControllerPowerState() == 0) {
        [self log:@"check: BT powered off by user, respect intent"];
        return;
    }

    NSTimeInterval sinceLast = -[_lastToggle timeIntervalSinceNow];
    if (sinceLast < kToggleDebounce) {
        [self log:[NSString stringWithFormat:@"check: debounced (%.1fs since last toggle)",
                   sinceLast]];
        return;
    }

    [self log:[NSString stringWithFormat:@"check: %@ still disconnected → toggling BT",
               peripheral.name ?: @"?"]];
    [self performToggle];
}

@end

#pragma mark - main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        dispatch_source_t sigTerm =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                   dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigTerm, ^{
            fprintf(stderr, "SIGTERM received, cleaning up\n");
            fflush(stderr);
            [gShared shutdown];
            exit(0);
        });
        dispatch_resume(sigTerm);
        signal(SIGTERM, SIG_IGN);

        BTResumed *w = [[BTResumed alloc] init];
        gShared = w;
        [w start];

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
