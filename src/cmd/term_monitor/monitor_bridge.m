#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>

@interface TermMonitor : NSObject <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy) NSString *sockPath;
@property (nonatomic, assign) BOOL isOnline;
@property (nonatomic, assign) NSInteger sessionCount;
@property (nonatomic, strong) NSArray<NSDictionary *> *sessions;

- (instancetype)initWithSocketPath:(NSString *)socketPath;
- (void)pollSessionHost;
- (void)openTermAction:(id)sender;
- (void)quitMonitorAction:(id)sender;
- (NSImage *)statusIconWithBackgroundIndicator:(BOOL)hasDot isOffline:(BOOL)isOffline;
@end

@implementation TermMonitor

- (instancetype)initWithSocketPath:(NSString *)socketPath {
    self = [super init];
    if (self) {
        _sockPath = [socketPath copy];
        _sessions = @[];
        _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        _statusItem.button.title = @"";
        _statusItem.button.image = [self statusIconWithBackgroundIndicator:NO isOffline:YES];
        _statusItem.button.toolTip = @"Term [Offline]";

        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Term"];
        menu.delegate = self;
        _statusItem.menu = menu;

        [self pollSessionHost];

        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(pollSessionHost)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_pollTimer invalidate];
}

- (NSImage *)statusIconWithBackgroundIndicator:(BOOL)hasDot isOffline:(BOOL)isOffline {
    NSImage *icon = [NSImage imageWithSize:NSMakeSize(18.0, 18.0) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        CGFloat alpha = isOffline ? 0.4 : 1.0;
        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:@"Term"];
        if (symbol) {
            [symbol drawInRect:dstRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:alpha];
        } else {
            NSColor *strokeColor = [[NSColor blackColor] colorWithAlphaComponent:alpha];
            [strokeColor setStroke];

            NSRect frameRect = NSMakeRect(1.5, 2.5, 15.0, 13.0);
            NSBezierPath *framePath = [NSBezierPath bezierPathWithRoundedRect:frameRect xRadius:2.5 yRadius:2.5];
            [framePath setLineWidth:1.2];
            [framePath stroke];

            NSBezierPath *chevron = [NSBezierPath bezierPath];
            [chevron moveToPoint:NSMakePoint(4.5, 11.0)];
            [chevron lineToPoint:NSMakePoint(7.5, 9.0)];
            [chevron lineToPoint:NSMakePoint(4.5, 7.0)];
            [chevron setLineWidth:1.2];
            [chevron setLineCapStyle:NSLineCapStyleRound];
            [chevron setLineJoinStyle:NSLineJoinStyleRound];
            [chevron stroke];

            NSBezierPath *cursor = [NSBezierPath bezierPath];
            [cursor moveToPoint:NSMakePoint(9.0, 7.0)];
            [cursor lineToPoint:NSMakePoint(13.0, 7.0)];
            [cursor setLineWidth:1.2];
            [cursor setLineCapStyle:NSLineCapStyleRound];
            [cursor stroke];
        }

        if (hasDot) {
            NSRect haloRect = NSMakeRect(11.0, 0.5, 6.5, 6.5);
            [[NSColor clearColor] setFill];
            NSRectFillUsingOperation(haloRect, NSCompositingOperationClear);

            NSRect dotRect = NSMakeRect(12.0, 1.5, 4.5, 4.5);
            [[NSColor blackColor] setFill];
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:dotRect];
            [dot fill];
        }

        return YES;
    }];
    [icon setTemplate:YES];
    return icon;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self pollSessionHost];
}

- (void)rebuildMenu {
    NSMenu *menu = self.statusItem.menu;
    if (!menu) {
        menu = [[NSMenu alloc] initWithTitle:@"Term"];
        menu.delegate = self;
        self.statusItem.menu = menu;
    }
    [menu removeAllItems];

    if (!self.isOnline) {
        NSMenuItem *offlineItem = [[NSMenuItem alloc] initWithTitle:@"Host Offline" action:nil keyEquivalent:@""];
        [offlineItem setEnabled:NO];
        [menu addItem:offlineItem];
    } else if (self.sessions.count == 0) {
        NSMenuItem *noSessions = [[NSMenuItem alloc] initWithTitle:@"No Active Sessions" action:nil keyEquivalent:@""];
        [noSessions setEnabled:NO];
        [menu addItem:noSessions];
    } else {
        for (NSDictionary *sess in self.sessions) {
            uint64_t wsId = [sess[@"id"] unsignedLongLongValue];
            NSString *title = sess[@"title"];
            BOOL active = [sess[@"has_active_viewer"] boolValue];
            NSString *statusStr = active ? @"Active" : @"Detached";

            NSString *displayTitle = (title.length > 0) ? title : [NSString stringWithFormat:@"Workspace %llu", wsId];
            NSString *itemText = [NSString stringWithFormat:@"#%llu: %@ (%@)", wsId, displayTitle, statusStr];

            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemText action:@selector(openTermAction:) keyEquivalent:@""];
            [item setTarget:self];
            [item setToolTip:[NSString stringWithFormat:@"Workspace %llu: %@ [%@]", wsId, displayTitle, statusStr]];
            [menu addItem:item];
        }
    }

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Term" action:@selector(openTermAction:) keyEquivalent:@"o"];
    [openItem setTarget:self];
    [menu addItem:openItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Monitor" action:@selector(quitMonitorAction:) keyEquivalent:@"q"];
    [quitItem setTarget:self];
    [menu addItem:quitItem];
}

