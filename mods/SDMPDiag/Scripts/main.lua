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
    -- a null UObject wrapper isn't nil in Lua, and touching it is a native
    -- crash pcall can't catch, so check IsValid before anything else
    if not obj or not safe(function() return obj:IsValid() end, false) then return "<null>" end
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

-- Last runtime theory before this needs a proper pak mod.
-- Characters replicate movement THROUGH the movement component, which knows how
-- to reconcile with a predicting client. The plain ReplicatedMovement path does
-- not - it stamps the server transform straight onto the client. If both are
-- running, every update stomps whatever prediction produced, which is exactly
-- the stall-then-jump we measured.
-- Turning it off on the server for the client's pawn is diagnostic, not a fix:
-- if the stutter clears, we know what to change properly in the blueprint.
local function repMove(on)
    local world = UEHelpers.GetWorld()
    local gm = world and safe(function() return world.AuthorityGameMode end, nil) or nil
    if not (gm and gm:IsValid()) then log("RM: run on the HOST"); return end

    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if not (p and p:IsValid()) then goto continue end
        if safe(function() return c:IsLocalController() end, false) == true then
            log(("RM[%d]: leaving host's own pawn alone"):format(i))
            goto continue
        end
        log(("RM[%d]: bReplicateMovement %s -> %s"):format(i,
            tostring(safe(function() return p.bReplicateMovement end, "?")), tostring(on)))
        local ok = pcall(function() p:SetReplicateMovement(on) end)
        if not ok then pcall(function() p.bReplicateMovement = on end) end
        pcall(function() p:ForceNetUpdate() end)
        log(("RM[%d]: now %s"):format(i, tostring(safe(function() return p.bReplicateMovement end, "?"))))
        ::continue::
    end
    log("RM: move the client. If it's smooth now, generic transform replication was the culprit.")
end

RegisterConsoleCommandHandler("sdmp_repmove_off", function() ExecuteInGameThread(function() repMove(false) end) return true end)
RegisterConsoleCommandHandler("sdmp_repmove_on",  function() ExecuteInGameThread(function() repMove(true)  end) return true end)

log("SDMPDiag: sdmp_repmove_off (host) disables generic transform replication on the client's pawn.")

-- Stopped guessing and read the assets. Player_AnimBP has RootMotionBasedOnRootBone
-- and BP_PlayerCharacter has only two AddMovementInput calls - far too few for a
-- full locomotion system. So movement is coming out of the animation, not the
-- movement component.
--
-- ERootMotionMode::RootMotionFromEverything is documented as not supported in
-- networked games. The client extracts motion from its own animation, the server
-- runs its own animation state, and the two disagree every frame - which is the
-- stall-then-catch-up we measured, and why it's invisible in single player.
--   0 NoRootMotionExtraction   1 IgnoreRootMotion
--   2 RootMotionFromEverything 3 RootMotionFromMontagesOnly  <- the net-safe one
local RMM = { [0]="NoRootMotionExtraction", [1]="IgnoreRootMotion",
              [2]="RootMotionFromEverything", [3]="RootMotionFromMontagesOnly" }

local function rootMotion(setTo)
    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if not (p and p:IsValid()) then goto continue end
        local mesh = safe(function() return p.Mesh end, nil)
        if not (mesh and mesh:IsValid()) then
            log(("RMM[%d]: no Mesh"):format(i)); goto continue
        end
        local cur = safe(function() return mesh.RootMotionMode end, nil)
        log(("RMM[%d]: %s  RootMotionMode = %s (%s)"):format(i, className(p),
            tostring(cur), RMM[cur] or "?"))
        if setTo ~= nil then
            local ok = pcall(function() mesh.RootMotionMode = setTo end)
            local now = safe(function() return mesh.RootMotionMode end, nil)
            log(("RMM[%d]: set -> %s  now %s (%s)"):format(i, tostring(ok),
                tostring(now), RMM[now] or "?"))
        end
        ::continue::
    end
    if setTo ~= nil then log("RMM: move the client now.") end
end

RegisterConsoleCommandHandler("sdmp_rootmotion", function()
    ExecuteInGameThread(function() rootMotion(nil) end) return true end)
RegisterConsoleCommandHandler("sdmp_rootmotion_fix", function()
    ExecuteInGameThread(function() rootMotion(3) end) return true end)

log("SDMPDiag: sdmp_rootmotion reports RootMotionMode, sdmp_rootmotion_fix sets montages-only.")

-- RootMotionMode came back as a TrivialObject wrapper rather than a number.
-- UE4SS hands enum byte properties back that way, so unwrap it properly before
-- concluding anything.
local function enumVal(o)
    if o == nil then return nil, "nil" end
    if type(o) == "number" then return o, "number" end
    local ok, v = pcall(function() return o:get() end)
    if ok and type(v) == "number" then return v, "get()" end
    ok, v = pcall(function() return o:GetValue() end)
    if ok and type(v) == "number" then return v, "GetValue()" end
    ok, v = pcall(function() return tonumber(tostring(o)) end)
    if ok and type(v) == "number" then return v, "tostring" end
    return nil, "type=" .. type(o) .. " str=" .. tostring(o)
end

local function rootMotion2(setTo)
    for i, c in ipairs(listControllers()) do
        local p = safe(function() return c.Pawn end, nil)
        if not (p and p:IsValid()) then goto continue end
        local mesh = safe(function() return p.Mesh end, nil)
        if not (mesh and mesh:IsValid()) then
            log(("RM2[%d]: no Mesh"):format(i)); goto continue
        end

        local raw = safe(function() return mesh.RootMotionMode end, nil)
        local v, how = enumVal(raw)
        log(("RM2[%d]: %s RootMotionMode raw=%s  value=%s (%s) via %s"):format(
            i, className(p), tostring(raw), tostring(v), RMM[v] or "?", how))

        -- the anim instance carries its own root motion setting too
        local ai = safe(function() return mesh:GetAnimInstance() end, nil)
        if ai and ai:IsValid() then
            log(("RM2[%d]:   AnimInstance=%s  RootMotionMode=%s"):format(i, className(ai),
                tostring((enumVal(safe(function() return ai.RootMotionMode end, nil))))))
        end

        local cm = safe(function() return p.CharacterMovement end, nil)
        if cm and cm:IsValid() then
            log(("RM2[%d]:   HasAnimRootMotion=%s  bServerAcceptClientAuthoritativePosition=%s"):format(i,
                tostring(safe(function() return p:IsPlayingRootMotion() end, "?")),
                tostring(safe(function() return cm.bServerAcceptClientAuthoritativePosition end, "?"))))
        end

        if setTo ~= nil then
            local ok = pcall(function() mesh.RootMotionMode = setTo end)
            local nv = enumVal(safe(function() return mesh.RootMotionMode end, nil))
            log(("RM2[%d]: set %s -> ok=%s now=%s (%s)"):format(i, tostring(setTo),
                tostring(ok), tostring(nv), RMM[nv] or "?"))
        end
        ::continue::
    end
end

RegisterConsoleCommandHandler("sdmp_rootmotion2", function()
    ExecuteInGameThread(function() rootMotion2(nil) end) return true end)
RegisterConsoleCommandHandler("sdmp_rootmotion2_fix", function()
    ExecuteInGameThread(function() rootMotion2(3) end) return true end)

log("SDMPDiag: sdmp_rootmotion2 unwraps the enum properly; _fix sets montages-only.")

-- Root motion is out: AnimInstance RootMotionMode = 3, montages-only, already
-- the net-safe value, and IsPlayingRootMotion false.
--
-- More importantly the earlier 0/31 trace may have been my own instrument.
-- LoopAsync sleeps on a worker thread and queues onto the game thread; if the
-- game thread drains several queued callbacks in one frame, consecutive samples
-- read the same position and the next batch jumps. That IS the 0-then-double
-- pattern. So the thing four theories were built on might never have existed.
--
-- Sample from inside the frame instead. BlueprintUpdateAnimation is a real
-- UFunction that runs once per frame on the anim instance, so a hook there is
-- genuine per-frame data with no queueing in between.
local ftActive, ftN, ftLast, ftRows = false, 0, nil, {}

local function frameTrace()
    ftActive, ftN, ftLast, ftRows = true, 0, nil, {}
    log("FT: hooking BlueprintUpdateAnimation for 200 frames")
end

