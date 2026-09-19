-- Gentle Seikret Weapon Swap
-- Monster Hunter Wilds / REFramework Lua mod
--
-- Behaviour:
--   Use the game's normal "call Seikret and change weapon" shortcut.
--   The Seikret is still called and must reach the hunter, but the hunter
--   stays on the ground. Once the Seikret is in interaction range, the
--   weapon is swapped on the ground. Drawn use returns to drawn idle; the
--   optional sheathed path returns to sheathed ground idle.

local MOD_NAME = "Gentle Seikret Weapon Swap"
local VERSION = "1.2.0"
local CONFIG_PATH = "GentleSeikretWeaponSwap.json"

-- In the current PC build, the ground D-pad-right shortcut has been observed
-- entering cCallPorter as RIDE (0), even though its command is the
-- call-and-change-weapon action. WP_CHANGE (1) is retained for other control
-- layouts/game paths. Already-mounted use is excluded separately below.
local CALL_TYPE_RIDE = 0
local CALL_TYPE_WEAPON_CHANGE = 1
local JUDGE_RESULT_CALL = 1
local JUDGE_RESULT_SHEATHED_DIRECT = 2
local JUDGE_RESULT_RODE = 3
local JUDGE_RESULT_WP_CALL = 4
local JUDGE_RESULT_WP_DIRECT = 5
local REQUEST_TIMEOUT_FRAMES = 2000

-- All action sequencing is counted in master HunterCharacter.update calls.
-- No wall-clock delay participates in the sheathe/swap/drawn-idle chain.
local GROUND_IDLE_SETTLE_FRAMES = 1
local RIDE_START_FALLBACK_FRAMES = 300
local WEAPON_PAIR_STABLE_FRAMES = 2
local SWAP_RETRY_FRAMES = 3
local DRAWN_IDLE_TIMEOUT_FRAMES = 180
local FINAL_STATE_GUARD_FRAMES = 45

local PHASE = {
    IDLE = "Idle",
    WAITING_FOR_SEIKRET = "Waiting for Seikret",
    SHEATHING = "Sheathing weapon",
    SWAPPING = "Changing weapon",
    WAITING_DRAWN_IDLE = "Waiting one frame for drawn idle",
    COOLDOWN = "Finishing without mounting",
}

local settings = {
    enabled = true,
    keep_sheathed_ground_vanilla = true,
    debug_logging = false,
}

local state = {
    phase = PHASE.IDLE,
    request_frames = 0,
    phase_frames = 0,
    weapon_before_swap = nil,
    weapon_type_before_swap = nil,
    reserve_before_swap = nil,
    reserve_type_before_swap = nil,
    stable_weapon = nil,
    stable_reserve = nil,
    stable_weapon_frames = 0,
    ground_idle_frames = 0,
    swap_attempts = 0,
    swap_retry_frames = 0,
    swap_error_logged = false,
    ride_start_blocked_this_request = false,
    native_ride_transition_seen = false,
    direct_in_range_request = false,
    restore_drawn_after_swap = true,
    weapon_prepared = false,
    draw_attempts = 0,
    last_draw_error = "none",
    draw_error_logged = false,
    mount_flags = nil,
    mount_block_owned = false,
    last_result = "Ready",
    riding_guard_frames = 0,
    weapon_intent_pending = false,
    input_intent_frames = 0,
    input_intent_started_drawn = nil,
    last_debug_judge = nil,
}

local action_id_type = sdk.find_type_definition("ace.ACTION_ID")
local disable_ride_hunter_flag = nil

local function debug_log(format_string, ...)
    if not settings.debug_logging then
        return
    end

    local message = format_string
    if select("#", ...) > 0 then
        message = string.format(format_string, ...)
    end
    log.info(string.format("[%s] %s", MOD_NAME, message))
end

local function clear_debug_state()
    state.draw_attempts = 0
    state.last_debug_judge = nil
end

local function load_settings()
    local loaded = json.load_file(CONFIG_PATH)
    if type(loaded) ~= "table" then
        return
    end

    if type(loaded.enabled) == "boolean" then
        settings.enabled = loaded.enabled
    end
    if type(loaded.keep_sheathed_ground_vanilla) == "boolean" then
        settings.keep_sheathed_ground_vanilla = loaded.keep_sheathed_ground_vanilla
    elseif type(loaded.handle_sheathed_ground) == "boolean" then
        -- Migrate the short-lived development setting with inverted wording.
        settings.keep_sheathed_ground_vanilla = not loaded.handle_sheathed_ground
    end
    if type(loaded.debug_logging) == "boolean" then
        settings.debug_logging = loaded.debug_logging
    end
end

local function save_settings()
    json.dump_file(CONFIG_PATH, settings)
end

local function to_integer(value)
    if type(value) == "number" then
        return math.floor(value)
    end

    local ok, converted = pcall(sdk.to_int64, value)
    if ok and converted ~= nil then
        return math.floor(converted)
    end

    return nil
end

