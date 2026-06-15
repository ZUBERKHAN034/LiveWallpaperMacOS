#include "ax_shim.h"

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
