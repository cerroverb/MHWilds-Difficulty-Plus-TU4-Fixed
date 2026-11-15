-- Focus Mode rules prototype, round 6.
-- With a melee weapon drawn, the focus button on its own no longer enters Focus Mode, and the focus
-- reticle stays hidden. Focus button + R1 still performs a Focus Strike, turned only the way a normal
-- attack turns, never towards the camera. R1 on its own keeps its normal use.
-- Monster wounds are highlighted while the focus button is held.
-- Ranged weapons and a sheathed weapon keep the game's behavior.
-- Switches are in the REFramework menu under "Focus Rules" and are saved to reframework/data/FocusRules.json.
-- With "Log focus state" on, focus state, the focus button and actions are written to re2_framework_log.txt.
-- Logging is on in test builds and off in releases. Its per-character hook is only installed when it
-- is on at script load.
--
-- Method names come from the game's il2cpp_dump.json (REFramework SDK dump).
-- Hook patterns follow Bimmr's MHWS-Weapon-Swapper (HunterCharacter.update, get_IsMaster,
-- BaseActionController:get_CurrentAction, json config) and MHWS-Buffer (getMasterPlayerInfo,
-- SKIP_ORIGINAL, replacing a return value with sdk.to_ptr): https://github.com/Bimmr
-- Reading keys follows getKey() on the command controller's merged input in DerKleineLi's MHWs-MIGGA
-- (Kinsect_dont_come_back.lua): https://github.com/DerKleineLi/MHWs-MIGGA
-- The wound highlight follows kmy0's HudController (hud/hook/options/scar.lua), which sets
-- app.cEnemyLoopEffectHighlight._IsAim from a hook on isActivate(), and hiding the reticle follows its
-- slinger_reticle element (findDisplayControl, _TargetControl, set_ForceInvisible):
-- https://github.com/kmy0/HudController

local CONFIG_PATH = "FocusRules.json"

local settings = {
    log_state = true, -- false in releases
    focus_strike_only = true,
    no_aim_turning = true,
    wounds_only_while_focus_held = true,
    hide_focus_reticle = true,
}

-- app.WeaponDef.TYPE: LONG_SWORD = 0 through ROD = 10 are melee. BOW, HEAVY_BOWGUN and LIGHT_BOWGUN follow.
local LAST_MELEE_WEAPON_TYPE = 10
-- app.PlayerKey.PAD
local PAD_KEY_FOCUS_STRIKE = 3 -- ATTACK_SP_B, R1 on a pad (round 4 log)
local PAD_KEY_FOCUS = 18 -- AIM
-- app.HunterDef.ACTION_START_TURN_TYPE: the _AIM variants turn towards the camera.
local START_TURN_FOR_AIM = { [3] = 1, [4] = 2 } -- LV1_AIM -> LV1, LV2_AIM -> LV2

-- Frames the focus button is held on for the game after a Focus Strike press, so Focus Mode can
-- start, and frames it stays on after the strike press is passed to the game.
local STRIKE_WINDOW_FRAMES = 30
local FRAMES_AFTER_STRIKE = 10

local function load_settings()
    local saved = json.load_file(CONFIG_PATH)
    if not saved then return end
    for key in pairs(settings) do
        if saved[key] ~= nil then
            settings[key] = saved[key]
        end
    end
end

load_settings()

local function get_master_hunter()
    local player_manager = sdk.get_managed_singleton("app.PlayerManager")
    if not player_manager then return nil end
    local player_info = player_manager:getMasterPlayerInfo()
    if not player_info then return nil end
    return player_info:get_Character()
end

local function is_melee(hunter)
    local weapon_type = hunter:get_WeaponType()
    return weapon_type >= 0 and weapon_type <= LAST_MELEE_WEAPON_TYPE
end

-- In round 1 two hunter objects reported get_IsMaster every frame, so the master is matched
-- against the character from PlayerManager instead. Its address is looked up once per frame,
-- and only the address is kept, so no hook calls into an object from an earlier frame.
local master_hunter_address = nil
local hide_focus_reticle_now = false

re.on_frame(function()
    local master = get_master_hunter()
    master_hunter_address = master and master:get_address() or nil
    local melee_drawn = master ~= nil and is_melee(master) and master:get_IsWeaponOn()
    hide_focus_reticle_now = settings.hide_focus_reticle and settings.focus_strike_only and melee_drawn
end)

local function is_master_hunter(hunter)
    return hunter ~= nil and master_hunter_address ~= nil and hunter:get_address() == master_hunter_address
end

local function is_master_melee(hunter)
    return is_master_hunter(hunter) and is_melee(hunter)
end

local function is_master_melee_drawn(hunter)
    return is_master_melee(hunter) and hunter:get_IsWeaponOn()
end

local function hunter_from_args(args)
    return sdk.to_managed_object(args[2])
end