local function get_enum_value(type_name, field_name)
    local type_definition = sdk.find_type_definition(type_name)
    if not type_definition then
        return nil
    end

    local field = type_definition:get_field(field_name)
    if not field then
        return nil
    end

    local ok, value = pcall(function()
        return field:get_data(nil)
    end)
    if not ok then
        return nil
    end

    return to_integer(value)
end

local function safe_call(object, method_name, ...)
    if not object then
        return nil, false
    end

    local arguments = { ... }
    local ok, result = pcall(function()
        return object:call(method_name, table.unpack(arguments))
    end)
    return result, ok
end

local function request_reserve_weapon_swap(hunter)
    -- The v1.042 game metadata still contains this method, but the current
    -- REFramework build does not expose it through Lua's colon proxy. Use the
    -- explicit managed signature while keeping Weapon Swapper's single-call
    -- behavior for each update attempt.
    local ok_call, call_result = pcall(function()
        return hunter:call("changeWeaponFromReserve(System.Boolean)", false)
    end)
    if ok_call then
        return true
    end
    return false, "object:call=" .. tostring(call_result)
end

local function get_master_hunter()
    local player_manager = sdk.get_managed_singleton("app.PlayerManager")
    if not player_manager then
        return nil
    end

    local player_info, ok = safe_call(player_manager, "getMasterPlayerInfo")
    if not ok or not player_info then
        player_info, ok = safe_call(player_manager, "getMasterPlayer")
    end
    if not ok or not player_info then
        return nil
    end

    local hunter, hunter_ok = safe_call(player_info, "get_Character")
    if not hunter_ok then
        return nil
    end
    return hunter
end

local function get_master_seikret()
    local porter_manager = sdk.get_managed_singleton("app.PorterManager")
    if not porter_manager then
        return nil
    end

    local porter_info, ok = safe_call(porter_manager, "getMasterPlayerPorter")
    if not ok or not porter_info then
        return nil
    end

    local porter, porter_ok = safe_call(porter_info, "get_Character")
    if not porter_ok then
        return nil
    end
    return porter
end

local function get_mount_flags()
    local porter = get_master_seikret()
    if not porter then
        return nil
    end

    local context, context_ok = safe_call(porter, "get_Context")
    if not context_ok or not context then
        return nil
    end

    local flags, flags_ok = safe_call(context, "get_PtContinueFlag")
    if not flags_ok then
        return nil
    end
    return flags
end

local function set_mount_block(enabled)
    if disable_ride_hunter_flag == nil then
        return false
    end

    if enabled then
        local flags = get_mount_flags()
        if not flags then
            return false
        end

        if state.mount_flags ~= flags then
            state.mount_flags = flags
            state.mount_block_owned = false
        end

        local check_ok, was_on = pcall(function()
            return flags:isOn(disable_ride_hunter_flag)
        end)
        if not check_ok then
            check_ok, was_on = pcall(function()
                return flags:check(disable_ride_hunter_flag)
            end)
        end

        if check_ok and was_on then
            -- Another game system or mod owns this flag. Do not clear it later.
            return true
        end

        local on_ok = pcall(function()
            flags:on(disable_ride_hunter_flag)
        end)
        if on_ok then
            state.mount_block_owned = true
        end
        return on_ok
    end

    if state.mount_flags and state.mount_block_owned then
        pcall(function()
            state.mount_flags:off(disable_ride_hunter_flag)
        end)
    end
    state.mount_flags = nil
    state.mount_block_owned = false
    return true
end

local function reset_request_state()
    state.request_frames = 0
    state.phase_frames = 0
    state.weapon_before_swap = nil
    state.weapon_type_before_swap = nil
    state.reserve_before_swap = nil
    state.reserve_type_before_swap = nil
    state.stable_weapon = nil
    state.stable_reserve = nil
    state.stable_weapon_frames = 0
    state.ground_idle_frames = 0
    state.swap_attempts = 0
    state.swap_retry_frames = 0
    state.swap_error_logged = false
    state.ride_start_blocked_this_request = false
    state.native_ride_transition_seen = false
    state.direct_in_range_request = false
    state.restore_drawn_after_swap = true
    state.weapon_prepared = false
    state.draw_attempts = 0
    state.last_draw_error = "none"
    state.draw_error_logged = false
    state.weapon_intent_pending = false
    state.input_intent_frames = 0
    state.input_intent_started_drawn = nil
end

local function finish_request(message)
    debug_log(
        "Flow finished: %s (requestFrames=%d, phase=%s)",
        message or "Ready",
        state.request_frames,
        state.phase
    )
    set_mount_block(false)
    reset_request_state()
    state.phase = PHASE.IDLE
    state.last_result = message or "Ready"
end

local function enter_phase(phase)
    state.phase = phase
    state.phase_frames = 0
end

local function make_action_id(category, index)
    if not action_id_type then
        return nil
    end

    local action_id = ValueType.new(action_id_type)
    sdk.set_native_field(action_id, action_id_type, "_Category", category)
    sdk.set_native_field(action_id, action_id_type, "_Index", index)
    return action_id
end

