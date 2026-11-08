#pragma once
#include "shim.h"
#include <stdio.h>

// Optional interaction-profile extensions. SwiftXR enables each one only when
// the runtime offers it, and suggests its profile only when it is enabled.
#define SWIFTXR_EXT_PSVR2_INTERACTION "XR_MNDX_psvr2_interaction"
#define SWIFTXR_EXT_GENERIC_CONTROLLER "XR_KHR_generic_controller"

// Creates an instance with Metal, optionally XR_EXTX_overlay, plus the given
// extra extensions (which the caller has checked the runtime offers).
static inline XrResult swiftxr_create_instance_with_extensions(const char *application_name, int overlay,
                                                               const char *const *extra, uint32_t extra_count,
                                                               void **out_instance) {
    if (application_name == NULL || out_instance == NULL || extra_count > 8) return XR_ERROR_VALIDATION_FAILURE;
    *out_instance = NULL;
    XrInstanceCreateInfo create_info = {0};
    create_info.type = XR_TYPE_INSTANCE_CREATE_INFO;
    snprintf(create_info.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "%s", application_name);
    create_info.applicationInfo.applicationVersion = 1;
    snprintf(create_info.applicationInfo.engineName, XR_MAX_ENGINE_NAME_SIZE, "%s", "SwiftXR");
    create_info.applicationInfo.engineVersion = 1;
    create_info.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    const char *extensions[10];
    uint32_t count = 0;
    extensions[count++] = XR_KHR_METAL_ENABLE_EXTENSION_NAME;
    if (overlay) extensions[count++] = "XR_EXTX_overlay";
    for (uint32_t i = 0; i < extra_count; i++) extensions[count++] = extra[i];
    create_info.enabledExtensionCount = count;
    create_info.enabledExtensionNames = extensions;
    XrInstance instance = XR_NULL_HANDLE;
    XrResult result = xrCreateInstance(&create_info, &instance);
    if (XR_SUCCEEDED(result)) *out_instance = (void *)instance;
    return result;
}

typedef struct SwiftXRControllerInput {
    XrInstance instance;
    XrSession session;
    XrActionSet set;
    XrPath hands[2];
    XrAction aim, select, primary, grip, back, menu, home, recenter, stick;
    XrSpace spaces[2];
} SwiftXRControllerInput;

typedef struct SwiftXRHandInput {
    uint32_t active, pose_valid, select, primary, grip, back, menu, home, recenter;
    float x, y;
    XrPosef pose;
} SwiftXRHandInput;

typedef struct SwiftXRControllerState {
    uint32_t focused;
    SwiftXRHandInput left, right;
} SwiftXRControllerState;

static inline void swiftxr_destroy_controller_input(SwiftXRControllerInput *input) {
    if (!input) return;
    for (int i = 0; i < 2; i++) if (input->spaces[i]) xrDestroySpace(input->spaces[i]);
    if (input->set) xrDestroyActionSet(input->set);
    free(input);
}

static inline XrResult swiftxr_input_action(SwiftXRControllerInput *input, const char *name,
                                           XrActionType type, XrAction *action) {
    XrActionCreateInfo info = {0};
    info.type = XR_TYPE_ACTION_CREATE_INFO;
    snprintf(info.actionName, sizeof(info.actionName), "%s", name);
    snprintf(info.localizedActionName, sizeof(info.localizedActionName), "%s", name);
    info.actionType = type;
    info.countSubactionPaths = 2;
    info.subactionPaths = input->hands;
    return xrCreateAction(input->set, &info, action);
}

static inline XrResult swiftxr_input_bind(SwiftXRControllerInput *input,
                                         XrActionSuggestedBinding *bindings, uint32_t *count,
                                         XrAction action, int hand, const char *component) {
    char path[256];
    snprintf(path, sizeof(path), "/user/hand/%s%s", hand == 0 ? "left" : "right", component);
    XrPath binding;
    XrResult result = xrStringToPath(input->instance, path, &binding);
    if (XR_FAILED(result)) return result;
    bindings[(*count)++] = (XrActionSuggestedBinding){action, binding};
    return XR_SUCCESS;
}

// Interaction profiles, each suggested separately; the runtime picks one per
// controller (preferring the controller's own profile) and never merges them.
//
//  - PS VR2 Sense (XR_MNDX_psvr2_interaction): PS on either hand is Home,
//    Create is Menu. Options is left unbound because holding it recentres in
//    Monado; a press must not also act in the app.
//  - Generic controller (XR_KHR_generic_controller): the common controls for
//    any controller, with no Menu or Home (the profile reserves them).
//  - Oculus Touch: left menu is Menu, right system is Home where the runtime
//    allows it. Also how Monado presents Sense without the MNDX profile.
//  - Simple controller: the portable aim/select/menu fallback.
enum { SWIFTXR_PROFILE_TOUCH, SWIFTXR_PROFILE_SIMPLE, SWIFTXR_PROFILE_GENERIC, SWIFTXR_PROFILE_PSVR2_SENSE };

