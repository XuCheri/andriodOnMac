#import "CGVirtualDisplayPrivate.h"
#import <signal.h>
#import <unistd.h>

static CGVirtualDisplay *ownedDisplay;
static BOOL exiting = NO;
static dispatch_source_t parentWatch;
static dispatch_source_t inputWatch;
static NSMutableArray *signalWatches;

static BOOL DisplayModeMatchesSize(CGDisplayModeRef mode, size_t width, size_t height) {
    // Both logical dimensions and backing pixels must match: a 960x540 HiDPI
    // mode backed by 1920x1080 pixels is not the requested 1920x1080 desktop.
    return mode && CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height &&
        CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height;
}

static CGDisplayModeRef CopyRequestedDisplayMode(CGDirectDisplayID displayID, size_t width, size_t height) {
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
    if (!modes) return NULL;
    CGDisplayModeRef selected = NULL;
    for (CFIndex index = 0; index < CFArrayGetCount(modes); ++index) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, index);
        if (DisplayModeMatchesSize(mode, width, height)) {
            selected = CGDisplayModeRetain(mode);
            break;
        }
    }
    CFRelease(modes);
    return selected;
}

static BOOL ConfigureOwnedDisplay(CGDirectDisplayID displayID, size_t width, size_t height, NSString **failureMessage) {
    *failureMessage = @"无法设置本次会话的扩展显示布局，请使用镜像模式。";
    // Wait for WindowServer registration; private creation is asynchronous.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while (!CGDisplayIsOnline(displayID) && deadline.timeIntervalSinceNow > 0 && !exiting) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    }
    if (!CGDisplayIsOnline(displayID) || exiting) return NO;
    CGDisplayModeRef requestedMode = CopyRequestedDisplayMode(displayID, width, height);
    while (!requestedMode && deadline.timeIntervalSinceNow > 0 && !exiting) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        requestedMode = CopyRequestedDisplayMode(displayID, width, height);
    }
    if (!requestedMode || exiting) {
        if (requestedMode) CGDisplayModeRelease(requestedMode);
        *failureMessage = [NSString stringWithFormat:@"虚拟显示器没有可用的 %zux%zu 非 HiDPI 显示模式，请调整分辨率或使用镜像模式。", width, height];
        return NO;
    }
    CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
    CGFloat right = CGRectGetMaxX(mainBounds);
    uint32_t count = 0;
    CGDirectDisplayID displays[64];
    if (CGGetActiveDisplayList(64, displays, &count) != kCGErrorSuccess) {
        CGDisplayModeRelease(requestedMode);
        return NO;
    }
    // Put this display to the right without overlapping or moving an existing
    // physical monitor that is already on the main display's right side.
    for (uint32_t index = 0; index < count; ++index) {
        if (displays[index] != displayID) right = MAX(right, CGRectGetMaxX(CGDisplayBounds(displays[index])));
    }
    CGDisplayConfigRef configuration = NULL;
    if (CGBeginDisplayConfiguration(&configuration) != kCGErrorSuccess) {
        CGDisplayModeRelease(requestedMode);
        return NO;
    }
    CGError error = CGConfigureDisplayMirrorOfDisplay(configuration, displayID, kCGNullDirectDisplay);
    // Select the exact desktop size in the same temporary transaction as the
    // layout; macOS may otherwise choose a smaller automatically added mode.
    if (error == kCGErrorSuccess) error = CGConfigureDisplayWithDisplayMode(configuration, displayID, requestedMode, NULL);
    if (error == kCGErrorSuccess) error = CGConfigureDisplayOrigin(configuration, displayID, (int32_t)right, (int32_t)CGRectGetMinY(mainBounds));
    if (error != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(configuration);
        CGDisplayModeRelease(requestedMode);
        return NO;
    }
    error = CGCompleteDisplayConfiguration(configuration, kCGConfigureForAppOnly);
    CGDisplayModeRelease(requestedMode);
    return error == kCGErrorSuccess;
}

static void Reply(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void Stop(void) {
    if (exiting) return;
    exiting = YES;
    ownedDisplay = nil;
    // Give WindowServer a chance to publish display removal before exit.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        Reply(@{@"type": @"stopped"});
        exit(0);
    });
}

