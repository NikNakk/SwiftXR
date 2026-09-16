#pragma once

#include "swapchain.h"

static inline XrResult
swiftxr_create_instance_with_overlay(const char *application_name, void **out_instance)
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
        XR_EXTX_OVERLAY_EXTENSION_NAME,
    };
    create_info.enabledExtensionCount = 2;
    create_info.enabledExtensionNames = extensions;

    XrInstance instance = XR_NULL_HANDLE;
    XrResult result = xrCreateInstance(&create_info, &instance);
    if (XR_SUCCEEDED(result)) {
        *out_instance = (void *)instance;
    }

    return result;
}

static inline XrResult
swiftxr_create_metal_overlay_session(
    void *instance,
    uint64_t system_id,
    void *command_queue,
    uint32_t layer_placement,
    void **out_session)
{
    if (instance == NULL || command_queue == NULL || out_session == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_session = NULL;

    XrGraphicsBindingMetalKHR binding = {0};
    binding.type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR;
    binding.commandQueue = command_queue;

    XrSessionCreateInfoOverlayEXTX overlay = {0};
    overlay.type = XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX;
    overlay.createFlags = 0;
    overlay.sessionLayersPlacement = layer_placement;
    overlay.next = &binding;

    XrSessionCreateInfo create_info = {0};
    create_info.type = XR_TYPE_SESSION_CREATE_INFO;
    create_info.next = &overlay;
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

static inline uint64_t
swiftxr_composition_layer_blend_texture_source_alpha_bit(void)
{
    return (uint64_t)XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
}

static inline XrResult
swiftxr_end_frame_projection_with_flags(
    void *session,
    void *space,
    void *swapchain,
    int64_t display_time,
    int32_t environment_blend_mode,
    const SwiftXRLocatedViews *located_views,
    uint32_t width,
    uint32_t height,
    uint64_t layer_flags)
{
    if (session == NULL || space == NULL || swapchain == NULL || located_views == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (located_views->view_count != 2) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrCompositionLayerProjectionView projection_views[2];
    swiftxr_view_data_to_projection_view(
        &projection_views[0],
        &located_views->left,
        (XrSwapchain)swapchain,
        0,
        width,
        height);
    swiftxr_view_data_to_projection_view(
        &projection_views[1],
        &located_views->right,
        (XrSwapchain)swapchain,
        1,
        width,
        height);

    XrCompositionLayerProjection layer = {0};
    layer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION;
    layer.layerFlags = (XrCompositionLayerFlags)layer_flags;
    layer.space = (XrSpace)space;
    layer.viewCount = 2;
    layer.views = projection_views;

    const XrCompositionLayerBaseHeader *layers[] = {
        (const XrCompositionLayerBaseHeader *)&layer,
    };

    XrFrameEndInfo end_info = {0};
    end_info.type = XR_TYPE_FRAME_END_INFO;
    end_info.displayTime = (XrTime)display_time;
    end_info.environmentBlendMode = (XrEnvironmentBlendMode)environment_blend_mode;
    end_info.layerCount = 1;
    end_info.layers = layers;

    return xrEndFrame((XrSession)session, &end_info);
}