static inline XrResult swiftxr_input_suggest(SwiftXRControllerInput *input, int profile_kind) {
    XrActionSuggestedBinding bindings[32];
    uint32_t count = 0;
    XrResult result;
    const char *profile_path = NULL;
#define BIND(action, hand, component) \
    do { result = swiftxr_input_bind(input, bindings, &count, input->action, hand, component); \
         if (XR_FAILED(result)) return result; } while (0)
    for (int hand = 0; hand < 2; hand++) BIND(aim, hand, "/input/aim/pose");
    switch (profile_kind) {
    case SWIFTXR_PROFILE_SIMPLE:
        profile_path = "/interaction_profiles/khr/simple_controller";
        for (int hand = 0; hand < 2; hand++) {
            BIND(select, hand, "/input/select/click");
            BIND(menu, hand, "/input/menu/click");
        }
        break;
    case SWIFTXR_PROFILE_TOUCH:
        profile_path = "/interaction_profiles/oculus/touch_controller";
        for (int hand = 0; hand < 2; hand++) {
            BIND(select, hand, "/input/trigger/value");
            BIND(stick, hand, "/input/thumbstick");
            BIND(grip, hand, "/input/squeeze/value");
        }
        BIND(primary, 0, "/input/x/click");
        BIND(primary, 1, "/input/a/click");
        BIND(back, 1, "/input/b/click");
        BIND(recenter, 0, "/input/y/click");
        BIND(menu, 0, "/input/menu/click");
        BIND(home, 1, "/input/system/click");
        break;
    case SWIFTXR_PROFILE_GENERIC:
        profile_path = "/interaction_profiles/khr/generic_controller";
        for (int hand = 0; hand < 2; hand++) {
            BIND(select, hand, "/input/trigger/value");
            BIND(stick, hand, "/input/thumbstick");
            BIND(grip, hand, "/input/squeeze/value");
            BIND(primary, hand, "/input/primary/click");
        }
        BIND(back, 1, "/input/secondary/click");
        BIND(recenter, 0, "/input/secondary/click");
        break;
    case SWIFTXR_PROFILE_PSVR2_SENSE:
        profile_path = "/interaction_profiles/mndx/pssense_controller_mndx";
        for (int hand = 0; hand < 2; hand++) {
            BIND(select, hand, "/input/trigger/value");
            BIND(stick, hand, "/input/thumbstick");
            BIND(grip, hand, "/input/squeeze/click");
            BIND(home, hand, "/input/system/click");
        }
        BIND(primary, 0, "/input/square_mndx/click");
        BIND(primary, 1, "/input/cross_mndx/click");
        BIND(back, 1, "/input/circle_mndx/click");
        BIND(recenter, 0, "/input/triangle_mndx/click");
        BIND(menu, 0, "/input/share_mndx/click");
        break;
    default:
        return XR_ERROR_VALIDATION_FAILURE;
    }
#undef BIND
    XrPath profile;
    result = xrStringToPath(input->instance, profile_path, &profile);
    if (XR_FAILED(result)) return result;
    XrInteractionProfileSuggestedBinding info = {0};
    info.type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING;
    info.interactionProfile = profile;
    info.countSuggestedBindings = count;
    info.suggestedBindings = bindings;
    return xrSuggestInteractionProfileBindings(input->instance, &info);
}

static inline XrResult swiftxr_create_controller_input(void *instance, void *session,
                                                       int psvr2_sense_profile, int generic_profile,
                                                       SwiftXRControllerInput **out_input) {
    *out_input = NULL;
    SwiftXRControllerInput *input = calloc(1, sizeof(*input));
    if (!input) return XR_ERROR_OUT_OF_MEMORY;
    input->instance = (XrInstance)instance;
    input->session = (XrSession)session;
    XrResult result;
#define CHECK(call) do { result = (call); if (XR_FAILED(result)) goto fail; } while (0)
    CHECK(xrStringToPath(input->instance, "/user/hand/left", &input->hands[0]));
    CHECK(xrStringToPath(input->instance, "/user/hand/right", &input->hands[1]));
    XrActionSetCreateInfo set = {0};
    set.type = XR_TYPE_ACTION_SET_CREATE_INFO;
    strcpy(set.actionSetName, "panel_input");
    strcpy(set.localizedActionSetName, "Panel input");
    CHECK(xrCreateActionSet(input->instance, &set, &input->set));
    CHECK(swiftxr_input_action(input, "aim", XR_ACTION_TYPE_POSE_INPUT, &input->aim));
    CHECK(swiftxr_input_action(input, "select", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->select));
    CHECK(swiftxr_input_action(input, "primary", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->primary));
    CHECK(swiftxr_input_action(input, "grip", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->grip));
    CHECK(swiftxr_input_action(input, "back", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->back));
    CHECK(swiftxr_input_action(input, "menu", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->menu));
    CHECK(swiftxr_input_action(input, "home", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->home));
    CHECK(swiftxr_input_action(input, "recenter", XR_ACTION_TYPE_BOOLEAN_INPUT, &input->recenter));
    CHECK(swiftxr_input_action(input, "scroll", XR_ACTION_TYPE_VECTOR2F_INPUT, &input->stick));
    CHECK(swiftxr_input_suggest(input, SWIFTXR_PROFILE_TOUCH));
    CHECK(swiftxr_input_suggest(input, SWIFTXR_PROFILE_SIMPLE));
    // Optional profiles: their extensions are enabled, so failure is a runtime
    // problem with that profile alone; keep the others working.
    if (generic_profile && XR_FAILED(swiftxr_input_suggest(input, SWIFTXR_PROFILE_GENERIC)))
        fprintf(stderr, "SwiftXR: generic controller bindings were rejected\n");
    if (psvr2_sense_profile && XR_FAILED(swiftxr_input_suggest(input, SWIFTXR_PROFILE_PSVR2_SENSE)))
        fprintf(stderr, "SwiftXR: PS VR2 Sense bindings were rejected\n");
    for (int i = 0; i < 2; i++) {
        XrActionSpaceCreateInfo space = {0};
        space.type = XR_TYPE_ACTION_SPACE_CREATE_INFO;
        space.action = input->aim;
        space.subactionPath = input->hands[i];
        space.poseInActionSpace.orientation.w = 1;
        CHECK(xrCreateActionSpace(input->session, &space, &input->spaces[i]));
    }
    XrSessionActionSetsAttachInfo attach = {0};
    attach.type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO;
    attach.countActionSets = 1;
    attach.actionSets = &input->set;
    CHECK(xrAttachSessionActionSets(input->session, &attach));
#undef CHECK
    *out_input = input;
    return XR_SUCCESS;
fail:
    swiftxr_destroy_controller_input(input);
    return result;
}

