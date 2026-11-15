-- Focus Mode rules prototype, round 1.
-- Each rule is off by default and can be switched in the REFramework menu under "Focus Rules".
-- With "Log focus state" on, changes in focus state, aim type and action are written to re2_framework_log.txt.
--
-- Method names come from the game's il2cpp_dump.json (REFramework SDK dump).
-- Hook patterns follow Bimmr's MHWS-Weapon-Swapper (HunterCharacter.update, get_IsMaster,
-- BaseActionController:get_CurrentAction) and MHWS-Buffer (getMasterPlayerInfo, SKIP_ORIGINAL,
-- replacing a return value with sdk.to_ptr): https://github.com/Bimmr

local settings = {
    log_state = true,
    block_focus_input = false,
    block_aim_turn_check = false,
    block_aim_turn_rotation = false,
}

-- app.WeaponDef.TYPE: LONG_SWORD = 0 through ROD = 10 are melee. BOW, HEAVY_BOWGUN and LIGHT_BOWGUN follow.
local LAST_MELEE_WEAPON_TYPE = 10

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

local function is_master_melee(hunter)
    return hunter ~= nil and hunter:get_IsMaster() and is_melee(hunter)
end

local function hunter_from_args(args)
    return sdk.to_managed_object(args[2])
end

-- Counts of aim turn calls during the current action, logged when the action changes.
local aim_turn_counts = { enabled = 0, rotations = 0 }
local last_state = {}

local function log_line(text)
    log.info("[FocusRules] " .. string.format("%.3f ", os.clock()) .. text)
end

local function read_focus_state(hunter)
    local context = hunter:get_HunterContext()
    local action = hunter:get_BaseActionController():get_CurrentAction()
    return {
        is_aim = context:get_IsAim(),
        aim_type = context:get_AimType(),
        action = action and action:get_type_definition():get_full_name() or "none",
        aim_turned = hunter:get_CurrentActionInfo():get_IsAimTurned(),
    }
end

local function log_state_changes(hunter)
    local state = read_focus_state(hunter)
    if state.action ~= last_state.action then
        if last_state.action then
            log_line(string.format("action end %s aim_turn_enabled=%d aim_turn_rotations=%d",
                last_state.action, aim_turn_counts.enabled, aim_turn_counts.rotations))
        end
        aim_turn_counts.enabled = 0
        aim_turn_counts.rotations = 0
        log_line("action start " .. state.action)
    end
    if state.is_aim ~= last_state.is_aim or state.aim_type ~= last_state.aim_type then
        log_line(string.format("focus is_aim=%s aim_type=%d", tostring(state.is_aim), state.aim_type))
    end
    if state.aim_turned ~= last_state.aim_turned then
        log_line("aim_turned=" .. tostring(state.aim_turned))
    end
    last_state = state
end

local hunter_type = sdk.find_type_definition("app.HunterCharacter")

-- update is inherited from app.CharacterBase, so this hook also runs for monsters and NPCs.
sdk.hook(hunter_type:get_method("update"), function(args)
    if not settings.log_state then return end
    local hunter = hunter_from_args(args)
    if not hunter or not hunter:get_type_definition():is_a("app.HunterCharacter") then return end
    if not hunter:get_IsMaster() then return end
    log_state_changes(hunter)
end)

-- The master player's controller turns the focus button into focus mode here.
sdk.hook(sdk.find_type_definition("app.cMasterPlayerControllerEntity"):get_method("updateAimCommand"), function()
    if settings.block_focus_input and is_master_melee(get_master_hunter()) then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end)

local aim_turn_check_hunter = nil

sdk.hook(hunter_type:get_method("isEnableAimTurn"), function(args)
    aim_turn_check_hunter = hunter_from_args(args)
end, function(retval)
    local hunter = aim_turn_check_hunter
    aim_turn_check_hunter = nil
    if not is_master_melee(hunter) then return retval end
    if settings.block_aim_turn_check then
        return sdk.to_ptr(0)
    end
    if (sdk.to_int64(retval) & 1) == 1 then
        aim_turn_counts.enabled = aim_turn_counts.enabled + 1
    end
    return retval
end)

local function on_aim_turn_rotation(args)
    if not is_master_melee(hunter_from_args(args)) then return end
    aim_turn_counts.rotations = aim_turn_counts.rotations + 1
    if settings.block_aim_turn_rotation then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end

sdk.hook(hunter_type:get_method("rotateAimTurnLook"), on_aim_turn_rotation)
sdk.hook(hunter_type:get_method("rotateAimTurnLook_WpOffset"), on_aim_turn_rotation)

local function setting_checkbox(label, key)
    local changed, value = imgui.checkbox(label, settings[key])
    if changed then
        settings[key] = value
        log_line(string.format("setting %s=%s", key, tostring(value)))
    end
end

re.on_draw_ui(function()
    if not imgui.tree_node("Focus Rules") then return end
    setting_checkbox("Log focus state", "log_state")
    setting_checkbox("Block focus input (melee)", "block_focus_input")
    setting_checkbox("Block aim turn check (melee)", "block_aim_turn_check")
    setting_checkbox("Block aim turn rotation (melee)", "block_aim_turn_rotation")
    imgui.tree_pop()
end)
