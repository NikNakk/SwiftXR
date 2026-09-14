#pragma once

#include "shim.h"

#define SWIFTXR_MAX_SWAPCHAIN_IMAGES 16

typedef struct SwiftXRViewConfigurationData {
    uint32_t view_count;
    uint32_t left_width;
    uint32_t left_height;
    uint32_t right_width;
    uint32_t right_height;
    uint32_t recommended_sample_count;
} SwiftXRViewConfigurationData;

typedef struct SwiftXRMetalSwapchainImages {
    uint32_t count;
    void *textures[SWIFTXR_MAX_SWAPCHAIN_IMAGES];
} SwiftXRMetalSwapchainImages;

static inline XrResult
swiftxr_get_stereo_view_configuration(
    void *instance,
    uint64_t system_id,
    SwiftXRViewConfigurationData *out_configuration)
{
    if (instance == NULL || out_configuration == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    memset(out_configuration, 0, sizeof(*out_configuration));

    uint32_t count = 0;
    XrResult result = xrEnumerateViewConfigurationViews(
        (XrInstance)instance,
        (XrSystemId)system_id,
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
        0,
        &count,
        NULL);
    if (XR_FAILED(result)) {
        return result;
    }
    if (count != 2) {
        return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }

    XrViewConfigurationView views[2] = {0};
    views[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    views[1].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;

    result = xrEnumerateViewConfigurationViews(
        (XrInstance)instance,
        (XrSystemId)system_id,
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
        2,
        &count,
        views);
    if (XR_FAILED(result)) {
        return result;
    }

    out_configuration->view_count = count;
    out_configuration->left_width = views[0].recommendedImageRectWidth;
    out_configuration->left_height = views[0].recommendedImageRectHeight;
    out_configuration->right_width = views[1].recommendedImageRectWidth;
    out_configuration->right_height = views[1].recommendedImageRectHeight;
    out_configuration->recommended_sample_count =
        views[0].recommendedSwapchainSampleCount > views[1].recommendedSwapchainSampleCount
            ? views[0].recommendedSwapchainSampleCount
            : views[1].recommendedSwapchainSampleCount;

    return XR_SUCCESS;
}

static inline XrResult
swiftxr_choose_color_swapchain_format(
    void *session,
    int64_t preferred_0,
    int64_t preferred_1,
    int64_t preferred_2,
    int64_t preferred_3,
    int64_t *out_format)
{
    if (session == NULL || out_format == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    uint32_t count = 0;
    XrResult result = xrEnumerateSwapchainFormats(
        (XrSession)session,
        0,
        &count,
        NULL);
    if (XR_FAILED(result)) {
        return result;
    }
    if (count == 0) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }

    int64_t *formats = (int64_t *)calloc(count, sizeof(int64_t));
    if (formats == NULL) {
        return XR_ERROR_OUT_OF_MEMORY;
    }

    result = xrEnumerateSwapchainFormats(
        (XrSession)session,
        count,
        &count,
        formats);
    if (XR_FAILED(result)) {
        free(formats);
        return result;
    }

    const int64_t preferred[] = {
        preferred_0,
        preferred_1,
        preferred_2,
        preferred_3,
    };

    for (uint32_t p = 0; p < 4; ++p) {
        for (uint32_t i = 0; i < count; ++i) {
            if (formats[i] == preferred[p]) {
                *out_format = formats[i];
                free(formats);
                return XR_SUCCESS;
            }
        }
    }

    free(formats);
    return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
}

static inline XrResult
swiftxr_create_stereo_swapchain(
    void *session,
    int64_t format,
    uint32_t width,
    uint32_t height,
    void **out_swapchain)
{
    if (session == NULL || out_swapchain == NULL || width == 0 || height == 0) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *out_swapchain = NULL;

    XrSwapchainCreateInfo create_info = {0};
    create_info.type = XR_TYPE_SWAPCHAIN_CREATE_INFO;
    create_info.createFlags = 0;
    create_info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT;
    create_info.format = format;
    create_info.sampleCount = 1;
    create_info.width = width;
    create_info.height = height;
    create_info.faceCount = 1;
    create_info.arraySize = 2;
    create_info.mipCount = 1;

    XrSwapchain swapchain = XR_NULL_HANDLE;
    XrResult result = xrCreateSwapchain(
        (XrSession)session,
        &create_info,
        &swapchain);
    if (XR_SUCCEEDED(result)) {
        *out_swapchain = (void *)swapchain;
    }

    return result;
}

static inline XrResult
swiftxr_destroy_swapchain(void *swapchain)
{
    if (swapchain == NULL) {
        return XR_SUCCESS;
    }
    return xrDestroySwapchain((XrSwapchain)swapchain);
}

static inline XrResult
swiftxr_enumerate_metal_swapchain_images(
    void *swapchain,
    SwiftXRMetalSwapchainImages *out_images)
{
    if (swapchain == NULL || out_images == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    memset(out_images, 0, sizeof(*out_images));

    uint32_t count = 0;
    XrResult result = xrEnumerateSwapchainImages(
        (XrSwapchain)swapchain,
        0,
        &count,
        NULL);
    if (XR_FAILED(result)) {
        return result;
    }
    if (count > SWIFTXR_MAX_SWAPCHAIN_IMAGES) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }

    XrSwapchainImageMetalKHR images[SWIFTXR_MAX_SWAPCHAIN_IMAGES] = {0};
    for (uint32_t i = 0; i < count; ++i) {
        images[i].type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    }

    result = xrEnumerateSwapchainImages(
        (XrSwapchain)swapchain,
        count,
        &count,
        (XrSwapchainImageBaseHeader *)images);
    if (XR_FAILED(result)) {
        return result;
    }

    out_images->count = count;
    for (uint32_t i = 0; i < count; ++i) {
        out_images->textures[i] = images[i].texture;
    }

    return XR_SUCCESS;
}

static inline void *
swiftxr_metal_swapchain_texture(
    const SwiftXRMetalSwapchainImages *images,
    uint32_t index)
{
    if (images == NULL || index >= images->count) {
        return NULL;
    }
    return images->textures[index];
}

static inline XrResult
swiftxr_acquire_swapchain_image(void *swapchain, uint32_t *out_index)
{
    if (swapchain == NULL || out_index == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrSwapchainImageAcquireInfo acquire_info = {0};
    acquire_info.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
    return xrAcquireSwapchainImage(
        (XrSwapchain)swapchain,
        &acquire_info,
        out_index);
}

static inline XrResult
swiftxr_wait_swapchain_image(void *swapchain)
{
    if (swapchain == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrSwapchainImageWaitInfo wait_info = {0};
    wait_info.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO;
    wait_info.timeout = XR_INFINITE_DURATION;
    return xrWaitSwapchainImage((XrSwapchain)swapchain, &wait_info);
}

static inline XrResult
swiftxr_release_swapchain_image(void *swapchain)
{
    if (swapchain == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    XrSwapchainImageReleaseInfo release_info = {0};
    release_info.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
    return xrReleaseSwapchainImage((XrSwapchain)swapchain, &release_info);
}

static inline void
swiftxr_view_data_to_projection_view(
    XrCompositionLayerProjectionView *destination,
    const SwiftXRViewData *source,
    XrSwapchain swapchain,
    uint32_t image_array_index,
    uint32_t width,
    uint32_t height)
{
    memset(destination, 0, sizeof(*destination));
    destination->type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;

    destination->pose.position.x = source->position_x;
    destination->pose.position.y = source->position_y;
    destination->pose.position.z = source->position_z;
    destination->pose.orientation.x = source->orientation_x;
    destination->pose.orientation.y = source->orientation_y;
    destination->pose.orientation.z = source->orientation_z;
    destination->pose.orientation.w = source->orientation_w;

    destination->fov.angleLeft = source->angle_left;
    destination->fov.angleRight = source->angle_right;
    destination->fov.angleUp = source->angle_up;
    destination->fov.angleDown = source->angle_down;

    destination->subImage.swapchain = swapchain;
    destination->subImage.imageRect.offset.x = 0;
    destination->subImage.imageRect.offset.y = 0;
    destination->subImage.imageRect.extent.width = (int32_t)width;
    destination->subImage.imageRect.extent.height = (int32_t)height;
    destination->subImage.imageArrayIndex = image_array_index;
}

static inline XrResult
swiftxr_end_frame_projection(
    void *session,
    void *space,
    void *swapchain,
    int64_t display_time,
    int32_t environment_blend_mode,
    const SwiftXRLocatedViews *located_views,
    uint32_t width,
    uint32_t height)
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