- (void)updateOfflineState {
    self.isOnline = NO;
    self.sessionCount = 0;
    self.sessions = @[];
    self.statusItem.button.title = @"";
    self.statusItem.button.image = [self statusIconWithBackgroundIndicator:NO isOffline:YES];
    self.statusItem.button.toolTip = @"Term [Offline]";
    [self rebuildMenu];
}

- (void)updateOnlineWithCount:(NSInteger)count sessions:(NSArray<NSDictionary *> *)sessions {
    self.isOnline = YES;
    self.sessionCount = count;
    self.sessions = sessions;

    NSInteger bgCount = 0;
    for (NSDictionary *sess in sessions) {
        if (![sess[@"has_active_viewer"] boolValue]) {
            bgCount++;
        }
    }
    if (sessions.count == 0 && count > 0) {
        bgCount = count;
    }
    BOOL hasBackground = (bgCount > 0);

    self.statusItem.button.title = @"";
    self.statusItem.button.image = [self statusIconWithBackgroundIndicator:hasBackground isOffline:NO];
    if (hasBackground) {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"Term: %ld background session%@",
                                          (long)bgCount, (bgCount == 1 ? @"" : @"s")];
    } else {
        self.statusItem.button.toolTip = @"Term";
    }

    [self rebuildMenu];
}

- (void)pollSessionHost {
    const char *path = [self.sockPath fileSystemRepresentation];
    if (!path || access(path, F_OK) != 0) {
        [self updateOfflineState];
        return;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        [self updateOfflineState];
        return;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    int conn_res = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (conn_res < 0) {
        if (errno == EINPROGRESS) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            int pres = poll(&pfd, 1, 100);
            if (pres <= 0) {
                close(fd);
                [self updateOfflineState];
                return;
            }
            int err = 0;
            socklen_t elen = sizeof(err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0 || err != 0) {
                close(fd);
                [self updateOfflineState];
                return;
            }
        } else {
            close(fd);
            [self updateOfflineState];
            return;
        }
    }

    // 40-byte List_Metadata frame
    // Magic "TERM", Major 1, Minor 0, Kind 2
    uint8_t req[40];
    memset(req, 0, sizeof(req));
    memcpy(req, "TERM", 4);
    req[4] = 1; req[5] = 0; // major = 1
    req[6] = 0; req[7] = 0; // minor = 0
    req[8] = 2; req[9] = 0; // kind = 2 (List_Metadata)
    req[10] = 0; req[11] = 0; // flags = 0
    req[12] = 0; req[13] = 0; req[14] = 0; req[15] = 0; // payload length = 0
    req[16] = 1; // request_id = 1

    size_t req_sent = 0;
    while (req_sent < sizeof(req)) {
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int pres = poll(&pfd, 1, 100);
        if (pres <= 0) break;
        ssize_t n = send(fd, req + req_sent, sizeof(req) - req_sent, 0);
        if (n <= 0) break;
        req_sent += (size_t)n;
    }
    if (req_sent < sizeof(req)) {
        close(fd);
        [self updateOfflineState];
        return;
    }

    uint8_t hdr[40];
    size_t hdr_read = 0;
    while (hdr_read < sizeof(hdr)) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pres = poll(&pfd, 1, 150);
        if (pres <= 0) break;
        ssize_t n = recv(fd, hdr + hdr_read, sizeof(hdr) - hdr_read, 0);
        if (n <= 0) break;
        hdr_read += (size_t)n;
    }
    if (hdr_read < sizeof(hdr) || memcmp(hdr, "TERM", 4) != 0) {
        close(fd);
        [self updateOfflineState];
        return;
    }

    uint16_t major = (uint16_t)(hdr[4] | (hdr[5] << 8));
    uint16_t kind = (uint16_t)(hdr[8] | (hdr[9] << 8));
    uint32_t payload_len = (uint32_t)(hdr[12] | (hdr[13] << 8) | (hdr[14] << 16) | (hdr[15] << 24));

    if (major != 1 || kind != 20 || payload_len > 1024 * 1024) {
        close(fd);
        [self updateOfflineState];
        return;
    }

    NSMutableData *payloadData = [NSMutableData dataWithLength:payload_len];
    uint8_t *payload = (uint8_t *)payloadData.mutableBytes;
    size_t payload_read = 0;
    while (payload_read < payload_len) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pres = poll(&pfd, 1, 150);
        if (pres <= 0) break;
        ssize_t n = recv(fd, payload + payload_read, payload_len - payload_read, 0);
        if (n <= 0) break;
        payload_read += (size_t)n;
    }
    close(fd);

    if (payload_read < payload_len || payload_len < 2) {
        [self updateOfflineState];
        return;
    }

    uint16_t session_count = (uint16_t)(payload[0] | (payload[1] << 8));
    NSMutableArray *sessions = [NSMutableArray arrayWithCapacity:session_count];
    size_t offset = 2;

    for (uint16_t i = 0; i < session_count; i++) {
        if (offset + 37 > payload_len) break;
        uint64_t ws_id = 0;
        memcpy(&ws_id, payload + offset, 8);
        offset += 8;

        uint8_t has_active_viewer = payload[offset];
        offset += 1;

        uint64_t active_viewer = 0;
        memcpy(&active_viewer, payload + offset, 8);
        offset += 8;

        uint64_t created_at_ns = 0;
        memcpy(&created_at_ns, payload + offset, 8);
        offset += 8;

        uint64_t snapshot_rev = 0;
        memcpy(&snapshot_rev, payload + offset, 8);
        offset += 8;

        uint16_t pane_count = (uint16_t)(payload[offset] | (payload[offset + 1] << 8));
        offset += 2;

        uint16_t title_len = (uint16_t)(payload[offset] | (payload[offset + 1] << 8));
        offset += 2;

        NSString *title = @"";
        if (title_len > 0 && offset + title_len <= payload_len) {
            title = [[NSString alloc] initWithBytes:payload + offset
                                             length:title_len
                                           encoding:NSUTF8StringEncoding];
            if (!title) title = @"";
            offset += title_len;
        }

        [sessions addObject:@{
            @"id": @(ws_id),
            @"has_active_viewer": @(has_active_viewer != 0),
            @"pane_count": @(pane_count),
            @"title": title
        }];
    }

    [self updateOnlineWithCount:session_count sessions:sessions];
}