local function is_weapon_drawn(hunter)
    local ok, drawn = pcall(function()
        return hunter:checkWeaponOn()
    end)
    if ok then
        return drawn == true
    end

    ok, drawn = pcall(function()
        return hunter:get_IsWeaponOn()
    end)
    return ok and drawn == true
end

local function is_seikret_in_range(hunter)
    local communicator, ok = safe_call(hunter, "get_PorterComm")
    if not ok or not communicator then
        return false
    end

    local in_range, range_ok = safe_call(communicator, "get_IsRiderWithinRanged")
    return range_ok and in_range == true
end

local function is_seikret_being_ridden()
    local porter = get_master_seikret()
    if not porter then
        return false
    end

    local ok, riding = pcall(function()
        return porter:get_IsRiding()
    end)
    if ok and riding == true then
        return true
    end
    return false
end

local function is_local_riding_or_just_judged_rode()
    return is_seikret_being_ridden()
        or state.riding_guard_frames > 0
end

local function request_simple_action(hunter, category, index)
    local action_id = make_action_id(category, index)
    if not action_id then
        return false
    end

    local ok = pcall(function()
        local sub_action_controller = hunter:get_SubActionController()
        if sub_action_controller then
            sub_action_controller:endActionRequest()
        end
        hunter:changeActionRequest(0, action_id, false)
    end)
    return ok
end

local function request_sheathe(hunter)
    return request_simple_action(hunter, 0, 1)
end

local function request_ground_idle(hunter)
    return request_simple_action(hunter, 0, 14)
end

local function request_drawn_idle(hunter)
    -- Weapon Swapper's "Skip weapon ready animation" path: category 1,
    -- index 14 is the idle stance with the weapon already drawn.
    local action_id = make_action_id(1, 14)
    if not action_id then
        return false, "could not create ace.ACTION_ID(1, 14)"
    end

    -- The shorthand colon proxy is absent or ambiguous for some methods in
    -- current REFramework builds. CatLib uses this exact managed signature.
    local ok, result = pcall(function()
        return hunter:call(
            "changeActionRequest(app.AppActionDef.LAYER, ace.ACTION_ID, System.Boolean)",
            0,
            action_id,
            false
        )
    end)
    if not ok then
        return false, tostring(result)
    end
    return true, tostring(result)
end

local function prepare_weapon_if_needed(hunter)
    local ok = pcall(function()
        local weapon_type = hunter:get_WeaponType()
        if weapon_type == 10 then
            local insect = hunter:get_Wp10Insect()
            if insect and not insect:get_field("_IsSetup") then
                insect:doStart()
            end
        end
    end)
    return ok
end

local function mark_ride_blocked()
    state.ride_start_blocked_this_request = true
    state.ground_idle_frames = 0
    state.stable_weapon = nil
    state.stable_reserve = nil
    state.stable_weapon_frames = 0
end

local function on_porter_ride_start_enter()
    if not settings.enabled or state.phase == PHASE.IDLE then
        return sdk.PreHookResult.CALL_ORIGINAL
    end

    -- This is the actual transition into mounting, rather than the upstream
    -- command judge. The request was armed only from the local ground shortcut,
    -- so already-mounted vanilla weapon changes never reach this active path.
    -- A delayed ride-start can arrive after the weapon has already changed.
    -- It still must be skipped, but requesting ground idle at that point would
    -- overwrite the restored drawn state.
    if state.phase == PHASE.WAITING_DRAWN_IDLE or state.phase == PHASE.COOLDOWN then
        state.ride_start_blocked_this_request = true
        debug_log("Delayed ride start blocked without changing final stance")
        return sdk.PreHookResult.SKIP_ORIGINAL
    end

    local hunter = get_master_hunter()
    local idle_requested = hunter ~= nil and request_ground_idle(hunter)
    -- Wait a deterministic number of hunter updates after replacing the ride
    -- action with ground idle before touching the weapon object.
    mark_ride_blocked()
    state.last_result = idle_requested
        and "Blocked ride-start; returning to ground idle"
        or "Blocked ride-start"
    debug_log(
        "Ride start blocked; ground idle requested=%s",
        tostring(idle_requested)
    )
    return sdk.PreHookResult.SKIP_ORIGINAL
end

