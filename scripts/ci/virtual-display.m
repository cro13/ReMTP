// Adds a 2x ("Retina") virtual display for as long as it runs. GitHub's macOS runners have one 1024 x 768
// screen at 1x, too small and too coarse for the README's screenshots (design/app-shots.sh). CI only; it uses
// CoreGraphics' private CGVirtualDisplay classes, as DeskPad and BetterDisplay do, and is never part of the app.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/ci/virtual-display.m -o virtual-display
//   ./virtual-display 1600 1000 &     # size in points; prints "ready ..." once the 2x mode is set
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <unistd.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int serialNum;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static void fail(NSString *message) {
    fprintf(stderr, "virtual-display: %s\n", message.UTF8String);
    exit(1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) fail(@"usage: virtual-display <width> <height> (points)");
        size_t width = (size_t)atoi(argv[1]), height = (size_t)atoi(argv[2]);
        if (width < 640 || height < 480) fail(@"the size is in points and at least 640 x 480");
        if (!NSClassFromString(@"CGVirtualDisplay")) fail(@"CGVirtualDisplay isn't available on this macOS");

        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        [descriptor setDispatchQueue:dispatch_queue_create("virtual-display", DISPATCH_QUEUE_SERIAL)];
        descriptor.name = @"Screenshots";
        descriptor.maxPixelsWide = (unsigned int)(width * 2);
        descriptor.maxPixelsHigh = (unsigned int)(height * 2);
        descriptor.sizeInMillimeters = CGSizeMake(width * 0.23, height * 0.23);  // about 220 pixels per inch
        descriptor.vendorID = 0xEEEE;
        descriptor.productID = 0x1234;
        descriptor.serialNum = 1;
        descriptor.terminationHandler = ^(__unused id a, __unused id b) { fail(@"the display went away"); };

        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display || display.displayID == 0) fail(@"couldn't create the display");

        // Offered both in pixels and in points: either way the system lists a width x height mode at 2x.
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 1;
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        settings.modes = @[
            [[modeClass alloc] initWithWidth:width * 2 height:height * 2 refreshRate:60],
            [[modeClass alloc] initWithWidth:width height:height refreshRate:60],
        ];
        if (![display applySettings:settings]) fail(@"couldn't apply the display's modes");

        CGDirectDisplayID displayID = display.displayID;
        NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
        CGDisplayModeRef wanted = NULL;
        for (int attempt = 0; attempt < 50 && !wanted; attempt++) {
            usleep(100000);
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)options);
            for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
                CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                if (attempt == 0) {
                    printf("mode %zu x %zu (%zu x %zu pixels)\n", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode),
                           CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
                }
                if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height
                    && CGDisplayModeGetPixelWidth(mode) == width * 2) {
                    wanted = CGDisplayModeRetain(mode);
                    break;
                }
            }
            if (modes) CFRelease(modes);
        }
        if (!wanted) fail([NSString stringWithFormat:@"no %zu x %zu mode at 2x", width, height]);

        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess
            || CGConfigureDisplayWithDisplayMode(config, displayID, wanted, NULL) != kCGErrorSuccess
            || CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
            fail(@"couldn't switch the display to its 2x mode");
        }
        CGDisplayModeRelease(wanted);
        usleep(500000);
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(displayID);
        printf("ready display %u: %zu x %zu (%zu x %zu pixels)\n", displayID, CGDisplayModeGetWidth(current),
               CGDisplayModeGetHeight(current), CGDisplayModeGetPixelWidth(current), CGDisplayModeGetPixelHeight(current));
        CGDisplayModeRelease(current);
        fflush(stdout);
        dispatch_main();  // keeps the display until the process is killed
    }
    return 0;
}
