#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

AXUIElementRef AXShimCreateApplication(pid_t pid);
CFTypeRef AXShimCopyAttr(AXUIElementRef e, CFStringRef attr);
bool AXShimPerformAction(AXUIElementRef e, CFStringRef action);
