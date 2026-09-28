--[[ SurrounDead MP — diagnostics
     Read-only. Dumps what we need to know before writing a line of mod code.
     F7 in game, or console: sdmp_diag
]]

local UEHelpers = require("UEHelpers")

local function log(s) print("[SDMP] " .. tostring(s) .. "\n") end

local ROLE = { [0]="None", [1]="SimulatedProxy", [2]="AutonomousProxy", [3]="Authority" }

local function safe(fn, fallback)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
end

local function className(obj)
    return safe(function() return obj:GetClass():GetFName():ToString() end, "<?>")
end

local CDOS = {
    "/Game/Blueprints/BP_PlayerCharacter.Default__BP_PlayerCharacter_C",
    "/Game/Blueprints/BP_PlayerController.Default__BP_PlayerController_C",
    "/Game/Blueprints/BP_SurroundeadGameMode.Default__BP_SurroundeadGameMode_C",
    "/Game/Blueprints/BP_SurroundeadGameState.Default__BP_SurroundeadGameState_C",
    "/Game/Blueprints/Vehicles/BP_VehicleMaster.Default__BP_VehicleMaster_C",
    "/Game/Blueprints/BuildingSystem/Actors/Buildable_MASTER.Default__Buildable_MASTER_C",
}

-- Engine defaults, so we can tell a deliberate Blueprint override from a
-- stock value. BP_PlayerController reporting bReplicates=false only means
-- something if the engine's own PlayerController reports true.
local NATIVE_CDOS = {
    "/Script/Engine.Default__PlayerController",
    "/Script/Engine.Default__Character",
    "/Script/Engine.Default__GameStateBase",
    "/Script/Engine.Default__GameModeBase",
}

local FLAGS = {
    "bReplicates", "bReplicateMovement", "bAlwaysRelevant",
    "bNetLoadOnClient", "bOnlyRelevantToOwner", "bNetUseOwnerRelevancy",
}

