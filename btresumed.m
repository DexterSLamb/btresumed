/*
 * btresumed — event-driven BLE HID recovery daemon (CoreBluetooth-based)
 *
 * Problem: macOS's BLE stack sometimes fails to re-encrypt paired LE peripherals.
 * Triggers include S3 resume and the peripheral's own idle-sleep cycle.
 * Symptom: HCI reason 762 / MIC failure 0x3D, repeated connect/disconnect loop.
 * Manual workaround is to toggle Bluetooth off/on. This daemon automates that
 * toggle only when needed, without touching pairing keys (quad-boot safe).
 *
 * Why CoreBluetooth: IOBluetoothDevice.pairedDevices on Sonoma+ does not
 * enumerate BLE devices. CBCentralManager is the correct API layer.
 *
 * Flow:
 *   1. Create CBCentralManager on main queue.
 *   2. When CM reaches PoweredOn:
 *        a. loadPersistedHIDs  — read known HID UUIDs from disk, use
 *           `retrievePeripheralsWithIdentifiers:` to get CBPeripheral objects
 *           even when they're not currently connected. (Apple's canonical
 *           pattern for reconnection across app/session boundaries.)
 *        b. retrieveConnectedPeripheralsWithServices: — enumerate peripherals
 *           that are connected right now.
 *        c. adoptPeripheral on all of the above — set delegate, add to
 *           strong-ref dict, call `connectPeripheral:` to subscribe to events.
 *   3. On didConnectPeripheral: classify by name heuristic. HID classification
 *      is persisted to disk so it survives daemon restarts and CB power cycles.
 *   4. On didDisconnectPeripheral: schedule a check kRecoveryWindow seconds
 *      later. If peripheral hasn't reconnected and it's a HID device, call
 *      IOBluetoothPreferenceSetControllerPowerState(0)/(1) — identical SPI
 *      path to System Settings' BT toggle.
 *   5. On didConnectPeripheral: cancel the pending check (natural recovery).
 *   6. On any non-PoweredOn → PoweredOn transition: clear pending checks
 *      (BT-off artifacts aren't real stuck states).
 *   7. Periodic rescan every kRescanInterval seconds for newly paired devices.
 *
 * State file: ~/Library/Application Support/btresumed/hids.plist
 * (Contains peripheral UUIDs classified as HID. Learned per-host, not portable.)
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

/* IOBluetooth SPI — same call System Settings toggle uses. */
extern int IOBluetoothPreferenceSetControllerPowerState(int powerState);
extern int IOBluetoothPreferenceGetControllerPowerState(void);

/* Tunables */
static const NSTimeInterval kRecoveryWindow = 5.0;   /* wait before concluding stuck */
static const NSTimeInterval kToggleDebounce = 10.0;  /* min gap between our toggles */
static const NSTimeInterval kRescanInterval = 60.0;  /* discover newly-paired devices */
static const useconds_t     kToggleOffOnGap = 500 * 1000;

@interface BTResumed : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
- (void)start;
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
    NSURL                                         *_stateFileURL;     /* cached path */
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
    if (!data) return;  /* no persisted state yet, normal first run */

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

    /* Apple CoreBluetooth canonical reconnection pattern: retrievePeripherals
     * WithIdentifiers returns CBPeripheral objects even if not currently
     * connected, so we can call connectPeripheral: on them and receive future
     * state events — even when the peripheral is stuck in a 762 connect/
     * disconnect loop from its own idle-sleep cycle. */
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

