#include "ax_shim.h"
#include <CoreFoundation/CoreFoundation.h>
#include <unistd.h>
#include <string.h>
#include <strings.h>

AXUIElementRef AXShimCreateApplication(pid_t pid) {
    return AXUIElementCreateApplication(pid);
}

CFTypeRef AXShimCopyAttr(AXUIElementRef e, CFStringRef attr) {
    CFTypeRef v = NULL;
    AXUIElementCopyAttributeValue(e, attr, &v);
    return v;
}

bool AXShimPerformAction(AXUIElementRef e, CFStringRef action) {
    return AXUIElementPerformAction(e, action) == kAXErrorSuccess;
}

bool AXShimFindWindowByTitle(pid_t appPid, const char *titleSubstr, double timeout) {
    AXUIElementRef app = AXUIElementCreateApplication(appPid);
    CFTimeInterval deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        CFTypeRef windowsVal = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsVal) == kAXErrorSuccess) {
            if (windowsVal && CFGetTypeID(windowsVal) == CFArrayGetTypeID()) {
                CFArrayRef windows = (CFArrayRef)windowsVal;
                CFIndex count = CFArrayGetCount(windows);
                for (CFIndex i = 0; i < count; i++) {
                    AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                    CFTypeRef titleVal = NULL;
                    if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleVal) == kAXErrorSuccess) {
                        if (titleVal && CFGetTypeID(titleVal) == CFStringGetTypeID()) {
                            char buf[1024];
                            if (CFStringGetCString((CFStringRef)titleVal, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                                if (strcasestr(buf, titleSubstr) != NULL) {
                                    CFRelease(titleVal);
                                    CFRelease(windowsVal);
                                    return true;
                                }
                            }
                        }
                        if (titleVal) CFRelease(titleVal);
                    }
                }
            }
            if (windowsVal) CFRelease(windowsVal);
        }
        usleep(500000);
    }
    return false;
}
