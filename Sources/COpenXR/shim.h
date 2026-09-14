#pragma once

#define XR_USE_GRAPHICS_API_METAL 1

#include <stdint.h>
#include <string.h>

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

static inline XrResult
swiftxr_create_instance(const char *application_name, void **out_instance)
{
    if (application_name == NULL || out_instance == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_instance = NULL;

    XrInstanceCreateInfo create_info = {0};
    create_info.type = XR_TYPE_INSTANCE_CREATE_INFO;

    strncpy(
        create_info.applicationInfo.applicationName,
        application_name,
        XR_MAX_APPLICATION_NAME_SIZE - 1);
    create_info.applicationInfo.applicationName[XR_MAX_APPLICATION_NAME_SIZE - 1] = '\0';
    create_info.applicationInfo.applicationVersion = 1;

    strncpy(
        create_info.applicationInfo.engineName,
        "SwiftXR",
        XR_MAX_ENGINE_NAME_SIZE - 1);
    create_info.applicationInfo.engineName[XR_MAX_ENGINE_NAME_SIZE - 1] = '\0';
    create_info.applicationInfo.engineVersion = 1;
    create_info.applicationInfo.apiVersion = XR_API_VERSION_1_0;

    const char *extensions[] = {
        XR_KHR_METAL_ENABLE_EXTENSION_NAME,
    };
    create_info.enabledExtensionCount = 1;
    create_info.enabledExtensionNames = extensions;

    XrInstance instance = XR_NULL_HANDLE;
    XrResult result = xrCreateInstance(&create_info, &instance);
    if (XR_SUCCEEDED(result)) {
        *out_instance = (void *)instance;
    }

    return result;
}

static inline XrResult
swiftxr_destroy_instance(void *instance)
{
    if (instance == NULL) {
        return XR_SUCCESS;
    }
    return xrDestroyInstance((XrInstance)instance);
}

static inline XrInstanceProperties
swiftxr_make_instance_properties(void)
{
    XrInstanceProperties properties = {0};
    properties.type = XR_TYPE_INSTANCE_PROPERTIES;
    return properties;
}

static inline XrResult
swiftxr_get_instance_properties(void *instance, XrInstanceProperties *properties)
{
    return xrGetInstanceProperties((XrInstance)instance, properties);
}

static inline const char *
swiftxr_runtime_name(const XrInstanceProperties *properties)
{
    return properties->runtimeName;
}

static inline uint64_t
swiftxr_runtime_version(const XrInstanceProperties *properties)
{
    return (uint64_t)properties->runtimeVersion;
}

static inline uint64_t
swiftxr_version_major(uint64_t version)
{
    return XR_VERSION_MAJOR((XrVersion)version);
}

static inline uint64_t
swiftxr_version_minor(uint64_t version)
{
    return XR_VERSION_MINOR((XrVersion)version);
}

static inline uint64_t
swiftxr_version_patch(uint64_t version)
{
    return XR_VERSION_PATCH((XrVersion)version);
}

static inline XrResult
swiftxr_get_hmd_system(void *instance, uint64_t *out_system_id)
{
    if (out_system_id == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrSystemGetInfo get_info = {0};
    get_info.type = XR_TYPE_SYSTEM_GET_INFO;
    get_info.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;

    XrSystemId system_id = XR_NULL_SYSTEM_ID;
    XrResult result = xrGetSystem((XrInstance)instance, &get_info, &system_id);
    if (XR_SUCCEEDED(result)) {
        *out_system_id = (uint64_t)system_id;
    }

    return result;
}

static inline XrSystemProperties
swiftxr_make_system_properties(void)
{
    XrSystemProperties properties = {0};
    properties.type = XR_TYPE_SYSTEM_PROPERTIES;
    return properties;
}

static inline XrResult
swiftxr_get_system_properties(
    void *instance,
    uint64_t system_id,
    XrSystemProperties *properties)
{
    return xrGetSystemProperties(
        (XrInstance)instance,
        (XrSystemId)system_id,
        properties);
}

static inline const char *
swiftxr_system_name(const XrSystemProperties *properties)
{
    return properties->systemName;
}

static inline uint32_t
swiftxr_system_vendor_id(const XrSystemProperties *properties)
{
    return properties->vendorId;
}

static inline uint32_t
swiftxr_system_max_swapchain_width(const XrSystemProperties *properties)
{
    return properties->graphicsProperties.maxSwapchainImageWidth;
}

static inline uint32_t
swiftxr_system_max_swapchain_height(const XrSystemProperties *properties)
{
    return properties->graphicsProperties.maxSwapchainImageHeight;
}

static inline uint32_t
swiftxr_system_max_layer_count(const XrSystemProperties *properties)
{
    return properties->graphicsProperties.maxLayerCount;
}

static inline uint32_t
swiftxr_system_orientation_tracking(const XrSystemProperties *properties)
{
    return properties->trackingProperties.orientationTracking;
}

static inline uint32_t
swiftxr_system_position_tracking(const XrSystemProperties *properties)
{
    return properties->trackingProperties.positionTracking;
}

static inline XrResult
swiftxr_get_metal_device(void *instance, uint64_t system_id, void **out_device)
{
    if (out_device == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_device = NULL;

    PFN_xrVoidFunction function = NULL;
    XrResult result = xrGetInstanceProcAddr(
        (XrInstance)instance,
        "xrGetMetalGraphicsRequirementsKHR",
        &function);
    if (XR_FAILED(result)) {
        return result;
    }
    if (function == NULL) {
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }

    PFN_xrGetMetalGraphicsRequirementsKHR get_requirements =
        (PFN_xrGetMetalGraphicsRequirementsKHR)function;

    XrGraphicsRequirementsMetalKHR requirements = {0};
    requirements.type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR;

    result = get_requirements(
        (XrInstance)instance,
        (XrSystemId)system_id,
        &requirements);
    if (XR_SUCCEEDED(result)) {
        *out_device = requirements.metalDevice;
    }

    return result;
}

static inline XrResult
swiftxr_create_metal_session(
    void *instance,
    uint64_t system_id,
    void *command_queue,
    void **out_session)
{
    if (instance == NULL || command_queue == NULL || out_session == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_session = NULL;

    XrGraphicsBindingMetalKHR binding = {0};
    binding.type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR;
    binding.commandQueue = command_queue;

    XrSessionCreateInfo create_info = {0};
    create_info.type = XR_TYPE_SESSION_CREATE_INFO;
    create_info.next = &binding;
    create_info.systemId = (XrSystemId)system_id;

    XrSession session = XR_NULL_HANDLE;
    XrResult result = xrCreateSession(
        (XrInstance)instance,
        &create_info,
        &session);
    if (XR_SUCCEEDED(result)) {
        *out_session = (void *)session;
    }

    return result;
}

static inline XrResult
swiftxr_destroy_session(void *session)
{
    if (session == NULL) {
        return XR_SUCCESS;
    }
    return xrDestroySession((XrSession)session);
}

static inline XrResult
swiftxr_begin_session(void *session)
{
    XrSessionBeginInfo begin_info = {0};
    begin_info.type = XR_TYPE_SESSION_BEGIN_INFO;
    begin_info.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return xrBeginSession((XrSession)session, &begin_info);
}

static inline XrResult
swiftxr_end_session(void *session)
{
    return xrEndSession((XrSession)session);
}

static inline XrResult
swiftxr_request_exit_session(void *session)
{
    return xrRequestExitSession((XrSession)session);
}

static inline XrResult
swiftxr_create_local_space(void *session, void **out_space)
{
    if (session == NULL || out_space == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_space = NULL;

    XrReferenceSpaceCreateInfo create_info = {0};
    create_info.type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO;
    create_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    create_info.poseInReferenceSpace.orientation.w = 1.0f;

    XrSpace space = XR_NULL_HANDLE;
    XrResult result = xrCreateReferenceSpace(
        (XrSession)session,
        &create_info,
        &space);
    if (XR_SUCCEEDED(result)) {
        *out_space = (void *)space;
    }

    return result;
}

static inline XrResult
swiftxr_destroy_space(void *space)
{
    if (space == NULL) {
        return XR_SUCCESS;
    }
    return xrDestroySpace((XrSpace)space);
}

static inline XrResult
swiftxr_poll_session_event(
    void *instance,
    void *session,
    uint32_t *out_had_event,
    uint32_t *out_has_state,
    int32_t *out_state,
    uint32_t *out_instance_loss_pending)
{
    if (instance == NULL || session == NULL ||
        out_had_event == NULL || out_has_state == NULL ||
        out_state == NULL || out_instance_loss_pending == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_had_event = 0;
    *out_has_state = 0;
    *out_state = (int32_t)XR_SESSION_STATE_UNKNOWN;
    *out_instance_loss_pending = 0;

    XrEventDataBuffer event = {0};
    event.type = XR_TYPE_EVENT_DATA_BUFFER;

    XrResult result = xrPollEvent((XrInstance)instance, &event);
    if (result == XR_EVENT_UNAVAILABLE) {
        return XR_SUCCESS;
    }
    if (XR_FAILED(result)) {
        return result;
    }

    *out_had_event = 1;

    if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
        const XrEventDataSessionStateChanged *state_event =
            (const XrEventDataSessionStateChanged *)&event;
        if (state_event->session == (XrSession)session) {
            *out_has_state = 1;
            *out_state = (int32_t)state_event->state;
        }
    } else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
        *out_instance_loss_pending = 1;
    }

    return XR_SUCCESS;
}
