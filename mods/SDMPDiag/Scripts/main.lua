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

-- Shipping builds compile logging out, so -log gives us nothing and a failed
-- ?listen is silent. Read the engine's own net driver table instead: if the
-- Engine.ini override didn't merge, GameNetDriver is simply undefined and
-- listen fails with no way to tell.
local function dumpNetDriverDefs()
    local engine = UEHelpers.GetEngine()
    if not engine or not engine:IsValid() then log("DRV: no engine"); return end

    local defs = safe(function() return engine.NetDriverDefinitions end, nil)
    if not defs then log("DRV: NetDriverDefinitions unreadable"); return end

    local n = safe(function() return #defs end, 0)
    log("DRV: " .. tostring(n) .. " net driver definition(s)")
    if n == 0 then
        log("DRV: EMPTY -- the ini override cleared the array and didn't refill it.")
        log("DRV: remove the SDMP LOOPBACK TEST block from Engine.ini.")
        return
    end

    for i = 1, n do
        local ok = pcall(function()
            local d = defs[i]
            local function nm(f)
                local v = d[f]
                if v == nil then return "?" end
                local s = safe(function() return v:ToString() end, nil)
                return s or tostring(v)
            end
            log(("DRV[%d]: def=%s  class=%s  fallback=%s")
                :format(i, nm("DefName"), nm("DriverClassName"), nm("DriverClassNameFallback")))
        end)
        if not ok then log("DRV[" .. i .. "]: unreadable") end
    end
end

-- Travel via GameplayStatics rather than the console. OpenLevel is a real
-- UFunction that takes an options string, so if `open ?listen` is being
-- swallowed somewhere this path sidesteps it.
local function hostListen()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not gs or not gs:IsValid() then log("HOST: no GameplayStatics"); return end
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("HOST: no world"); return end

    log("HOST: OpenLevel(PersistentLevel, absolute=true, options='listen')")
    local ok, err = pcall(function()
        gs:OpenLevel(world, FName("PersistentLevel"), true, "listen")
    end)
    if not ok then log("HOST: OpenLevel failed -- " .. tostring(err)) end
end

RegisterConsoleCommandHandler("sdmp_drivers", function()
    ExecuteInGameThread(dumpNetDriverDefs)
    return true
end)
RegisterConsoleCommandHandler("sdmp_host", function()
    ExecuteInGameThread(hostListen)
    return true
end)
RegisterKeyBind(Key.F9, function() ExecuteInGameThread(dumpNetDriverDefs) end)

log("SDMPDiag: F9 / sdmp_drivers to dump net driver defs, sdmp_host to listen.")

-- The Engine.ini route doesn't survive: the game re-serializes user config on
-- exit and drops any section it doesn't track, so the override was gone by the
-- time we looked. Patch the live array instead. Session-only, nothing on disk,
-- nothing for the game to overwrite.
local function setIpDriver()
    local engine = UEHelpers.GetEngine()
    if not engine or not engine:IsValid() then log("DRV: no engine"); return end

    local defs = safe(function() return engine.NetDriverDefinitions end, nil)
    if not defs then log("DRV: NetDriverDefinitions unreadable"); return end

    local n = safe(function() return #defs end, 0)
    local changed = 0
    for i = 1, n do
        pcall(function()
            local d = defs[i]
            local name = safe(function() return d.DefName:ToString() end, "?")
            if name == "GameNetDriver" then
                d.DriverClassName = FName("OnlineSubsystemUtils.IpNetDriver")
                d.DriverClassNameFallback = FName("OnlineSubsystemUtils.IpNetDriver")
                changed = changed + 1
            end
        end)
    end

    if changed == 0 then
        log("DRV: no GameNetDriver entry found to patch")
    else
        log("DRV: patched " .. changed .. " entry -> IpNetDriver. Verifying:")
    end
    dumpNetDriverDefs()
end

RegisterConsoleCommandHandler("sdmp_ipdriver", function()
    ExecuteInGameThread(setIpDriver)
    return true
end)
-- No key bound: F10 is taken by the console. Type sdmp_ipdriver instead.

log("SDMPDiag: type sdmp_ipdriver in the console to force the IP net driver.")

-- The GameMode has no login hooks at all - just ReceiveBeginPlay - so it never
-- spawns anyone. BP_PlayerController does, via Svr_RequestRespawn_Random /
-- _SpawnPoint. Those are server RPCs the game already wrote for its own death
-- and respawn flow. A joining client has no pawn; ask for one.
local RESPAWN_FNS = {
    "Svr_RequestRespawn_Random",
    "Svr_RequestRespawn_SpawnPoint",
    "Survival_Respawn",
}

local function requestSpawn()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("SPAWN: no PlayerController"); return end

    local pawn = safe(function() return pc.Pawn end, nil)
    if pawn and pawn:IsValid() then
        log("SPAWN: already have a pawn (" .. className(pawn) .. "), nothing to do")
        return
    end

    for _, name in ipairs(RESPAWN_FNS) do
        local fn = safe(function() return pc[name] end, nil)
        if fn ~= nil then
            log("SPAWN: calling " .. name)
            local ok, err = pcall(function() pc[name](pc) end)
            if ok then
                log("SPAWN: " .. name .. " returned. Check F8 in a second.")
                return
            end
            log("SPAWN: " .. name .. " threw -- " .. tostring(err))
        else
            log("SPAWN: no such function " .. name)
        end
    end
    log("SPAWN: nothing worked. Run sdmp_funcs and send the list.")
end

-- Fallback: what can we actually call on this controller?
local function dumpFuncs()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("FN: no PlayerController"); return end

    local cls = safe(function() return pc:GetClass() end, nil)
    local guard = 0
    while cls and cls:IsValid() and guard < 6 do
        local cname = safe(function() return cls:GetFName():ToString() end, "?")
        log("FN: --- " .. cname .. " ---")
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = safe(function() return fn:GetFName():ToString() end, "?")
                if n:match("^Svr") or n:match("^Server") or n:match("Respawn")
                   or n:match("Spawn") or n:match("Possess") then
                    log("FN:   " .. n)
                end
            end)
        end)
        cls = safe(function() return cls:GetSuperStruct() end, nil)
        guard = guard + 1
    end