local function begin_weapon_change_call(call_type, started_drawn_override, direct_override)
    if not settings.enabled then
        return false
    end

    local hunter = get_master_hunter()
    if not hunter then
        return false
    end

    local started_drawn = started_drawn_override
    if started_drawn == nil then
        started_drawn = is_weapon_drawn(hunter)
    end
    if not started_drawn and settings.keep_sheathed_ground_vanilla then
        return false
    end

    if state.phase ~= PHASE.IDLE then
        finish_request("Previous request replaced")
    end

    reset_request_state()
    enter_phase(PHASE.WAITING_FOR_SEIKRET)
    if not settings.debug_logging then
        clear_debug_state()
    end
    state.restore_drawn_after_swap = started_drawn
    if direct_override == nil then
        state.direct_in_range_request = is_seikret_in_range(hunter)
    else
        state.direct_in_range_request = direct_override
    end
    state.last_result = string.format("Ground call detected (CallType %d)", call_type)

    -- The WP_CALL judge post-hook has already obtained the native result and
    -- will return it unchanged. Block riding immediately after that decision,
    -- before the game can create the automatic mount transition.
    local blocked = set_mount_block(true)
    if state.direct_in_range_request then
        -- No summon or native ride/change chain is needed when the Seikret is
        -- already beside the hunter. Mark the ground path ready now; the
        -- upcoming CallPorter entry is skipped by on_call_porter_enter().
        mark_ride_blocked()
    end
    debug_log(
        "Ground flow started: CallType=%d, startedDrawn=%s, inRange=%s, ride block=%s; timeout=%d ground=%d pair=%d swapRetry=%d finalGuard=%d",
        call_type,
        tostring(started_drawn),
        tostring(state.direct_in_range_request),
        tostring(blocked),
        REQUEST_TIMEOUT_FRAMES,
        GROUND_IDLE_SETTLE_FRAMES,
        WEAPON_PAIR_STABLE_FRAMES,
        SWAP_RETRY_FRAMES,
        FINAL_STATE_GUARD_FRAMES
    )
    if not blocked then
        state.last_result = "Waiting for Seikret; ride block is not ready"
    end
    return true
end

local function get_call_type(call_action)
    if not call_action then
        return nil
    end

    local value, ok = safe_call(call_action, "get_CallType")
    if ok then
        return to_integer(value)
    end

    local candidates = { "_CallType", "<CallType>k__BackingField" }
    for _, field_name in ipairs(candidates) do
        local field_ok, field_value = pcall(function()
            return call_action:get_field(field_name)
        end)
        if field_ok and field_value ~= nil then
            return to_integer(field_value)
        end
    end

    return nil
end

local function consume_input_intent()
    local started_drawn = state.input_intent_started_drawn
    state.weapon_intent_pending = false
    state.input_intent_frames = 0
    state.input_intent_started_drawn = nil
    return started_drawn
end

local function on_call_porter_enter(args)
    local call_action = sdk.to_managed_object(args[2])
    local call_type = get_call_type(call_action)
    debug_log("CallPorter entered: CallType=%s, phase=%s", tostring(call_type), state.phase)

    if state.phase ~= PHASE.IDLE and state.direct_in_range_request then
        debug_log("CallPorter skipped: Seikret was already in range at input")
        return sdk.PreHookResult.SKIP_ORIGINAL
    end

    if state.phase == PHASE.SWAPPING then
        state.native_ride_transition_seen = true
    end

    if call_type == CALL_TYPE_WEAPON_CHANGE then
        -- Type 1 remains vanilla unless the optional ground-sheathed behavior
        -- is enabled. Already-mounted changes are always excluded.
        if settings.keep_sheathed_ground_vanilla or state.phase ~= PHASE.IDLE then
            return
        end
        if is_local_riding_or_just_judged_rode() then
            state.last_result = "Ignored: already riding; vanilla swap preserved"
            debug_log("CallType 1 left vanilla: hunter is already riding")
            return
        end

        local started_drawn = consume_input_intent()
        local took_over = begin_weapon_change_call(call_type, started_drawn)
        if took_over and state.direct_in_range_request then
            debug_log("CallPorter skipped: direct in-range Type 1 takeover")
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        return
    elseif call_type == CALL_TYPE_RIDE then
        -- WP_CHANGE (1) can transition into RIDE (0) as part of the same
        -- command chain. Do not reinterpret or overwrite an active request.
        if state.phase ~= PHASE.IDLE then
            return
        end

        -- Actual trace on this build:
        --   change shortcut: judge=WP_CALL(4), then RIDE(0) ~1 ms later
        --   normal summon:   judge=CALL(1), then RIDE(0)
        -- Consume the frame-level intent armed by the judge post-hook.
        if not state.weapon_intent_pending and state.input_intent_frames <= 0 then
            state.last_result = "Ignored: normal ground summon"
            debug_log("CallType 0 left vanilla: no weapon-change intent")
            return
        end

        local started_drawn = consume_input_intent()
        if is_local_riding_or_just_judged_rode() then
            state.last_result = "Ignored: already riding; vanilla swap preserved"
            debug_log("Ground flow ignored: hunter is already riding")
            return
        end

        local took_over = begin_weapon_change_call(call_type, started_drawn)
        if took_over and state.direct_in_range_request then
            debug_log("CallPorter skipped: direct in-range Type 0 takeover")
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end
end

local function update_waiting_for_seikret(hunter)
    if not is_seikret_in_range(hunter) then
        return
    end

    if not state.mount_block_owned and not set_mount_block(true) then
        finish_request("Cancelled: could not block automatic mounting")
        return
    end

    if is_weapon_drawn(hunter) then
        if request_sheathe(hunter) then
            enter_phase(PHASE.SHEATHING)
            state.last_result = "Seikret arrived; sheathing"
            debug_log("Seikret in range; sheathe action requested")
        else
            finish_request("Cancelled: could not request sheathe")
        end
    else
        enter_phase(PHASE.SWAPPING)
        state.last_result = "Seikret arrived; changing weapon"
        debug_log("Seikret in range; hunter already sheathed")
    end
