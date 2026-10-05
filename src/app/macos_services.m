#include <stddef.h>
#include <stdint.h>
#include <objc/objc.h>
#include <objc/NSObjCRuntime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreFoundation/CFAttributedString.h>
#import <Foundation/Foundation.h>
#import <Foundation/NSExtensionContext.h>
#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <SDL3/SDL.h>

#include <stdlib.h>
#include <string.h>

static Uint32 term_service_event_type = 0;
static NSMutableArray<NSDictionary<NSString *, id> *> *term_service_requests;

static BOOL TermSupportedWorkspaceURL(NSURL *url) {
    NSString *name = url.lastPathComponent;
    NSString *extension = name.pathExtension;
    if (![extension isEqualToString:@"odin"] && ![extension isEqualToString:@"json"]) return NO;
    if ([name hasSuffix:[@".term." stringByAppendingString:extension]]) return YES;
    return [url.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@".term"];
}

static BOOL TermSubmitServiceRequest(NSInteger kind, NSString *path) {
    if (!path || !term_service_requests) return NO;
    @synchronized (term_service_requests) {
        [term_service_requests addObject:@{@"kind": @(kind), @"path": [path copy]}];
    }
    if (term_service_event_type != 0) {
        SDL_Event event = {0};
        event.type = term_service_event_type;
        if (!SDL_PushEvent(&event)) return NO;
    }
    return YES;
}

@interface TermServiceProvider : NSObject
- (void)openTermHere:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error;
- (void)restoreTermWorkspace:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error;
@end

@implementation TermServiceProvider
- (NSURL *)selectedFileURL:(NSPasteboard *)pasteboard error:(NSString **)error {
    NSArray *objects = [pasteboard readObjectsForClasses:@[NSURL.class]
                                                 options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (objects.count != 1 || ![objects.firstObject isFileURL]) {
        if (error) *error = @"Select exactly one file or folder in Finder.";
        return nil;
    }
    return objects.firstObject;
}

- (void)openTermHere:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    NSURL *url = [self selectedFileURL:pasteboard error:error];
    if (!url) return;
    NSNumber *isDirectory = nil;
    if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil] || !isDirectory.boolValue) {
        if (error) *error = @"Select exactly one folder in Finder.";
        return;
    }
    if (!TermSubmitServiceRequest(1, url.path)) {
        if (error) *error = @"Term could not queue the folder restore request.";
    }
}

- (void)restoreTermWorkspace:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    NSURL *url = [self selectedFileURL:pasteboard error:error];
    if (!url) return;
    NSNumber *isDirectory = nil;
    if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil] || isDirectory.boolValue || !TermSupportedWorkspaceURL(url)) {
        if (error) *error = @"Select one supported Term workspace file.";
        return;
    }
    if (!TermSubmitServiceRequest(2, url.path)) {
        if (error) *error = @"Term could not queue the workspace restore request.";
    }
}
@end

bool term_macos_services_init(void) {
    if (term_service_event_type == 0) {
        term_service_event_type = SDL_RegisterEvents(1);
        if (term_service_event_type == (Uint32)-1) return false;
    }
    if (!term_service_requests) term_service_requests = [[NSMutableArray alloc] init];
    static TermServiceProvider *provider;
    if (!provider) provider = [[TermServiceProvider alloc] init];
    [NSApplication sharedApplication].servicesProvider = provider;
    return YES;
}

int term_macos_services_pop(int *kind, char **path) {
    if (!term_service_requests || !kind || !path) return 0;
    NSDictionary<NSString *, id> *request = nil;
    @synchronized (term_service_requests) {
        if (term_service_requests.count == 0) return 0;
        request = term_service_requests.firstObject;
        [term_service_requests removeObjectAtIndex:0];
    }
    const char *utf8 = [request[@"path"] fileSystemRepresentation];
    if (!utf8) return 0;
    char *copy = strdup(utf8);
    if (!copy) return 0;
    *kind = [request[@"kind"] intValue];
    *path = copy;
    return 1;
}

void term_macos_services_free_path(char *path) { free(path); }