local function dumpCDO(path)
    local obj = StaticFindObject(path)
    if not obj or not obj:IsValid() then
        log("  MISSING  " .. path)
        return
    end
    local parts = {}
    for _, f in ipairs(FLAGS) do
        local v = safe(function() return obj[f] end, nil)
        if v ~= nil then parts[#parts+1] = f .. "=" .. tostring(v) end
    end
    local freq = safe(function() return obj.NetUpdateFrequency end, nil)
    if freq then parts[#parts+1] = "NetUpdateFrequency=" .. tostring(freq) end
    log("  " .. path:match("([^%.]+)$") .. "  ->  " .. table.concat(parts, "  "))
end

-- Walk a Blueprint class up to its native parent.
local function dumpChain(path)
    local cls = StaticFindObject(path)
    if not cls or not cls:IsValid() then log("  MISSING class " .. path); return end
    local names, cur, guard = {}, cls, 0
    while cur and cur:IsValid() and guard < 12 do
        names[#names+1] = safe(function() return cur:GetFName():ToString() end, "?")
        cur = safe(function() return cur:GetSuperStruct() end, nil)
        guard = guard + 1
    end
    log("  " .. table.concat(names, "  <-  "))
end

local function dumpWorld()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("no world yet"); return end
    log("World: " .. safe(function() return world:GetFullName() end, "?"))

    local nd = safe(function() return world.NetDriver end, nil)
    if nd and nd:IsValid() then
        log("NetDriver: " .. className(nd) .. "  (" ..
            safe(function() return nd:GetFName():ToString() end, "?") .. ")")
        local conns = safe(function() return nd.ClientConnections end, nil)
        if conns then log("ClientConnections: " .. tostring(#conns)) end
    else
        log("NetDriver: <none>  -- standalone, not hosting")
    end

    local gm = safe(function() return world.AuthorityGameMode end, nil)
    if gm and gm:IsValid() then log("AuthorityGameMode: " .. className(gm))
    else log("AuthorityGameMode: <none>  -- this instance is a client") end

    local gs = safe(function() return world.GameState end, nil)
    if gs and gs:IsValid() then
        log("GameState: " .. className(gs))
        local ps = safe(function() return gs.PlayerArray end, nil)
        if ps then log("PlayerArray: " .. tostring(#ps) .. " player(s)") end
    end
end

local function dumpLocalPlayer()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("no PlayerController"); return end
    log("PlayerController: " .. className(pc) ..
        "  Role=" .. (ROLE[safe(function() return pc.Role end, -1)] or "?") ..
        "  RemoteRole=" .. (ROLE[safe(function() return pc.RemoteRole end, -1)] or "?"))
    local pawn = safe(function() return pc.Pawn end, nil)
    if pawn and pawn:IsValid() then
        log("Pawn: " .. className(pawn) ..
            "  Role=" .. (ROLE[safe(function() return pawn.Role end, -1)] or "?") ..
            "  bReplicates=" .. tostring(safe(function() return pawn.bReplicates end, "?")))
    else
        log("Pawn: <none>  -- unpossessed. This is the classic join bug.")
    end
end

-- Both halves matter. What replicates tells us what we get for free; what
-- doesn't tells us the work list.
local function dumpActorSweep()
    local yes, no, total = {}, {}, 0
    local nRep = 0
    local ok = pcall(function()
        local actors = FindAllOf("Actor")
        if not actors then return end
        for _, a in ipairs(actors) do
            total = total + 1
            local c = className(a)
            if safe(function() return a.bReplicates end, false) == true then
                nRep = nRep + 1
                yes[c] = (yes[c] or 0) + 1
            else
                no[c] = (no[c] or 0) + 1
            end
        end
    end)
    if not ok then log("actor sweep failed"); return end

    local function top(t, n, label)
        local rows = {}
        for c, k in pairs(t) do rows[#rows+1] = { c = c, n = k } end
        table.sort(rows, function(x, y) return x.n > y.n end)
        log(label)
        for i = 1, math.min(#rows, n) do
            log(("  %5d  %s"):format(rows[i].n, rows[i].c))
        end
        if #rows > n then log("  ... and " .. (#rows - n) .. " more classes") end
    end

    log(("Actors in world: %d   replicating: %d (%.1f%%)")
        :format(total, nRep, total > 0 and (nRep / total * 100) or 0))
    top(yes, 15, "-- replicating --")
    top(no, 25, "-- NOT replicating (the work list) --")
end

local function runDiag()
    log("================ SurrounDead MP diagnostics ================")
    dumpWorld()
    log("--- local player ---")
    dumpLocalPlayer()
    log("--- game CDO replication defaults ---")
    for _, p in ipairs(CDOS) do dumpCDO(p) end
    log("--- engine defaults, for comparison ---")
    for _, p in ipairs(NATIVE_CDOS) do dumpCDO(p) end
    log("--- class chains ---")
    dumpChain("/Game/Blueprints/BP_PlayerController.BP_PlayerController_C")
    dumpChain("/Game/Blueprints/BP_SurroundeadGameMode.BP_SurroundeadGameMode_C")
    log("--- actor sweep ---")
    dumpActorSweep()
    log("===========================================================")
end

RegisterKeyBind(Key.F7, function() ExecuteInGameThread(runDiag) end)

RegisterConsoleCommandHandler("sdmp_diag", function()
    ExecuteInGameThread(runDiag)
    return true
end)

log("SDMPDiag loaded. F7 or `sdmp_diag` to dump.")

-- One line of net state. F8, or `sdmp_net`. For checking whether a listen
-- server actually came up, or whether a connect landed, without the full dump.
local function netStatus()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("NET: no world"); return end

    local nd   = safe(function() return world.NetDriver end, nil)
    local gm   = safe(function() return world.AuthorityGameMode end, nil)
    local pc   = UEHelpers.GetPlayerController()
    local pawn = pc and safe(function() return pc.Pawn end, nil) or nil

    local conns = 0
    if nd and nd:IsValid() then
        conns = safe(function() return #nd.ClientConnections end, 0)
    end

    log(("NET: driver=%s  connections=%d  authority=%s  pawn=%s  role=%s"):format(
        (nd and nd:IsValid()) and className(nd) or "NONE (standalone)",
        conns,
        (gm and gm:IsValid()) and "yes" or "no (we are a client)",
        (pawn and pawn:IsValid()) and className(pawn) or "NONE",
        pawn and (ROLE[safe(function() return pawn.Role end, -1)] or "?") or "-"))

    local map = safe(function() return world:GetFName():ToString() end, "?")
    log("NET: map=" .. map .. "  actors=" .. tostring(safe(function()
        local a = FindAllOf("Actor"); return a and #a or 0 end, 0)))
end

RegisterKeyBind(Key.F8, function() ExecuteInGameThread(netStatus) end)
RegisterConsoleCommandHandler("sdmp_net", function()
    ExecuteInGameThread(netStatus)
    return true
end)

log("SDMPDiag: F8 / sdmp_net for quick net status.")