end

local function update_sheathing(hunter)
    if is_weapon_drawn(hunter) then
        return
    end

    enter_phase(PHASE.SWAPPING)
    state.last_result = "Weapon sheathed; changing weapon"
    debug_log("Sheathe confirmed; entering weapon swap phase")
end

local function update_swapping(hunter)
        -- When the Seikret is already next to the hunter, DISABLE_RIDE_HUNTER
        -- can prevent cPorterRideStart.doEnter from being reached at all. Do
        -- not deadlock waiting for a hook that will never run. The native
        -- chain normally reaches judge=CALL shortly afterward, though, so the
        -- fallback is permitted only after a long quiet window with no native
        -- downstream transition at all.
        if not state.ride_start_blocked_this_request
            and not state.native_ride_transition_seen
            and state.phase_frames >= RIDE_START_FALLBACK_FRAMES
        then
            local idle_requested = request_ground_idle(hunter)
            mark_ride_blocked()
            state.last_result = idle_requested
                and "Ride start absent; continuing from ground idle"
                or "Ride start absent; continuing on ground"
            debug_log(
                "Ride-start fallback after %d frame(s); ground idle requested=%s",
                state.phase_frames,
                tostring(idle_requested)
            )
            return
        end

        -- Only call after the real ride-start action has been intercepted and
        -- the replacement ground-idle state has existed for one hunter update,
        -- or after the deterministic fallback above performs the same reset.
        if not state.ride_start_blocked_this_request
            or state.ground_idle_frames < GROUND_IDLE_SETTLE_FRAMES
        then
            return
        end

        state.swap_retry_frames = state.swap_retry_frames + 1

        local pair_ok, active_weapon, reserve_weapon = pcall(function()
            return hunter:get_Weapon(), hunter:get_ReserveWeapon()
        end)
        if not pair_ok or active_weapon == nil or reserve_weapon == nil then
            state.last_result = "Waiting for active/reserve weapon objects"
            return
        end

        -- The ride cancellation itself rebuilds get_Weapon(), which caused
        -- v0.11's false positive. Require the active/reserve pair to remain
        -- identical across two hunter updates before taking the snapshot.
        if active_weapon ~= state.stable_weapon or reserve_weapon ~= state.stable_reserve then
            state.stable_weapon = active_weapon
            state.stable_reserve = reserve_weapon
            state.stable_weapon_frames = 1
            state.last_result = "Waiting for stable ground weapon pair"
            return
        end
        state.stable_weapon_frames = state.stable_weapon_frames + 1
        if state.stable_weapon_frames < WEAPON_PAIR_STABLE_FRAMES then
            return
        end

        if state.weapon_before_swap == nil then
            state.weapon_before_swap = active_weapon
            state.reserve_before_swap = reserve_weapon
            local active_type_ok, active_type = pcall(function()
                return hunter:get_WeaponType()
            end)
            local reserve_type_ok, reserve_type = pcall(function()
                return reserve_weapon:get_field("_WpType")
            end)
            state.weapon_type_before_swap = active_type_ok and to_integer(active_type) or nil
            state.reserve_type_before_swap = reserve_type_ok and to_integer(reserve_type) or nil
        end

        -- A successful swap may become visible on the update after the call.
        local active_is_old_reserve = active_weapon == state.reserve_before_swap
        local reserve_is_old_active = reserve_weapon == state.weapon_before_swap
        local active_type_ok, active_type = pcall(function()
            return hunter:get_WeaponType()
        end)
        active_type = active_type_ok and to_integer(active_type) or nil
        local type_pair_swapped = state.weapon_type_before_swap ~= state.reserve_type_before_swap
            and active_type ~= nil
            and active_type == state.reserve_type_before_swap

        if active_is_old_reserve or reserve_is_old_active or type_pair_swapped then
            if state.restore_drawn_after_swap then
                enter_phase(PHASE.WAITING_DRAWN_IDLE)
                state.last_result = "Reserve weapon change confirmed; waiting one frame"
                debug_log(
                    "Weapon swap confirmed after %d request(s); drawn-idle request begins next frame",
                    state.swap_attempts
                )
            else
                local idle_ok = request_ground_idle(hunter)
                enter_phase(PHASE.COOLDOWN)
                state.last_result = "Weapon changed; remaining sheathed"
                debug_log(
                    "Weapon swap confirmed after %d request(s); sheathed ground idle requested=%s",
                    state.swap_attempts,
                    tostring(idle_ok)
                )
            end
            return
        end

        if state.swap_attempts > 0 and state.swap_retry_frames < SWAP_RETRY_FRAMES then
            return
        end
        state.swap_retry_frames = 0
        local swap_ok, call_detail = request_reserve_weapon_swap(hunter)
        state.swap_attempts = state.swap_attempts + 1
        debug_log("Reserve weapon swap request #%d: success=%s", state.swap_attempts, tostring(swap_ok))
        if not swap_ok then
            state.last_result = "Weapon change request failed; retrying"
            if not state.swap_error_logged then
                state.swap_error_logged = true
                log.error(string.format(
                    "[%s] Reserve weapon swap failed: %s",
                    MOD_NAME,
                    tostring(call_detail)
                ))
            end
        else
            state.last_result = "Changing weapon"
        end