local function log_line(text)
    if settings.log_state then
        log.info("[FocusRules] " .. string.format("%.3f ", os.clock()) .. text)
    end
end

-- Focus button state as the player pressed it, read before this script changes it.
local focus_button_held = false

-- Focus Mode stance actions every weapon has (round 1 to 5 logs). While the hunter is still in one
-- of these after the strike press was sent, the game has not started the strike yet.
local FOCUS_STANCE_ACTIONS = { cAimIdle = true, cAimIdleHigh = true, cAimWalk = true, cAimWalkStop = true }

local strike = { frames_left = 0, pending = false, sent = false, start_action = nil }

local function current_action_name(hunter)
    local action = hunter:get_BaseActionController():get_CurrentAction()
    return action and action:get_type_definition():get_name() or "none"
end

local function reset_strike()
    strike.frames_left = 0
    strike.pending = false
    strike.sent = false
end

local function start_strike_window(hunter, strike_key)
    strike.frames_left = STRIKE_WINDOW_FRAMES
    strike.pending = true
    strike.sent = false
    strike.start_action = current_action_name(hunter)
    strike_key:clear()
    log_line("strike armed during " .. strike.start_action)
end

local function send_strike_press(strike_key)
    strike_key:set_On(true)
    strike_key:set_OnTrigger(true)
    if not strike.sent then
        log_line("strike passed to game")
    end
    strike.sent = true
end

-- Keeps Focus Mode on for the game and sends the press once Focus Mode is active. The press is sent
-- again each frame until the hunter leaves the action it was in and the Focus Mode stance actions.
local function hold_focus_for_strike(hunter, focus_key, strike_key)
    strike.frames_left = strike.frames_left - 1
    focus_key:set_On(true)
    if not strike.pending then return end

    local action = current_action_name(hunter)
    if strike.sent and action ~= strike.start_action and not FOCUS_STANCE_ACTIONS[action] then
        strike.pending = false
        strike.frames_left = math.min(strike.frames_left, FRAMES_AFTER_STRIKE)
        log_line("strike ended in " .. action)
    elseif hunter:get_HunterContext():get_IsAim() then
        send_strike_press(strike_key)
    end
    if strike.frames_left == 0 and strike.pending then
        log_line("strike window ended in " .. action)
    end
end

-- app.PlayerKey.PAD ATTACK_00 to ATTACK_SP_B, logged while the focus button is held to confirm
-- which one the game uses for Focus Strikes.
local ATTACK_KEYS = { 0, 1, 2, 3 }

local function log_attack_presses(input)
    for _, key_index in ipairs(ATTACK_KEYS) do
        if input:getKey(key_index):get_OnTrigger() then
            log_line("attack key " .. key_index .. " pressed with focus button held")
        end
    end
end

-- The command controller merges pad and keyboard input here, before the game reads its commands.
local merging_controller = nil

sdk.hook(sdk.find_type_definition("app.cPlayerCommandController"):get_method("mergeAndUpdateInput"), function(args)
    merging_controller = sdk.to_managed_object(args[2])
end, function(retval)
    local controller = merging_controller
    merging_controller = nil
    local hunter = controller and controller:get_Character()
    if not is_master_hunter(hunter) then return retval end

    local input = controller:get_MergedVirtualInput()
    local focus_key = input:getKey(PAD_KEY_FOCUS)
    local strike_key = input:getKey(PAD_KEY_FOCUS_STRIKE)
    focus_button_held = focus_key:get_On()
    if focus_button_held then
        log_attack_presses(input)
    end

    if not settings.focus_strike_only or not is_master_melee_drawn(hunter) then
        reset_strike()
        return retval
    end
    if strike.frames_left == 0 and focus_button_held and strike_key:get_OnTrigger() then
        start_strike_window(hunter, strike_key)
    end
    if strike.frames_left > 0 then
        hold_focus_for_strike(hunter, focus_key, strike_key)
    else
        focus_key:clear()
    end
    return retval
end)

-- Focus Strikes and other Focus Mode actions start with an _AIM turn towards the camera.
-- Using the plain turn makes them turn like a normal attack.
sdk.hook(sdk.find_type_definition("app.HunterCharacter"):get_method("beginActionStartTurn"), function(args)
    if not settings.no_aim_turning or not is_master_melee(hunter_from_args(args)) then return end
    local turn_type = sdk.to_int64(args[4]) & 0xFFFFFFFF
    local plain_turn = START_TURN_FOR_AIM[turn_type]
    if plain_turn then
        args[4] = sdk.to_ptr(plain_turn)
        log_line(string.format("start turn %d -> %d", turn_type, plain_turn))
    end
end)

-- Round 1 and 2 logs: in Focus Mode the hunter turns to the camera through rotateAimTurnLook,
-- gated by isEnableAimTurn.
local hunter_type = sdk.find_type_definition("app.HunterCharacter")
local aim_turn_check_hunter = nil