- (void)openTermAction:(id)sender {
    NSURL *bundleURL = nil;
    NSString *execPath = [[NSBundle mainBundle] executablePath];
    if (execPath) {
        NSString *helperDir = [execPath stringByDeletingLastPathComponent];
        NSString *contentsDir = [helperDir stringByDeletingLastPathComponent];
        NSString *appDir = [contentsDir stringByDeletingLastPathComponent];
        if ([appDir hasSuffix:@".app"] && [[NSFileManager defaultManager] fileExistsAtPath:appDir]) {
            bundleURL = [NSURL fileURLWithPath:appDir];
        }
    }
    if (!bundleURL) {
        bundleURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"io.dwlhm.term"];
    }
    if (!bundleURL && [[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Term.app"]) {
        bundleURL = [NSURL fileURLWithPath:@"/Applications/Term.app"];
    }

    if (bundleURL) {
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:bundleURL
                                              configuration:config
                                          completionHandler:nil];
    } else {
        [[NSWorkspace sharedWorkspace] launchApplication:@"Term"];
    }
}

- (void)quitMonitorAction:(id)sender {
    [NSApp terminate:nil];
}

@end

static TermMonitor *g_monitor = nil;

int term_monitor_run(const char *socket_path) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *termDir = [home stringByAppendingPathComponent:@".term"];
        mkdir([termDir fileSystemRepresentation], 0700);

        NSString *lockPath = [termDir stringByAppendingPathComponent:@"term-monitor.lock"];
        int lock_fd = open([lockPath fileSystemRepresentation], O_RDWR | O_CREAT, 0600);
        if (lock_fd >= 0) {
            if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
                if (errno == EWOULDBLOCK || errno == EAGAIN) {
                    close(lock_fd);
                    return 0;
                }
            }
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSString *path = nil;
        if (socket_path && strlen(socket_path) > 0) {
            path = [NSString stringWithUTF8String:socket_path];
        } else {
            path = [termDir stringByAppendingPathComponent:@"term-host.sock"];
        }

        g_monitor = [[TermMonitor alloc] initWithSocketPath:path];
        (void)g_monitor;
        [NSApp run];

        if (lock_fd >= 0) {
            close(lock_fd);
        }
    }
    return 0;
}