end

local function update_waiting_drawn_idle(hunter)
    if is_weapon_drawn(hunter) then
        prepare_weapon_if_needed(hunter)
        state.weapon_prepared = true
        enter_phase(PHASE.COOLDOWN)
        state.last_result = "Weapon changed; drawn idle confirmed"
        debug_log("Drawn idle confirmed after %d request(s)", state.draw_attempts)
        return
    end

    if state.phase_frames > DRAWN_IDLE_TIMEOUT_FRAMES then
        enter_phase(PHASE.COOLDOWN)
        state.last_result = "Weapon changed; drawn idle timed out after 180 frames"
        log.error(string.format(
            "[%s] Drawn idle was not confirmed; last request error: %s",
            MOD_NAME,
            state.last_draw_error
        ))
        return
    end

    -- The first request occurs exactly one hunter update after swap
    -- confirmation. Keep requesting the same no-animation idle action on
    -- fixed frame intervals until the game confirms checkWeaponOn().
    local drawn_idle_ok, detail = request_drawn_idle(hunter)
    if settings.debug_logging then
        state.draw_attempts = state.draw_attempts + 1
        if state.draw_attempts == 1 or state.draw_attempts % 30 == 0 then
            debug_log(
                "Drawn-idle request #%d: success=%s",
                state.draw_attempts,
                tostring(drawn_idle_ok)
            )
        end
    end
    if drawn_idle_ok then
        state.last_draw_error = "none"
        state.last_result = "Restoring drawn idle"
    else
        state.last_draw_error = tostring(detail)
        state.last_result = "Drawn-idle request failed; retrying"
        if not state.draw_error_logged then
            state.draw_error_logged = true
            log.error(string.format(
                "[%s] Exact drawn-idle action request failed: %s",
                MOD_NAME,
                state.last_draw_error
            ))
        end
    end
end

local function update_cooldown(hunter)
    set_mount_block(true)
    local drawn = is_weapon_drawn(hunter)
    if not state.restore_drawn_after_swap and drawn then
        request_ground_idle(hunter)
    elseif not state.weapon_prepared and drawn then
        state.weapon_prepared = prepare_weapon_if_needed(hunter)
    end

    if state.phase_frames < FINAL_STATE_GUARD_FRAMES then
        return
    end

    drawn = is_weapon_drawn(hunter)
    if state.restore_drawn_after_swap then
        finish_request(drawn
            and "Weapon changed successfully; drawn idle confirmed"
            or "Weapon changed, but drawn idle was not confirmed")
    else
        finish_request(drawn
            and "Weapon changed, but sheathed idle was not confirmed"
            or "Weapon changed successfully; remained sheathed")
    end
end

local PHASE_UPDATERS = {
    [PHASE.WAITING_FOR_SEIKRET] = update_waiting_for_seikret,
    [PHASE.SHEATHING] = update_sheathing,
    [PHASE.SWAPPING] = update_swapping,
    [PHASE.WAITING_DRAWN_IDLE] = update_waiting_drawn_idle,
    [PHASE.COOLDOWN] = update_cooldown,
}

local function update_request(hunter)
    if state.phase == PHASE.IDLE then
        return
    end

    state.request_frames = state.request_frames + 1
    state.phase_frames = state.phase_frames + 1
    if state.ride_start_blocked_this_request then
        state.ground_idle_frames = state.ground_idle_frames + 1
    end

    if not settings.enabled then
        finish_request("Cancelled: mod disabled")
        return
    end
    if state.request_frames > REQUEST_TIMEOUT_FRAMES then
        finish_request("Cancelled: Seikret/swap timeout")
        return
    end

    -- A skipped ride-start may report IsRiding briefly despite the hunter
    -- remaining on foot; only an unblocked transition cancels the request.
    if is_seikret_being_ridden()
        and not state.ride_start_blocked_this_request
        and state.phase ~= PHASE.SWAPPING
    then
        finish_request("Cancelled: vanilla riding already started")
        return
    end

    set_mount_block(true)
    local updater = PHASE_UPDATERS[state.phase]
    if updater then
        updater(hunter)
    end
end

local function install_hook(type_name, method_name, pre_hook)
    local type_definition = sdk.find_type_definition(type_name)
    if not type_definition then
        log.error(string.format("[%s] Missing type: %s", MOD_NAME, type_name))
        return false
    end

    local method = type_definition:get_method(method_name)
    if not method and not string.find(method_name, "(", 1, true) then
        method = type_definition:get_method(method_name .. "()")
    end
    if not method then
        log.error(string.format("[%s] Missing method: %s.%s", MOD_NAME, type_name, method_name))
        return false
    end

    sdk.hook(method, pre_hook, nil)
    return true
