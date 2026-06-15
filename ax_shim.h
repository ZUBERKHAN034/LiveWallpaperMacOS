#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

AXUIElementRef AXShimCreateApplication(pid_t pid);
CFTypeRef AXShimCopyAttr(AXUIElementRef e, CFStringRef attr);
bool AXShimPerformAction(AXUIElementRef e, CFStringRef action);

// Full self-contained traversal in C — no AXUIElement returned to Swift
bool AXShimFindAndPress(pid_t appPid, const char *descSubstr, double timeout);
bool AXShimFindWindowByTitle(pid_t appPid, const char *titleSubstr, double timeout);