local okHook, errHook = pcall(function()
    RegisterHook("/Game/Blueprints/Player_AnimBP.Player_AnimBP_C:BlueprintUpdateAnimation",
    function(ctx)
        if not ftActive then return end
        local ok = pcall(function()
            local ai = ctx:get()
            local pawn = ai:GetOwningActor()
            if not (pawn and pawn:IsValid()) then return end
            -- only our own locally controlled character
            if safe(function() return pawn:IsLocallyControlled() end, false) ~= true then return end

            local l = pawn:K2_GetActorLocation()
            ftN = ftN + 1
            local step = 0.0
            if ftLast then
                step = math.sqrt((l.X-ftLast.x)^2 + (l.Y-ftLast.y)^2)
            end
            ftLast = { x = l.X, y = l.Y }
            ftRows[#ftRows+1] = step

            if ftN >= 200 then
                ftActive = false
                local parts = {}
                for i = 2, #ftRows do parts[#parts+1] = ("%.1f"):format(ftRows[i]) end
                log("FT: per-frame steps (units):")
                for i = 1, #parts, 40 do
                    log("FT:   " .. table.concat(parts, " ", i, math.min(i+39, #parts)))
                end
                local zero, big = 0, 0
                for i = 2, #ftRows do
                    if ftRows[i] < 0.05 then zero = zero + 1 end
                    if ftRows[i] > 20 then big = big + 1 end
                end
                log(("FT: %d frames, %d with no movement, %d jumps over 20 units"):format(
                    #ftRows, zero, big))
                log("FT: even steps = prediction is fine and the stutter is visual.")
                log("FT: zeros then jumps = the position really does stall.")
            end
        end)
        if not ok then ftActive = false; log("FT: hook body failed") end
    end)
end)
log("FT: hook registered = " .. tostring(okHook) .. (okHook and "" or (" err=" .. tostring(errHook))))

RegisterConsoleCommandHandler("sdmp_frametrace", function() frameTrace() return true end)

log("SDMPDiag: sdmp_frametrace samples inside the frame - no queueing artifact.")

-- The hook target didn't exist - BlueprintUpdateAnimation isn't implemented on
-- that anim blueprint - so nothing got sampled. But there's a simpler way to
-- settle whether the old trace was real: record world time with each sample.
--
-- If the "no movement" samples also show no time passing, they were batched
-- onto one frame and the stall was my instrument. If time advanced normally
-- while position didn't, the stall is real. Same data either way, and it
-- reports speed as step/dt so a steady 750 shows up as steady even if the
-- sampling is uneven.
local function fine3()
    local n, rows = 0, {}
    log("F3: sampling 120x with world time")
    LoopAsync(16, function()
        n = n + 1
        ExecuteInGameThread(function()
            local world = UEHelpers.GetWorld()
            local pc = UEHelpers.GetPlayerController()
            local p = pc and safe(function() return pc.Pawn end, nil) or nil
            if not (world and p and p:IsValid()) then return end
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local t = gs and safe(function() return gs:GetTimeSeconds(world) end, nil) or nil
            local l = safe(function() return p:K2_GetActorLocation() end, nil)
            if t and l then rows[#rows+1] = { t = t, x = l.X, y = l.Y } end

            if n >= 120 and #rows > 2 then
                local out = {}
                for i = 2, #rows do
                    local dt = rows[i].t - rows[i-1].t
                    local d  = math.sqrt((rows[i].x-rows[i-1].x)^2 + (rows[i].y-rows[i-1].y)^2)
                    out[#out+1] = ("dt=%.3f d=%.1f v=%.0f"):format(dt, d, dt > 0.0001 and d/dt or -1)
                end
                log("F3: dt / distance / implied speed")
                for i = 1, #out, 6 do
                    log("F3:   " .. table.concat(out, "  |  ", i, math.min(i+5, #out)))
                end
                local sameFrame = 0
                for i = 2, #rows do
                    if (rows[i].t - rows[i-1].t) < 0.0005 then sameFrame = sameFrame + 1 end
                end
                log(("F3: %d of %d samples landed on the same frame as the previous one"):format(
                    sameFrame, #rows - 1))
                log("F3: lots of those = the old 0/31 trace was my sampling, not the game.")
            end
        end)
        return n >= 120
    end)
end

-- So we can pick a real per-frame hook target next time instead of guessing.
local function animFuncs()
    local pc = UEHelpers.GetPlayerController()
    local p = pc and safe(function() return pc.Pawn end, nil) or nil
    local mesh = p and p:IsValid() and safe(function() return p.Mesh end, nil) or nil
    local ai = mesh and mesh:IsValid() and safe(function() return mesh:GetAnimInstance() end, nil) or nil
    if not (ai and ai:IsValid()) then log("AF: no anim instance"); return end
    local cls = safe(function() return ai:GetClass() end, nil)
    log("AF: " .. safe(function() return cls:GetFName():ToString() end, "?"))
    pcall(function()
        cls:ForEachFunction(function(fn)
            log("AF:   " .. safe(function() return fn:GetFName():ToString() end, "?"))
        end)
    end)
end

RegisterConsoleCommandHandler("sdmp_fine3",    function() fine3() return true end)
RegisterConsoleCommandHandler("sdmp_animfuncs",function() ExecuteInGameThread(animFuncs) return true end)

log("SDMPDiag: sdmp_fine3 samples with world time; sdmp_animfuncs lists anim functions.")

-- Nobody has checked whether the server is correcting the client. Position
-- "agreeing" doesn't rule it out - after a correction they agree by definition.
-- And a correction on your own pawn looks exactly like this: snap back, replay,
-- catch up. SetReplicateMovement(false) wouldn't touch it either, corrections
-- go through CharacterMovement's own RPCs.
--
-- There's a reason to suspect it. BP_PlayerCharacter has ReceiveTick, an
-- FInterpTo, and sets MaxWalkSpeed through Svr_UpdateSpeed -> MC_UpdateSpeed
-- (plus Svr_UpdateSprintSpeed / Svr_UpdateWalkSpeed / Svr_SetActorLocation /
-- Svr_SetActorRotation / Svr_SetMovement). If speed is pushed over RPCs while
-- the client predicts with whatever value it had, server and client simulate
-- the same move at different speeds and the server snaps us back.
--
-- sdmp_rpcwatch counts all of that per second for 15s. Run it on BOTH
-- instances and sprint on the client. It flips net.UsePackedMovementRPCs to 0
-- locally so acks (ClientAckGoodMove) and corrections (ClientAdjustPosition)
-- arrive as separate RPCs we can tell apart.
local BPC = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
local WATCH = {
    -- client side, native
    "/Script/Engine.Character:ClientAckGoodMove",
    "/Script/Engine.Character:ClientAdjustPosition",
    "/Script/Engine.Character:ClientVeryShortAdjustPosition",
    "/Script/Engine.Character:ClientAdjustRootMotionPosition",
    "/Script/Engine.Character:ClientMoveResponsePacked",
    -- server side, native
    "/Script/Engine.Character:ServerMovePacked",
    "/Script/Engine.Character:ServerMove",
    "/Script/Engine.Character:ServerMoveNoBase",
    "/Script/Engine.Character:ServerMoveDual",
    "/Script/Engine.Character:ServerMoveDualNoBase",
    -- the game's own movement RPCs
    BPC .. "Svr_UpdateSpeed",
    BPC .. "MC_UpdateSpeed",
    BPC .. "Svr_UpdateSprintSpeed",
    BPC .. "Svr_UpdateWalkSpeed",
    BPC .. "Svr_SetActorLocation",
    BPC .. "Svr_SetActorRotation",
    BPC .. "Svr_SetMovement",
    BPC .. "Svr_SetJumpVelocity",
    BPC .. "Svr_ReduceStamina",
    BPC .. "MC_SetCapsuleSize",
}

local rw = { hooked = false, on = false, counts = {}, lastArg = {}, ok = 0, bad = {} }

local function shortName(path) return path:match(":(.+)$") or path end

local function rwHookAll()
    if rw.hooked then return end
    rw.hooked = true
    for _, path in ipairs(WATCH) do
        local name = shortName(path)
        local ok, err = pcall(function()
            RegisterHook(path, function(ctx, a1)
                if not rw.on then return end
                local who = "?"
                pcall(function()
                    local c = ctx:get()
                    who = (c:IsLocallyControlled() == true) and "own" or "other"
                end)
                local key = name .. "@" .. who
                rw.counts[key] = (rw.counts[key] or 0) + 1
                if a1 then
                    pcall(function()
                        local v = a1:get()
                        if type(v) == "number" then rw.lastArg[key] = v end
                    end)
                end
            end)
        end)
        if ok then rw.ok = rw.ok + 1 else rw.bad[#rw.bad+1] = name end
    end
    log(("RW: hooked %d/%d"):format(rw.ok, #WATCH))
    if #rw.bad > 0 then log("RW: not hookable: " .. table.concat(rw.bad, ", ")) end
end

local function rwCvar(cmd)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local world = UEHelpers.GetWorld()
    local pc = UEHelpers.GetPlayerController()
    local ok = pcall(function() ksl:ExecuteConsoleCommand(world, cmd, pc) end)
    log("RW: " .. cmd .. " -> " .. tostring(ok))
end

local function rpcWatch()
    local side = "?"
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        side = (pc and safe(function() return pc:HasAuthority() end, false)) and "HOST" or "CLIENT"
        rwCvar("net.UsePackedMovementRPCs 0")
        rwHookAll()
        rw.counts, rw.lastArg, rw.on = {}, {}, true
        log("RW[" .. side .. "]: watching 15s - sprint on the client now")
    end)
    local sec = 0
    LoopAsync(1000, function()
        sec = sec + 1
        ExecuteInGameThread(function()
            local keys = {}
            for k in pairs(rw.counts) do keys[#keys+1] = k end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                local s = k .. "=" .. rw.counts[k]
                if rw.lastArg[k] then s = s .. ("(%.0f)"):format(rw.lastArg[k]) end
                parts[#parts+1] = s
            end
            log(("RW[%s] t=%02d  %s"):format(side, sec,
                #parts > 0 and table.concat(parts, "  ") or "(nothing)"))
            rw.counts, rw.lastArg = {}, {}
            if sec >= 15 then
                rw.on = false
                log("RW[" .. side .. "]: done. ClientAdjustPosition@own on the CLIENT = server is correcting us.")
            end
        end)
        return sec >= 15
    end)
end

-- If rpcwatch shows corrections, this is the A/B: tell the server to trust the
-- remote client's movement. Stutter gone = corrections were it. Run on HOST.
local function trustClient(on)
    local n = 0
    local chars = FindAllOf("BP_PlayerCharacter_C") or {}
    for _, c in ipairs(chars) do
        if c:IsValid() and safe(function() return c:IsLocallyControlled() end, true) == false then
            pcall(function()
                local cmc = c.CharacterMovement
                cmc.bIgnoreClientMovementErrorChecksAndCorrection = on
                cmc.bServerAcceptClientAuthoritativePosition = on
                n = n + 1
                log(("TC: %s ignoreCorrections=%s acceptClientPos=%s"):format(
                    className(c),
                    tostring(cmc.bIgnoreClientMovementErrorChecksAndCorrection),
                    tostring(cmc.bServerAcceptClientAuthoritativePosition)))
            end)
        end
    end
    log(("TC: applied to %d remote character(s)"):format(n))
end

RegisterConsoleCommandHandler("sdmp_rpcwatch",    function() rpcWatch() return true end)
RegisterConsoleCommandHandler("sdmp_trustclient", function() ExecuteInGameThread(function() trustClient(true)  end) return true end)
RegisterConsoleCommandHandler("sdmp_trustserver", function() ExecuteInGameThread(function() trustClient(false) end) return true end)

log("SDMPDiag: sdmp_rpcwatch counts movement RPCs; sdmp_trustclient turns off server corrections.")

-- sdmp_trustclient didn't change the stutter, and the host log shows a steady
-- ~55 ServerMovePacked/s with no speed RPC spam. Corrections are out, and with
-- them the network. Whatever it is happens on the client's own frame.
--
-- So sample inside that frame. BP_PlayerCharacter implements ReceiveTick (the
-- anim BP didn't, which is why sdmp_frametrace never fired). Per frame we log
-- the actor, the mesh, the camera and the yaws, so the layer that stalls names
-- itself: actor stalls = movement, actor smooth but camera stalls = camera,
-- both smooth = it's the animation / what you're looking at.
local tk = { hooked = false, on = false, rows = {}, side = "?" }

local function v2(a, b) return math.sqrt((a.X-b.X)^2 + (a.Y-b.Y)^2) end

local function tkReport()
    local r = tk.rows
    log(("TK[%s]: %d frames. dt ms | actor d | mesh d | cam d | actor yaw | ctrl yaw | vel"):format(tk.side, #r))
    local stallA, stallM, stallC, spikeDt = 0, 0, 0, 0
    local sumDt = 0
    for i = 2, #r do
        local a, b = r[i-1], r[i]
        local dt = b.t - a.t
        local dA, dM, dC = v2(a.a, b.a), v2(a.m, b.m), v2(a.c, b.c)
        sumDt = sumDt + dt
        if b.v > 100 then
            if dA < 0.05 then stallA = stallA + 1 end
            if dM < 0.05 then stallM = stallM + 1 end
            if dC < 0.05 then stallC = stallC + 1 end
        end
        b.line = ("%5.1f %6.1f %6.1f %6.1f %7.1f %7.1f %4.0f"):format(
            dt*1000, dA, dM, dC, b.ay, b.cy, b.v)
    end
    local mean = sumDt / math.max(1, #r-1)
    for i = 2, #r do
        if (r[i].t - r[i-1].t) > mean * 2 then spikeDt = spikeDt + 1 end
    end
    for i = 2, #r do log("TK:  " .. r[i].line) end
    log(("TK[%s]: mean dt %.1f ms, %d dt spikes (>2x mean)"):format(tk.side, mean*1000, spikeDt))
    log(("TK[%s]: while moving, frames with no step - actor %d, mesh %d, camera %d"):format(
        tk.side, stallA, stallM, stallC))
end

local function tkHook()
    if tk.hooked then return true end
    local ok, err = pcall(function()
        RegisterHook("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:ReceiveTick",
        function(ctx)
            if not tk.on then return end
            pcall(function()
                local p = ctx:get()
                if p:IsLocallyControlled() ~= true then return end
                local world = UEHelpers.GetWorld()
                local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                local pc = p.Controller
                local cam = pc.PlayerCameraManager
                local a = p:K2_GetActorLocation()
                local m = p.Mesh:K2_GetComponentLocation()
                local c = cam:GetCameraLocation()
                local vel = p.CharacterMovement.Velocity
                tk.rows[#tk.rows+1] = {
                    t  = gs:GetTimeSeconds(world),
                    a  = { X = a.X, Y = a.Y },
                    m  = { X = m.X, Y = m.Y },
                    c  = { X = c.X, Y = c.Y },
                    ay = p:K2_GetActorRotation().Yaw,
                    cy = pc:GetControlRotation().Yaw,
                    v  = math.sqrt(vel.X^2 + vel.Y^2),
                }
                if #tk.rows >= 240 then tk.on = false; tkReport() end
            end)
        end)
    end)
    tk.hooked = ok
    if not ok then log("TK: hook failed: " .. tostring(err)) end
    return ok
end

local function tickTrace()
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        tk.side = (pc and safe(function() return pc:HasAuthority() end, false)) and "HOST" or "CLIENT"
        if not tkHook() then return end
        tk.rows, tk.on = {}, true
        log("TK[" .. tk.side .. "]: recording 240 frames from ReceiveTick - be running")
    end)
end

RegisterConsoleCommandHandler("sdmp_ticktrace", function() tickTrace() return true end)

log("SDMPDiag: sdmp_ticktrace samples actor/mesh/camera inside ReceiveTick.")

-- ticktrace result: frames are steady (4.1 ms, no hitches) and the actor moves
-- smoothly ~3 units a frame - except every so often it jumps 10-17 units in one
-- frame, and the yaw snaps back to an old value (148 -> 17.6) and re-turns.
-- Something is writing old position/rotation onto our own pawn. The frame is
-- fine; the pawn is being teleported.
--
-- sdmp_snaptrace is ticktrace plus an event log: every way the pawn can be
-- moved from outside (net RPCs, OnRep, BP SetActorLocation/Rotation, the
-- character BP's own MC_/Client_/OnRep_ functions) is hooked and stamped with
-- the frame it landed on. The report lists what fired on each snap frame.
local st = { hooked = false, on = false, rows = {}, ev = {}, pawnAddr = nil, side = "?", count = {} }

local ST_NATIVE = {
    "/Script/Engine.Actor:K2_SetActorLocation",
    "/Script/Engine.Actor:K2_SetActorRotation",
    "/Script/Engine.Actor:K2_SetActorLocationAndRotation",
    "/Script/Engine.Actor:K2_SetActorTransform",
    "/Script/Engine.Actor:K2_TeleportTo",
    "/Script/Engine.Actor:K2_AddActorWorldOffset",
    "/Script/Engine.Actor:K2_AddActorWorldRotation",
    "/Script/Engine.Actor:OnRep_ReplicatedMovement",
    "/Script/Engine.Character:OnRep_ReplicatedBasedMovement",
    "/Script/Engine.Character:ClientMoveResponsePacked",
    "/Script/Engine.Character:ClientAdjustPosition",
    "/Script/Engine.Character:ClientVeryShortAdjustPosition",
    "/Script/Engine.Character:ClientAdjustRootMotionPosition",
    "/Script/Engine.Character:ClientAckGoodMove",
    "/Script/Engine.Character:LaunchCharacter",
    "/Script/Engine.Controller:SetControlRotation",
    "/Script/Engine.Controller:ClientSetRotation",
    "/Script/Engine.Controller:ClientSetLocation",
}

local function stAddr(o) return safe(function() return o:GetAddress() end, nil) end

local function stMark(name, ctx)
    if not st.on then return end
    local mine = false
    pcall(function()
        local o = ctx:get()
        local a = o:GetAddress()
        if a == st.pawnAddr then mine = true; return end
        -- controller functions: is it our controller?
        local p = safe(function() return o.Pawn end, nil)
        if p and p:IsValid() and p:GetAddress() == st.pawnAddr then mine = true; return end
        local ow = safe(function() return o:GetOwner() end, nil)
        if ow and ow:IsValid() and ow:GetAddress() == st.pawnAddr then mine = true end
    end)
    if not mine then return end
    st.ev[#st.ev+1] = { f = #st.rows, n = name }
    st.count[name] = (st.count[name] or 0) + 1
end

local function stReport()
    local r = st.rows
    local steps = {}
    for i = 2, #r do
        steps[i] = v2(r[i-1].a, r[i].a)
    end
    local byFrame = {}
    for _, e in ipairs(st.ev) do
        byFrame[e.f] = byFrame[e.f] or {}
        table.insert(byFrame[e.f], e.n)
    end
    local snaps = 0
    log(("ST[%s]: snap frames (step > 2x neighbours, or yaw jump > 3 deg):"):format(st.side))
    for i = 3, #r - 1 do
        local nb = (steps[i-1] + steps[i+1]) / 2
        local dyaw = math.abs(((r[i].ay - r[i-1].ay + 180) % 360) - 180)
        if (steps[i] > 2 * nb and steps[i] - nb > 2) or dyaw > 3 then
            snaps = snaps + 1
            local evs = {}
            for f = i - 2, i do
                for _, n in ipairs(byFrame[f] or {}) do evs[#evs+1] = n .. "@" .. (f - i) end
            end
            -- signed: how much of this step went along the direction we were
            -- already moving. Negative = pulled back, big positive = shoved ahead.
            local px, py = r[i-1].a.X - r[i-2].a.X, r[i-1].a.Y - r[i-2].a.Y
            local pl = math.sqrt(px*px + py*py)
            local fwd = 0
            if pl > 0.001 then
                fwd = ((r[i].a.X - r[i-1].a.X) * px + (r[i].a.Y - r[i-1].a.Y) * py) / pl
            end
            log(("ST:  frame %3d  step %5.1f (nb %4.1f) fwd %6.1f  yaw %6.1f->%6.1f  events: %s"):format(
                i, steps[i], nb, fwd, r[i-1].ay, r[i].ay, #evs > 0 and table.concat(evs, ", ") or "NONE"))
        end
    end
    log(("ST[%s]: %d snaps in %d frames"):format(st.side, snaps, #r))
    -- raw series, so the shape is visible and not just the snap count:
    -- per frame "step@dt_ms" for actor, then mesh steps separately
    do
        local parts, mparts, zero, dbl = {}, {}, 0, 0
        for i = 2, #r do
            local dt = (r[i].t or 0) - (r[i-1].t or 0)
            parts[#parts+1] = ("%.1f@%.0f"):format(steps[i], dt * 1000)
            if r[i].m and r[i-1].m then mparts[#mparts+1] = ("%.1f"):format(v2(r[i-1].m, r[i].m)) end
        end
        for i = 1, math.min(#parts, 240), 40 do
            log("ST raw: " .. table.concat(parts, " ", i, math.min(i + 39, #parts, 240)))
        end
        for i = 1, math.min(#mparts, 240), 60 do
            log("ST mesh: " .. table.concat(mparts, " ", i, math.min(i + 59, #mparts, 240)))
        end
    end
    do
        -- frame-quantized view: how many frames moved ~0, and how many moved
        -- 2+ frames' worth, relative to the median step while moving
        local mv = {}
        for i = 2, #r do if steps[i] > 0.5 then mv[#mv+1] = steps[i] end end
        table.sort(mv)
        local med = mv[math.max(1, math.floor(#mv / 2))] or 0
        local stall, dbl = 0, 0
        for i = 2, #r do
            if r[i].v > 100 and med > 0 then
                if steps[i] < med * 0.25 then stall = stall + 1 end
                if steps[i] > med * 1.75 then dbl = dbl + 1 end
            end
        end
        st.lastStalls, st.lastDoubles = stall, dbl
        log(("ST[%s]: median step %.1f, %d stalled frames, %d catch-up frames"):format(st.side, med, stall, dbl))
        local tpAll, tpStall, tpNext = 0, 0, 0
        for i = 2, #r do
            if r[i].tp == true then tpAll = tpAll + 1 end
            if r[i].v > 100 and med > 0 and steps[i] < med * 0.25 then
                if r[i].tp == true then tpStall = tpStall + 1 end
                if r[i+1] and r[i+1].tp == true then tpNext = tpNext + 1 end
            end
        end
        log(("ST[%s]: bJustTeleported true on %d/%d frames; on %d of %d stalls (next frame: %d)"):format(
            st.side, tpAll, #r - 1, tpStall, stall, tpNext))
    end
    -- Which events line up with stalls: hits on stall frames (or the frame
    -- before) vs total hits.
    do
        local stallSet, nStall = {}, 0
        for i = 3, #r - 1 do
            if r[i].v > 100 and steps[i] < 0.5 then stallSet[i] = true; nStall = nStall + 1 end
        end
        local onStall, total = {}, {}
        for _, e in ipairs(st.ev) do
            total[e.n] = (total[e.n] or 0) + 1
            -- event recorded after row f was taken lands in row f+1's step
            if stallSet[e.f + 1] or stallSet[e.f] then onStall[e.n] = (onStall[e.n] or 0) + 1 end
        end
        local list = {}
        for n, c in pairs(total) do list[#list+1] = { n = n, s = onStall[n] or 0, t = c } end
        table.sort(list, function(a, b) return a.s > b.s end)
        local out = {}
        for i = 1, math.min(12, #list) do
            out[#out+1] = ("%s %d/%d"):format(list[i].n, list[i].s, list[i].t)
        end
        log(("ST corr: %d stall frames. event: hits near a stall / total hits -> %s"):format(
            nStall, #out > 0 and table.concat(out, ", ") or "no events at all"))
    end
    -- On each stalled frame (and the frames either side): did the movement
    -- component run? LastUpdateLocation moves only when PerformMovement runs.
    -- Velocity/accel/input say whether it had a reason to move.
    do
        local shown = 0
        for i = 3, #r - 1 do
            if r[i].v > 100 and steps[i] < 0.5 and shown < 12 then
                shown = shown + 1
                local function d(a, b) return (a and b) and v2(a, b) or -1 end
                local cells = {}
                for j = i - 1, i + 1 do
                    cells[#cells+1] = ("[%s step=%.1f lastUpd=%.1f vel=%.0f tp=%s nu=%s]"):format(
                        j == i and "STALL" or (j < i and "prev" or "next"),
                        steps[j] or -1, d(r[j-1] and r[j-1].lu, r[j].lu), r[j].v,
                        tostring(r[j].tp), tostring(r[j].nu))
                end
                log("ST stall f" .. i .. " " .. table.concat(cells, " "))
            end
        end
    end
    st.lastSnaps = snaps
    st.lastCounts = {}
    for k, v in pairs(st.count) do st.lastCounts[k] = v end
    local parts = {}
    for k, v in pairs(st.count) do parts[#parts+1] = k .. "=" .. v end
    table.sort(parts)
    log("ST: event totals: " .. (#parts > 0 and table.concat(parts, "  ") or "none"))
end

local function stHookAll(pawn)
    if st.hooked then return end
    st.hooked = true
    local ok, bad = 0, {}
    local function hook(path, name)
        local good = pcall(function()
            RegisterHook(path, function(ctx) stMark(name, ctx) end)
        end)
        if good then ok = ok + 1 else bad[#bad+1] = name end
    end
    for _, path in ipairs(ST_NATIVE) do hook(path, shortName(path)) end
    -- Every Blueprint function on the character and its controller, plus the
    -- native component setters. The stall-frame log showed velocity still
    -- climbing on the stalled frame while the position didn't move at all -
    -- the movement maths ran, the move didn't land. Something on those
    -- frames is setting or holding the transform; whatever fires on nearly
    -- every stall frame and rarely otherwise is it.
    local skip = { ReceiveTick = true, ExecuteUbergraph_BP_PlayerCharacter = true }
    pcall(function()
        pawn:GetClass():ForEachFunction(function(fn)
            local n = safe(function() return fn:GetFName():ToString() end, "")
            -- broad hooking came back flat (Event_AutoRun etc. hit at the base
            -- rate) and 849 hooks perturb the very thing we're timing, so back
            -- to network-driven functions only
            if n:match("^MC_") or n:match("^Client_") or n:match("^OnRep_") then hook(BPC .. n, n) end
        end)
    end)
    pcall(function()
        local pc = pawn.Controller
        local cls = pc:GetClass()
        local path = safe(function() return cls:GetFullName() end, "")
        path = path:match("^%S+%s+(.+)$") or path
        if false and path:find("^/Game/") then
            cls:ForEachFunction(function(fn)
                local n = safe(function() return fn:GetFName():ToString() end, "")
                if n ~= "" and not n:find("Ubergraph") and not n:find("DelegateSignature") and n ~= "ReceiveTick" then hook(path .. ":" .. n, "PC." .. n) end
            end)
        end
    end)
    for _, n in ipairs({ "K2_SetWorldLocation", "K2_SetWorldRotation", "K2_SetWorldTransform",
                         "K2_SetWorldLocationAndRotation", "K2_SetRelativeLocation", "K2_SetRelativeRotation",
                         "K2_SetRelativeTransform", "K2_SetRelativeLocationAndRotation",
                         "K2_AddWorldOffset", "K2_AddWorldRotation", "K2_AddRelativeLocation",
                         "K2_AddLocalOffset", "SetWorldScale3D" }) do
        hook("/Script/Engine.SceneComponent:" .. n, "SC." .. n)
    end
    for _, n in ipairs({ "StopMovementImmediately", "SetMovementMode", "AddImpulse", "AddForce",
                         "SetPlaneConstraintEnabled", "DisableMovement" }) do
        hook("/Script/Engine.CharacterMovementComponent:" .. n, "CMC." .. n)
    end
    -- the per-frame sampler
    local good = pcall(function()
        RegisterHook(BPC .. "ReceiveTick", function(ctx)
            if not st.on then return end
            pcall(function()
                local p = ctx:get()
                if p:GetAddress() ~= st.pawnAddr then return end
                local pc = p.Controller
                local a = p:K2_GetActorLocation()
                local vel = p.CharacterMovement.Velocity
                local mloc = safe(function() return p.Mesh:K2_GetComponentLocation() end, nil)
                local cmc = p.CharacterMovement
                local lu = safe(function() return cmc:GetLastUpdateLocation() end, nil)
                local acc = safe(function() return cmc:GetCurrentAcceleration() end, nil)
                local inp = safe(function() return p:GetLastMovementInputVector() end, nil)
                st.rows[#st.rows+1] = {
                    a  = { X = a.X, Y = a.Y },
                    m  = mloc and { X = mloc.X, Y = mloc.Y } or nil,
                    lu = lu and { X = lu.X, Y = lu.Y } or nil,
                    acc = acc and math.sqrt(acc.X^2 + acc.Y^2) or -1,
                    tp = safe(function() return cmc.bJustTeleported end, nil),
                    nu = safe(function() return cmc.bNetworkUpdateReceived end, nil),
                    inp = inp and math.sqrt(inp.X^2 + inp.Y^2) or -1,
                    t  = safe(function()
                        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(UEHelpers.GetWorld())
                    end, 0),
                    ay = p:K2_GetActorRotation().Yaw,
                    cy = pc:GetControlRotation().Yaw,
                    v  = math.sqrt(vel.X^2 + vel.Y^2),
                }
                if #st.rows >= 480 then st.on = false; stReport() end
            end)
        end)
    end)
    if good then ok = ok + 1 else bad[#bad+1] = "ReceiveTick" end
    log(("ST: hooked %d functions"):format(ok))
    if #bad > 0 then log("ST: couldn't hook: " .. table.concat(bad, ", ")) end
end

local function snapTrace()
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        local p = pc and safe(function() return pc.Pawn end, nil) or nil
        if not (p and p:IsValid()) then log("ST: no pawn"); return end
        st.side = safe(function() return pc:HasAuthority() end, false) and "HOST" or "CLIENT"
        st.pawnAddr = stAddr(p)
        -- unpacked movement RPCs so an ack (ClientAckGoodMove) and a correction
        -- (ClientAdjustPosition) show up as different names. Needs typing on
        -- the host too: net.UsePackedMovementRPCs 0
        rwCvar("net.UsePackedMovementRPCs 0")
        stHookAll(p)
        st.rows, st.ev, st.count, st.on = {}, {}, {}, true
        log("ST[" .. st.side .. "]: recording 480 frames - sprint and turn a bit")
    end)
end

RegisterConsoleCommandHandler("sdmp_snaptrace", function() snapTrace() return true end)

log("SDMPDiag: sdmp_snaptrace logs what moved the pawn on each snap frame.")

-- ===========================================================================
-- Zombies never hit remote players. The zombie's attack is all animation:
-- AttackPlayer plays a montage on the server, and AnimNotify_ZombieAttack*
-- inside that montage starts the Left/RightArmTrace / AttackTrace sphere traces
-- that call ApplyDamage. Nothing about it is replicated. On a listen server the
-- zombie's mesh only animates when the HOST can see it, so a zombie swinging at
-- a client somewhere off the host's screen plays a frozen montage, no notify
-- fires, and the trace never runs. Fix: on the host, any zombie within ~50 m of
-- a remote player always ticks its animation; put it back once nobody's near.
local ZF = { touched = {}, logged = 0 }
local function zombieAnimFix()
    local world = UEHelpers.GetWorld()
    if not (world and safe(function() return world:IsValid() end, false)) then return end
    local gm = safe(function() return world.AuthorityGameMode end, nil)
    if not (gm and safe(function() return gm:IsValid() end, false)) then return end
    local remote = {}
    for _, c in ipairs(listControllers()) do
        if safe(function() return c:IsLocalController() end, true) == false then
            local p = safe(function() return c.Pawn end, nil)
            if p and safe(function() return p:IsValid() end, false) then
                local l = safe(function() return p:K2_GetActorLocation() end, nil)
                if l then remote[#remote + 1] = { X = l.X, Y = l.Y, Z = l.Z } end
            end
        end
    end
    if #remote == 0 and next(ZF.touched) == nil then return end
    local seen = {}
    local zs = safe(function() return FindAllOf("BP_MasterZombie_C") end, nil) or {}
    for _, z in ipairs(zs) do
        if safe(function() return z:IsValid() end, false) then
            local key = safe(function() return z:GetAddress() end, nil)
            local mesh = safe(function() return z.Mesh end, nil)
            if key and mesh and safe(function() return mesh:IsValid() end, false) then
                seen[key] = true
                local zl = safe(function() return z:K2_GetActorLocation() end, nil)
                local near = false
                if zl then
                    for _, r in ipairs(remote) do
                        if (r.X - zl.X)^2 + (r.Y - zl.Y)^2 + (r.Z - zl.Z)^2 < 5000 * 5000 then near = true; break end
                    end
                end
                local t = ZF.touched[key]
                if near and not t then
                    local orig = safe(function() local v = mesh.VisibilityBasedAnimTickOption; return type(v) == "number" and v or v:get() end, nil)
                    local uro = safe(function() return mesh.bEnableUpdateRateOptimizations end, nil)
                    pcall(function() mesh.VisibilityBasedAnimTickOption = 0 end)   -- AlwaysTickPoseAndRefreshBones
                    pcall(function() mesh.bEnableUpdateRateOptimizations = false end)
                    ZF.touched[key] = { mesh = mesh, orig = orig, uro = uro }
                    if ZF.logged < 8 then
                        ZF.logged = ZF.logged + 1
                        log(("ZF: %s near a remote player - animation always ticks (was %s, uro %s)"):format(
                            className(z), tostring(orig), tostring(uro)))
                    end
                elseif t and not near then
                    if t.orig then pcall(function() mesh.VisibilityBasedAnimTickOption = t.orig end) end
                    if t.uro ~= nil then pcall(function() mesh.bEnableUpdateRateOptimizations = t.uro end) end
                    ZF.touched[key] = nil
                end
            end
        end
    end
    for k in pairs(ZF.touched) do
        if not seen[k] then ZF.touched[k] = nil end   -- dead or despawned
    end
end
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(zombieAnimFix)
        if not ok then log("ZF error: " .. tostring(err)) end
    end)
    return false
end)

-- The attack montage only ever plays on the host (PlayAnimMontage isn't
-- replicated and the zombie has no multicast for it), so on a client zombies
-- deal damage without ever swinging. Clients play the swing themselves: a live
-- zombie within melee range of any player, not running, swings on the same
-- 1.45-2.05s rhythm the host uses. The client copy's damage is zeroed first,
-- because the montage's notifies run the hit traces and the hit code has no
-- authority check - a client swing would otherwise hurt the local copy of the
-- player (ApplyDamage with 0 does nothing; the blood puff still shows).
local ZA = { next = {}, tick = 0, plays = 0, logged = 0, sndErr = false }
local function zombieSwingMirror()
    local world = UEHelpers.GetWorld()
    if not (world and safe(function() return world:IsValid() end, false)) then return end
    local gm = safe(function() return world.AuthorityGameMode end, nil)
    local isHost = gm and safe(function() return gm:IsValid() end, false)
    ZA.tick = ZA.tick + 0.25
    ZA.st = ZA.st or { at = 0 }
    local st = ZA.st
    local report = ZA.tick >= st.at
    if report then st.at = ZA.tick + 4 end
    if isHost then   -- host / single player: real swings
        if report and (ZA.hostSaid or 0) < 3 then ZA.hostSaid = (ZA.hostSaid or 0) + 1; log("ZA status: has authority, not mirroring") end
        return
    end
    local players = {}
    for _, pc in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if safe(function() return pc:IsValid() end, false) then
            local l = safe(function() return pc:K2_GetActorLocation() end, nil)
            if l then players[#players + 1] = { X = l.X, Y = l.Y, Z = l.Z } end
        end
    end
    if #players == 0 then
        if report then log("ZA status: client, no BP_PlayerCharacter_C found") end
        return
    end
    st.nz, st.best, st.bspd, st.bdz = 0, 1e9, -1, 0
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local seen = {}
    for _, z in ipairs(safe(function() return FindAllOf("BP_MasterZombie_C") end, nil) or {}) do
        if safe(function() return z:IsValid() end, false) then
            local key = safe(function() return z:GetAddress() end, nil)
            if key then
                seen[key] = true
                -- client copy never deals damage; the host's copy does that
                if safe(function() return z.DamageToDo end, 0) ~= 0 then
                    pcall(function() z.DamageToDo = 0 end)
                    pcall(function() z.DamageMultiplier = 0 end)
                    pcall(function() z["CanCauseRadDamage?"] = false end)
                end
                local dead = safe(function() return z["IsDead?"] end, false)
                local zl = safe(function() return z:K2_GetActorLocation() end, nil)
                st.nz = st.nz + 1
                if zl then
                    for _, p in ipairs(players) do
                        local d = math.sqrt((p.X - zl.X)^2 + (p.Y - zl.Y)^2)
                        if d < st.best then
                            st.best, st.bdz, st.bdead = d, p.Z - zl.Z, dead
                            local v = safe(function() return z:GetVelocity() end, nil)
                            st.bspd = v and math.sqrt(v.X * v.X + v.Y * v.Y) or -1
                        end
                    end
                end
                if zl and not dead and (ZA.next[key] or 0) <= ZA.tick then
                    local close = false
                    for _, p in ipairs(players) do
                        local d2 = (p.X - zl.X)^2 + (p.Y - zl.Y)^2
                        if d2 < 220 * 220 and math.abs(p.Z - zl.Z) < 200 then close = true; break end
                    end
                    local v = close and safe(function() return z:GetVelocity() end, nil)
                    if close and v and (v.X * v.X + v.Y * v.Y) < 300 * 300 then
                        local arr = safe(function() return z.AttackMontage end, nil)
                        local n = arr and safe(function() return arr:GetArrayNum() end, 0) or 0
                        if n == 0 and not ZA.nErr then ZA.nErr = true; log("ZA: zombie has no AttackMontage entries on this machine") end
                        if n > 0 then
                            local e = safe(function() return arr[math.random(1, n)] end, nil)
                            local m = e
                            if not (m and safe(function() return m:IsValid() end, false)) then
                                m = safe(function() return e:get() end, nil)
                            end
                            if not (m and safe(function() return m:IsValid() end, false)) and not ZA.mErr then
                                ZA.mErr = true
                                log(("ZA: couldn't read an attack montage (n=%d, elem=%s)"):format(n, type(e)))
                            end
                            if m and safe(function() return m:IsValid() end, false) then
                                local ok = pcall(function() z:PlayAnimMontage(m, 1.0, FName("None")) end)
                                if gs and gs:IsValid() then
                                    local sok = pcall(function()
                                        gs:PlaySoundAtLocation(z, z.AttackSound, zl, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil)
                                    end)
                                    if not sok and not ZA.sndErr then ZA.sndErr = true; log("ZA: attack sound failed") end
                                end
                                ZA.plays = ZA.plays + 1
                                if ZA.logged < 6 then
                                    ZA.logged = ZA.logged + 1
                                    log(("ZA: %s swings (montage ok=%s, %d so far)"):format(className(z), tostring(ok), ZA.plays))
                                end
                            end
                        end
                        local lo = safe(function() return z.TimeBetweenAttacksMin end, 1.45) or 1.45
                        local hi = safe(function() return z.TimeBetweenAttacksMax end, 2.05) or 2.05
                        ZA.next[key] = ZA.tick + lo + math.random() * (hi - lo)
                    end
                end
            end
        end
    end
    for k in pairs(ZA.next) do if not seen[k] then ZA.next[k] = nil end end
    if report and st.nz > 0 then
        log(("ZA status: players=%d zombies=%d nearest=%.0f dz=%.0f speed=%.0f dead=%s swings=%d"):format(
            #players, st.nz, st.best, st.bdz, st.bspd, tostring(st.bdead), ZA.plays))
    elseif report then
        log(("ZA status: players=%d, no BP_MasterZombie_C found"):format(#players))
    end
end
LoopAsync(250, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(zombieSwingMirror)
        if not ok then log("ZA error: " .. tostring(err)) end
    end)
    return false
end)

-- ===========================================================================
-- Downed / revive. In co-op, a hit that would kill you puts you down instead:
-- you crawl, can't jump, and bleed out over DN.BLEED seconds (zombie hits
-- while down take a couple of seconds off). A partner crouching next to you
-- for DN.REVIVE seconds gets you back up at DN.UP_HP health. Single player is
-- untouched (no remote players = vanilla death).
--
-- Host is authoritative. Lethal damage is caught in a PRE hook on the native
-- GameplayStatics:ApplyDamage (zombie hits, bleeding etc. all go through it;
-- Blueprint hooks only run after the function, too late). State goes to every
-- machine through PlayerState.Score, which the game doesn't use:
--   0 = fine, 100+N = down with N seconds left, 1000+P = being revived, P%.
-- Each machine then handles its own pawn (crouch, crawl speed, no jump) so
-- client prediction agrees with the host, and shows the notifications.
--
-- Bleeding out uses the game's own death, which calls
-- GetPlayerController(self, 0).UnPossess() - on the host that's the HOST's
-- controller, so a client dying used to take the host's character away. We
-- re-possess the host's pawn straight after.
-- ===========================================================================
local DN = { BLEED = 60, REVIVE = 5, DOWN_HP = 5, UP_HP = 30, RANGE = 200,
             down = {}, allowKill = {}, me = nil, lastMsg = 0, msgT = 0, nErr = false }

local function dnLocalPC()
    for _, c in ipairs(listControllers()) do
        if safe(function() return c:IsLocalController() end, false) == true then return c end
    end
    return nil
end
local function dnIsHost()
    local world = UEHelpers.GetWorld()
    if not (world and safe(function() return world:IsValid() end, false)) then return false end
    local gm = safe(function() return world.AuthorityGameMode end, nil)
    return gm ~= nil and safe(function() return gm:IsValid() end, false)
end
local function dnCoop()   -- host with at least one remote player
    for _, c in ipairs(listControllers()) do
        if safe(function() return c:IsLocalController() end, true) == false then return true end
    end
    return false
end
local function dnHealth(p) return safe(function() return p.MedicalComponent.Health end, nil) end
local function dnSetHealth(p, h)
    pcall(function() p.MedicalComponent.Health = h end)
    pcall(function() p:SendHealthToClient(h) end)
end
local function dnState(p)  -- read the replicated state off any pawn
    local sc = safe(function() return p.PlayerState.Score end, 0) or 0
    if sc >= 1000 then return "reviving", sc - 1000 end
    if sc >= 100 then return "down", sc - 100 end
    return "up", 0
end
local function dnPublish(p, v)
    local ps = safe(function() return p.PlayerState end, nil)
    if not (ps and safe(function() return ps:IsValid() end, false)) then return end
    if safe(function() return ps.Score end, -1) == v then return end
    pcall(function() ps.Score = v end)
    pcall(function()
        StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers"):MarkPropertyDirty(ps, FName("Score"))
    end)
end
DN.isDown = function(p)
    local k = safe(function() return p:GetAddress() end, nil)
    return k ~= nil and DN.down[k] ~= nil
end

local function dnNotify(txt, pawn)
    local ok = pcall(function()
        local gfl = StaticFindObject("/Game/Blueprints/GameFunctionLibrary.Default__GameFunctionLibrary_C")
        gfl:CreateNotificationUI(FText(txt), nil, { R = 1.0, G = 0.35, B = 0.3, A = 1.0 }, 3.0, false, pawn)
    end)
    if not ok and not DN.nErr then DN.nErr = true; log("DN: notification failed (" .. txt .. ")") end
end

local function dnEnter(p)
    local key = safe(function() return p:GetAddress() end, nil)
    if not key or DN.down[key] then return end
    local cmc = safe(function() return p.CharacterMovement end, nil)
    DN.down[key] = { p = p, t = DN.BLEED, rev = 0,
        walk = safe(function() return cmc.MaxWalkSpeed end, nil),
        crouch = safe(function() return cmc.MaxWalkSpeedCrouched end, nil),
        jump = safe(function() return cmc.JumpZVelocity end, nil) }
    dnSetHealth(p, DN.DOWN_HP)
    dnPublish(p, 100 + DN.BLEED)
    log(("DN: %s is DOWN (%ds to bleed out)"):format(className(p), DN.BLEED))
end

local function dnRestoreMove(p, d)
    local cmc = safe(function() return p.CharacterMovement end, nil)
    if not cmc then return end
    if d.walk then pcall(function() cmc.MaxWalkSpeed = d.walk end) end
    if d.crouch then pcall(function() cmc.MaxWalkSpeedCrouched = d.crouch end) end
    if d.jump then pcall(function() cmc.JumpZVelocity = d.jump end) end
end

local function dnBleedOut(key, d)
    local p = d.p
    DN.down[key] = nil
    dnPublish(p, 0)
    dnRestoreMove(p, d)
    local pc = dnLocalPC()
    local hostPawn = pc and safe(function() return pc.Pawn end, nil)
    log("DN: " .. className(p) .. " bled out")
    DN.allowKill[key] = true
    local ok, err = pcall(function()
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(p, 1000.0, nil, nil, nil)
    end)
    DN.allowKill[key] = nil
    if not ok then log("DN: kill failed: " .. tostring(err)) end
    -- the game's death unpossesses GetPlayerController(0) = the host
    DN.repossess = { pc = pc, pawn = hostPawn, n = 0 }
end

local function dnHostTick()
    -- put the host back in its own body if a remote death took it
    local r = DN.repossess
    if r then
        r.n = r.n + 1
        if r.pc and r.pawn and safe(function() return r.pc:IsValid() and r.pawn:IsValid() end, false) then
            local cur = safe(function() return r.pc.Pawn end, nil)
            local curOk = cur and safe(function() return cur:IsValid() end, false)
            if not curOk or cur:GetAddress() ~= r.pawn:GetAddress() then
                local ok = pcall(function() r.pc:Possess(r.pawn) end)
                log("DN: host lost its pawn to the death code - re-possess " .. tostring(ok))
                DN.repossess = nil
            end
        end
        if r.n > 8 then DN.repossess = nil end
    end
    if not dnCoop() then return end
    local players = {}
    for _, pc in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if safe(function() return pc:IsValid() end, false) and not safe(function() return pc["PlayerDead?"] end, false) then
            players[#players + 1] = pc
        end
    end
    for _, p in ipairs(players) do
        -- slow drains (hunger, radiation...) that never hit ApplyDamage
        local h = dnHealth(p)
        if h and h <= 2 and not DN.isDown(p) then dnEnter(p) end
    end
    for key, d in pairs(DN.down) do
        local p = d.p
        if not safe(function() return p:IsValid() end, false) then
            DN.down[key] = nil
        else
            if (dnHealth(p) or 0) ~= DN.DOWN_HP then dnSetHealth(p, DN.DOWN_HP) end
            local cmc = safe(function() return p.CharacterMovement end, nil)
            if cmc then
                pcall(function() cmc.MaxWalkSpeed = 70 end)
                pcall(function() cmc.MaxWalkSpeedCrouched = 70 end)
                pcall(function() cmc.JumpZVelocity = 0 end)
            end
            local pl = safe(function() return p:K2_GetActorLocation() end, nil)
            local reviver = nil
            for _, o in ipairs(players) do
                if o:GetAddress() ~= key and not DN.isDown(o) and safe(function() return o.bIsCrouched end, false) then
                    local ol = safe(function() return o:K2_GetActorLocation() end, nil)
                    if pl and ol and (ol.X - pl.X)^2 + (ol.Y - pl.Y)^2 + (ol.Z - pl.Z)^2 < DN.RANGE * DN.RANGE then
                        reviver = o; break
                    end
                end
            end
            if reviver then
                d.rev = d.rev + 0.25 / DN.REVIVE
            else
                d.rev = 0
                d.t = d.t - 0.25
            end
            if d.rev >= 1 then
                DN.down[key] = nil
                dnRestoreMove(p, d)
                dnSetHealth(p, DN.UP_HP)
                dnPublish(p, 0)
                log("DN: " .. className(p) .. " revived by " .. className(reviver))
            elseif d.t <= 0 then
                dnBleedOut(key, d)
            elseif d.rev > 0 then
                dnPublish(p, 1000 + math.floor(d.rev * 100))
            else
                dnPublish(p, 100 + math.ceil(d.t))
            end
        end
    end
end

-- every machine: look after its own pawn, tell the player what's going on
local function dnLocalTick()
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    if not (me and safe(function() return me:IsValid() end, false)) then return end
    if className(me) ~= "BP_PlayerCharacter_C" then return end
    DN.msgT = DN.msgT + 0.25
    local st, n = dnState(me)
    local cmc = safe(function() return me.CharacterMovement end, nil)
    if st ~= "up" then
        if not DN.me then
            DN.me = { walk = safe(function() return cmc.MaxWalkSpeed end, nil),
                      crouch = safe(function() return cmc.MaxWalkSpeedCrouched end, nil),
                      jump = safe(function() return cmc.JumpZVelocity end, nil) }
            log("DN: local player is down")
            DN.lastMsg = -99
        end
        if cmc then
            pcall(function() cmc.MaxWalkSpeed = 70 end)
            pcall(function() cmc.MaxWalkSpeedCrouched = 70 end)
            pcall(function() cmc.JumpZVelocity = 0 end)
        end
        if not safe(function() return me.bIsCrouched end, false) then pcall(function() me:Crouch(false) end) end
        if DN.msgT - DN.lastMsg >= 4 then
            DN.lastMsg = DN.msgT
            if st == "reviving" then
                dnNotify(("Being revived... %d%%"):format(n), me)
            else
                dnNotify(("You're down! Bleeding out in %ds - your partner can crouch next to you to revive"):format(n), me)
            end
        end
        return
    end
    if DN.me then
        dnRestoreMove(me, DN.me)
        pcall(function() me:UnCrouch(false) end)
        DN.me = nil
        log("DN: local player is back up")
        dnNotify("You're back on your feet", me)
    end
    -- partner down?
    if DN.msgT - DN.lastMsg >= 4 then
        for _, o in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
            if safe(function() return o:IsValid() end, false) and o:GetAddress() ~= me:GetAddress() then
                local ost, on = dnState(o)
                if ost == "down" then
                    DN.lastMsg = DN.msgT
                    dnNotify(("Your partner is down! Crouch next to them to revive (%ds)"):format(on), me)
                    break
                elseif ost == "reviving" then
                    DN.lastMsg = DN.msgT
                    dnNotify(("Reviving partner... %d%%"):format(on), me)
                    break
                end
            end
        end
    end
end

-- lethal hits become downed (host only, co-op only)
pcall(function()
    RegisterHook("/Script/Engine.GameplayStatics:ApplyDamage", function(ctx, damaged, dmg)
        if not dnIsHost() then return end
        local a = safe(function() return damaged:get() end, nil)
        if not (a and safe(function() return a:IsValid() end, false)) then return end
        if className(a) ~= "BP_PlayerCharacter_C" then return end
        if safe(function() return a.bCanBeDamaged end, true) == false then return end   -- god mode
        local key = safe(function() return a:GetAddress() end, nil)
        if not key or DN.allowKill[key] then return end
        if not dnCoop() then return end
        local d = safe(function() return dmg:get() end, 0) or 0
        if d <= 0 then return end
        local dd = DN.down[key]
        if dd then
            pcall(function() dmg:set(0.0) end)
            dd.t = dd.t - 2
            return
        end
        local h = dnHealth(a)
        if h and h - d <= 0 then
            pcall(function() dmg:set(0.0) end)
            dnEnter(a)
        end
    end)
end)

LoopAsync(250, function()
    ExecuteInGameThread(function()
        if dnIsHost() then
            local ok, err = pcall(dnHostTick)
            if not ok then log("DN host error: " .. tostring(err)) end
        end
        local ok, err = pcall(dnLocalTick)
        if not ok and not DN.lErr then DN.lErr = true; log("DN local error: " .. tostring(err)) end
    end)
    return false
end)
RegisterConsoleCommandHandler("sdmp_down", function()   -- debug: down yourself / everyone on host
    ExecuteInGameThread(function()
        for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do if p:IsValid() then dnEnter(p) end end
    end)
    return true
end)

-- Auto mode. Driving two game windows by hand (or by remote control) is slow
-- and flaky: the console ignores pasted text, the game grabs the mouse, and
-- every run is a dozen typed commands. So the bats pass a role on the command
-- line and the mod does the whole run sheet itself:
--
--   -sdmprole=host    ipdriver -> listen -> Continue -> wait for joiners ->
--                     spawn them -> netperf
--   -sdmprole=client  wait for host ready -> ipdriver -> connect -> input/UI ->
--                     drop the main menu -> scripted walk/sprint/turn with
--                     snaptrace running -> summary
--   -sdmpauto         actually do it (role alone just tags the log)
--   -sdmpquit         both quit when the client finishes, for back-to-back runs
--
-- The two processes hand off through files next to this script, since they
-- share the Mods folder. Everything is logged with an AUTO prefix.
-- ===========================================================================
do
    local A = { role = nil, auto = false, quit = false, step = "init", t = 0,
                worldAddr = nil, tries = 0, run = nil }

    local function alog(s) log("AUTO[" .. (A.role or "?") .. "] " .. s) end

    local function modDir()
        local src = debug.getinfo(1, "S").source or ""
        local dir = src:match("^@(.*)[/\\]Scripts[/\\]main%.lua$")
        return dir or "ue4ss/Mods/SDMPDiag"
    end
    local function fpath(n) return modDir() .. "/" .. n end
    local function fwrite(n, s)
        local f = io.open(fpath(n), "w"); if f then f:write(s); f:close(); return true end
        return false
    end
    local function fread(n)
        local f = io.open(fpath(n), "r"); if not f then return nil end
        local s = f:read("*a"); f:close(); return s
    end

    local function cmdline()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local s = safe(function() return ksl:GetCommandLine():ToString() end, nil)
        if not s then s = safe(function() return tostring(ksl:GetCommandLine()) end, "") end
        return s or ""
    end

    local function console(cmd)
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local ok = pcall(function()
            ksl:ExecuteConsoleCommand(UEHelpers.GetWorld(), cmd, UEHelpers.GetPlayerController())
        end)
        alog("console '" .. cmd .. "' -> " .. tostring(ok))
    end

    local function myPawn()
        local pc = UEHelpers.GetPlayerController()
        local p = pc and safe(function() return pc.Pawn end, nil) or nil
        if p and p:IsValid() then return p, pc end
        return nil, pc
    end

    local function worldAddr()
        local w = UEHelpers.GetWorld()
        return w and safe(function() return w:GetAddress() end, nil) or nil
    end

    local function menu()
        local m = nil
        pcall(function()
            local all = FindAllOf("MenuWidget_C")
            if all then for _, w in ipairs(all) do if w:IsValid() then m = w end end end
        end)
        return m
    end

    -- If the menu class guess is wrong, say what widgets do exist so the next
    -- run can use the right name, and carry on after a timeout.
    -- First launch shows "PRESS ANY KEY" and the menu doesn't exist until a
    -- key goes in. Its OnKeyDown override just broadcasts EventKeyDown, so call
    -- it with empty geometry/key-event structs - the key itself is ignored.
    local function pressAnyKey()
        local w = nil
        pcall(function()
            for _, x in ipairs(FindAllOf("PressAnyKeyWidget_C") or {}) do
                if x:IsValid() and safe(function() return x:IsInViewport() end, true) then w = x end
            end
        end)
        if not w then return end
        -- The widget's own OnKeyDown needs a real FKey, which Lua can't build.
        -- What it feeds is the MainMenu level script's Event_KeyDown, which
        -- takes down the prompt and calls CreateMenu - call that directly.
        local lvl = nil
        pcall(function()
            for _, l in ipairs(FindAllOf("MainMenu_C") or {}) do if l:IsValid() then lvl = l end end
        end)
        if not lvl then alog("PressAnyKey: no MainMenu_C level script"); return end
        for _, fn in ipairs({ "Event_KeyDown", "CreateMenu" }) do
            local ok, err = pcall(function() lvl[fn](lvl) end)
            alog("PressAnyKey: MainMenu_C:" .. fn .. " -> " .. (ok and "called" or ("threw: " .. tostring(err))))
            if ok then return end
        end
    end

    local function menuOrTimeout()
        if menu() then return true end
        if (A.waitMenu or 0) % 3 == 1 then pressAnyKey() end
        A.waitMenu = (A.waitMenu or 0) + 1
        if A.waitMenu == 15 then
            local seen = {}
            pcall(function()
                for _, w in ipairs(FindAllOf("UserWidget") or {}) do
                    if w:IsValid() then seen[className(w)] = true end
                end
            end)
            local list = {}
            for k in pairs(seen) do list[#list+1] = k end
            table.sort(list)
            alog("no MenuWidget_C after 15s. live widgets: " .. table.concat(list, ", "))
            A.dumpUI()
        end
        return A.waitMenu >= 20
    end

    -- Discovery: where the menu buttons live and what they can be told to do.
    A.dumpUI = function()
        local function fnames(obj)
            local out = {}
            pcall(function()
                obj:GetClass():ForEachFunction(function(fn)
                    out[#out+1] = safe(function() return fn:GetFName():ToString() end, "?")
                end)
            end)
            return table.concat(out, ", ")
        end
        pcall(function()
            for _, l in ipairs(FindAllOf("LevelScriptActor") or {}) do
                if l:IsValid() then alog("UI LevelScript " .. className(l) .. " functions: " .. fnames(l)) end
            end
        end)
        pcall(function()
            for _, x in ipairs(FindAllOf("PressAnyKeyWidget_C") or {}) do
                local props = {}
                x:GetClass():ForEachProperty(function(pr)
                    props[#props+1] = safe(function() return pr:GetFName():ToString() end, "?")
                end)
                alog("UI PressAnyKeyWidget props: " .. table.concat(props, ", "))
                break
            end
        end)
        pcall(function()
            local gi = UEHelpers.GetGameInstance()
            alog("UI GameInstance " .. className(gi) .. " functions: " .. fnames(gi))
        end)
        local shown = {}
        for _, cls in ipairs({ "ButtonWidget_C", "PressAnyKeyWidget_C", "CommandButton_C", "SaveMenu_C" }) do
            pcall(function()
                for _, w in ipairs(FindAllOf(cls) or {}) do
                    if w:IsValid() then
                        alog("UI " .. safe(function() return w:GetFullName() end, "?"))
                        if not shown[cls] then shown[cls] = true; alog("UI " .. cls .. " functions: " .. fnames(w)) end
                    end
                end
            end)
        end
    end

    -- Find the Continue button's handler on the menu and call it - the same
    -- thing a click does. Names aren't known yet, so log everything the first
    -- time and try anything with "continue" in it.
    local function pressContinue()
        local m = menu()
        if not m then alog("no MenuWidget_C to press Continue on"); return false end
        local names, cands = {}, {}
        pcall(function()
            m:GetClass():ForEachFunction(function(fn)
                local n = safe(function() return fn:GetFName():ToString() end, "")
                names[#names+1] = n
                -- click handlers only; hovering Continue does nothing useful
                if n:lower():find("continue") and not n:find("Hover") then cands[#cands+1] = n end
            end)
        end)
        if A.tries == 0 then alog("MenuWidget functions: " .. table.concat(names, ", ")) end
        A.tries = A.tries + 1
        -- MenuWidget has two: the Continue button and a ContinueGame button
        -- (probably on a confirm/save panel). Alternate between them across
        -- retries so whichever one actually loads gets its turn.
        table.sort(cands)
        if #cands == 0 then alog("no Continue click handler on the menu"); return false end
        local pick = cands[((A.tries - 1) % #cands) + 1]
        for _, n in ipairs({ pick }) do
            local ok, err = pcall(function() m[n](m) end)
            alog("Continue via " .. n .. " -> " .. (ok and "called" or ("threw: " .. tostring(err))))
            if ok then return true end
        end
        alog("no callable Continue handler found")
        return false
    end

    -- One line per pawn: where it is and what its movement component thinks
    -- the speed limits are. Run on both sides during a phase, the host's copy
    -- and the client's own pawn can be compared second by second.
    A.mon = function(tag, p)
        if true then return end -- off: keep test runs light
        pcall(function()
            local cmc = p.CharacterMovement
            local l = p:K2_GetActorLocation()
            local v = cmc.Velocity
            alog(("MON %s pos=%.0f,%.0f vel=%.0f maxWalk=%.0f maxAccel=%.0f mode=%s"):format(
                tag, l.X, l.Y, math.sqrt(v.X*v.X + v.Y*v.Y),
                safe(function() return cmc.MaxWalkSpeed end, -1),
                safe(function() return cmc.MaxAcceleration end, -1),
                tostring(safe(function() return cmc.MovementMode end, "?"))))
        end)
    end

    -- Host-side twin of snaptrace: per frame, where is the SERVER's copy of
    -- the client? If the server copy is smooth while the client snaps, the
    -- client is mis-replaying its own moves. If the server copy itself
    -- jumps, the server is applying the client's moves unevenly.
    A.ht = { on = false, rows = {}, hooked = false }
    A.hostTrace = function()
        if not A.ht.hooked then
            A.ht.hooked = true
            pcall(function()
                RegisterHook(BPC .. "ReceiveTick", function(ctx)
                    if not A.ht.on then return end
                    pcall(function()
                        local p = ctx:get()
                        if p:IsLocallyControlled() ~= false then return end
                        local l = p:K2_GetActorLocation()
                        local rows = A.ht.rows
                        rows[#rows+1] = { X = l.X, Y = l.Y }
                        if #rows >= 720 then
                            A.ht.on = false
                            local steps, snaps, back, zero = {}, 0, 0, 0
                            for i = 2, #rows do
                                steps[i] = math.sqrt((rows[i].X-rows[i-1].X)^2 + (rows[i].Y-rows[i-1].Y)^2)
                                if steps[i] < 0.01 then zero = zero + 1 end
                            end
                            local lines = {}
                            for i = 3, #rows - 1 do
                                local nb = (steps[i-1] + steps[i+1]) / 2
                                if steps[i] > 2 * nb and steps[i] - nb > 2 then
                                    snaps = snaps + 1
                                    local px, py = rows[i-1].X - rows[i-2].X, rows[i-1].Y - rows[i-2].Y
                                    local pl = math.sqrt(px*px + py*py)
                                    local fwd = pl > 0.001 and ((rows[i].X-rows[i-1].X)*px + (rows[i].Y-rows[i-1].Y)*py) / pl or 0
                                    if fwd < 0 then back = back + 1 end
                                    if #lines < 25 then lines[#lines+1] = ("f%d %.1f(%+.1f)"):format(i, steps[i], fwd) end
                                end
                            end
                            alog(("HT: server copy over %d frames: %d snaps (%d backward), %d frames with no movement"):format(
                                #rows, snaps, back, zero))
                            if #lines > 0 then alog("HT: " .. table.concat(lines, "  ")) end
                        end
                    end)
                end)
            end)
        end
        A.ht.rows, A.ht.on = {}, true
        alog("HT: tracing server copy of the client for 720 frames")
    end

    -- Server-side ack/adjustment throttles on the remote players' movement
    -- components. Logs the values either way.
    A.acks = function(fast)
        for _, c in ipairs(listControllers()) do
            local rp = safe(function() return c.Pawn end, nil)
            if rp and safe(function() return rp:IsValid() end, false)
               and safe(function() return c:IsLocalController() end, true) == false then
                pcall(function()
                    local cmc = rp.CharacterMovement
                    local function g(n) return tostring(safe(function() return cmc[n] end, "?")) end
                    alog(("acks before: AckGoodMoves=%s Adjustments=%s LargeCorr=%s LargeDist=%s MaxSmooth=%s"):format(
                        g("NetworkMinTimeBetweenClientAckGoodMoves"), g("NetworkMinTimeBetweenClientAdjustments"),
                        g("NetworkMinTimeBetweenClientAdjustmentsLargeCorrection"), g("NetworkLargeClientCorrectionDistance"),
                        g("NetworkMaxSmoothUpdateDistance")))
                    if fast then
                        cmc.NetworkMinTimeBetweenClientAckGoodMoves = 0.0
                        cmc.NetworkMinTimeBetweenClientAdjustments = 0.0
                        cmc.NetworkMinTimeBetweenClientAdjustmentsLargeCorrection = 0.0
                    else
                        cmc.NetworkMinTimeBetweenClientAckGoodMoves = 0.1
                        cmc.NetworkMinTimeBetweenClientAdjustments = 0.1
                        cmc.NetworkMinTimeBetweenClientAdjustmentsLargeCorrection = 0.05
                    end
                    alog(("acks after (%s): AckGoodMoves=%s Adjustments=%s"):format(
                        fast and "fast" or "default",
                        g("NetworkMinTimeBetweenClientAckGoodMoves"), g("NetworkMinTimeBetweenClientAdjustments")))
                end)
            end
        end
    end

    -- Full movement-component config, plus tick settings, for one pawn. The
    -- stall correlation came back flat (no Blueprint function lines up with
    -- the stalls), so compare configuration instead: the host's own pawn is
    -- smooth, the client's own pawn isn't, same class.
    A.dumpMove = function(tag, p)
        pcall(function()
            local cmc = p.CharacterMovement
            local vals = {}
            cmc:GetClass():ForEachProperty(function(pr)
                local n = safe(function() return pr:GetFName():ToString() end, nil)
                if not n then return end
                local v = safe(function() return cmc[n] end, nil)
                local tv = type(v)
                if tv == "number" or tv == "boolean" then
                    if tv == "number" and v ~= math.floor(v) then v = ("%.4g"):format(v) end
                    vals[#vals+1] = n .. "=" .. tostring(v)
                end
            end)
            table.sort(vals)
            for i = 1, #vals, 25 do
                alog(("CFG %s cmc: %s"):format(tag, table.concat(vals, " ", i, math.min(i + 24, #vals))))
            end
            local function tk(o, f)
                return safe(function() local t = o[f]; return ("interval=%s group=%s enabled=%s"):format(
                    tostring(safe(function() return t.TickInterval end, "?")),
                    tostring(safe(function() return t.TickGroup end, "?")),
                    tostring(safe(function() return t.bCanEverTick end, "?"))) end, "?")
            end
            alog(("CFG %s ticks: actor[%s] cmc[%s] mesh[%s] meshAnimTick=%s role=%s"):format(tag,
                tk(p, "PrimaryActorTick"), tk(cmc, "PrimaryComponentTick"), tk(p.Mesh, "PrimaryComponentTick"),
                tostring(safe(function() return p.Mesh.VisibilityBasedAnimTickOption end, "?")),
                ROLE[safe(function() return p.Role end, -1)] or "?"))
        end)
    end

    -- Host-side send rate. MaxNetTickRate caps how often the net driver
    -- ticks (sends) independently of the frame rate.
    A.hostNet = function(mode)
        local w = UEHelpers.GetWorld()
        local nd = w and safe(function() return w.NetDriver end, nil) or nil
        local before = nd and safe(function() return nd.MaxNetTickRate end, "?") or "?"
        if mode == "net60" then
            pcall(function() nd.MaxNetTickRate = 60 end)
            console("t.MaxFPS 0")
        elseif mode == "fps60" or mode == "fps120" then
            if A.origNetTick then pcall(function() nd.MaxNetTickRate = A.origNetTick end) end
            console(mode == "fps60" and "t.MaxFPS 60" or "t.MaxFPS 120")
        else
            if A.origNetTick then pcall(function() nd.MaxNetTickRate = A.origNetTick end) end
            console("t.MaxFPS 0")
        end
        if A.origNetTick == nil and type(before) == "number" then A.origNetTick = before end
        alog(("host net mode %s: MaxNetTickRate %s -> %s"):format(tostring(mode), tostring(before),
            tostring(nd and safe(function() return nd.MaxNetTickRate end, "?") or "?")))
    end

    -- Zombie test (test.bat zombie). Open problem #2: zombies chase the client
    -- but never hurt it. BP_MasterZombie calls GetPlayerCharacter (= player
    -- index 0 = the host) somewhere, which is the classic single-player
    -- assumption. Put the client next to a zombie, leave it damageable, and
    -- record the whole attack path on the host: the zombie's attack/trace/
    -- damage functions, every ApplyDamage and who it hit, and the damage
    -- functions on both players.
    -- What does a zombie look like at the moment it tries to attack the client?
    -- Every number/bool/object variable on BP_MasterZombie_C and its AI
    -- controller, plus how far it is from each player. First call per zombie
    -- (up to 3 zombies), then the first zombie again a few seconds later.
    A.zProbe = function(zb, args, who)
        local z = A.ztest
        if not (z and zb and safe(function() return zb:IsValid() end, false)) then return end
        z.probed = z.probed or {}
        local key = safe(function() return zb:GetAddress() end, 0)
        local pr = z.probed[key]
        if pr then
            if pr.again or z.t < pr.t + 4 or key ~= z.firstZ then return end
            pr.again = true
        else
            z.np = (z.np or 0) + 1
            if z.np > 3 then return end
            z.probed[key] = { t = z.t }
            z.firstZ = z.firstZ or key
        end
        local tag = ("ZP %s#%d%s"):format(className(zb), z.np, pr and " (+4s)" or "")
        local zl = safe(function() return zb:K2_GetActorLocation() end, nil)
        local function dist(a)
            local l = safe(function() return a:K2_GetActorLocation() end, nil)
            if not (l and zl) then return "?" end
            return ("%.0f"):format(math.sqrt((l.X - zl.X)^2 + (l.Y - zl.Y)^2 + (l.Z - zl.Z)^2))
        end
        alog(("%s dist client=%s host=%s args=%d"):format(tag, dist(z.p), dist(myPawn()), #args))
        for i, a in ipairs(args) do
            local v = safe(function() return a:get() end, nil)
            alog(("%s   arg%d = %s"):format(tag, i, type(v) == "userdata" and who(v) or tostring(v)))
        end
        local function dump(obj, cls, label)
            if not (obj and cls) then return end
            local vals = {}
            pcall(function()
                cls:ForEachProperty(function(prop)
                    local pn = safe(function() return prop:GetFName():ToString() end, nil)
                    if not pn or pn:find("^Uber") or pn:find("^K2Node") or pn:find("^CallFunc") or pn:find("^Temp_") then return end
                    local v = safe(function() return obj[pn] end, nil)
                    local tv = type(v)
                    if tv == "number" then
                        if v ~= math.floor(v) then v = ("%.4g"):format(v) end
                        vals[#vals+1] = pn .. "=" .. tostring(v)
                    elseif tv == "boolean" then
                        vals[#vals+1] = pn .. "=" .. tostring(v)
                    elseif tv == "userdata" then
                        local inner = safe(function() return v:get() end, nil)
                        if type(inner) == "number" or type(inner) == "boolean" then
                            vals[#vals+1] = pn .. "=" .. tostring(inner)
                        elseif safe(function() return v:IsValid() ~= nil end, false) then
                            vals[#vals+1] = pn .. "=" .. who(v)
                        end
                    end
                end)
            end)
            table.sort(vals)
            for i = 1, #vals, 12 do
                alog(("%s %s: %s"):format(tag, label, table.concat(vals, "  ", i, math.min(i + 11, #vals))))
            end
        end
        dump(zb, StaticFindObject("/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"), "zombie")
        local ctl = safe(function() return zb.Controller end, nil)
        if ctl and safe(function() return ctl:IsValid() end, false) then
            alog(("%s controller=%s"):format(tag, className(ctl)))
            dump(ctl, safe(function() return ctl:GetClass() end, nil), "ai")
        end
    end

    A.zTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp = z.p
        if not (cp and safe(function() return cp:IsValid() end, false)) then return end
        local hp = myPawn()
        local function who(a)
            if not a then return "nil" end
            if type(a) ~= "userdata" or not safe(function() return a:IsValid() end, false) then return "null" end
            local ad = safe(function() return a:GetAddress() end, nil)
            if ad and ad == safe(function() return cp:GetAddress() end, -1) then return "CLIENT" end
            if ad and hp and ad == safe(function() return hp:GetAddress() end, -2) then return "HOST" end
            return className(a)
        end
        if z.t == 1 then
            z.count, z.shown = {}, {}
            local function mark(name, detail)
                z.count[name] = (z.count[name] or 0) + 1
                if (z.shown[name] or 0) < 6 then
                    z.shown[name] = (z.shown[name] or 0) + 1
                    alog("ZT " .. name .. (detail and (" " .. detail) or ""))
                end
            end
            local zp = "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C"
            local zc = StaticFindObject(zp)
            local n = 0
            if zc and zc:IsValid() then
                zc:ForEachFunction(function(fn)
                    local fname = safe(function() return fn:GetFName():ToString() end, "")
                    if fname:find("Attack") or fname:find("Damage") or fname:find("Trace") or fname:find("Hit")
                       or fname:find("Target") or fname:find("Distance") or fname:find("Range")
                       or fname:find("Montage") or fname:find("Can") or fname:find("Player") then
                        if not fname:find("Delegate") and not fname:find("Ubergraph") then
                            if pcall(function()
                                RegisterHook(zp .. ":" .. fname, function(ctx, ...)
                                    mark("zombie:" .. fname)
                                    if fname == "AttackPlayer" then
                                        local zb = safe(function() return ctx:get() end, nil)
                                        A.zProbe(zb, { ... }, who)
                                    end
                                end)
                            end) then n = n + 1 end
                        end
                    end
                end)
            end
            pcall(function()
                RegisterHook("/Script/Engine.GameplayStatics:ApplyDamage", function(ctx, damaged, dmg, inst, causer)
                    local d = safe(function() return damaged:get() end, nil)
                    local c = safe(function() return causer:get() end, nil)
                    mark("ApplyDamage->" .. who(d), ("dmg=%s causer=%s"):format(
                        tostring(safe(function() return dmg:get() end, "?")), who(c)))
                end)
                n = n + 1
            end)
            local pcCls = StaticFindObject(PC_PATH)
            if pcCls and pcCls:IsValid() then
                pcCls:ForEachFunction(function(fn)
                    local fname = safe(function() return fn:GetFName():ToString() end, "")
                    if (fname:find("Damage") or fname:find("Health") or fname:find("Hurt") or fname:find("Died"))
                       and not fname:find("Delegate") and not fname:find("Ubergraph") then
                        if pcall(function()
                            RegisterHook(BPC .. fname, function(ctx) mark("player:" .. fname .. "@" .. who(safe(function() return ctx:get() end, nil))) end)
                        end) then n = n + 1 end
                    end
                end)
            end
            alog("ZT: hooked " .. n .. " functions; client is damageable")
        end
        -- every 8s: put the client 150 units from the nearest zombie to the host
        if z.t % 8 == 2 and z.t < 40 then
            local best, bd = nil, 1e18
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            pcall(function()
                for _, a in ipairs(FindAllOf("Character") or {}) do
                    if a:IsValid() and className(a):find("Zombie") and hl then
                        local l = a:K2_GetActorLocation()
                        local d = (l.X - hl.X)^2 + (l.Y - hl.Y)^2
                        if d < bd then best, bd = a, d end
                    end
                end
            end)
            if best then
                local l = best:K2_GetActorLocation()
                local ok = safe(function() return cp:K2_TeleportTo({ X = l.X + 150, Y = l.Y, Z = l.Z + 30 }, cp:K2_GetActorRotation()) end, false)
                alog(("ZT: client -> next to %s (%.0f from host) teleport=%s"):format(className(best), math.sqrt(bd), tostring(ok)))
            else
                alog("ZT: no zombie found near the host")
            end
        end
        if z.t == 45 then
            local parts = {}
            for k, v in pairs(z.count or {}) do parts[#parts+1] = k .. "=" .. v end
            table.sort(parts)
            alog("ZT RESULT: " .. (#parts > 0 and table.concat(parts, "  ") or "nothing fired"))
            fwrite("sdmp_done.txt", "1")
        end
    end

    -- Downed test: zombies put the client down, the host crouches next to it
    -- to revive; then down again and left to bleed out (shortened to 20s),
    -- checking the host keeps its own character afterwards.
    A.dTick = function()
        local z = A.ztest
        z.t = z.t + 1
        z.ph = z.ph or "down1"
        local cp, hp = z.p, myPawn()
        if not (cp and safe(function() return cp:IsValid() end, false)) then
            if z.ph ~= "end" then alog("DT: client pawn gone in phase " .. z.ph); z.ph = "end"; z.pt = z.t end
        end
        local function toZombie()
            local best, bd = nil, 1e18
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            for _, a in ipairs(safe(function() return FindAllOf("BP_MasterZombie_C") end, nil) or {}) do
                if a:IsValid() and hl and not safe(function() return a["IsDead?"] end, false) then
                    local l = a:K2_GetActorLocation()
                    local d = (l.X - hl.X)^2 + (l.Y - hl.Y)^2
                    if d < bd then best, bd = a, d end
                end
            end
            if best then
                local l = best:K2_GetActorLocation()
                pcall(function() cp:K2_TeleportTo({ X = l.X + 150, Y = l.Y, Z = l.Z + 30 }, cp:K2_GetActorRotation()) end)
            end
        end
        local function toHost()
            local l = safe(function() return hp:K2_GetActorLocation() end, nil)
            if l then pcall(function() cp:K2_TeleportTo({ X = l.X + 120, Y = l.Y, Z = l.Z + 30 }, cp:K2_GetActorRotation()) end) end
        end
        local down = z.ph ~= "end" and DN.isDown(cp)
        if z.ph == "down1" or z.ph == "down2" then
            if down then
                alog(("DT: client DOWN at %ds (phase %s), health=%s"):format(z.t, z.ph, tostring(safe(function() return cp.MedicalComponent.Health end, "?"))))
                toHost()
                z.pt = z.t
                if z.ph == "down1" then
                    z.ph = "revive"
                    pcall(function() hp:Crouch(false) end)
                else
                    z.ph = "bleed"
                end
            elseif z.t % 8 == 2 then
                toZombie()
            end
        elseif z.ph == "revive" then
            if not safe(function() return hp.bIsCrouched end, false) then pcall(function() hp:Crouch(false) end) end
            if not down then
                alog(("DT: client REVIVED after %ds, health=%s"):format(z.t - z.pt,
                    tostring(safe(function() return cp.MedicalComponent.Health end, "?"))))
                z.revived = true
                pcall(function() hp:UnCrouch(false) end)
                DN.BLEED = 20
                z.ph, z.pt = "down2", z.t
            elseif z.t - z.pt > 20 then
                alog("DT: FAIL revive didn't finish in 20s")
                pcall(function() hp:UnCrouch(false) end)
                DN.BLEED = 20
                z.ph, z.pt = "down2", z.t
            end
        elseif z.ph == "bleed" then
            if not down then
                local pc
                for _, c in ipairs(FindAllOf("PlayerController") or {}) do
                    if c:IsValid() and safe(function() return c:IsLocalController() end, false) then pc = c end
                end
                local hostOk = pc and safe(function() return pc.Pawn:GetAddress() == hp:GetAddress() end, false)
                alog(("DT: client bled out after %ds; client dead=%s; host still has its character=%s"):format(
                    z.t - z.pt, tostring(safe(function() return cp["PlayerDead?"] end, "?")), tostring(hostOk)))
                z.bled, z.hostOk = true, hostOk
                z.ph, z.pt = "end", z.t
            elseif z.t - z.pt > 45 then
                alog("DT: FAIL no bleed-out after 45s")
                z.ph, z.pt = "end", z.t
            end
        end
        if (z.ph == "end" and z.t - z.pt >= 6) or z.t > 220 then
            if not z.reported then
                z.reported = true
                alog(("DT RESULT: revived=%s bledOut=%s hostKeptCharacter=%s (t=%ds)"):format(
                    tostring(z.revived or false), tostring(z.bled or false), tostring(z.hostOk), z.t))
                DN.BLEED = 60
                fwrite("sdmp_done.txt", "1")
            end
        end
    end

    -- ---------------------------------------------------------------- host
    local function hostTick()
        if A.step == "init" then
            fwrite("sdmp_ready.txt", "0"); fwrite("sdmp_done.txt", "0"); fwrite("sdmp_phase.txt", "0"); fwrite("sdmp_htrace.txt", "0")
            -- No need to get past "press any key": the listen travel reloads
            -- the map and the menu comes back up without it.
            if not UEHelpers.GetPlayerController() then return end
            A.boot = (A.boot or 0) + 1
            if A.boot < 3 then return end
            ExecuteInGameThread(setIpDriver)
            A.worldAddr = worldAddr()
            ExecuteInGameThread(hostListen)
            A.step, A.t = "listening", 0
        elseif A.step == "listening" then
            -- wait for the listen travel to swap the world and the menu to come
            -- back (or 30s, in case the new world reuses the old address)
            A.lt = (A.lt or 0) + 1
            if (worldAddr() ~= A.worldAddr and menuOrTimeout()) or A.lt > 30 then
                A.t = A.t + 1
                if A.t >= 3 then
                    ExecuteInGameThread(netStatus)
                    A.step, A.t = "continue", 0
                end
            end
        elseif A.step == "continue" then
            if myPawn() then A.step = "ingame"; return end
            if A.t % 10 == 0 then pressContinue() end
            A.t = A.t + 1
            if A.t > 60 then alog("FAIL: no host pawn 60s after Continue"); A.step = "dead" end
        elseif A.step == "ingame" then
            ExecuteInGameThread(netStatus)
            -- The join crash. Starting the client on Entry didn't help (and the
            -- game ignores a map on the command line anyway), so it isn't a
            -- stale copy on the client. Next suspect: the navmesh actor has a
            -- stable name in the map package; if the server replicates it, the
            -- client resolves that path and starts its own async load of
            -- PersistentLevel while the travel is still loading it - and the
            -- loader trips over the half-made RecastNavMesh-Default. Clients
            -- don't run navigation here (bAllowClientSideNavigation=False), so
            -- the navmesh has no reason to replicate. Log it and turn it off.
            pcall(function()
                for _, nm in ipairs(FindAllOf("RecastNavMesh") or {}) do
                    if nm:IsValid() then
                        local before = safe(function() return nm.bReplicates end, "?")
                        local nlc = safe(function() return nm.bNetLoadOnClient end, "?")
                        pcall(function() nm:SetReplicates(false) end)
                        alog(("navmesh %s: bReplicates %s -> %s, bNetLoadOnClient=%s"):format(
                            safe(function() return nm:GetFName():ToString() end, "?"),
                            tostring(before), tostring(safe(function() return nm.bReplicates end, "?")),
                            tostring(nlc)))
                    end
                end
            end)
            -- test runs shouldn't end with the host dead in a ditch
            console("god")
            -- unpacked movement RPCs both sides, so the client log can tell
            -- ClientAckGoodMove (fine) from ClientAdjustPosition (correction)
            console("net.UsePackedMovementRPCs 0")
            fwrite("sdmp_ready.txt", "1")
            alog("host is in game and listening - client may join")
            A.step, A.t = "serving", 0
        elseif A.step == "serving" then
            -- Spawn joiners - but only through the engine route, and only once
            -- they've had time to load the map. A joiner's controller exists
            -- while it's still loading; ServerRestartPlayer refuses it then, and
            -- hostSpawn2's manual fallback spawned a fresh character every
            -- second (42 of them in the first auto run). Never again.
            A.seen = A.seen or {}
            local world = UEHelpers.GetWorld()
            local gm = world and safe(function() return world.AuthorityGameMode end, nil)
            local cls = StaticFindObject(PC_PATH)
            -- DefaultPawnClass starts out null. Calling GetFName on a null
            -- UObject isn't a Lua error pcall can catch - it's a native read of
            -- offset 0x18 and the whole game goes down (that was the host
            -- crash on the last three auto runs). IsValid first, always, and
            -- only do this once.
            if not A.dpSet and gm and gm:IsValid() and cls and cls:IsValid() then
                local dp = safe(function() return gm.DefaultPawnClass end, nil)
                local name = (dp and dp:IsValid()) and safe(function() return dp:GetFName():ToString() end, "") or ""
                if name ~= "BP_PlayerCharacter_C" then
                    alog("DefaultPawnClass was " .. (name ~= "" and name or "null") .. " -> BP_PlayerCharacter_C : " ..
                        tostring(pcall(function() gm.DefaultPawnClass = cls end)))
                end
                A.dpSet = true
            end
            for _, c in ipairs(listControllers()) do
                local key = safe(function() return c:GetAddress() end, nil)
                local p = safe(function() return c.Pawn end, nil)
                if key and not (p and p:IsValid()) then
                    A.seen[key] = (A.seen[key] or 0) + 1
                    local n = A.seen[key]
                    if n >= 8 and n % 5 == 3 and n <= 60 then
                        local ok, err = pcall(function() c:ServerRestartPlayer() end)
                        local p2 = safe(function() return c.Pawn end, nil)
                        alog(("joiner pawnless %ds: ServerRestartPlayer -> %s, pawn=%s"):format(
                            n, ok and "ok" or tostring(err), (p2 and p2:IsValid()) and className(p2) or "none"))
                        if p2 and p2:IsValid() then netPerf() end
                    end
                elseif key and p and p:IsValid() and not (A.handled or {})[key]
                       and safe(function() return c:IsLocalController() end, true) == false then
                    -- (was: only when we'd seen it pawnless first - a joiner
                    -- that already had a pawn on first sight never got moved
                    -- to the host, which is why it kept spawning in hordes)
                    A.handled = A.handled or {}
                    A.handled[key] = true
                    alog("joiner has pawn " .. className(p))
                    A.seen[key] = -1
                    netPerf()
                    -- Joiners spawn at a PlayerStart ~2.5 km away, and last run
                    -- that was in the middle of a horde - the client couldn't
                    -- move, so the run measured nothing. Bring them to the host
                    -- (players should spawn together for beta anyway), and for
                    -- test runs make them immune server-side; the client's own
                    -- "god" only covers its local copy.
                    local hp = myPawn()
                    local hl = hp and safe(function() return hp:K2_GetActorLocation() end, nil)
                    if hl then
                        local dest = { X = hl.X + 250.0, Y = hl.Y + 150.0, Z = hl.Z + 50.0 }
                        local rot = safe(function() return hp:K2_GetActorRotation() end, { Pitch = 0, Yaw = 0, Roll = 0 })
                        local ok = safe(function() return p:K2_TeleportTo(dest, rot) end, false)
                        alog(("moved joiner next to host -> %s"):format(tostring(ok)))
                    end
                    if A.test == "zombie" or A.test == "downed" then
                        A.ztest = { p = p, t = 0 }
                    else
                        pcall(function() p.bCanBeDamaged = false end)
                    end
                    -- (config dumps done - nothing differed)
                end
            end
            for _, c in ipairs(listControllers()) do
                local rp = safe(function() return c.Pawn end, nil)
                if rp and safe(function() return rp:IsValid() end, false)
                   and safe(function() return c:IsLocalController() end, true) == false then
                    A.mon("host-copy", rp)
                end
            end
            if (fread("sdmp_htrace.txt") or "") == "go" then
                fwrite("sdmp_htrace.txt", "0")
                -- A.hostTrace()  (off: keep test runs light)
                -- Control: run the exact same scripted walk/sprint + snaptrace
                -- on the HOST's own pawn at the same 60fps cap. The host looks
                -- smooth; if the instrument still counts stalls there, the
                -- stall count is partly how we sample, not what's on screen.
                -- (host control run removed: capping the host at 60fps for it is
                -- what dropped the client from ~70 stalls to 11 - now tested
                -- properly as phases below)
            end
            -- phase requests from the client: "set:<rep>:<trust>" -> "ok:<same>"
            local req = fread("sdmp_phase.txt") or ""
            local r, t, ak, hn = req:match("^set:(%a+):(%a+):?(%a*):?(%w*)$")
            if r then
                repMove(r == "on")
                trustClient(t == "on")
                A.acks(ak == "fast")
                A.hostNet(hn)
                fwrite("sdmp_phase.txt", "ok:" .. r .. ":" .. t .. ":" .. ak .. ":" .. hn)
                alog(("phase: replicate movement %s, server corrections %s"):format(r, t == "on" and "off" or "on"))
            end
            if A.ztest then (A.test == "downed" and A.dTick or A.zTick)() end
            A.serveT = (A.serveT or 0) + 1
            if A.quit and A.serveT > 300 then
                alog("FAIL: no finished client after 5 min - quitting")
                A.step = "quit"; console("quit"); return
            end
            if A.quit and (fread("sdmp_done.txt") or ""):find("1") then
                alog("client finished - quitting")
                A.step = "quit"
                console("quit")
            end
        end
    end

    -- -------------------------------------------------------------- client
    local function startRun()
        local p, pc = myPawn()
        A.hookRun()

        if not A.capped then A.capped = true; console("t.MaxFPS 60") end
        A.run = { frames = 0, phase = "walk", n = 0, sprintOk = nil }
        alog("scripted run: 3s walk, then sprint + snaptrace, turning halfway")
    end

    A.startRun = startRun

    local function clientTick()
        if A.step == "init" then
            if not UEHelpers.GetPlayerController() then return end
            if not (fread("sdmp_ready.txt") or ""):find("1") then
                A.t = A.t + 1
                if A.t % 10 == 1 then alog("waiting for host to be ready") end
                if A.t > 240 then alog("FAIL: host never became ready"); A.step = "dead" end
                return
            end
            ExecuteInGameThread(setIpDriver)
            -- The menu runs inside PersistentLevel - the same map we're about
            -- to join. Joining straight from it loads PersistentLevel while
            -- the old copy is still in memory, and the async loader dies on
            -- RecastNavMesh-Default ("found in memory ... does not have all
            -- load flags"). Hop through the engine's empty Entry map first so
            -- the old world is fully gone before the join.
            -- test.bat now starts the client straight on Entry, so it never
            -- loads PersistentLevel before joining. The hop below only runs if
            -- it was launched some other way.
            local wname = safe(function() return UEHelpers.GetWorld():GetFName():ToString() end, "?")
            alog("client starting on map " .. wname)
            if wname ~= "Entry" then console("open /Engine/Maps/Entry") end
            A.step, A.t = "entry", 0
        elseif A.step == "entry" then
            A.t = A.t + 1
            if A.t == 4 then
                pcall(function()
                    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
                end)
            end
            if A.t >= 6 then
                -- Navmesh replication was already off (bReplicates=false), so
                -- that theory's dead. But it's also bNetLoadOnClient=false: the
                -- client destroys its own copy while loading the map. If any
                -- replicated actor (a zombie's AI, say) points at it, the
                -- client's package map resolves that path by async-loading
                -- PersistentLevel again, finds the destroyed export, and dies
                -- with exactly this error. With async net loading off it just
                -- resolves to null instead.
                console("net.AllowAsyncLoading 0")
                A.noClientNav()
                alog("on Entry map, old world released - connecting")
                A.step, A.t = "connect", 0
            end
        elseif A.step == "connect" then
            -- The Entry map hands us a standalone DefaultPawn, so "have a pawn"
            -- isn't enough - wait for our own character, owned by the server.
            -- (First auto run took the DefaultPawn as joined, never connected,
            -- then crashed in a hook on a class the Entry hop had unloaded.)
            local p = myPawn()
            if p and className(p) == "BP_PlayerCharacter_C"
               and (ROLE[safe(function() return p.Role end, -1)] or "") == "AutonomousProxy" then
                A.step, A.t = "joined", 0; return
            end
            if A.t % 45 == 0 then console("open 127.0.0.1:7777") end
            A.t = A.t + 1
            if A.t > 120 then alog("FAIL: never got a pawn after 2 min"); A.step = "dead" end
        elseif A.step == "joined" then
            A.tron = false
            local p = myPawn()
            local role = ROLE[safe(function() return p.Role end, -1)] or "?"
            alog("have pawn " .. className(p) .. " role=" .. role)
            -- the client's main menu never closes on its own; take it down
            -- rather than clicking Continue, which runs the client's own
            -- save-load flow
            local m = menu()
            if m then
                alog("removing main menu -> " .. tostring(pcall(function() m:RemoveFromParent() end)))
            end
            fixInput2()
            buildUI()
            if A.test == "zombie" or A.test == "downed" then
                -- no client-side god: we want the damage to land
                alog("zombie test: standing still, host drives it")
                A.step, A.t = "zwait", 0
                return
            end
            console("god")
            A.step, A.t = "settle", 0
        elseif A.step == "settle" then
            A.t = A.t + 1
            -- phase 1 has host settings too (host fps 60): request them first
            if not A.p1sent then
                A.p1sent = true
                A.want = "ok:on:off:default:fps60"
                fwrite("sdmp_phase.txt", "set:on:off:default:fps60")
            end
            if A.t >= 5 and ((fread("sdmp_phase.txt") or "") == A.want or A.t > 20) then
                startRun(); A.step = "running"
            end
        elseif A.step == "running" then
            local mp = myPawn()
            if mp then A.mon("client-own", mp) end
            if A.run and A.run.phase == "done" then
                -- Same scripted run under each host setting. Run B of the last
                -- test (corrections off) still snapped - every snap a pull
                -- BACK of ~11 units with no move RPC at all. Something local
                -- is restoring an older position. Prime suspect: replicated
                -- movement (the server's lagging copy) being applied to our
                -- own pawn, so phase 2 turns that off.
                -- repmove off is out: the MON lines showed the host's copy of
                -- the client frozen in place while the client's own pawn
                -- covered ~10,000 units a second at a reported 400 - the
                -- server stops simulating the client entirely, so "no snaps"
                -- there meant nothing. Back to normal vs no-corrections, now
                -- with the host tracing its copy of the client frame by frame.
                -- Last run: no-corrections still snapped 31 times (normal 32), so
                -- the server isn't causing it. The host's copy only advances
                -- when a move packet lands, which is normal. The snaps are
                -- client-local. Suspect: move combining. At 240 fps the client
                -- merges several frames into one packet, and when it merges it
                -- rewinds to the start of the pending move and re-simulates the
                -- lot - any difference between that and the frame-by-frame
                -- result (we're turning, accel ramps) is a visible pop. Test it
                -- with combining off, and separately with the frame rate capped
                -- (fewer frames per packet = less combining).
                -- At a 60fps cap the raw series is unambiguous: every frame is
                -- 17ms, and the pawn moves exactly 0, 1, 2 or 3 frames' worth
                -- (0 / 12.5 / 25 / 37.5) - a frame of movement goes missing
                -- and turns up on a neighbouring frame. The mesh does the same,
                -- so it's on screen. Stalls come about every 6-8 frames, close
                -- to the rate of move responses (~13/s). Now both phases at
                -- 60fps so the steps stay clean: normal vs server corrections
                -- off. If the stalls survive with corrections off, it's acks
                -- or the client's own tick; if they vanish, it's corrections.
                -- Result: corrections off -> 0 catch-ups but still 50 stalled
                -- frames. So frames of movement are genuinely LOST on the
                -- client (corrections were putting them back). The client CMC
                -- skips performing a move when it can't allocate a saved move -
                -- the saved-move buffer only drains when the server acks, and
                -- the server only acks every NetworkMinTimeBetweenClientAckGoodMoves
                -- (0.1s by default; ~13 responses/s is what we see). Test: have
                -- the host ack every move.
                -- Fast acks (480 responses instead of 119) changed nothing: 77
                -- stalls vs 75. Saved-move starvation is out. This run is one
                -- normal 60fps phase with per-frame movement-component state on
                -- every stalled frame.
                -- Control run result: with the HOST capped at 60fps too, the
                -- client dropped from ~70 stalls to 11 and looked better. On a
                -- listen server the net driver sends every host frame (~180/s
                -- uncapped). Test whether it's the host's send rate:
                --   1 host uncapped (baseline)
                --   2 host NetDriver.MaxNetTickRate = 60 (host keeps its fps)
                --   3 host capped at 60fps (repeat of the control)
                -- FOUND THE LEVER. host uncapped 77 stalls, host net tick 60 95
                -- (send rate isn't it), host fps 60 -> 1 stall, 1 snap. It's
                -- the host's FRAME RATE. Now map it out:
                --   1 host 60 / client 60   (confirm)
                --   2 host 120 / client 60  (is it the ratio, or just "host fast"?)
                --   3 host 60 / client uncapped
                -- Note this is two games on one PC, so part of it may be the
                -- uncapped host hogging the machine rather than the netcode.
                -- That didn't hold up: this run host60/client60 had 80 stalls
                -- (last run: 1) and host120/client60 had 11. Same settings,
                -- opposite results, and Mason saw it come and go within one
                -- run, plus black flashes getting worse until a crash. That
                -- reads like the PC itself: two full UE5 games on one GPU
                -- fighting for VRAM and time. Both instances now start at
                -- the lowest graphics settings, and the same setting runs
                -- three times so we can see how much it varies on its own.
                local PHASES = {
                    { name = "low gfx #1", rep = "on", trust = "off", acks = "default", net = "fps60", on = {}, off = {} },
                    { name = "low gfx #2", rep = "on", trust = "off", acks = "default", net = "fps60", on = {}, off = {} },
                    { name = "low gfx #3", rep = "on", trust = "off", acks = "default", net = "fps60", on = {}, off = {} },
                }
                A.PH = PHASES
                A.results = A.results or {}
                A.phase = A.phase or 1
                A.results[A.phase] = { snaps = st.lastSnaps, counts = st.lastCounts or {},
                    stalls = st.lastStalls, doubles = st.lastDoubles,
                    speed = A.run and A.run.lastSpeed or -1 }
                alog(("phase %d (%s): %s snaps"):format(A.phase, PHASES[A.phase].name, tostring(st.lastSnaps)))
                for _, c in ipairs(PHASES[A.phase].off or {}) do console(c) end
                if A.phase < #PHASES then
                    A.phase = A.phase + 1
                    local ph = PHASES[A.phase]
                    for _, c in ipairs(ph.on or {}) do console(c) end
                    local tail = ph.rep .. ":" .. ph.trust .. ":" .. (ph.acks or "") .. ":" .. (ph.net or "")
                    A.want = "ok:" .. tail
                    fwrite("sdmp_phase.txt", "set:" .. tail)
                    A.step, A.t = "waitB", 0
                else
                    local parts = {}
                    for i, ph in ipairs(PHASES) do
                        local r = A.results[i] or {}
                        parts[#parts+1] = ("%s=%s snaps, %s stalls, %s catch-ups (top speed %s)"):format(
                            ph.name, tostring(r.snaps), tostring(r.stalls), tostring(r.doubles), tostring(r.speed))
                    end
                    alog("PHASE RESULT: " .. table.concat(parts, " | "))
                    fwrite("sdmp_done.txt", "1")
                    A.step, A.t = "finished", 0
                end
            end
        elseif A.step == "waitB" then
            A.t = A.t + 1
            if (fread("sdmp_phase.txt") or "") == A.want then
                alog("host confirmed " .. A.want .. " - next run")
                startRun(); A.step = "running"
            elseif A.t > 20 then
                alog("FAIL: host never confirmed " .. tostring(A.want)); fwrite("sdmp_done.txt", "1"); A.step, A.t = "finished", 0
            end
        elseif A.step == "zwait" then
            A.t = A.t + 1
            if (fread("sdmp_done.txt") or ""):find("1") or A.t > (A.test == "downed" and 260 or 120) then
                A.step, A.t = "finished", 0
            end
        elseif A.step == "finished" then
            A.t = A.t + 1
            if A.quit and A.t >= 5 then A.step = "quit"; console("quit") end
        end
    end

    -- The run is driven from the pawn's own tick so input is applied once per
    -- frame - driving it from LoopAsync would make the input itself uneven.
    -- Registered lazily: a BP function can't be hooked until its class loads,
    -- which is after the menu.
    A.hookRun = function()
        if A.runHooked then return end
        A.runHooked = true
        local ok, err = pcall(function()
        RegisterHook(BPC .. "ReceiveTick", function(ctx)
            local r = A.run
            if not r or r.phase == "done" then return end
            pcall(function()
                local p = ctx:get()
                if p:IsLocallyControlled() ~= true then return end
                local pc = p.Controller
                r.frames = r.frames + 1
                if r.phase == "walk" then
                    if r.frames == 1 then r.t0 = os.clock() end
                    if os.clock() - r.t0 > 3 then
                        r.phase = "sprint"
                        r.sprintOk = pcall(function() p:Event_Sprint() end)
                        alog("Event_Sprint -> " .. tostring(r.sprintOk))
                        snapTrace()
                        fwrite("sdmp_htrace.txt", "go")
                        r.t1 = os.clock()
                    end
                elseif r.phase == "sprint" then
                    -- turn gently in the second second
                    if os.clock() - r.t1 > 1.0 then pcall(function() pc:AddYawInput(0.15) end) end
                    if not st.on and os.clock() - r.t1 > 1.0 then
                        pcall(function() p:Event_StopSprint() end)
                        local spd = safe(function()
                            local v = p.CharacterMovement.Velocity
                            return math.sqrt(v.X*v.X + v.Y*v.Y) end, -1)
                        alog(("RESULT: snaptrace done, last speed %.0f, sprint call %s"):format(
                            spd, tostring(r.sprintOk)))
                        r.phase = "done"
                        return
                    end
                    if os.clock() - r.t1 > 15 then alog("FAIL: snaptrace never finished"); r.phase = "done"; return end
                end
                pcall(function()
                    local v = p.CharacterMovement.Velocity
                    local sp = math.sqrt(v.X*v.X + v.Y*v.Y)
                    if sp > (r.lastSpeed or 0) then r.lastSpeed = math.floor(sp) end
                end)
                local yaw = pc:GetControlRotation().Yaw * math.pi / 180
                p:AddMovementInput({ X = math.cos(yaw), Y = math.sin(yaw), Z = 0.0 }, 1.0, false)
            end)
        end)
        end)
        alog("run hook registered = " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
    end

    -- FOUND IT (trace run 1). During the join the client constructs its own
    -- RecastNavMesh_<n> in PersistentLevel - spawned, not loaded. That's the
    -- client's navigation system auto-creating nav data for the "Default"
    -- agent, which it names RecastNavMesh-Default. It does that while the map
    -- package is still streaming in, so when the loader reaches the real
    -- RecastNavMesh-Default export it finds a same-named object already in
    -- memory that it didn't load -> "found in memory ... does not have all
    -- load flags". (The client has a nav system even on Entry: AbstractNavData
    -- began play there.) Clients never path-find here, so tell the nav system
    -- not to create nav data on its own - on the CDO, so the new world's
    -- instance inherits it, and on the current instance for good measure.
    A.noClientNav = function()
        local function patch(ns, tag)
            if not (ns and safe(function() return ns:IsValid() end, false)) then return end
            local before = safe(function() return ns.bAutoCreateNavigationData end, "?")
            local cs = safe(function() return ns.bAllowClientSideNavigation end, "?")
            pcall(function() ns.bAutoCreateNavigationData = false end)
            alog(("nav %s %s: bAutoCreateNavigationData %s -> %s, bAllowClientSideNavigation=%s"):format(
                tag, className(ns), tostring(before),
                tostring(safe(function() return ns.bAutoCreateNavigationData end, "?")), tostring(cs)))
        end
        patch(StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1"), "CDO")
        local w = UEHelpers.GetWorld()
        local inst = w and safe(function() return w.NavigationSystem end, nil) or nil
        if inst and safe(function() return inst:IsValid() end, false) then
            patch(inst, "world")
            -- a game subclass would have its own CDO
            local cdo = safe(function() return inst:GetClass():GetCDO() end, nil)
            patch(cdo, "subclass CDO")
        end
    end

    -- --------------------------------------------------- join crash trace
    -- Four guesses at the RecastNavMesh join crash have been wrong, so stop
    -- guessing and record. On the client, from boot until we have a pawn:
    --   * every RecastNavMesh constructed (the crash says an export was
    --     already in memory without load flags - who made it, and when?)
    --   * the first BeginPlay of each class (the crash stack runs through
    --     ProcessEvent, so some Blueprint is triggering the load)
    --   * every SD_GameInstance function call (the game instance survives
    --     map loads, so its hooks can't go stale like a level's would)
    -- The last lines before the crash name the culprit.
    A.trace = function()
        if A.traced then return end
        A.traced = true
        A.tron = true
        local seen = {}
        local function tlog(s)
            if A.tron then log("TRACE " .. s) end
        end
        pcall(function()
            NotifyOnNewObject("/Script/NavigationSystem.RecastNavMesh", function(o)
                tlog("NEW RecastNavMesh " .. safe(function() return o:GetFullName() end, "?"))
            end)
        end)
        pcall(function()
            RegisterBeginPlayPreHook(function(ctx)
                if not A.tron then return end
                pcall(function()
                    local a = ctx:get()
                    local c = className(a)
                    if not seen[c] then
                        seen[c] = true
                        tlog("BeginPlay " .. c)
                    end
                end)
            end)
        end)
        pcall(function()
            local gi = UEHelpers.GetGameInstance()
            local cls = gi:GetClass()
            local path = safe(function() return cls:GetFullName() end, "")
            path = path:match("^%S+%s+(.+)$") or path
            local n = 0
            cls:ForEachFunction(function(fn)
                local name = safe(function() return fn:GetFName():ToString() end, "")
                if name ~= "" and not name:find("Ubergraph") and not name:find("DelegateSignature") then
                    if pcall(function()
                        RegisterHook(path .. ":" .. name, function() tlog("GI " .. name) end)
                    end) then n = n + 1 end
                end
            end)
            alog("trace: hooked " .. n .. " game instance functions on " .. path)
        end)
        alog("trace armed")
    end

    -- -------------------------------------------------------------- start
    local function boot()
        local cl = cmdline()
        A.role = cl:match("%-sdmprole=(%a+)")
        A.auto = cl:find("%-sdmpauto") ~= nil
        A.quit = cl:find("%-sdmpquit") ~= nil
        A.test = cl:match("%-sdmptest=(%a+)")
        if not A.role then return end
        alog(("boot: auto=%s quit=%s dir=%s"):format(tostring(A.auto), tostring(A.quit), modDir()))
        if not A.auto then return end
        -- two games share one GPU in a test run; keep both light
        console("scalability 0")
        console("r.ScreenPercentage 50")
        -- join-crash trace retired: the cause is found and fixed, and its
        -- always-on BeginPlay/NewObject hooks are the prime suspect for the
        -- UE4SS access violation the client hit right after joining
        -- if A.role == "client" then A.trace() end
        LoopAsync(1000, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(A.role == "host" and hostTick or clientTick)
                if not ok then alog("tick error in step " .. A.step .. ": " .. tostring(err)) end
            end)
            if A.step == "dead" and A.quit then A.step = "quit"; ExecuteInGameThread(function() console("quit") end) end
            return A.step == "dead" or A.step == "quit"
        end)
    end

    -- the command line is readable once the engine is up; give it a moment
    ExecuteWithDelay(3000, function() ExecuteInGameThread(boot) end)
end

log("SDMPDiag: auto mode - launch with -sdmprole=host|client -sdmpauto (tools/test.bat).")