end

local function get_type_full_name(type_definition)
    if not type_definition then
        return "<none>"
    end

    local ok, full_name = pcall(function()
        return type_definition:get_full_name()
    end)
    if ok and full_name then
        return full_name
    end
    return tostring(type_definition)
end

local function begin_from_weapon_judge(force_direct, require_drawn)
    local hunter = get_master_hunter()
    local request_active = state.phase ~= PHASE.IDLE
    local started_drawn = state.input_intent_started_drawn
    if started_drawn == nil and hunter ~= nil then
        started_drawn = is_weapon_drawn(hunter)
    end

    local stance_allowed = started_drawn == true
        or (not require_drawn and not settings.keep_sheathed_ground_vanilla)
    local ground_allowed = not is_seikret_being_ridden()
        or (request_active and state.ride_start_blocked_this_request)
    local intent_allowed = not force_direct
        or state.input_intent_frames > 0
        or request_active
    local should_take_over = settings.enabled
        and hunter ~= nil
        and ground_allowed
        and stance_allowed
        and intent_allowed

    state.weapon_intent_pending = should_take_over
    if should_take_over and state.phase == PHASE.IDLE then
        begin_weapon_change_call(
            CALL_TYPE_WEAPON_CHANGE,
            started_drawn,
            force_direct and true or nil
        )
    end
    return should_take_over
end

local function handle_weapon_judge_result(result, method_name)
    if result == nil or result < 0 or result > 7 then
        return false
    end

    if settings.debug_logging and state.last_debug_judge ~= result then
        state.last_debug_judge = result
        debug_log("Weapon-change judge %s returned %d", method_name, result)
    end

    if result == JUDGE_RESULT_WP_CALL then
        -- Out-of-range drawn shortcut. Start now because some builds proceed
        -- toward riding without entering either CallPorter hook.
        begin_from_weapon_judge(false, true)
    elseif result == JUDGE_RESULT_WP_DIRECT
        or result == JUDGE_RESULT_SHEATHED_DIRECT
    then
        -- Direct results can bypass CallPorter. Returning true tells the post
        -- hook to replace the accepted native result with NONE (0).
        return begin_from_weapon_judge(true, false)
    elseif result == JUDGE_RESULT_CALL then
        if state.phase == PHASE.SWAPPING then
            state.native_ride_transition_seen = true
            state.weapon_intent_pending = false
        elseif state.input_intent_frames > 0 then
            -- Out-of-range sheathed shortcut. Start while the dedicated input
            -- marker still exists instead of carrying it to CallPorter.
            begin_from_weapon_judge(false, false)
        else
            state.weapon_intent_pending = false
        end
    elseif result == JUDGE_RESULT_RODE then
        state.riding_guard_frames = 12
        state.weapon_intent_pending = false
    else
        state.weapon_intent_pending = false
    end
    return false
end

local function install_weapon_change_judge_hooks()
    local type_name = "app.btable.PlCommand.cWpChangeCallPorterJudge"
    local type_definition = sdk.find_type_definition(type_name)
    if not type_definition then
        log.error(string.format("[%s] Missing type: %s", MOD_NAME, type_name))
        return
    end

    for _, method in ipairs(type_definition:get_methods()) do
        local method_name = method:get_name()
        local return_type = nil
        local return_ok = pcall(function()
            return_type = method:get_return_type()
        end)
        local return_name = return_ok and get_type_full_name(return_type) or "<unknown>"

        -- Prefer the strongly typed RESULT return. The Int32 fallback is
        -- limited to this one judge class and judge/evaluate-style methods.
        local lower_name = string.lower(method_name)
        local is_result_return = string.find(return_name, "cWpChangeCallPorterJudge.RESULT", 1, true) ~= nil
        local is_int_judge = return_name == "System.Int32" and lower_name == "judge"

        if is_result_return or is_int_judge then
            local hooked_name = method_name
            local hook_ok, hook_error = pcall(function()
                sdk.hook(method, nil, function(retval)
                    local result = to_integer(retval)
                    -- Judge results stay vanilla. Ride interruption happens at
                    -- cPorterRideStart.doEnter, after the Seikret call itself.
                    -- The only exception is an accepted in-range ground
                    -- shortcut: the mod replaces that direct native action,
                    -- so returning NONE (0) prevents a second swap/mount.
                    if handle_weapon_judge_result(result, hooked_name) then
                        debug_log("Native direct judge result %d suppressed", result)
                        return sdk.to_ptr(0)
                    end
                    return retval
                end)
            end)

            if not hook_ok then
                log.error(string.format(
                    "[%s] Could not hook judge method %s: %s",
                    MOD_NAME,
                    hooked_name,
                    tostring(hook_error)
                ))
            end
        end
    end
end

