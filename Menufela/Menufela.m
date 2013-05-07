// This file is just full of ugly hacks to make xnomad work better

#import "Menufela.h"
#import <Carbon/Carbon.h>
#import <objc/runtime.h>


#define KILLLIST @[@"com.apple.iTunes", @"com.torusknot.SourceTree", @"freemind.main.FreeMind"] // Only hide menubar
#define BLACKLIST @[@"com.apple.systempreferences", @"com.adobe.Photoshop", @"com.rdio.desktop", @"net.elasticthreads.nv"] // Only draw border
#define GRAYLIST @[@"com.apple.Safari", @"com.google.chrome"]  // Draw border and watch mouse

#pragma mark Definitions

#define PrefKey(key)  (@"Menufela_" key)
#define ReadPref(key) [Defaults objectForKey:PrefKey(key)]
#define WritePref(key, value) [Defaults setObject:(value) forKey:PrefKey(key)]

@interface NSObject (Menufela)
+ (void)mf_swizzle:(SEL)aOrig with:(SEL)aNew;
@end

@interface NSWindow ()
- (id)_borderView;
@end

// Associated object keys (since we can't append ivars)
static const char * const reposKey  = "mf_dontRepositionContentView";
static const char * const trackKey  = "mf_trackingArea";
static const char * const borderKey = "mf_border";
static const char * const mf_hasBeenUpdatedKey = "mf_hasBeenUpdated";

@interface NSWindow (Menufela)
- (void)mf_setupTitleBar;
- (void)mf_update;
@end

@interface Menufela ()
+ (void)_updateMenubarState;
+ (void)_toggleMenubar:(id)sender;
@end


#pragma mark - Implementations

@implementation Menufela

+ (void)load
{
    @autoreleasepool {
    [Defaults registerDefaults:@{ PrefKey(@"ShouldHideMenubar"): @YES }];

    // Insert the menu hiding toggle menuitem
    NSMenu *windowMenu = [NSApp windowsMenu];
    NSUInteger zoomIdx = [windowMenu indexOfItemWithTitle:@"Zoom"];
    [windowMenu insertItem:[NSMenuItem separatorItem] atIndex:zoomIdx+1];
    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Menubar"
                                                        action:@selector(_toggleMenubar:)
                                                 keyEquivalent:@"\n"];
    toggleItem.target = self;
    toggleItem.keyEquivalentModifierMask = NSControlKeyMask;
    [windowMenu insertItem:toggleItem atIndex:zoomIdx+2];
    
    [NotificationCenter addObserver:self
                           selector:@selector(_updateMenubarState)
                               name:NSApplicationDidBecomeActiveNotification
                             object:NSApp];
    [self _updateMenubarState];

    // Set up our NSWindow overrides
    [NSWindow mf_swizzle:@selector(dealloc) with:@selector(mf_dealloc)];
    [NSWindow mf_swizzle:@selector(setContentView:) with:@selector(mf_setContentView:)];

    [NSWindow mf_swizzle:@selector(initWithCoder:) with:@selector(mf_initWithCoder:)];
    [NSWindow mf_swizzle:@selector(observeValueForKeyPath:ofObject:change:context:)
                    with:@selector(mf_observeValueForKeyPath:ofObject:change:context:)];
    [NSWindow mf_swizzle:@selector(initWithContentRect:styleMask:backing:defer:screen:)
                    with:@selector(mf_initWithContentRect:styleMask:backing:defer:screen:)];
    [NSWindow mf_swizzle:@selector(initWithContentRect:styleMask:backing:defer:)
                    with:@selector(mf_initWithContentRect:styleMask:backing:defer:)];

    // Initialize any windows that might already exist
    for(NSWindow *window in [NSApp windows]) {
        [window mf_setupTitleBar];
        [window mf_update];
    }
    }
}

+ (void)_updateMenubarState
{
    @autoreleasepool {
        if([ReadPref(@"ShouldHideMenubar") boolValue])
            SetSystemUIMode(kUIModeAllSuppressed, kUIOptionAutoShowMenuBar);
        else
            SetSystemUIMode(kUIModeNormal, 0);
    }
}

+ (void)_toggleMenubar:(id)sender
{
    @autoreleasepool {
        WritePref(@"ShouldHideMenubar", @(![ReadPref(@"ShouldHideMenubar") boolValue]));
        [self _updateMenubarState];
    }
}

@end


@implementation NSObject (Menufela)

+ (void)mf_swizzle:(SEL)aOrig with:(SEL)aNew
{
    Method origMethod = class_getInstanceMethod(self, aOrig);
    Method newMethod = class_getInstanceMethod(self, aNew);
    if(class_addMethod(self, aOrig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod)))
        class_replaceMethod(self, aNew, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    else
        method_exchangeImplementations(origMethod, newMethod);
}

