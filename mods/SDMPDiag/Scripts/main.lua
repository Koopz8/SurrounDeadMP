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

-- v2. Last run ruled out the interesting causes: role=AutonomousProxy and
-- AcknowledgedPawn set, so possession is completely correct and the client is
-- allowed to drive. What's left is input plumbing.
--   * SetInputMode_GameOnly returned false - arity again, UE5 takes
--     (Target, bFlushInput).
--   * bShowMouseCursor=true, so we're in menu input mode.
--   * The game is on Enhanced Input. IMC_General is almost certainly added in
--     BeginPlay behind an IsLocallyControlled check, and on a client the pawn's
--     BeginPlay can run before the controller is assigned - so it gets skipped
--     and there are no bindings at all.
local IMC_PATH = "/Game/Input/IMC_General.IMC_General"

local function fixInput2()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("IN2: no PlayerController"); return end
    local pawn = safe(function() return pc.Pawn end, nil)
    log("IN2: pawn=" .. ((pawn and pawn:IsValid()) and className(pawn) or "NONE") ..
        "  role=" .. (pawn and (ROLE[safe(function() return pawn.Role end, -1)] or "?") or "-"))

    -- 1. input mode, with the argument it actually wants
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if wbl and wbl:IsValid() then
        local ok = pcall(function() wbl:SetInputMode_GameOnly(pc, false) end)
        log("IN2: SetInputMode_GameOnly(pc,false) -> " .. tostring(ok))
        if not ok then
            log("IN2: retrying with one arg -> " ..
                tostring(pcall(function() wbl:SetInputMode_GameOnly(pc) end)))
        end
    end

    local okc = pcall(function() pc.bShowMouseCursor = false end)
    log("IN2: bShowMouseCursor=false -> " .. tostring(okc) ..
        " (now " .. tostring(safe(function() return pc.bShowMouseCursor end, "?")) .. ")")

    -- 2. enhanced input bindings
    local sub = nil
    pcall(function() sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem") end)
    if not (sub and sub:IsValid()) then
        log("IN2: no EnhancedInputLocalPlayerSubsystem found")
    else
        local imc = StaticFindObject(IMC_PATH)
        if not (imc and imc:IsValid()) then
            log("IN2: IMC_General not loaded -- can't add mappings")
        else
            local ok3 = pcall(function()
                sub:AddMappingContext(imc, 0, { bIgnoreAllPressedKeysUntilRelease = false })
            end)
            log("IN2: AddMappingContext(IMC_General, 0, opts) -> " .. tostring(ok3))
            if not ok3 then
                log("IN2: retrying with two args -> " ..
                    tostring(pcall(function() sub:AddMappingContext(imc, 0) end)))
            end
        end
    end

    pcall(function() pc:EnableInput(pc) end)
    log("IN2: done. Try moving.")
end

RegisterConsoleCommandHandler("sdmp_input2", function()
    ExecuteInGameThread(fixInput2)
    return true
end)

log("SDMPDiag: sdmp_input2 - input mode with correct arity, plus IMC_General.")

-- Same shape of bug as DefaultPawnClass, most likely: GameMode.HUDClass never
-- set, because single player builds its HUD through the load-save flow rather
-- than letting the engine spawn one per controller. No AHUD means none of the
-- game's UMG widgets ever get created on the client.
local HUD_PATH = "/Game/Blueprints/HUD_Game.HUD_Game_C"
local SMOOTH = { [0]="Disabled", [1]="Linear", [2]="Exponential", [3]="Replay" }

local function fixHud()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("HUD: no PlayerController"); return end

    local hud = safe(function() return pc.MyHUD end, nil)
    log("HUD: MyHUD = " .. ((hud and hud:IsValid()) and className(hud) or "NONE"))

    local hudCls = StaticFindObject(HUD_PATH)
    if not (hudCls and hudCls:IsValid()) then log("HUD: HUD_Game_C not found"); return end

    -- host: make sure anyone who joins later gets one
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if gm and gm:IsValid() then
        local hc = safe(function() return gm.HUDClass end, nil)
        log("HUD: GameMode.HUDClass = " ..
            ((hc and hc:IsValid()) and safe(function() return hc:GetFName():ToString() end, "?") or "NONE"))
        if not (hc and hc:IsValid()) then
            log("HUD: setting GameMode.HUDClass -> " .. tostring(pcall(function() gm.HUDClass = hudCls end)))
        end
    end

    if not (hud and hud:IsValid()) then
        local ok, err = pcall(function() pc:ClientSetHUD(hudCls) end)
        log("HUD: ClientSetHUD -> " .. (ok and "called" or ("threw: " .. tostring(err))))
        local h2 = safe(function() return pc.MyHUD end, nil)
        log("HUD: MyHUD is now " .. ((h2 and h2:IsValid()) and className(h2) or "STILL NONE"))
    end
end

-- Is the stutter the network, or just two copies of a 22k-actor UE5 world
-- fighting over one GPU? Read the numbers instead of guessing.
local function moveInfo()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then log("MV: no PlayerController"); return end

    local ps = safe(function() return pc.PlayerState end, nil)
    if ps and ps:IsValid() then
        log("MV: ping=" .. tostring(safe(function() return ps.ExactPing end, "?")) ..
            "ms  compressed=" .. tostring(safe(function() return ps.Ping end, "?")))
    end

    local pawn = safe(function() return pc.Pawn end, nil)
    if not (pawn and pawn:IsValid()) then log("MV: no pawn"); return end
    local cm = safe(function() return pawn.CharacterMovement end, nil)
    if not (cm and cm:IsValid()) then log("MV: no CharacterMovement"); return end

    local sm = safe(function() return cm.NetworkSmoothingMode end, nil)
    log("MV: NetworkSmoothingMode=" .. tostring(SMOOTH[sm] or sm) ..
        "  MaxSmoothUpdateDist=" .. tostring(safe(function() return cm.NetworkMaxSmoothUpdateDistance end, "?")) ..
        "  NoSmoothUpdateDist=" .. tostring(safe(function() return cm.NetworkNoSmoothUpdateDistance end, "?")))
    log("MV: NetworkSimulatedSmoothLocationTime=" ..
        tostring(safe(function() return cm.NetworkSimulatedSmoothLocationTime end, "?")) ..
        "  ServerAcceptClientAuthoritativePosition=" ..
        tostring(safe(function() return cm.bServerAcceptClientAuthoritativePosition end, "?")))
    log("MV: NetUpdateFrequency=" .. tostring(safe(function() return pawn.NetUpdateFrequency end, "?")) ..
        "  MinNetUpdateFrequency=" .. tostring(safe(function() return pawn.MinNetUpdateFrequency end, "?")))
end

RegisterConsoleCommandHandler("sdmp_hud", function() ExecuteInGameThread(fixHud) return true end)
RegisterConsoleCommandHandler("sdmp_move", function() ExecuteInGameThread(moveInfo) return true end)

log("SDMPDiag: sdmp_hud creates the client HUD, sdmp_move reports movement/ping numbers.")

-- MyHUD exists (HUD_Game_C), so HUDClass isn't the problem. The game's UI is
-- assembled from many separate widgets - Compass, TimeUI, medical bars - built
-- during the normal start flow. A client whose character arrived via
-- ServerRestartPlayer skips all of it. Almost certainly the same
-- BeginPlay-before-controller race that ate the input context, which would
-- mean one fix covers both. Enumerating first, since that's what found
-- ServerRestartPlayer.
local function pawnFuncs()
    local pc = UEHelpers.GetPlayerController()
    local pawn = pc and safe(function() return pc.Pawn end, nil) or nil
    if not (pawn and pawn:IsValid()) then log("PF: no pawn"); return end

    local cls = safe(function() return pawn:GetClass() end, nil)
    local guard = 0
    while cls and cls:IsValid() and guard < 4 do
        log("PF: --- " .. safe(function() return cls:GetFName():ToString() end, "?") .. " ---")
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = safe(function() return fn:GetFName():ToString() end, "?")
                if n:match("UI") or n:match("Widget") or n:match("HUD")
                   or n:match("Init") or n:match("Setup") or n:match("Create")
                   or n:match("Possess") or n:match("BeginPlay") then
                    log("PF:   " .. n)
                end
            end)
        end)
        cls = safe(function() return cls:GetSuperStruct() end, nil)
        guard = guard + 1
    end

    -- components often own their own UI setup
    pcall(function()
        local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
        if comps then
            log("PF: " .. #comps .. " components")
            for i = 1, math.min(#comps, 40) do
                log("PF:   comp " .. className(comps[i]))
            end
        end
    end)
end

-- The earlier ping read returned object wrappers. UE5 has a proper accessor.
local function pingInfo()
    local pc = UEHelpers.GetPlayerController()
    local ps = pc and safe(function() return pc.PlayerState end, nil) or nil
    if not (ps and ps:IsValid()) then log("PING: no PlayerState"); return end
    local ok, v = pcall(function() return ps:GetPingInMilliseconds() end)
    log("PING: " .. (ok and (tostring(v) .. " ms") or ("GetPingInMilliseconds threw: " .. tostring(v))))
end

RegisterConsoleCommandHandler("sdmp_pawnfuncs", function() ExecuteInGameThread(pawnFuncs) return true end)
RegisterConsoleCommandHandler("sdmp_ping", function() ExecuteInGameThread(pingInfo) return true end)

log("SDMPDiag: sdmp_pawnfuncs lists pawn UI/setup functions, sdmp_ping reports real ping.")

-- stat unit says host 7.55ms and client 5.77ms - both well over 130fps. So the
-- stutter is not performance and the movement config is stock, which leaves the
-- net driver's own throttles. UE ships them tuned for 2004 broadband:
--   NetServerMaxTickRate  30   - the whole server replicates 30x/sec
--   MaxClientRate         10000 bytes/sec
--   MaxInternetClientRate 10000 bytes/sec
-- 10 KB/s across a world with thousands of relevant replicating actors means
-- updates queue and the client renders stale positions. That reads exactly like
-- tearing. Run on the HOST.
local function netPerf()
    local world = UEHelpers.GetWorld()
    if not world or not world:IsValid() then log("NP: no world"); return end
    local nd = safe(function() return world.NetDriver end, nil)
    if not (nd and nd:IsValid()) then log("NP: no NetDriver -- run on the HOST"); return end

    local function show(tag)
        log(("NP[%s]: ServerMaxTickRate=%s  MaxClientRate=%s  MaxInternetClientRate=%s  NetServerMaxTickRate=%s"):format(
            tag,
            tostring(safe(function() return nd.NetServerMaxTickRate end, "?")),
            tostring(safe(function() return nd.MaxClientRate end, "?")),
            tostring(safe(function() return nd.MaxInternetClientRate end, "?")),
            tostring(safe(function() return nd.NetServerMaxTickRate end, "?"))))
        local conns = safe(function() return nd.ClientConnections end, nil)
        if conns then
            for i = 1, safe(function() return #conns end, 0) do
                pcall(function()
                    local c = conns[i]
                    log(("NP[%s]: conn %d CurrentNetSpeed=%s"):format(
                        tag, i, tostring(safe(function() return c.CurrentNetSpeed end, "?"))))
                end)
            end
        end
    end

    show("before")

    pcall(function() nd.NetServerMaxTickRate = 60 end)
    pcall(function() nd.MaxClientRate = 200000 end)
    pcall(function() nd.MaxInternetClientRate = 200000 end)

    -- the per-connection speed is negotiated at join, so bump the live ones too
    local conns = safe(function() return nd.ClientConnections end, nil)
    if conns then
        for i = 1, safe(function() return #conns end, 0) do
            pcall(function() conns[i].CurrentNetSpeed = 200000 end)
        end
    end

    show("after")
    log("NP: done. Move the client around and see if it's smoother.")
end

RegisterConsoleCommandHandler("sdmp_netperf", function() ExecuteInGameThread(netPerf) return true end)

log("SDMPDiag: sdmp_netperf (on the host) reports and raises the net driver throttles.")

-- sdmp_pawnfuncs found it. BP_PlayerCharacter_C carries the whole client UI
-- surface as client RPCs the server is meant to fire after possession:
--   Client_AddUI            builds it
--   Client_UpdateHealthUI / Stamina / Hunger / Thirst / Oxygen / Radiation
--   ShowCompassWidget, SetUIVisibility, GetInGameUI, ClearUI
-- None of it runs for a player the server restarted by hand, which is why the
-- host's HUD is fine and the client has nothing. Run on the CLIENT.
local UI_BUILD  = { "Client_AddUI", "ShowCompassWidget" }
local UI_UPDATE = {
    "Client_UpdateHealthUI", "Client_UpdateStaminaUI", "Client_UpdateHungerUI",
    "Client_UpdateThirstUI", "Client_UpdateOxygenUI", "Client_UpdateRadiationUI",
}

local function buildUI()
    local pc = UEHelpers.GetPlayerController()
    local pawn = pc and safe(function() return pc.Pawn end, nil) or nil
    if not (pawn and pawn:IsValid()) then log("UI: no pawn"); return end

    local existing = safe(function() return pawn:GetInGameUI() end, nil)
    log("UI: GetInGameUI before = " .. tostring(existing))

    for _, name in ipairs(UI_BUILD) do
        if safe(function() return pawn[name] end, nil) ~= nil then
            local ok, err = pcall(function() pawn[name](pawn) end)
            log("UI: " .. name .. " -> " .. (ok and "called" or ("threw: " .. tostring(err))))
        else
            log("UI: no such function " .. name)
        end
    end

    -- visibility is a separate flag from existence
    pcall(function() pawn:SetUIVisibility(true) end)

    -- nudge each bar so they draw with real values rather than empty
    for _, name in ipairs(UI_UPDATE) do
        if safe(function() return pawn[name] end, nil) ~= nil then
            local ok = pcall(function() pawn[name](pawn) end)
            log("UI: " .. name .. " -> " .. tostring(ok))
        end
    end

    log("UI: GetInGameUI after = " .. tostring(safe(function() return pawn:GetInGameUI() end, nil)))
end

RegisterConsoleCommandHandler("sdmp_ui", function() ExecuteInGameThread(buildUI) return true end)

log("SDMPDiag: sdmp_ui (on the client) calls Client_AddUI and the update RPCs.")

-- Hunch: the zombies and the choppiness are one bug. Zombies chase the client
-- but never attack, which is what you'd see if the server's copy of the client
-- pawn sits somewhere the client isn't - the AI walks to a ghost and never
-- reaches attack range. That same divergence is what choppy movement looks
-- like from the client side. Run sdmp_pos on BOTH within a second of each
-- other while the client is running, and compare.
local function posDump()
    local world = UEHelpers.GetWorld()
    local isHost = world and safe(function() return world.AuthorityGameMode end, nil) ~= nil
    log("POS: side=" .. (isHost and "HOST" or "CLIENT"))

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            local loc = safe(function() return p:K2_GetActorLocation() end, nil)
            local vel = safe(function() return p:GetVelocity() end, nil)
            log(("POS[%d]: role=%s  loc=%s  vel=%s"):format(
                i,
                ROLE[safe(function() return p.Role end, -1)] or "?",
                loc and ("%.0f %.0f %.0f"):format(loc.X, loc.Y, loc.Z) or "?",
                vel and ("%.0f"):format(math.sqrt(vel.X*vel.X + vel.Y*vel.Y)) or "?"))
        end
    end
end

-- 30 was the default and 60 may still not be enough for a survival game where
-- you notice every hitch. Tunable so we can find the knee.
local function setTick(n)
    local world = UEHelpers.GetWorld()
    local nd = world and safe(function() return world.NetDriver end, nil) or nil
    if not (nd and nd:IsValid()) then log("TICK: no NetDriver -- run on the HOST"); return end
    pcall(function() nd.NetServerMaxTickRate = n end)
    log("TICK: NetServerMaxTickRate = " .. tostring(safe(function() return nd.NetServerMaxTickRate end, "?")))
end

RegisterConsoleCommandHandler("sdmp_pos",    function() ExecuteInGameThread(posDump) return true end)
RegisterConsoleCommandHandler("sdmp_tick60", function() ExecuteInGameThread(function() setTick(60)  end) return true end)
RegisterConsoleCommandHandler("sdmp_tick120",function() ExecuteInGameThread(function() setTick(120) end) return true end)

log("SDMPDiag: sdmp_pos on both sides to compare positions; sdmp_tick60/120 on the host.")

-- Positions matched exactly, so the ghost theory is dead and both symptoms
-- need explaining some other way. Two samples with vel=0 told us nothing about
-- what happens while actually moving, so sample it properly: 40 readings at
-- 100ms on each side, then diff the traces. A client whose own position is
-- smooth locally but arrives at the server in 30hz steps looks exactly like
-- this, and a trace shows it where two snapshots can't.
local function track(tag)
    local n = 0
    log("TRK: starting 4s trace [" .. tag .. "]")
    LoopAsync(100, function()
        n = n + 1
        ExecuteInGameThread(function()
            for i, c in ipairs(listControllers()) do
                local p = safe(function() return c.Pawn end, nil)
                if p and p:IsValid() then
                    local loc = safe(function() return p:K2_GetActorLocation() end, nil)
                    local vel = safe(function() return p:GetVelocity() end, nil)
                    if loc then
                        log(("TRK[%s] %02d pawn%d role=%s %.0f %.0f %.0f spd=%.0f"):format(
                            tag, n, i,
                            ROLE[safe(function() return p.Role end, -1)] or "?",
                            loc.X, loc.Y, loc.Z,
                            vel and math.sqrt(vel.X*vel.X + vel.Y*vel.Y) or -1))
                    end
                end
            end
        end)
        return n >= 40
    end)
end

-- "No health lost" might mean no damage, or it might mean damage landing with
-- a health bar that never updates - Client_UpdateHealthUI wanted a parameter we
-- never passed, so the bar could be lying. Read the real numbers off the server.
local function statDump()
    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if not (p and p:IsValid()) then goto continue end
        log("ST: --- pawn " .. i .. " " .. className(p) .. " ---")
        local cls = safe(function() return p:GetClass() end, nil)
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pn = safe(function() return prop:GetFName():ToString() end, "")
                if pn:match("[Hh]ealth") or pn:match("[Ss]tamina") or pn:match("[Hh]unger")
                   or pn:match("[Tt]hirst") or pn:match("[Dd]amage") or pn:match("[Dd]ead")
                   or pn:match("[Aa]live") or pn:match("Invuln") or pn:match("[Gg]odMode") then
                    local v = safe(function() return p[pn] end, nil)
                    log(("ST:   %s = %s"):format(pn, tostring(v)))
                end
            end)
        end)
        ::continue::
    end
end

RegisterConsoleCommandHandler("sdmp_track_host",   function() track("HOST")   return true end)
RegisterConsoleCommandHandler("sdmp_track_client", function() track("CLIENT") return true end)
RegisterConsoleCommandHandler("sdmp_stats", function() ExecuteInGameThread(statDump) return true end)

log("SDMPDiag: sdmp_track_host / sdmp_track_client trace positions; sdmp_stats reads real health.")

-- The trace settled it. Client moves smoothly 0->400 speed over 4 seconds; the
-- server's copy of that same pawn never moves at all, spd=0 the whole time,
-- ~900 units from where the client actually is. The server is not receiving or
-- not applying ServerMove. That single fact explains all three symptoms: the
-- client predicts forward and gets yanked back (choppy), the AI walks to a
-- position the player left long ago (zombies chase, never attack), and nothing
-- ever hits you (health never drops).
-- ServerMove is an RPC, and RPCs need ownership. Check the chain.
local MOVEMODE = { [0]="None", [1]="Walking", [2]="NavWalking", [3]="Falling",
                   [4]="Swimming", [5]="Flying", [6]="Custom" }

local function ownDump()
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    local side = (gm and gm:IsValid()) and "HOST" or "CLIENT"
    log("OWN: side=" .. side)

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            local owner = safe(function() return p.Owner end, nil)
            local ctrl  = safe(function() return p.Controller end, nil)
            log(("OWN[%d]: pawn=%s role=%s/%s"):format(i, className(p),
                ROLE[safe(function() return p.Role end, -1)] or "?",
                ROLE[safe(function() return p.RemoteRole end, -1)] or "?"))
            log(("OWN[%d]:   Owner=%s  Controller=%s  bReplicateMovement=%s"):format(i,
                (owner and owner:IsValid()) and className(owner) or "NONE",
                (ctrl and ctrl:IsValid()) and className(ctrl) or "NONE",
                tostring(safe(function() return p.bReplicateMovement end, "?"))))

            local cm = safe(function() return p.CharacterMovement end, nil)
            if cm and cm:IsValid() then
                log(("OWN[%d]:   MovementMode=%s  MaxWalkSpeed=%s  bIsActive=%s"):format(i,
                    tostring(MOVEMODE[safe(function() return cm.MovementMode end, -1)] or "?"),
                    tostring(safe(function() return cm.MaxWalkSpeed end, "?")),
                    tostring(safe(function() return cm.bIsActive end, "?"))))
            else
                log(("OWN[%d]:   no CharacterMovement"):format(i))
            end

            local ok, locctl = pcall(function() return p:IsLocallyControlled() end)
            log(("OWN[%d]:   IsLocallyControlled=%s"):format(i, ok and tostring(locctl) or "n/a"))
        end
    end
end

-- If Owner is wrong, ServerMove gets dropped server-side as unowned. Cheap to
-- test: re-assert it and re-possess.
local function reOwn()
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if not (gm and gm:IsValid()) then log("RO: run on the HOST"); return end

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            local owner = safe(function() return p.Owner end, nil)
            local same = (owner and owner:IsValid()) and (className(owner) == className(c))
            log(("RO[%d]: Owner=%s controller=%s"):format(i,
                (owner and owner:IsValid()) and className(owner) or "NONE", className(c)))
            if not same then
                log(("RO[%d]: re-asserting ownership"):format(i))
                pcall(function() p:SetOwner(c) end)
                pcall(function() c:UnPossess() end)
                pcall(function() c:Possess(p) end)
                log(("RO[%d]: Owner now %s"):format(i, (function()
                    local o = safe(function() return p.Owner end, nil)
                    return (o and o:IsValid()) and className(o) or "NONE" end)()))
            end
        end
    end
end

RegisterConsoleCommandHandler("sdmp_own",   function() ExecuteInGameThread(ownDump) return true end)
RegisterConsoleCommandHandler("sdmp_reown", function() ExecuteInGameThread(reOwn)   return true end)

log("SDMPDiag: sdmp_own dumps ownership/movement state; sdmp_reown (host) re-asserts it.")

-- Host trace shows the client hitting 750 speed while MaxWalkSpeed reads 400 on
-- both sides. Sprint is almost certainly a client-local MaxWalkSpeed change the
-- server never hears about, so the server simulates 400, sees 750, and corrects
-- the client backwards every tick. That is exactly "freezes mid run but keeps
-- going". Single player never notices because there's nobody to disagree with.
--
-- sdmp_speedwatch logs MaxWalkSpeed alongside speed so we can watch them
-- diverge. sdmp_speedfix raises it on the server's copy so it stops arguing -
-- a blunt test of the theory, not the real fix. The real fix is making the
-- sprint state replicate.
local function speedWatch(tag)
    local n = 0
    log("SPD: watching 4s [" .. tag .. "]")
    LoopAsync(100, function()
        n = n + 1
        ExecuteInGameThread(function()
            for i, c in ipairs(listControllers()) do
                local p = safe(function() return c.Pawn end, nil)
                local cm = p and p:IsValid() and safe(function() return p.CharacterMovement end, nil) or nil
                if cm and cm:IsValid() then
                    local vel = safe(function() return p:GetVelocity() end, nil)
                    log(("SPD[%s] %02d pawn%d spd=%.0f MaxWalk=%s mode=%s"):format(
                        tag, n, i,
                        vel and math.sqrt(vel.X*vel.X + vel.Y*vel.Y) or -1,
                        tostring(safe(function() return cm.MaxWalkSpeed end, "?")),
                        tostring(MOVEMODE[safe(function() return cm.MovementMode end, -1)] or "?")))
                end
            end
        end)
        return n >= 40
    end)
end

local function speedFix(v)
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if not (gm and gm:IsValid()) then log("SF: run on the HOST"); return end
    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        local cm = p and p:IsValid() and safe(function() return p.CharacterMovement end, nil) or nil
        if cm and cm:IsValid() then
            pcall(function() cm.MaxWalkSpeed = v end)
            log(("SF[%d]: MaxWalkSpeed -> %s"):format(i,
                tostring(safe(function() return cm.MaxWalkSpeed end, "?"))))
        end
    end
    log("SF: server will stop correcting up to " .. v .. ". Move the client and see.")
end

RegisterConsoleCommandHandler("sdmp_speedwatch_host",   function() speedWatch("HOST")   return true end)
RegisterConsoleCommandHandler("sdmp_speedwatch_client", function() speedWatch("CLIENT") return true end)
RegisterConsoleCommandHandler("sdmp_speedfix", function() ExecuteInGameThread(function() speedFix(900.0) end) return true end)

log("SDMPDiag: sdmp_speedwatch_host/_client logs MaxWalkSpeed vs actual; sdmp_speedfix on host.")

-- It's the client's OWN pawn stuttering. That one should be locally predicted
-- and completely immune to network rate, so either prediction isn't running on
-- it or its updates are being starved. The video's character-region cadence
-- works out around 15Hz, which is far slower than the 120Hz tick we set - that
-- gap is the thing to explain.
--
-- sdmp_fine samples every 20ms for 2s. If the position advances in even little
-- steps every sample, prediction is running and the stutter is elsewhere. If it
-- moves in ~15 chunky jumps, it's being driven by replication like a remote
-- actor and prediction is dead.
local function fineTrace()
    local n = 0
    log("FINE: 2s at 20ms")
    LoopAsync(20, function()
        n = n + 1
        ExecuteInGameThread(function()
            local pc = UEHelpers.GetPlayerController()
            local p = pc and safe(function() return pc.Pawn end, nil) or nil
            if p and p:IsValid() then
                local l = safe(function() return p:K2_GetActorLocation() end, nil)
                if l then log(("FINE %03d %.1f %.1f %.1f"):format(n, l.X, l.Y, l.Z)) end
            end
        end)
        return n >= 100
    end)
end

-- With 4200 replicating actors competing, a pawn on default priority can get
-- starved down to a few updates a second no matter what the tick rate is.
-- Players should always win that contest. Run on the HOST.
local function priorityFix()
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if not (gm and gm:IsValid()) then log("PRI: run on the HOST"); return end

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if p and p:IsValid() then
            log(("PRI[%d]: before  NetPriority=%s  bAlwaysRelevant=%s  NetUpdateFreq=%s  MinNetUpdateFreq=%s"):format(i,
                tostring(safe(function() return p.NetPriority end, "?")),
                tostring(safe(function() return p.bAlwaysRelevant end, "?")),
                tostring(safe(function() return p.NetUpdateFrequency end, "?")),
                tostring(safe(function() return p.MinNetUpdateFrequency end, "?"))))
            pcall(function() p.NetPriority = 20.0 end)
            pcall(function() p.bAlwaysRelevant = true end)
            pcall(function() p.NetUpdateFrequency = 120.0 end)
            pcall(function() p.MinNetUpdateFrequency = 60.0 end)
            pcall(function() p:ForceNetUpdate() end)
            log(("PRI[%d]: after   NetPriority=%s  bAlwaysRelevant=%s  NetUpdateFreq=%s  MinNetUpdateFreq=%s"):format(i,
                tostring(safe(function() return p.NetPriority end, "?")),
                tostring(safe(function() return p.bAlwaysRelevant end, "?")),
                tostring(safe(function() return p.NetUpdateFrequency end, "?")),
                tostring(safe(function() return p.MinNetUpdateFrequency end, "?"))))
        end
    end
end

RegisterConsoleCommandHandler("sdmp_fine",    function() fineTrace() return true end)
RegisterConsoleCommandHandler("sdmp_priority",function() ExecuteInGameThread(priorityFix) return true end)

log("SDMPDiag: sdmp_fine 20ms trace; sdmp_priority (host) stops player pawns being starved.")

-- sdmp_fine nailed the shape of it. At 750 units/sec a 20ms step should be a
-- steady 15 units. Instead: 15 3 14 17 37 18 8 15 31 15 19 15 0 19 31 5 ...
-- Stalls at 0-3, then jumps of 28-37, which is two or three steps arriving at
-- once. Position is being written in server-sized chunks rather than predicted
-- forward. Priority made no difference and it was already NetPriority 3 with
-- NetUpdateFrequency 100, so starvation is out too.
--
-- One clean bisect left. Trace every pawn, not just the local one, and have the
-- HOST run while the CLIENT records. The host's character on the client is a
-- simulated proxy:
--   host's char also stutters  -> general replication smoothing, tune
--                                 NetworkSmoothingMode, ordinary problem
--   only our own stutters      -> client prediction genuinely isn't running,
--                                 which is a real engine-level fault
local function fineAll(tag)
    local n = 0
    log("FINE2: 2s at 20ms [" .. tag .. "]")
    LoopAsync(20, function()
        n = n + 1
        ExecuteInGameThread(function()
            for i, c in ipairs(listControllers()) do
                local p = safe(function() return c.Pawn end, nil)
                if p and p:IsValid() then
                    local l = safe(function() return p:K2_GetActorLocation() end, nil)
                    if l then
                        log(("FINE2[%s] %03d p%d %s %.1f %.1f"):format(
                            tag, n, i,
                            ROLE[safe(function() return p.Role end, -1)] or "?",
                            l.X, l.Y))
                    end
                end
            end
        end)
        return n >= 100
    end)
end

RegisterConsoleCommandHandler("sdmp_fine2", function() fineAll("C") return true end)

log("SDMPDiag: sdmp_fine2 traces every pawn - run on the client while the HOST moves.")

-- Bisect result: the host's character is smooth on the client, our own is not.
-- Backwards from normal - a simulated proxy is interpolated, an autonomous one
-- is predicted and should be the smoother of the two. So prediction isn't
-- running on our pawn and it's being driven by corrections instead.
--
-- Same shape as every other bug in this game: the client-side setup ran before
-- possession completed, so it never took. reown skipped the re-possess because
-- ownership already looked right; this forces it, which makes the engine redo
-- the whole handshake - ClientRestart, input component, movement init - in the
-- correct order this time. Run on the HOST.
local function rePossess()
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if not (gm and gm:IsValid()) then log("RP: run on the HOST"); return end

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if not (p and p:IsValid()) then goto continue end
        -- leave the host's own alone, it's fine
        if safe(function() return c:IsLocalController() end, false) == true then
            log(("RP[%d]: skipping local (host) controller"):format(i))
            goto continue
        end

        log(("RP[%d]: forcing unpossess/possess on %s"):format(i, className(p)))
        pcall(function() c:UnPossess() end)
        pcall(function() c:Possess(p) end)
        local p2 = safe(function() return c.Pawn end, nil)
        log(("RP[%d]: pawn now %s"):format(i, (p2 and p2:IsValid()) and className(p2) or "NONE"))
        ::continue::
    end
    log("RP: done. On the client re-run sdmp_input2 and sdmp_ui, then move.")
end

-- Remote players have no PlayerController on a client, so controller-based
-- tracing can never see them. Enumerate characters instead.
local function fineChars()
    local n = 0
    log("FC: 2s at 20ms, all characters")
    LoopAsync(20, function()
        n = n + 1
        ExecuteInGameThread(function()
            pcall(function()
                local cs = FindAllOf("Character")
                if not cs then return end
                for i, ch in ipairs(cs) do
                    if ch:IsValid() and className(ch) == "BP_PlayerCharacter_C" then
                        local l = safe(function() return ch:K2_GetActorLocation() end, nil)
                        if l then
                            log(("FC %03d c%d %s %.1f %.1f"):format(n, i,
                                ROLE[safe(function() return ch.Role end, -1)] or "?", l.X, l.Y))
                        end
                    end
                end
            end)
        end)
        return n >= 100
    end)
end

RegisterConsoleCommandHandler("sdmp_repossess", function() ExecuteInGameThread(rePossess) return true end)
RegisterConsoleCommandHandler("sdmp_finechars", function() fineChars() return true end)

log("SDMPDiag: sdmp_repossess (host) redoes the possession handshake; sdmp_finechars traces all characters.")