local function install_weapon_change_input_hooks()
    local type_name = "app.btable.PlCommand.cWpChangeCallPorterInputCheck"
    local type_definition = sdk.find_type_definition(type_name)
    if not type_definition then
        log.error(string.format("[%s] Missing type: %s", MOD_NAME, type_name))
        return
    end

    -- Runtime metadata on game build 1.42 exposes executeNormal() as Int32
    -- and success() as Void. success() is reached only when this dedicated
    -- weapon-change input node accepts the command, so it distinguishes the
    -- sheathed weapon-change shortcut from an ordinary Seikret summon.
    local success_method = type_definition:get_method("success")
        or type_definition:get_method("success()")
    if not success_method then
        log.error(string.format("[%s] Missing method: %s.success", MOD_NAME, type_name))
        return
    end

    local hook_ok, hook_error = pcall(function()
        sdk.hook(success_method, function()
            if settings.enabled then
                local hunter = get_master_hunter()
                if hunter ~= nil then
                    state.input_intent_started_drawn = is_weapon_drawn(hunter)
                else
                    state.input_intent_started_drawn = nil
                end
                state.input_intent_frames = 4
                debug_log(
                    "Weapon-change input accepted; intent armed for 4 frames, startedDrawn=%s",
                    tostring(state.input_intent_started_drawn)
                )
            end
        end, nil)
    end)
    if not hook_ok then
        log.error(string.format(
            "[%s] Could not hook input success method: %s",
            MOD_NAME,
            tostring(hook_error)
        ))
    end
end

load_settings()
disable_ride_hunter_flag = get_enum_value(
    "app.PorterDef.CONTINUE_FLAG",
    "DISABLE_RIDE_HUNTER"
)

if disable_ride_hunter_flag == nil then
    log.error(string.format("[%s] DISABLE_RIDE_HUNTER enum was not found; mod will remain inert", MOD_NAME))
    state.last_result = "Unsupported game build: ride-block flag missing"
else
    install_hook("app.PlayerCommonSubAction.cCallPorter", "doEnter", on_call_porter_enter)
    install_hook("app.WpCommonSubAction.cCallPorter", "doEnter", on_call_porter_enter)
    install_weapon_change_input_hooks()
    install_weapon_change_judge_hooks()
    install_hook(
        "app.PlayerCommonSubAction.cPorterRideStart",
        "doEnter",
        on_porter_ride_start_enter
    )

    install_hook("app.HunterCharacter", "update", function(args)
        local hunter = sdk.to_managed_object(args[2])
        if not hunter then
            return
        end

        local master_ok, is_master = pcall(function()
            return hunter:get_IsMaster()
        end)
        if not master_ok or not is_master then
            return
        end

        local action_ok, has_current_action = pcall(function()
            local controller = hunter:get_BaseActionController()
            return controller ~= nil and controller:get_CurrentAction() ~= nil
        end)
        if not action_ok or not has_current_action then
            return
        end

        if state.riding_guard_frames > 0 then
            state.riding_guard_frames = state.riding_guard_frames - 1
        end
        if state.input_intent_frames > 0 then
            state.input_intent_frames = state.input_intent_frames - 1
            if state.input_intent_frames == 0 then
                state.input_intent_started_drawn = nil
            end
        end

        update_request(hunter)
    end)

    log.info(string.format("[%s] v%s loaded", MOD_NAME, VERSION))
end

re.on_draw_ui(function()
    if not imgui.collapsing_header(MOD_NAME .. " v" .. VERSION) then
        return
    end

    local changed
    changed, settings.enabled = imgui.checkbox("Enabled", settings.enabled)
    if changed then
        if not settings.enabled and state.phase ~= PHASE.IDLE then
            finish_request("Cancelled: mod disabled")
        end
        save_settings()
    end

    changed, settings.keep_sheathed_ground_vanilla = imgui.checkbox(
        "Keep sheathed ground behavior vanilla",
        settings.keep_sheathed_ground_vanilla
    )
    if changed then
        if settings.keep_sheathed_ground_vanilla
            and state.phase ~= PHASE.IDLE
            and not state.restore_drawn_after_swap
        then
            finish_request("Cancelled: sheathed ground behavior returned to vanilla")
        end
        save_settings()
    end

    changed, settings.debug_logging = imgui.checkbox("Debug logging", settings.debug_logging)
    if changed then
        save_settings()
        clear_debug_state()
        if settings.debug_logging then
            debug_log("Debug logging enabled; detailed events will be written to re2_framework_log.txt")
        end
    end

    imgui.text("Ground + drawn shortcut: call, swap without mounting, stay drawn.")
    if settings.keep_sheathed_ground_vanilla then
        imgui.text("Ground + sheathed shortcut: vanilla.")
    else
        imgui.text("Ground + sheathed shortcut: swap without mounting, stay sheathed.")
    end
    imgui.text("Already-mounted weapon changes always stay vanilla.")
    imgui.separator()
    imgui.text("State: " .. state.phase)
    imgui.text("Last result: " .. state.last_result)

    if state.phase ~= PHASE.IDLE and imgui.button("Cancel pending request") then
        finish_request("Cancelled manually")
    end
end)