@end


@implementation NSWindow (Menufela)

- (void)mf_setupTitleBar
{
    if(![self mf_shouldHideTitlebar])
        return;

    [self mf_update];

    [NotificationCenter addObserver:self selector:@selector(mf_update)
                               name:NSWindowDidResizeNotification
                             object:self];
    [NotificationCenter addObserver:self selector:@selector(mf_update)
                               name:NSWindowDidEndSheetNotification
                             object:self];

    [self.toolbar addObserver:self
                   forKeyPath:@"visible"
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
    [self.contentView addObserver:self forKeyPath:@"frame"
                          options:NSKeyValueObservingOptionNew
                          context:NULL];


    // Wait till we're onscreen to add borders
    [NotificationCenter addObserver:self selector:@selector(mf_initBorder)
                               name:NSWindowDidUpdateNotification
                             object:self];
}

- (void)mf_initBorder
{
    [NotificationCenter removeObserver:self
                                  name:NSWindowDidUpdateNotification
                                object:self];
    

    // Create a child window to keep the border
    NSWindow *child = [[NSWindow alloc] initWithContentRect:self.frame
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];

    NSRect bounds  = { NSZeroPoint, self.frame.size };
    NSBox *border  = [[NSBox alloc] initWithFrame:bounds];
    border.boxType = NSBoxCustom;
    border.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable;
    border.borderType = NSLineBorder;
    border.borderColor = [NSColor blackColor];
    border.borderWidth = 1;
    child.contentView = border;
    [border release];

    child.ignoresMouseEvents = YES;
    child.movableByWindowBackground = NO;
    child.opaque = NO;
    child.backgroundColor = [NSColor clearColor];
    [child setHidesOnDeactivate:NO];
    [child useOptimizedDrawing:YES];
    [self addChildWindow:child ordered:NSWindowAbove];

    objc_setAssociatedObject(self, borderKey, child, OBJC_ASSOCIATION_RETAIN);
    [child release];

    [NotificationCenter addObserver:self selector:@selector(mf_updateBorder)
                               name:NSWindowDidBecomeKeyNotification
                             object:self];
    [NotificationCenter addObserver:self selector:@selector(mf_updateBorder)
                               name:NSWindowDidResignKeyNotification
                             object:self];
}

#pragma mark -

- (void)mf_updateBorder
{
    NSWindow *borderWin = objc_getAssociatedObject(self, borderKey);
    [borderWin.contentView setBorderColor:self.isKeyWindow ? [NSColor redColor] : [NSColor blackColor]];
    [borderWin setFrame:self.frame display:YES];
}

- (BOOL)mf_shouldHideTitlebar
{
    return (self.styleMask & NSTitledWindowMask)
        && ![self isKindOfClass:[NSPanel class]]
        && ![self isSheet]
        && ![self parentWindow]
        && ![KILLLIST containsObject:[[NSBundle mainBundle] bundleIdentifier]];
}

- (void)mf_update
{
    if(![self mf_shouldHideTitlebar] || objc_getAssociatedObject(self, reposKey) != nil)
        return;

    BOOL firstUpdate = ![objc_getAssociatedObject(self, mf_hasBeenUpdatedKey) boolValue];
    objc_setAssociatedObject(self, mf_hasBeenUpdatedKey, @true, OBJC_ASSOCIATION_RETAIN);

    [[self standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[self standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[self standardWindowButton:NSWindowZoomButton] setHidden:YES];

    self.hasShadow = NO;
    self.resizeIncrements = (NSSize){1,1};
    self.contentResizeIncrements = self.resizeIncrements;
    unless(self.styleMask & NSResizableWindowMask)
        self.level = MAX(self.level, NSFloatingWindowLevel);

    NSRect windowFrame = [self frame];
    NSView *topView = [self _borderView];
    NSView *contentView = [self contentView];
    NSRect contentFrame = [contentView frame];
    NSRect frame = topView.frame;
    self.toolbar.showsBaselineSeparator = NO;

    if([BLACKLIST containsObject:[[NSBundle mainBundle] bundleIdentifier]])
        goto updateBorder;
//    if([GRAYLIST containsObject:[[NSBundle mainBundle] bundleIdentifier]])
//        goto skipTitlebarRemoval;

    objc_setAssociatedObject(self, reposKey, @true, OBJC_ASSOCIATION_RETAIN);
    if(firstUpdate && !(self.styleMask & NSResizableWindowMask)) {
        // Since in a non-resizable window it's very reasonable to expect that the
        // view isn't meant to be resized, we resize the window instead (and only once)
        windowFrame.size.height -= 22;
        [self setFrame:windowFrame display:YES];
        topView.frame = windowFrame;
        contentView.frame = contentFrame;
    } else if(self.styleMask & NSResizableWindowMask) {
        if(self.toolbar.isVisible) {
            // Find the tallest item
            float toolbarHeight = 0;
            if(self.toolbar.displayMode != NSToolbarDisplayModeLabelOnly) {
                for(NSToolbarItem *item in self.toolbar.visibleItems) {
                    if([item isKindOfClass:NSClassFromString(@"NSToolbarFlexibleSpaceItem")]
                       || [item isKindOfClass:NSClassFromString(@"NSToolbarSpaceItem")])
                        continue;
                    else if(item.view)
                        toolbarHeight = MAX(toolbarHeight, MAX(item.maxSize.height, NSMaxY(item.view.bounds)));
                    else
                        toolbarHeight = MAX(toolbarHeight, item.maxSize.height);
                }
            }

            if(self.toolbar.displayMode == NSToolbarDisplayModeLabelOnly
               || self.toolbar.displayMode == NSToolbarDisplayModeIconAndLabel)
                toolbarHeight += 14;
            
            contentFrame.size.height = windowFrame.size.height - toolbarHeight - 9;
            // Leave 3 px of the titlebar so that the toolbar has equal top/bottom margins
            frame.size.height = windowFrame.size.height + 19;
        } else {
            contentFrame.size.height = windowFrame.size.height+1;
            frame.size.height = windowFrame.size.height + 22;
        }
        contentView.frame = contentFrame;
        topView.frame     = frame;
    }
skipTitlebarRemoval:
    objc_setAssociatedObject(self, reposKey, nil, OBJC_ASSOCIATION_RETAIN);

    // Update the tracking area
    NSTrackingArea *oldTrackingArea = objc_getAssociatedObject(self, trackKey);
    if(oldTrackingArea)
        [[self contentView] removeTrackingArea:oldTrackingArea];

    NSRect bounds = { NSZeroPoint, windowFrame.size };
    NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:bounds
                                                                options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways
                                                                  owner:self
                                                               userInfo:nil];
    [[self contentView] addTrackingArea:trackingArea];
    objc_setAssociatedObject(self, trackKey, trackingArea, OBJC_ASSOCIATION_RETAIN);
    [trackingArea release];
    
updateBorder:
    [self mf_updateBorder];
}


#pragma mark -

- (void)mouseEntered:(NSEvent *)aEvent
{
    if([NSEvent modifierFlags] & NSCommandKeyMask || self.isKeyWindow)
        return;
    [self makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}


- (void)mf_observeValueForKeyPath:(NSString *)keyPath
                         ofObject:(id)object
                           change:(NSDictionary *)change
                          context:(void *)context
{
    if(([keyPath isEqualToString:@"visible"] && object == self.toolbar)
       || ([keyPath isEqualToString:@"frame"] && object == self.contentView))
        [self mf_update];
    else
        [self mf_observeValueForKeyPath:keyPath
                               ofObject:object
                                 change:change
                                context:context];
}


- (void)mf_setContentView:(NSView *)aView
{
    @try { [self.contentView removeObserver:self forKeyPath:@"frame"]; } @catch(id e) {}
    [self mf_setContentView:aView];
    [self mf_update];
    [aView addObserver:self
            forKeyPath:@"frame"
               options:NSKeyValueObservingOptionNew
               context:NULL];
}

#pragma mark -

- (id)mf_initWithCoder:(NSCoder *)aDecoder
{
    if((self = [self mf_initWithCoder:aDecoder]))
        [self mf_setupTitleBar];
    return self;
}

- (id)mf_initWithContentRect:(NSRect)contentRect
                   styleMask:(NSUInteger)aStyle
                     backing:(NSBackingStoreType)bufferingType
                       defer:(BOOL)flag
                      screen:(NSScreen *)screen
{
    if((self = [self mf_initWithContentRect:contentRect
                                 styleMask:aStyle
                                   backing:bufferingType
                                     defer:flag
                                    screen:screen]))
        [self mf_setupTitleBar];
    return self;
}

// Surprisingly, this method doesn't just call the above with screen:nil
- (id)mf_initWithContentRect:(NSRect)contentRect
                   styleMask:(NSUInteger)aStyle
                     backing:(NSBackingStoreType)bufferingType
                       defer:(BOOL)flag
{
    if((self = [self mf_initWithContentRect:contentRect
                                  styleMask:aStyle
                                    backing:bufferingType
                                      defer:flag]))
        [self mf_setupTitleBar];
    return self;
}

- (void)mf_dealloc
{
    @try { [self.contentView removeObserver:self forKeyPath:@"frame"]; } @catch(id e) {}
    [self mf_dealloc];
}

@end