#pragma mark - Periodic rescan

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

    /* Clear stale pending on any non-PoweredOn → PoweredOn transition.
     * (Unknown is the first-call initial state; nothing to clear then.) */
    if (prev != CBManagerStateUnknown &&
        prev != CBManagerStatePoweredOn &&
        _pending.count > 0) {
        [self log:[NSString stringWithFormat:
                   @"clearing %lu pending check(s) (transition-from-%ld artifacts)",
                   (unsigned long)_pending.count, (long)prev]];
        [_pending removeAllObjects];
    }

    /* (1) Load persisted HID UUIDs — survives CB power cycles + daemon restarts. */
    [self loadPersistedHIDs];

    /* (2) Discover currently-connected peripherals (new pairings + Classic). */
    NSArray<CBPeripheral *> *connected =
        [central retrieveConnectedPeripheralsWithServices:connectedPeripheralUUIDs()];
    [self log:[NSString stringWithFormat:@"found %lu currently connected BLE peripheral(s)",
               (unsigned long)connected.count]];
    for (CBPeripheral *p in connected) {
        [self adoptPeripheral:p];
    }

    /* (3) Re-arm every tracked peripheral so CB resumes delivering state
     * events for them (connectPeripheral is idempotent). */
    for (CBPeripheral *p in _peripherals.allValues) {
        [central connectPeripheral:p options:nil];
    }
}

- (void)adoptPeripheral:(CBPeripheral *)p {
    BOOL isNew = (_peripherals[p.identifier] == nil);
    p.delegate = self;
    _peripherals[p.identifier] = p;  /* always update ref in case CB handed a newer one */
    if (isNew) {
        [self log:[NSString stringWithFormat:@"adopt: %@ (%@) state=%ld",
                   p.identifier.UUIDString, p.name ?: @"?", (long)p.state]];
    }
    /* connectPeripheral subscribes us to peripheral state events and, if the
     * peripheral isn't currently connected, tells CB to keep retrying. Both
     * behaviors are what we want. */
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
    /* Re-classify: peripheral.name may have been nil at first didConnect. */
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

    /* Re-arm CB subscription. */
    [central connectPeripheral:peripheral options:nil];
}

#pragma mark - Classification

- (void)classifyPeripheral:(CBPeripheral *)peripheral {
    /* Once classified HID, never downgrade. Non-HID is always re-checkable
     * because the name may have been nil at first adoption. */
    if ([_hidPeripherals containsObject:peripheral.identifier]) return;

    if (nameLooksLikeHID(peripheral.name)) {
        [_hidPeripherals addObject:peripheral.identifier];
        [_loggedNonHID removeObject:peripheral.identifier];
        [self log:[NSString stringWithFormat:@"classified HID-like: %@ (%@)",
                   peripheral.identifier.UUIDString, peripheral.name ?: @"?"]];
        [self persistHIDs];
        return;
    }

    /* Log non-HID classification only once per peripheral to avoid spam. */
    if (![_loggedNonHID containsObject:peripheral.identifier]) {
        [_loggedNonHID addObject:peripheral.identifier];
        [self log:[NSString stringWithFormat:
                   @"classified non-HID: %@ (%@) — won't trigger toggle (re-checkable)",
                   peripheral.identifier.UUIDString, peripheral.name ?: @"?"]];
    }
}

#pragma mark - Evaluation

- (void)evaluateAndMaybeToggle:(CBPeripheral *)peripheral {
    /* Final re-classification — last chance for a late-arriving name. */
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

    int state = IOBluetoothPreferenceGetControllerPowerState();
    if (state == 0) {
        [self log:@"check: BT powered off by user, respect intent"];
        return;
    }

    NSTimeInterval sinceLast = -[_lastToggle timeIntervalSinceNow];
    if (sinceLast < kToggleDebounce) {
        [self log:[NSString stringWithFormat:@"check: debounced (%.1fs since last toggle)",
                   sinceLast]];
        return;
    }

    [self log:[NSString stringWithFormat:@"check: %@ still disconnected → toggle BT",
               peripheral.name ?: @"?"]];
    IOBluetoothPreferenceSetControllerPowerState(0);
    usleep(kToggleOffOnGap);
    IOBluetoothPreferenceSetControllerPowerState(1);
    _lastToggle = [NSDate date];
    [self log:@"toggle complete"];
}

@end

#pragma mark - main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        dispatch_source_t sigTerm =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                   dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigTerm, ^{
            fprintf(stderr, "SIGTERM received, exiting\n");
            fflush(stderr);
            exit(0);
        });
        dispatch_resume(sigTerm);
        signal(SIGTERM, SIG_IGN);

        BTResumed *w = [[BTResumed alloc] init];
        [w start];

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