static inline XrResult swiftxr_input_boolean(SwiftXRControllerInput *input, XrAction action,
                                            XrPath hand, uint32_t *value) {
    XrActionStateGetInfo get = {0};
    get.type = XR_TYPE_ACTION_STATE_GET_INFO;
    get.action = action;
    get.subactionPath = hand;
    XrActionStateBoolean state = {0};
    state.type = XR_TYPE_ACTION_STATE_BOOLEAN;
    XrResult result = xrGetActionStateBoolean(input->session, &get, &state);
    *value = state.isActive && state.currentState;
    return result;
}

static inline XrResult swiftxr_poll_controller_input(SwiftXRControllerInput *input, void *base_space,
                                                     int64_t time, SwiftXRControllerState *out) {
    memset(out, 0, sizeof(*out));
    XrActiveActionSet active = {input->set, XR_NULL_PATH};
    XrActionsSyncInfo sync = {0};
    sync.type = XR_TYPE_ACTIONS_SYNC_INFO;
    sync.countActiveActionSets = 1;
    sync.activeActionSets = &active;
    XrResult result = xrSyncActions(input->session, &sync);
    if (result == XR_SESSION_NOT_FOCUSED) return XR_SUCCESS;
    if (XR_FAILED(result)) return result;
    out->focused = 1;
#define CHECK(call) do { result = (call); if (XR_FAILED(result)) return result; } while (0)
    for (int i = 0; i < 2; i++) {
        SwiftXRHandInput *hand = i == 0 ? &out->left : &out->right;
        XrActionStateGetInfo get = {0};
        get.type = XR_TYPE_ACTION_STATE_GET_INFO;
        get.subactionPath = input->hands[i];
        get.action = input->aim;
        XrActionStatePose pose = {0};
        pose.type = XR_TYPE_ACTION_STATE_POSE;
        CHECK(xrGetActionStatePose(input->session, &get, &pose));
        hand->active = pose.isActive;
        if (pose.isActive) {
            XrSpaceLocation location = {0};
            location.type = XR_TYPE_SPACE_LOCATION;
            CHECK(xrLocateSpace(input->spaces[i], (XrSpace)base_space, time, &location));
            const XrSpaceLocationFlags valid = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
            hand->pose_valid = (location.locationFlags & valid) == valid;
            hand->pose = location.pose;
        }
        CHECK(swiftxr_input_boolean(input, input->select, input->hands[i], &hand->select));
        CHECK(swiftxr_input_boolean(input, input->primary, input->hands[i], &hand->primary));
        CHECK(swiftxr_input_boolean(input, input->grip, input->hands[i], &hand->grip));
        CHECK(swiftxr_input_boolean(input, input->back, input->hands[i], &hand->back));
        CHECK(swiftxr_input_boolean(input, input->menu, input->hands[i], &hand->menu));
        CHECK(swiftxr_input_boolean(input, input->home, input->hands[i], &hand->home));
        CHECK(swiftxr_input_boolean(input, input->recenter, input->hands[i], &hand->recenter));
        get.action = input->stick;
        XrActionStateVector2f stick = {0};
        stick.type = XR_TYPE_ACTION_STATE_VECTOR2F;
        CHECK(xrGetActionStateVector2f(input->session, &get, &stick));
        if (stick.isActive) { hand->x = stick.currentState.x; hand->y = stick.currentState.y; }
    }
#undef CHECK
    return XR_SUCCESS;
}