end

RegisterConsoleCommandHandler("sdmp_spawn", function()
    ExecuteInGameThread(requestSpawn)
    return true
end)
RegisterConsoleCommandHandler("sdmp_funcs", function()
    ExecuteInGameThread(dumpFuncs)
    return true
end)

log("SDMPDiag: sdmp_spawn asks the server for a pawn. sdmp_funcs lists candidates.")

-- Run on the HOST. Svr_RequestRespawn_Random from the client returned without
-- doing anything - either it needs params we didn't pass or its body early-outs
-- for a player who was never alive. So do it with authority instead: find the
-- pawnless controller (that's the joiner), spawn a character next to the host,
-- and possess it. Crude, but it's the shortest path to proving a second player
-- can exist at all.
local SPAWN_OFFSET = 250.0

local function listControllers()
    local out = {}
    pcall(function()
        local pcs = FindAllOf("PlayerController")
        if not pcs then return end
        for _, c in ipairs(pcs) do
            if c:IsValid() then out[#out+1] = c end
        end
    end)
    return out
end

local function hostSpawn()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("HS: no world"); return end
    if not safe(function() return world.AuthorityGameMode end, nil) then
        log("HS: no AuthorityGameMode -- run this on the HOST, not the client")
        return
    end

    local pcs = listControllers()
    log("HS: " .. #pcs .. " PlayerController(s)")

    local hostPawn, targets = nil, {}
    for i, c in ipairs(pcs) do
        local p = safe(function() return c.Pawn end, nil)
        local has = p and p:IsValid()
        log(("HS[%d]: %s  pawn=%s  remoteRole=%s"):format(
            i, className(c), has and className(p) or "NONE",
            ROLE[safe(function() return c.RemoteRole end, -1)] or "?"))
        if has and not hostPawn then hostPawn = p else
            if not has then targets[#targets+1] = c end
        end
    end

    if #targets == 0 then log("HS: every controller already has a pawn"); return end
    if not hostPawn then log("HS: no existing pawn to copy a location from"); return end

    local loc = safe(function() return hostPawn:K2_GetActorLocation() end, nil)
    if not loc then log("HS: couldn't read host pawn location"); return end
    log(("HS: host at %.0f %.0f %.0f"):format(loc.X, loc.Y, loc.Z))

    local cls = StaticFindObject("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C")
    if not cls or not cls:IsValid() then log("HS: BP_PlayerCharacter_C class not found"); return end

    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not gs or not gs:IsValid() then log("HS: no GameplayStatics"); return end

    local xform = {
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = loc.X + SPAWN_OFFSET, Y = loc.Y + SPAWN_OFFSET, Z = loc.Z + 100.0 },
        Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    for _, c in ipairs(targets) do
        local ok, err = pcall(function()
            -- 2 = AdjustIfPossibleButAlwaysSpawn
            local pawn = gs:BeginDeferredActorSpawnFromClass(world, cls, xform, 2, c)
            if not pawn or not pawn:IsValid() then error("deferred spawn returned nothing") end
            gs:FinishSpawningActor(pawn, xform)
            log("HS: spawned " .. className(pawn) .. ", possessing")
            c:Possess(pawn)
        end)
        if ok then
            local p = safe(function() return c.Pawn end, nil)
            log("HS: controller pawn is now " .. ((p and p:IsValid()) and className(p) or "STILL NONE"))
        else
            log("HS: spawn/possess failed -- " .. tostring(err))
        end
    end
end

RegisterConsoleCommandHandler("sdmp_hostspawn", function()
    ExecuteInGameThread(hostSpawn)
    return true
end)

log("SDMPDiag: sdmp_hostspawn (on the host) spawns and possesses for pawnless controllers.")

-- v2. Two fixes from the last run:
--   * BeginDeferredActorSpawnFromClass wants 6 args in 5.3, not 5 - it gained
--     TransformScaleMethod. FinishSpawningActor wants 3.
--   * sdmp_funcs turned up ServerRestartPlayer on APlayerController, which is
--     the engine's own "give me a pawn" RPC. That routes through the GameMode
--     and possesses properly, so try it before hand-rolling a spawn.
-- The GameMode's DefaultPawnClass is probably unset (single player never needs
-- it), so point it at BP_PlayerCharacter first or RestartPlayer makes a
-- DefaultPawn sphere.
local PC_PATH = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"

local function hostSpawn2()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("HS2: no world"); return end

    local gm = safe(function() return world.AuthorityGameMode end, nil)
    if not gm or not gm:IsValid() then
        log("HS2: no AuthorityGameMode -- run this on the HOST")
        return
    end

    local charCls = StaticFindObject(PC_PATH)
    if not charCls or not charCls:IsValid() then log("HS2: BP_PlayerCharacter_C not found"); return end

    local dp = safe(function() return gm.DefaultPawnClass end, nil)
    log("HS2: GameMode.DefaultPawnClass = " ..
        ((dp and dp:IsValid()) and safe(function() return dp:GetFName():ToString() end, "?") or "NONE"))
    if not (dp and dp:IsValid()) or safe(function() return dp:GetFName():ToString() end, "") ~= "BP_PlayerCharacter_C" then
        local ok = pcall(function() gm.DefaultPawnClass = charCls end)
        log("HS2: set DefaultPawnClass -> BP_PlayerCharacter_C : " .. tostring(ok))
    end

    local hostPawn, targets = nil, {}
    for _, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            if not hostPawn then hostPawn = p end
        else
            targets[#targets+1] = c
        end
    end
    if #targets == 0 then log("HS2: nobody is pawnless"); return end
    log("HS2: " .. #targets .. " pawnless controller(s)")

    for _, c in ipairs(targets) do
        -- 1. the engine's own route
        local ok, err = pcall(function() c:ServerRestartPlayer() end)
        log("HS2: ServerRestartPlayer -> " .. (ok and "called" or ("threw: " .. tostring(err))))

        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            log("HS2: pawn is now " .. className(p) .. " -- done, engine route works")
        else
            log("HS2: still no pawn, falling back to manual spawn")
            if not hostPawn then log("HS2: no host pawn to place next to"); return end
            local loc = safe(function() return hostPawn:K2_GetActorLocation() end, nil)
            if not loc then log("HS2: no host location"); return end

            local xform = {
                Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                Translation = { X = loc.X + 250.0, Y = loc.Y + 250.0, Z = loc.Z + 100.0 },
                Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
            }
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local ok2, err2 = pcall(function()
                -- 6th arg is ESpawnActorScaleMethod, new in 5.3. 0 = OverrideRootScale.
                local pawn = gs:BeginDeferredActorSpawnFromClass(world, charCls, xform, 2, c, 0)
                if not pawn or not pawn:IsValid() then error("deferred spawn returned nothing") end
                gs:FinishSpawningActor(pawn, xform, 0)
                log("HS2: spawned " .. className(pawn))
                c:Possess(pawn)
            end)
            if not ok2 then log("HS2: manual spawn failed -- " .. tostring(err2)) end
            local p2 = safe(function() return c.Pawn end, nil)
            log("HS2: final pawn = " .. ((p2 and p2:IsValid()) and className(p2) or "STILL NONE"))
        end
    end
end

RegisterConsoleCommandHandler("sdmp_hostspawn2", function()
    ExecuteInGameThread(hostSpawn2)
    return true
end)

log("SDMPDiag: sdmp_hostspawn2 - engine RestartPlayer first, manual spawn as fallback.")

-- Run on the CLIENT. The pawn exists but won't move. Three usual suspects:
-- the controller is still in UI input mode from the menu, the client-side
-- possession setup (ClientRestart, which builds the input component) never
-- ran, or the pawn came through as a SimulatedProxy the client can't drive.
-- Report all three, then try the fixes.
local function fixInput()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("IN: no PlayerController"); return end

    local pawn = safe(function() return pc.Pawn end, nil)
    if not (pawn and pawn:IsValid()) then log("IN: no pawn to drive"); return end

    log("IN: pawn=" .. className(pawn) ..
        "  role=" .. (ROLE[safe(function() return pawn.Role end, -1)] or "?") ..
        "  remoteRole=" .. (ROLE[safe(function() return pawn.RemoteRole end, -1)] or "?"))
    log("IN: bShowMouseCursor=" .. tostring(safe(function() return pc.bShowMouseCursor end, "?")) ..
        "  AcknowledgedPawn=" .. (function()
            local a = safe(function() return pc.AcknowledgedPawn end, nil)
            return (a and a:IsValid()) and className(a) or "NONE" end)())

    -- If the client never acknowledged the pawn, the possession handshake is
    -- incomplete and input was never wired up locally.
    local ack = safe(function() return pc.AcknowledgedPawn end, nil)
    if not (ack and ack:IsValid()) then
        log("IN: no AcknowledgedPawn -- calling ClientRestart to finish possession")
        local ok, err = pcall(function() pc:ClientRestart(pawn) end)
        log("IN: ClientRestart -> " .. (ok and "called" or ("threw: " .. tostring(err))))
    end

    -- Menu left us in UI input mode.
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if wbl and wbl:IsValid() then
        local ok = pcall(function() wbl:SetInputMode_GameOnly(pc) end)
        log("IN: SetInputMode_GameOnly -> " .. tostring(ok))
    else
        log("IN: WidgetBlueprintLibrary not found")
    end
    pcall(function() pc.bShowMouseCursor = false end)
    pcall(function() pc:EnableInput(pc) end)

    log("IN: done. Try moving.")
end

RegisterConsoleCommandHandler("sdmp_input", function()
    ExecuteInGameThread(fixInput)
    return true
end)

log("SDMPDiag: sdmp_input (on the client) reports and repairs input/possession state.")