sdk.hook(hunter_type:get_method("isEnableAimTurn"), function(args)
    aim_turn_check_hunter = hunter_from_args(args)
end, function(retval)
    local hunter = aim_turn_check_hunter
    aim_turn_check_hunter = nil
    if settings.no_aim_turning and is_master_melee(hunter) then
        return sdk.to_ptr(0)
    end
    return retval
end)

local function skip_aim_turn_rotation(args)
    if settings.no_aim_turning and is_master_melee(hunter_from_args(args)) then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

sdk.hook(hunter_type:get_method("rotateAimTurnLook"), skip_aim_turn_rotation)
sdk.hook(hunter_type:get_method("rotateAimTurnLook_WpOffset"), skip_aim_turn_rotation)

-- app.GUI020002 draws the Focus Mode and slinger reticle, and shows it while the script holds Focus Mode
-- on for a strike. Round 7 showed that setting it invisible once per frame from re.on_frame does not
-- stick, so it is applied right after the GUI's own updates. It is shown again only once, so the
-- game's own visibility is left alone.
local focus_reticle_gui = nil
local focus_reticle_hidden = false

local function apply_focus_reticle_visibility(gui)
    if not hide_focus_reticle_now and not focus_reticle_hidden then return end
    local display_control = sdk.get_managed_singleton("app.GUIManager"):get_HudDisplayManager()
        :findDisplayControl(gui:get_ID())
    display_control._TargetControl:set_ForceInvisible(hide_focus_reticle_now)
    if focus_reticle_hidden ~= hide_focus_reticle_now then
        log_line("focus reticle hidden=" .. tostring(hide_focus_reticle_now))
    end
    focus_reticle_hidden = hide_focus_reticle_now
end

local function hook_focus_reticle_update(method_name)
    sdk.hook(sdk.find_type_definition("app.GUI020002"):get_method(method_name), function(args)
        focus_reticle_gui = sdk.to_managed_object(args[2])
    end, function(retval)
        local gui = focus_reticle_gui
        focus_reticle_gui = nil
        if gui then
            apply_focus_reticle_visibility(gui)
        end
        return retval
    end)
end

hook_focus_reticle_update("guiHudUpdate")
hook_focus_reticle_update("guiHudVisibleUpdate")

local highlight_effect = nil

sdk.hook(sdk.find_type_definition("app.cEnemyLoopEffectHighlight"):get_method("isActivate"), function(args)
    highlight_effect = sdk.to_managed_object(args[2])
end, function(retval)
    local effect = highlight_effect
    highlight_effect = nil
    if not settings.wounds_only_while_focus_held or not effect then return retval end
    effect._IsAim = focus_button_held
    return sdk.to_ptr(focus_button_held and 1 or 0)
end)

local last_state = {}

local function read_focus_state(hunter)
    local context = hunter:get_HunterContext()
    local action = hunter:get_BaseActionController():get_CurrentAction()
    return {
        is_aim = context:get_IsAim(),
        aim_type = context:get_AimType(),
        action = action and action:get_type_definition():get_full_name() or "none",
        focus_button = focus_button_held,
    }
end

local function log_state_changes(hunter)
    local state = read_focus_state(hunter)
    if state.action ~= last_state.action then
        log_line("action " .. state.action)
    end
    if state.is_aim ~= last_state.is_aim or state.aim_type ~= last_state.aim_type then
        log_line(string.format("focus is_aim=%s aim_type=%d", tostring(state.is_aim), state.aim_type))
    end
    if state.focus_button ~= last_state.focus_button then
        log_line("focus_button=" .. tostring(state.focus_button))
    end
    last_state = state
end

-- update is inherited from app.CharacterBase, so this hook runs for every monster and NPC each frame.
-- It is installed only when logging is on at script load.
if settings.log_state then
    sdk.hook(hunter_type:get_method("update"), function(args)
        if not settings.log_state then return end
        local hunter = hunter_from_args(args)
        if not hunter or not hunter:get_type_definition():is_a("app.HunterCharacter") then return end
        if not is_master_hunter(hunter) then return end
        log_state_changes(hunter)
    end)
end

local function setting_checkbox(label, key)
    local changed, value = imgui.checkbox(label, settings[key])
    if changed then
        settings[key] = value
        json.dump_file(CONFIG_PATH, settings)
        log_line(string.format("setting %s=%s", key, tostring(value)))
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Focus Rules") then return end
    setting_checkbox("L2 alone does nothing, L2 + R1 does a Focus Strike (melee, weapon drawn)", "focus_strike_only")
    setting_checkbox("No turning towards the camera (melee)", "no_aim_turning")
    setting_checkbox("Show wounds only while L2 is held", "wounds_only_while_focus_held")
    setting_checkbox("Hide the focus reticle (melee, weapon drawn)", "hide_focus_reticle")
    setting_checkbox("Log focus state (applies after Reset scripts)", "log_state")
    imgui.tree_pop()
end)