static BOOL Create(NSInteger width, NSInteger height) {
    if (ownedDisplay || exiting) {
        Reply(@{@"type": @"error", @"message": @"虚拟显示器已经创建，请先停止当前会话。"});
        return NO;
    }
    if (width < 320 || height < 320 || width > 4096 || height > 4096 || width * height > 8294400) {
        Reply(@{@"type": @"error", @"message": @"虚拟显示器尺寸不受支持。"});
        return NO;
    }
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !settingsClass || !modeClass || !displayClass ||
        ![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)] ||
        ![displayClass instancesRespondToSelector:@selector(applySettings:)]) {
        Reply(@{@"type": @"error", @"message": @"当前 macOS 没有可用的实验性虚拟显示接口，请使用镜像模式。"});
        return NO;
    }
    @try {
        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"AndroidOnMac Android Display";
        descriptor.maxPixelsWide = (unsigned int)width;
        descriptor.maxPixelsHigh = (unsigned int)height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 150.0, height * 25.4 / 150.0);
        descriptor.vendorID = 0x5843;
        descriptor.productID = 0x414D;
        descriptor.serialNum = arc4random() | 1;
        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[[[modeClass alloc] initWithWidth:width height:height refreshRate:60.0]];
        if (!display || ![display applySettings:settings] || display.displayID == kCGNullDirectDisplay) {
            Reply(@{@"type": @"error", @"message": @"macOS 未能创建虚拟显示器，请使用镜像模式。"});
            return NO;
        }
        ownedDisplay = display;
        CGDirectDisplayID displayID = display.displayID;
        NSString *configurationError = nil;
        if (!ConfigureOwnedDisplay(displayID, (size_t)width, (size_t)height, &configurationError)) {
            ownedDisplay = nil;
            Reply(@{@"type": @"error", @"message": configurationError});
            return NO;
        }
        // Callers wait for ScreenCaptureKit to enumerate this exact display ID.
        Reply(@{@"type": @"created", @"displayID": @(displayID), @"width": @(width), @"height": @(height)});
        return YES;
    } @catch (NSException *exception) {
        ownedDisplay = nil;
        Reply(@{@"type": @"error", @"message": @"当前 macOS 的虚拟显示接口不兼容，请使用镜像模式。"});
        return NO;
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        pid_t parent = getppid();
        BOOL probe = NO;
        BOOL run = NO;
        NSInteger width = 1280, height = 720;
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--probe") == 0) probe = YES;
            else if (strcmp(argv[i], "--run") == 0) run = YES;
            else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) width = atoi(argv[++i]);
            else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) height = atoi(argv[++i]);
            else return 64;
        }
        parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(parentWatch, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(parentWatch, ^{
            if (getppid() != parent || parent <= 1 || (kill(parent, 0) == -1 && errno == ESRCH)) Stop();
        });
        dispatch_resume(parentWatch);
        signalWatches = [NSMutableArray array];
        for (NSNumber *number in @[@(SIGTERM), @(SIGINT), @(SIGHUP)]) {
            int signo = number.intValue;
            signal(signo, SIG_IGN);
            dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signo, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(source, ^{ Stop(); });
            dispatch_resume(source);
            [signalWatches addObject:source];
        }
        if (probe || run) {
            if (!Create(width, height)) return 1;
            if (probe) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Stop(); });
        } else {
            NSMutableData *pending = [NSMutableData data];
            inputWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(inputWatch, ^{
                char bytes[4096];
                ssize_t count = read(STDIN_FILENO, bytes, sizeof bytes);
                if (count <= 0) { Stop(); return; }
                [pending appendBytes:bytes length:(NSUInteger)count];
                if (pending.length > 8192) { Stop(); return; }
                while (pending.length) {
                    const void *newline = memchr(pending.bytes, '\n', pending.length);
                    if (!newline) break;
                    NSUInteger length = (const char *)newline - (const char *)pending.bytes;
                    NSData *line = [pending subdataWithRange:NSMakeRange(0, length)];
                    [pending replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
                    id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                    if (![message isKindOfClass:NSDictionary.class]) { Stop(); break; }
                    NSString *type = message[@"type"] ?: message[@"command"];
                    if ([type isEqual:@"stop"]) { Stop(); break; }
                    if ([type isEqual:@"create"] && [message[@"width"] isKindOfClass:NSNumber.class] && [message[@"height"] isKindOfClass:NSNumber.class]) {
                        Create([message[@"width"] integerValue], [message[@"height"] integerValue]);
                    } else {
                        Reply(@{@"type": @"error", @"message": @"无效的虚拟显示命令。"});
                    }
                }
            });
            dispatch_resume(inputWatch);
            dispatch_main();
        }
        dispatch_main();
    }
}
