#pragma once

#define XR_USE_GRAPHICS_API_METAL 1

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

static inline int32_t
swiftxr_result_value(XrResult result)
{
    return (int32_t)result;
}

static inline XrExtensionProperties
swiftxr_make_extension_properties(void)
{
    XrExtensionProperties property = {0};
    property.type = XR_TYPE_EXTENSION_PROPERTIES;
    return property;
}

static inline const char *
swiftxr_extension_name(const XrExtensionProperties *property)
{
    return property->extensionName;
}
