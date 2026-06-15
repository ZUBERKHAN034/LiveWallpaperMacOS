#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

AXUIElementRef AXShimCreateApplication(pid_t pid);
CFTypeRef AXShimCopyAttr(AXUIElementRef e, CFStringRef attr);
bool AXShimPerformAction(AXUIElementRef e, CFStringRef action);
bool AXShimFindWindowByTitle(pid_t appPid, const char *titleSubstr, double timeout);
