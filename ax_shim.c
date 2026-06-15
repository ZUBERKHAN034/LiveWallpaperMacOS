#include "ax_shim.h"
#include <CoreFoundation/CoreFoundation.h>
#include <unistd.h>
#include <string.h>

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

static AXUIElementRef find_button_impl(AXUIElementRef root, const char *descSubstr) {
    CFMutableArrayRef queue = CFArrayCreateMutable(NULL, 0, NULL);
    CFArrayAppendValue(queue, root);
    AXUIElementRef found = NULL;
    while (CFArrayGetCount(queue) > 0 && found == NULL) {
        AXUIElementRef cur = (AXUIElementRef)CFArrayGetValueAtIndex(queue, 0);
        CFArrayRemoveValueAtIndex(queue, 0);
        CFTypeRef roleVal = NULL;
        if (AXUIElementCopyAttributeValue(cur, kAXRoleAttribute, &roleVal) == kAXErrorSuccess) {
            bool isButton = (roleVal && CFGetTypeID(roleVal) == CFStringGetTypeID() &&
                             CFStringCompare((CFStringRef)roleVal, kAXButtonRole, 0) == kCFCompareEqualTo);
            if (isButton) {
                CFTypeRef descVal = NULL;
                if (AXUIElementCopyAttributeValue(cur, kAXDescriptionAttribute, &descVal) == kAXErrorSuccess) {
                    if (descVal && CFGetTypeID(descVal) == CFStringGetTypeID()) {
                        char buf[1024];
                        if (CFStringGetCString((CFStringRef)descVal, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                            if (strcasestr(buf, descSubstr) != NULL) {
                                found = cur;
                                CFRetain(found);
                            }
                        }
                    }
                    if (descVal) CFRelease(descVal);
                }
            }
            if (roleVal) CFRelease(roleVal);
        }
        if (found != NULL) break;
        CFTypeRef kidsVal = NULL;
        if (AXUIElementCopyAttributeValue(cur, kAXChildrenAttribute, &kidsVal) == kAXErrorSuccess) {
            if (kidsVal && CFGetTypeID(kidsVal) == CFArrayGetTypeID()) {
                CFArrayRef kids = (CFArrayRef)kidsVal;
                CFIndex kcount = CFArrayGetCount(kids);
                for (CFIndex i = 0; i < kcount; i++) {
                    CFArrayAppendValue(queue, CFArrayGetValueAtIndex(kids, i));
                }
            }
            if (kidsVal) CFRelease(kidsVal);
        }
    }
    CFRelease(queue);
    return found;
}

bool AXShimFindAndPress(pid_t appPid, const char *descSubstr, double timeout) {
    if (!AXShimFindWindowByTitle(appPid, "wallpaper", timeout)) return false;
    AXUIElementRef app = AXUIElementCreateApplication(appPid);
    CFTypeRef windowsVal = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsVal) != kAXErrorSuccess) return false;
    if (!windowsVal || CFGetTypeID(windowsVal) != CFArrayGetTypeID()) return false;
    CFArrayRef windows = (CFArrayRef)windowsVal;
    CFIndex count = CFArrayGetCount(windows);
    bool ok = false;
    for (CFIndex i = 0; i < count && !ok; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CFTypeRef titleVal = NULL;
        if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleVal) == kAXErrorSuccess) {
            if (titleVal && CFGetTypeID(titleVal) == CFStringGetTypeID()) {
                char buf[1024];
                if (CFStringGetCString((CFStringRef)titleVal, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    if (strcasestr(buf, "wallpaper") != NULL) {
                        AXUIElementRef btn = find_button_impl(win, descSubstr);
                        if (btn) {
                            ok = (AXUIElementPerformAction(btn, kAXPressAction) == kAXErrorSuccess);
                            CFRelease(btn);
                        }
                    }
                }
            }
            if (titleVal) CFRelease(titleVal);
        }
    }
    CFRelease(windowsVal);
    return ok;
}
