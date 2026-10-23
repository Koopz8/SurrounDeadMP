--[[ SurrounDead Co-op (SurrounDeadMP)
     Two-player co-op for SurrounDead over UE4SS. Main menu: F7 hosts, F8 joins
     the IP in config.txt. Test tooling lives in tools/ (test.bat, playtest.bat).
]]
local SDMP_VERSION = "0.1.0-beta"

local UEHelpers = require("UEHelpers")

-- Both test instances write the same UE4SS.log, and the second one to start
-- wipes it, so each instance also keeps its own sdmp_<role>.log next to the mod
-- (opened per line so it survives a crash).
local LOGF = { path = nil, verbose = false }
-- chatty per-second diagnostics only go out in test runs or with debug=true
local QUIET = { "^SDMPDiag:", "^ZA status", "^CENSUS", "^NP%[", "^NP:", "^CS slots", "^GEAR", "^WX ", "^SKYLINK",
                "^DN: BP_PlayerCharacter_C down ", "^CS rx", "^WEATHER" }
local function log(s)
    s = tostring(s)
    if not LOGF.verbose then
        for _, q in ipairs(QUIET) do if s:find(q) then return end end
    end
    local line = "[SDMP] " .. s
    print(line .. "\n")
    if LOGF.path then
        local f = io.open(LOGF.path, "a")
        if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end
    end
end

local ROLE = { [0]="None", [1]="SimulatedProxy", [2]="AutonomousProxy", [3]="Authority" }

local function safe(fn, fallback)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return fallback
end

-- Timers that run ON THE GAME THREAD. LoopAsync runs its callback on a worker
-- thread in the same Lua state the game thread is using for hooks; with
-- several of those loops going, the state got corrupted ("FindAllOf cannot be
-- called with 0 parameters") and the host crashed every ~8 minutes. The
-- installed UE4SS build has the delayed-action API, so use it; fall back to
-- the old way only if it's missing.
local HAS_GT_TIMERS = type(LoopInGameThreadWithDelay) == "function" and type(CancelDelayedAction) == "function"
local function gameLoop(ms, fn)   -- fn returns true to stop
    if HAS_GT_TIMERS then
        local h
        h = LoopInGameThreadWithDelay(ms, function()
            local ok, stop = pcall(fn)
            if not ok then print("[SDMP] loop error: " .. tostring(stop) .. "\n") end
            if ok and stop == true and h then CancelDelayedAction(h) end
        end)
        return h
    end
    LoopAsync(ms, function()
        ExecuteInGameThread(function() pcall(fn) end)
        return false
    end)
end
print("[SDMP] timers: " .. (HAS_GT_TIMERS and "game thread (LoopInGameThreadWithDelay)" or "LoopAsync fallback") .. "\n")
local function gameDelay(ms, fn)
    if type(ExecuteInGameThreadWithDelay) == "function" then
        return ExecuteInGameThreadWithDelay(ms, function() pcall(fn) end)
    end
    ExecuteWithDelay(ms, function() ExecuteInGameThread(function() pcall(fn) end) end)
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

-- (F7 is the co-op "host" key now; the diag dump is sdmp_diag only)

RegisterConsoleCommandHandler("sdmp_diag", function()
    ExecuteInGameThread(runDiag)
    return true
end)

log("SurrounDead Co-op " .. SDMP_VERSION .. " loaded. Main menu: F7 = host, F8 = join (see config.txt).")

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

RegisterConsoleCommandHandler("sdmp_net", function()
    ExecuteInGameThread(netStatus)
    return true
end)

log("SDMPDiag: sdmp_net for quick net status.")

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
RegisterConsoleCommandHandler("sdmp_host_raw", function()   -- old manual step; sdmp_host now does the whole thing
    ExecuteInGameThread(hostListen)
    return true
end)

log("SDMPDiag: sdmp_drivers to dump net driver defs.")

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
            -- ShowCompassWidget takes Show? (bool)
            local ok, err = pcall(function() if name == "ShowCompassWidget" then pawn[name](pawn, true) else pawn[name](pawn) end end)
            log("UI: " .. name .. " -> " .. (ok and "called" or ("threw: " .. tostring(err))))
        else
            log("UI: no such function " .. name)
        end
    end

    -- visibility is a separate flag from existence
    pcall(function() pawn:SetUIVisibility(true) end)

    -- nudge each bar so they draw with real values rather than empty; each
    -- update takes the new value
    local VAL = {
        Client_UpdateHealthUI = { "MedicalComponent", "Health" },
        Client_UpdateStaminaUI = { "StaminaComponent", "CurrentStamina" },
        Client_UpdateHungerUI = { "HungerThirstComponent", "CurrentHunger" },
        Client_UpdateThirstUI = { "HungerThirstComponent", "CurrentThirst" },
        Client_UpdateRadiationUI = { "RadiationComponent", "CurrentRadiation" },
    }
    for _, name in ipairs(UI_UPDATE) do
        local src = VAL[name]
        local v = src and safe(function() return pawn[src[1]][src[2]] end, nil)
        if type(v) == "number" and safe(function() return pawn[name] end, nil) ~= nil then
            local ok = pcall(function() pawn[name](pawn, v) end)
            log(("UI: %s(%.0f) -> %s"):format(name, v, tostring(ok)))
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
-- Per-tick gameplay code stays away from the world while it's being swapped
-- (listen travel, joining): pawns and PlayerStates are torn down mid-read and
-- even IsValid() on a freed object can read garbage and crash the game.
local WS = { addr = nil, since = 0 }
local function worldSettled()
    local w = UEHelpers.GetWorld()
    local a = (w and safe(function() return w:IsValid() end, false)) and safe(function() return w:GetAddress() end, nil) or nil
    local now = os.time()
    if a ~= WS.addr then WS.addr, WS.since = a, now end
    return a ~= nil and (now - WS.since) >= 4
end

local ZF = { touched = {}, logged = 0 }
local function zombieAnimFix()
    if not worldSettled() then return end
    local world = UEHelpers.GetWorld()
    if not (world and safe(function() return world:IsValid() end, false)) then return end
    local gm = safe(function() return world.AuthorityGameMode end, nil)
    if not (gm and safe(function() return gm:IsValid() end, false)) then return end
    local remote = {}
    for _, c in ipairs(listControllers()) do
        if safe(function() return c:IsLocalController() end, true) == false then
            local p = safe(function() return c.Pawn end, nil)
            if p and safe(function() return p:IsValid() end, false)
               and (safe(function() return p:GetGameTimeSinceCreation() end, 0) or 0) >= 5 then
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
gameLoop(1000, function()
    local ok, err = pcall(zombieAnimFix)
    if not ok then log("ZF error: " .. tostring(err)) end
end)

-- The attack montage only ever plays on the host (PlayAnimMontage isn't
-- replicated and the zombie has no multicast for it), so on a client zombies
-- deal damage without ever swinging. Clients play the swing themselves: a live
-- zombie within melee range of any player, not running, swings on the same
-- 1.45-2.05s rhythm the host uses. The client copy's damage is zeroed first,
-- because the montage's notifies run the hit traces and the hit code has no
-- authority check - a client swing would otherwise hurt the local copy of the
-- player (ApplyDamage with 0 does nothing; the blood puff still shows).
-- Player characters old enough to touch from per-tick code. A character a
-- moment old (a joiner being spawned and possessed) is where the host has
-- crashed inside Lua callbacks, so leave it alone for a few seconds.
local function livePlayers(minAge)
    local out = {}
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if p and safe(function() return p:IsValid() end, false)
           and (safe(function() return p:GetGameTimeSinceCreation() end, 0) or 0) >= (minAge or 5) then
            out[#out + 1] = p
        end
    end
    return out
end

local ZA = { next = {}, tick = 0, plays = 0, logged = 0, sndErr = false, last = {}, cnt = {}, events = 0 }
-- Swing signal. The host's zombie plays a real attack montage; joiners used to
-- guess when to swing (stopped + close), which looked off. Now the host tags
-- every real swing on the zombie's AnimRootMotionTranslationScale - a float
-- the engine already replicates to everyone watching that zombie - as
-- 1 + (flip * 500 + montage index) / 1e6. Joiners play exactly that montage
-- when the value changes. (A 0.05 % root-motion scale change does nothing
-- visible on the host.)
local function zaMontage(z, i)   -- i is 1-based
    local arr = safe(function() return z.AttackMontage end, nil)
    local n = arr and safe(function() return arr:GetArrayNum() end, 0) or 0
    if i < 1 or i > n then return nil, n end
    local e = safe(function() return arr[i] end, nil)
    local m = e
    if not (m and safe(function() return m:IsValid() end, false)) then m = safe(function() return e:get() end, nil) end
    if m and safe(function() return m:IsValid() end, false) then return m, n end
    return nil, n
end
pcall(function()
    RegisterHook("/Script/Engine.Character:PlayAnimMontage", function(ctx, montage)
        local z = safe(function() return ctx:get() end, nil)
        if not z then return end
        local cn = safe(function() return z:GetClass():GetFName():ToString() end, "")
        if not cn:find("Zombie") then return end
        local w = UEHelpers.GetWorld()
        local gm = w and safe(function() return w.AuthorityGameMode end, nil)
        if not (gm and safe(function() return gm:IsValid() end, false)) then return end   -- host only
        local m = safe(function() return montage:get() end, nil)
        if not m then return end
        local ma = m:GetAddress()
        local idx
        for i = 1, 16 do
            local cand, n = zaMontage(z, i)
            if i > n then break end
            if cand and cand:GetAddress() == ma then idx = i; break end
        end
        if not idx then return end   -- not an attack (hit reaction, death...)
        local k = z:GetAddress()
        ZA.cnt[k] = 1 - (ZA.cnt[k] or 0)
        local v = 1.0 + (ZA.cnt[k] * 500 + idx) / 1e6
        pcall(function() z.AnimRootMotionTranslationScale = v end)
        pcall(function() StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers"):MarkPropertyDirty(z, FName("AnimRootMotionTranslationScale")) end)
        pcall(function() z:ForceNetUpdate() end)
        ZA.events = ZA.events + 1
        if ZA.events <= 3 then log(("ZA: host swing %d tagged (montage %d)"):format(ZA.events, idx)) end
    end)
end)
local function zombieSwingMirror()
    if not worldSettled() then return end
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
    for _, pc in ipairs(livePlayers(5)) do
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
                -- the host's swing signal
                local sv = safe(function() return z.AnimRootMotionTranslationScale end, nil)
                if type(sv) == "number" then
                    local prev = ZA.last[key]
                    ZA.last[key] = sv
                    if prev and math.abs(sv - prev) > 5e-7 and sv > 1.0000005 and not dead then
                        local code = math.floor((sv - 1.0) * 1e6 + 0.5)
                        local idx = code % 500
                        local m = zaMontage(z, idx)
                        if m then
                            local anim = safe(function() return z.Mesh:GetAnimInstance() end, nil)
                            if anim and safe(function() return anim:IsValid() end, false) then
                                if not ZA.rm then ZA.rm = {} end
                                if not ZA.rm[key] then ZA.rm[key] = true; pcall(function() anim.RootMotionMode = 1 end) end
                            end
                            pcall(function() z:PlayAnimMontage(m, 1.0, FName("None")) end)
                            if gs and gs:IsValid() and zl then
                                pcall(function() gs:PlaySoundAtLocation(z, z.AttackSound, zl, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, nil, nil, nil, nil) end)
                            end
                            if not ZA.gotEvent then log("ZA: first swing signal from the host - following the host's swings from now on") end
                            ZA.gotEvent = true
                            ZA.plays = ZA.plays + 1
                            ZA.evPlays = (ZA.evPlays or 0) + 1
                            if ZA.evPlays <= 3 then log(("ZA: mirrored host swing (montage %d, %d so far)"):format(idx, ZA.evPlays)) end
                        end
                    end
                end
                if zl and not dead and not ZA.gotEvent and (ZA.next[key] or 0) <= ZA.tick then
                    local close = false
                    for _, p in ipairs(players) do
                        local d2 = (p.X - zl.X)^2 + (p.Y - zl.Y)^2
                        if d2 < 220 * 220 and math.abs(p.Z - zl.Z) < 200 then close = true; break end
                    end
                    local v = close and safe(function() return z:GetVelocity() end, nil)
                    -- only a zombie that's stopped, and isn't mid-swing already
                    local anim = close and safe(function() return z.Mesh:GetAnimInstance() end, nil)
                    if anim and not safe(function() return anim:IsValid() end, false) then anim = nil end
                    local busy = anim and safe(function() return anim:IsAnyMontagePlaying() end, false)
                    if close and v and not busy and (v.X * v.X + v.Y * v.Y) < 60 * 60 then
                        -- the client's copy is moved by replication; root motion from a
                        -- locally played montage fights it and looks jittery
                        if anim and not ZA.rm then ZA.rm = {} end
                        if anim and not ZA.rm[key] then
                            ZA.rm[key] = true
                            pcall(function() anim.RootMotionMode = 1 end)   -- IgnoreRootMotion
                        end
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
    for k in pairs(ZA.last) do if not seen[k] then ZA.last[k] = nil end end
    if ZA.rm then for k in pairs(ZA.rm) do if not seen[k] then ZA.rm[k] = nil end end end
    if report and st.nz > 0 then
        log(("ZA status: players=%d zombies=%d nearest=%.0f dz=%.0f speed=%.0f dead=%s swings=%d (from host signal %d)"):format(
            #players, st.nz, st.best, st.bdz, st.bspd, tostring(st.bdead), ZA.plays, ZA.evPlays or 0))
    elseif report then
        log(("ZA status: players=%d, no BP_MasterZombie_C found"):format(#players))
    end
end
gameLoop(250, function()
    local ok, err = pcall(zombieSwingMirror)
    if not ok then log("ZA error: " .. tostring(err)) end
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
local DN = { BLEED = 60, REVIVE = 5, DOWN_HP = 5, UP_HP = 30, RANGE = 260,
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
local function dnValid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local function dnCMC(p)
    local c = safe(function() return p.CharacterMovement end, nil)
    if c ~= nil and safe(function() return c:IsValid() end, false) then return c end
    return nil
end
local function dnHealth(p)
    local mc = safe(function() return p.MedicalComponent end, nil)
    if not dnValid(mc) then return nil end
    return safe(function() return mc.Health end, nil)
end
local function dnSetHealth(p, h)
    local mc = safe(function() return p.MedicalComponent end, nil)
    if not dnValid(mc) then return end
    pcall(function() mc.Health = h end)
    pcall(function() p:SendHealthToClient(h) end)
end
local function dnState(p)  -- read the replicated state off any pawn
    local ps = safe(function() return p.PlayerState end, nil)
    if not dnValid(ps) then return "up", 0 end
    local sc = safe(function() return ps.Score end, 0) or 0
    if sc >= 10000 then return "up", 0 end   -- host carrying time of day (see TOD)
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

-- Crouched by any measure: the flag, the movement component's view, or a
-- crouch that's been asked for but not applied yet (server copy of a remote
-- player lags a move or two behind their input).
DN.isCrouching = function(o)
    if safe(function() return o.bIsCrouched end, false) then return true, "flag" end
    local cmc = safe(function() return o.CharacterMovement end, nil)
    if dnValid(cmc) then
        if safe(function() return cmc:IsCrouching() end, false) then return true, "cmc" end
        if safe(function() return cmc.bWantsToCrouch end, false) then return true, "wants" end
    end
    return false, "no"
end
-- is anyone other than p alive and on their feet to come and revive them?
local function dnHasReviver(p)
    local k = safe(function() return p:GetAddress() end, 0)
    for _, o in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(o) and safe(function() return o:GetAddress() end, 0) ~= k
           and safe(function() return o:GetLocalRole() end, 0) ~= 0
           and not safe(function() return o["PlayerDead?"] end, false) and not DN.isDown(o)
           and safe(function() return o.Controller end, nil) ~= nil and dnValid(safe(function() return o.Controller end, nil)) then
            return true
        end
    end
    return false
end

local function dnEnter(p)
    local key = safe(function() return p:GetAddress() end, nil)
    if not key or DN.down[key] then return end
    local cmc = dnCMC(p)
    DN.down[key] = { p = p, t = DN.BLEED, rev = 0,
        walk = cmc and safe(function() return cmc.MaxWalkSpeed end, nil),
        crouch = cmc and safe(function() return cmc.MaxWalkSpeedCrouched end, nil),
        jump = cmc and safe(function() return cmc.JumpZVelocity end, nil) }
    dnSetHealth(p, DN.DOWN_HP)
    dnPublish(p, 100 + DN.BLEED)
    log(("DN: %s is DOWN (%ds to bleed out)"):format(className(p), DN.BLEED))
end

local function dnRestoreMove(p, d)
    local cmc = dnCMC(p)
    if not cmc then return end
    if d.walk then pcall(function() cmc.MaxWalkSpeed = d.walk end) end
    if d.crouch then pcall(function() cmc.MaxWalkSpeedCrouched = d.crouch end) end
    if d.jump then pcall(function() cmc.JumpZVelocity = d.jump end) end
end

-- The death sequence calls GetPlayerController(0)...ResetPassiveSkills() - on
-- the host that resets the HOST's passive skills whenever a joiner dies.
-- Snapshot them just before a joiner's death and put them back after.
local function dnHostSkills()
    local pc = dnLocalPC()
    DN.psCls = DN.psCls or StaticFindObject("/Game/Blueprints/Components/PassiveSkillsComponent.PassiveSkillsComponent_C")
    if not (dnValid(pc) and dnValid(DN.psCls)) then return nil end
    local comp = safe(function() return pc:GetComponentByClass(DN.psCls) end, nil)
    return dnValid(comp) and comp or nil
end
DN.guardHostSkills = function(why)
    local comp = dnHostSkills()
    if not comp then return end
    local vals = {}
    pcall(function()
        DN.psCls:ForEachProperty(function(prop)
            local n = safe(function() return prop:GetFName():ToString() end, nil)
            if n then
                local v = safe(function() return comp[n] end, nil)
                if type(v) == "number" or type(v) == "boolean" then vals[n] = v end
            end
        end)
    end)
    local function restore(tag)
        local c = dnHostSkills()
        if not c then return end
        local changed = 0
        for n, v in pairs(vals) do
            if safe(function() return c[n] end, v) ~= v then
                pcall(function() c[n] = v end)
                changed = changed + 1
            end
        end
        if changed > 0 then log(("DN: put back %d of the host's passive skill values (%s, %s)"):format(changed, why, tag)) end
    end
    gameDelay(300, function() restore("0.3s") end)
    gameDelay(2000, function() restore("2s") end)
end

local function dnBleedOut(key, d)
    local p = d.p
    DN.down[key] = nil
    dnPublish(p, 0)
    dnRestoreMove(p, d)
    local pc = dnLocalPC()
    local hostPawn = pc and safe(function() return pc.Pawn end, nil)
    log("DN: " .. className(p) .. " bled out")
    if safe(function() return p:IsLocallyControlled() end, true) == false then pcall(DN.guardHostSkills, "joiner bled out") end
    DN.allowKill[key] = true
    local ok, err = pcall(function()
        StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(p, 1000.0, nil, nil, nil)
    end)
    DN.allowKill[key] = nil
    if not ok then log("DN: kill failed: " .. tostring(err)) end
    -- the game's death unpossesses GetPlayerController(0) = the host. Only put
    -- the host back when it was a JOINER who died - when the host itself bleeds
    -- out, the host losing that (dead) body is exactly right.
    local remote = safe(function() return p:IsLocallyControlled() end, true) == false
    if remote and hostPawn and safe(function() return hostPawn:GetAddress() end, 0) ~= key then
        DN.repossess = { pc = pc, pawn = hostPawn, n = 0 }
    end
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
    for _, pc in ipairs(livePlayers(5)) do
        if safe(function() return pc:IsValid() end, false) and not safe(function() return pc["PlayerDead?"] end, false) then
            players[#players + 1] = pc
        end
    end
    for _, p in ipairs(players) do
        -- slow drains (hunger, radiation...) that never hit ApplyDamage
        -- a freshly spawned character sits at 0 health until its save data
        -- loads, so leave anything younger than 10s alone
        local age = safe(function() return p:GetGameTimeSinceCreation() end, 0) or 0
        local h = dnHealth(p)
        local ctl = safe(function() return p.Controller end, nil)
        if age >= 10 and h and h <= 2 and dnValid(ctl) and not DN.isDown(p) and dnHasReviver(p) then dnEnter(p) end
    end
    for key, d in pairs(DN.down) do
        local p = d.p
        if not safe(function() return p:IsValid() end, false) then
            DN.down[key] = nil
        else
            if (dnHealth(p) or 0) ~= DN.DOWN_HP then dnSetHealth(p, DN.DOWN_HP) end
            local cmc = dnCMC(p)
            if cmc then
                pcall(function() cmc.MaxWalkSpeed = 70 end)
                pcall(function() cmc.MaxWalkSpeedCrouched = 70 end)
                pcall(function() cmc.JumpZVelocity = 0 end)
            end
            local pl = safe(function() return p:K2_GetActorLocation() end, nil)
            local reviver, near, nearD, nearC = nil, nil, 1e9, nil
            for _, o in ipairs(players) do
                if o:GetAddress() ~= key and not DN.isDown(o) then
                    local ol = safe(function() return o:K2_GetActorLocation() end, nil)
                    if pl and ol then
                        local d2 = math.sqrt((ol.X - pl.X)^2 + (ol.Y - pl.Y)^2)
                        local dz = math.abs(ol.Z - pl.Z)
                        local cr, why = DN.isCrouching(o)
                        if not cr then
                            local v = safe(function() return o:GetVelocity() end, nil)
                            local sp = v and math.sqrt(v.X * v.X + v.Y * v.Y) or 999
                            if sp < 40 then cr, why = true, "still" else why = ("moving %.0f"):format(sp) end
                        end
                        if d2 < nearD then near, nearD, nearC = o, d2, why end
                        if cr and d2 < DN.RANGE and dz < 200 then reviver = o; break end
                    end
                end
            end
            -- every 2s while down, say why a revive is or isn't happening
            d.diag = (d.diag or 0) + 1
            if d.diag % 8 == 1 then
                log(("DN: %s down %.0fs left, rev %d%%, nearest partner %s at %.0f (crouch: %s)"):format(
                    className(p), d.t, math.floor(d.rev * 100), near and className(near) or "none", nearD, tostring(nearC)))
            end
            if not reviver and not dnHasReviver(p) and d.t > 2 then
                d.t = 2   -- partner's dead or down too: nobody's coming
            end
            if reviver then
                d.miss = 0
                d.rev = d.rev + 0.25 / DN.REVIVE
            else
                -- a second of grace so a flicker in crouch/range doesn't wipe progress
                d.miss = (d.miss or 0) + 1
                if d.miss > 4 then d.rev = 0 end
                if d.rev == 0 then d.t = d.t - 0.25 end
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

-- List every player character this machine knows about (debugging the extra
-- character that shows up after a death).
DN.census = function(tag)
    local pcs = safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}
    log(("CENSUS %s: %d player characters"):format(tag, #pcs))
    for i, p in ipairs(pcs) do
        if dnValid(p) then
            local c = safe(function() return p.Controller end, nil)
            local cs = dnValid(c) and (className(c) .. (safe(function() return c:IsLocalController() end, false) and "(local)" or "(remote)")) or "none"
            local l = safe(function() return p:K2_GetActorLocation() end, nil)
            local role = safe(function() return p:GetLocalRole() end, "?")
            if type(role) == "userdata" then role = safe(function() return role:get() end, "?") end
            log(("CENSUS %s  #%d %s role=%s ctl=%s dead=%s hp=%s age=%.0f hidden=%s at %s"):format(tag, i,
                string.format("%X", safe(function() return p:GetAddress() end, 0)) , tostring(role), cs,
                tostring(safe(function() return p["PlayerDead?"] end, "?")), tostring(dnHealth(p)),
                safe(function() return p:GetGameTimeSinceCreation() end, -1) or -1,
                tostring(safe(function() return p.bHidden end, "?")),
                l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?"))
        end
    end
end

-- A client loads the same save as the host and runs the single-player "spawn
-- the player at the saved spot" itself, so it ends up with an extra character
-- of its own standing where the host is (role Authority on a client = made
-- locally, nobody else can see it). Remove those, and log which game function
-- made them so we can stop it at the source.
DN.ghosts = DN.ghosts or {}
local function dnGhostSweep()
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) then
            local role = safe(function() return p:GetLocalRole() end, 0)
            if type(role) == "userdata" then role = safe(function() return role:get() end, 0) end
            if role == 3 then
                local k = safe(function() return p:GetAddress() end, 0)
                if not DN.ghosts[k] then
                    DN.ghosts[k] = true
                    local l = safe(function() return p:K2_GetActorLocation() end, nil)
                    local ok = pcall(function() p:K2_DestroyActor() end)
                    log(("DN: removed a client-only ghost character at %s -> %s"):format(
                        l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?", tostring(ok)))
                end
            end
        end
    end
end
local function dnHookSpawns()
    if DN.spawnHooked then return end
    local gi = StaticFindObject("/Game/Blueprints/SD_GameInstance.SD_GameInstance_C")
    if not dnValid(gi) then return end
    DN.spawnHooked = true
    local n = 0
    pcall(function()
        gi:ForEachFunction(function(fn)
            local name = safe(function() return fn:GetFName():ToString() end, "")
            if name:find("Spawn") and not name:find("Delegate") and not name:find("Ubergraph") then
                if pcall(function()
                    RegisterHook("/Game/Blueprints/SD_GameInstance.SD_GameInstance_C:" .. name, function()
                        log(("GI: %s ran (%s)"):format(name, dnIsHost() and "has authority" or "network client"))
                    end)
                end) then n = n + 1 end
            end
        end)
    end)
    log("DN: watching " .. n .. " SD_GameInstance spawn functions")
end

-- Late joiners see everyone naked. Clothing goes Svr_AttachClothing ->
-- MC_AttachClothing(component, mesh, ...), a multicast that sets the mesh on
-- every machine - but the host dresses while loading its save, before anyone
-- has joined, so nobody else ever got those calls. When a player joins, the host
-- replays the current mesh of every skeletal mesh component on every player
-- through that same multicast. Body Part = None skips the game's body-part
-- swapping and just sets the mesh.
local CS = { known = {}, due = {}, err = false }
local CS_SLOTS = { "Torso", "Biceps", "LowerThighs", "Clothing_Feet", "Clothing_Legs", "Clothing_Torso", "head",
                   "Clothing_Gloves", "Arms", "Feet", "LowerLegs", "Legs", "Hands", "Clothing_Armor" }
local function clothingResend(why)
    local smc = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
    if not dnValid(smc) then return end
    local sent, pawns = 0, 0
    for _, p in ipairs(livePlayers(3)) do
        if dnValid(p) and not safe(function() return p["PlayerDead?"] end, false) then
            pawns = pawns + 1
            local main = safe(function() return p.Mesh:GetAddress() end, 0)
            -- the character Blueprint's own component variables (Torso, Arms,
            -- the clothing slots...) - every one holding a skeletal mesh component
            if not CS.names then
                CS.names = {}
                local cls = StaticFindObject("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C")
                pcall(function()
                    cls:ForEachProperty(function(prop)
                        local n = safe(function() return prop:GetFName():ToString() end, nil)
                        if n then
                            local v = safe(function() return p[n] end, nil)
                            if type(v) == "userdata" and dnValid(v) and className(v):find("SkeletalMeshComponent") then
                                CS.names[#CS.names + 1] = n
                            end
                        end
                    end)
                end)
                log("CS: clothing/body slots: " .. table.concat(CS.names, ", "))
            end
            local list = {}
            for _, n in ipairs(CS.names) do
                local c = safe(function() return p[n] end, nil)
                if dnValid(c) then list[#list + 1] = { n = n, c = c } end
            end
            for _, it in ipairs(list) do
                local c = it.c
                if safe(function() return c:GetAddress() end, 0) ~= main then
                    local mesh = safe(function() return c:GetSkeletalMeshAsset() end, nil) or safe(function() return c.SkeletalMesh end, nil)
                    if mesh ~= nil and not dnValid(mesh) then mesh = nil end
                    if (CS.shown or 0) < 40 then
                        CS.shown = (CS.shown or 0) + 1
                        log(("CS:   %s.%s = %s"):format(string.format("%X", safe(function() return p:GetAddress() end, 0)),
                            it.n, mesh and safe(function() return mesh:GetFName():ToString() end, "?") or "none"))
                    end
                    -- queued, not sent: Unreal drops unreliable multicasts past
                    -- net.MaxRPCPerNetUpdate (default 2) per actor per net update
                    CS.queue = CS.queue or {}
                    CS.queue[#CS.queue + 1] = { p = p, c = c, mesh = mesh }
                    sent = sent + 1
                end
            end
        end
    end
    log(("CS: queued %d clothing/body meshes on %d players (%s)"):format(sent, pawns, why))
end
local function clothingDrain()
    if not CS.queue or #CS.queue == 0 then return end
    if not CS.cvar then
        CS.cvar = true
        pcall(function()
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(
                UEHelpers.GetWorld(), "net.MaxRPCPerNetUpdate 16", nil)
        end)
        log("CS: net.MaxRPCPerNetUpdate -> 16")
    end
    local perPawn = {}
    local i = 1
    while i <= #CS.queue do
        local it = CS.queue[i]
        local k = safe(function() return it.p:GetAddress() end, 0)
        if (perPawn[k] or 0) >= 2 then
            i = i + 1
        else
            table.remove(CS.queue, i)
            if dnValid(it.p) and dnValid(it.c) then
                perPawn[k] = (perPawn[k] or 0) + 1
                local ok, err = pcall(function() it.p:MC_AttachClothing(it.c, it.mesh, {}, true, FName("None"), false) end)
                if not ok and not CS.err then CS.err = true; log("CS: MC_AttachClothing failed: " .. tostring(err)) end
            end
        end
    end
    if #CS.queue == 0 then log("CS: clothing resend sent") end
end
-- Equipped gear (cap, mask, backpack, weapons, flashlight) are item actors the
-- game attaches to the character, spawned with replication OFF - single-player
-- never needed them on the network, so nobody else ever sees them. While
-- co-op is running the host turns replication on for anything attached to a
-- player; Unreal then sends the actor along with its attachment.
CS.gearDone = CS.gearDone or {}
local function gearReplicate()
    local n = 0
    for _, p in ipairs(livePlayers(10)) do
        if dnValid(p) then
            local list = {}
            pcall(function() p.Children:ForEach(function(_, e) list[#list + 1] = e:get() end) end)
            for _, a in ipairs(list) do
                if dnValid(a) then
                    local k = safe(function() return a:GetAddress() end, 0)
                    if not CS.gearDone[k] and safe(function() return a.bReplicates end, true) == false
                       and dnValid(safe(function() return a:GetAttachParentActor() end, nil))
                       and className(a):find("Pickup") then
                        CS.gearDone[k] = true
                        local ok = pcall(function() a:SetReplicates(true) end)
                        -- attach offsets (the bat's -90 pitch) only travel reliably
                        -- with movement replication on
                        pcall(function() a:SetReplicateMovement(true) end)
                        pcall(function() a:ForceNetUpdate() end)
                        n = n + 1
                        if n <= 12 then
                            local root = safe(function() return a.RootComponent end, nil)
                            local r = dnValid(root) and (safe(function() return root:GetRelativeRotation() end, nil) or safe(function() return root.RelativeRotation end, nil))
                            log(("GEAR: replicating %s on %X -> %s (rel rot %s, physics %s)"):format(className(a), safe(function() return p:GetAddress() end, 0), tostring(ok),
                                r and ("%.0f,%.0f,%.0f"):format(r.Pitch, r.Yaw, r.Roll) or "?",
                                tostring(dnValid(root) and safe(function() return root:IsSimulatingPhysics() end, "?"))))
                        end
                    end
                end
            end
        end
    end
end
-- Items lying on the ground are pickup actors spawned with replication OFF,
-- same as gear: a joiner never saw anything the host or another player
-- dropped, and the host's copy of a level item it picked up stayed put on
-- the joiner's screen. While co-op is running the host turns replication on
-- for loose pickups within 80 m of a joiner, so they appear, fall and vanish
-- for everyone. Level-placed items keep their identity (the joiner's own copy
-- becomes the replicated one, like doors).
CS.groundDone = CS.groundDone or {}
CS.GROUND_R2 = 8000 * 8000
local function groundReplicate()
    local remote = {}
    for _, p in ipairs(livePlayers(5)) do
        if safe(function() return p:IsLocallyControlled() end, true) == false then
            local l = safe(function() return p:K2_GetActorLocation() end, nil)
            if l then remote[#remote + 1] = l end
        end
    end
    if #remote == 0 then return end
    local n, seen = 0, 0
    for _, c in ipairs(safe(function() return FindAllOf("BP_JigPickupComponent_C") end, nil) or {}) do
        local a = dnValid(c) and safe(function() return c:GetOwner() end, nil)
        if dnValid(a) then
            seen = seen + 1
            local k = safe(function() return a:GetAddress() end, 0)
            if not CS.groundDone[k] and safe(function() return a.bReplicates end, true) == false
               and not dnValid(safe(function() return a:GetAttachParentActor() end, nil))
               and CS.inPlayWorld(a) then
                local l = safe(function() return a:K2_GetActorLocation() end, nil)
                local near = false
                for _, r in ipairs(remote) do
                    if l and (l.X - r.X)^2 + (l.Y - r.Y)^2 < CS.GROUND_R2 then near = true; break end
                end
                if near then
                    CS.groundDone[k] = true
                    pcall(function() a:SetReplicates(true) end)
                    pcall(function() a:SetReplicateMovement(true) end)
                    pcall(function() a:ForceNetUpdate() end)
                    n = n + 1
                    if n <= 6 then log("GROUND: replicating " .. className(a)) end
                end
            end
        end
    end
    if n > 0 then log(("GROUND: %d loose item(s) now replicate (%d pickups loaded)"):format(n, seen)) end
end
CS.groundReplicate = groundReplicate
local function clothingSync()
    clothingDrain()
    CS.gt = (CS.gt or 0) + 1
    if CS.gt % 8 == 0 and dnCoop() then pcall(gearReplicate) end   -- every 2s
    if CS.gt % 8 == 4 and dnCoop() then pcall(groundReplicate) end -- every 2s, offset
    local now = os.time()
    for _, c in ipairs(listControllers()) do
        if safe(function() return c:IsLocalController() end, true) == false then
            local p = safe(function() return c.Pawn end, nil)
            if dnValid(p) then
                local k = safe(function() return p:GetAddress() end, nil)
                if k and not CS.known[k] then
                    CS.known[k] = true
                    CS.due[#CS.due + 1] = now + 5
                    CS.due[#CS.due + 1] = now + 15
                end
            end
        end
    end
    local run = false
    for i = #CS.due, 1, -1 do
        if now >= CS.due[i] then table.remove(CS.due, i); run = true end
    end
    if run then clothingResend("player joined") end
end
-- client side: what clothing calls arrive, and what each slot ends up holding
local function csClientWatch()
    if CS.hooked then return end
    local cls = StaticFindObject("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C")
    if not dnValid(cls) then return end
    CS.hooked = true
    CS.rx = 0
    pcall(function()
        RegisterHook("/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:MC_AttachClothing", function(ctx, comp, mesh)
            CS.rx = CS.rx + 1
            if CS.rx <= 60 then
                local c = safe(function() return comp:get() end, nil)
                local m = safe(function() return mesh:get() end, nil)
                local cn = dnValid(c) and safe(function() return c:GetFName():ToString() end, "?") or "nil"
                local mn = dnValid(m) and safe(function() return m:GetFName():ToString() end, "?") or "NONE"
                -- what the component holds after the call ran
                local now = dnValid(c) and safe(function() local a = c:GetSkeletalMeshAsset(); return dnValid(a) and a:GetFName():ToString() or "none" end, "?") or "?"
                log(("CS rx: %s <- %s (now %s)"):format(cn, mn, now))
            end
        end)
    end)
    log("CS: client watching MC_AttachClothing")
end
CS.dumpSlots = function(tag)
    CS.names = CS.names or CS_SLOTS
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) then
            local parts = {}
            for _, n in ipairs(CS.names or {}) do
                local c = safe(function() return p[n] end, nil)
                local m = dnValid(c) and safe(function() return c:GetSkeletalMeshAsset() end, nil)
                local vis = dnValid(c) and safe(function() return c:IsVisible() end, "?")
                parts[#parts + 1] = n .. "=" .. (dnValid(m) and safe(function() return m:GetFName():ToString() end, "?") or "none") .. (vis == false and "(hidden)" or "")
            end
            log(("CS slots %s %X role=%s: %s"):format(tag, safe(function() return p:GetAddress() end, 0),
                tostring(safe(function() return p:GetLocalRole() end, "?")), table.concat(parts, " ")))
        end
    end
end

-- What's hanging off each player (equipped cap, backpack, weapons are actors
-- the game SetOwner()s to the character, so they show up in Children).
CS.gearCensus = function(tag)
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) then
            local items = {}
            pcall(function()
                p.Children:ForEach(function(_, e)
                    local a = e:get()
                    if dnValid(a) then
                        local par = safe(function() return a:GetAttachParentActor() end, nil)
                        items[#items + 1] = ("%s[rep=%s hidden=%s attached=%s]"):format(className(a),
                            tostring(safe(function() return a.bReplicates end, "?")),
                            tostring(safe(function() return a.bHidden end, "?")),
                            tostring(dnValid(par)))
                    end
                end)
            end)
            -- transforms of the attached items, to compare host vs joiner
            pcall(function()
                p.Children:ForEach(function(_, e)
                    local a = e:get()
                    if dnValid(a) and className(a):find("Pickup") and dnValid(safe(function() return a:GetAttachParentActor() end, nil)) then
                        local function tr(c)
                            local l = safe(function() return c.RelativeLocation end, nil)
                            local r = safe(function() return c.RelativeRotation end, nil)
                            return ("loc(%.0f,%.0f,%.0f) rot(%.0f,%.0f,%.0f)"):format(l and l.X or 0, l and l.Y or 0, l and l.Z or 0,
                                r and r.Pitch or 0, r and r.Yaw or 0, r and r.Roll or 0)
                        end
                        local root = safe(function() return a.RootComponent end, nil)
                        local parts = { "root " .. (dnValid(root) and (safe(function() return root:GetFName():ToString() end, "?") .. " " .. tr(root) .. " socket=" .. tostring(safe(function() return root:GetAttachSocketName():ToString() end, "?"))) or "?") }
                        pcall(function()
                            root.AttachChildren:ForEach(function(_, ce)
                                local c = ce:get()
                                if dnValid(c) then parts[#parts + 1] = safe(function() return c:GetFName():ToString() end, "?") .. " " .. tr(c) end
                            end)
                        end)
                        log(("GEARX %s %s: %s"):format(tag, className(a), table.concat(parts, " | ")))
                    end
                end)
            end)
            log(("GEAR %s %X role=%s: %s"):format(tag, safe(function() return p:GetAddress() end, 0),
                tostring(safe(function() return p:GetLocalRole() end, "?")),
                #items > 0 and table.concat(items, ", ") or "nothing"))
        end
    end
end
-- widgets on screen (hunting the "PRESS ANY KEY" that never goes away)
CS.widgetCensus = function(tag)
    local names = {}
    for _, w in ipairs(safe(function() return FindAllOf("UserWidget") end, nil) or {}) do
        if dnValid(w) and safe(function() return w:IsInViewport() end, false) then
            names[#names + 1] = className(w) .. (safe(function() return w:IsVisible() end, true) and "" or "(hidden)")
        end
    end
    log(("WIDGETS %s: %s"):format(tag, #names > 0 and table.concat(names, ", ") or "none"))
end
-- The main menu's "PRESS ANY KEY" (PressAnyKeyWidget_C) stays up after a
-- joiner loads in (they never press a key on that screen) and after the
-- auto-Continue on a play-test host.
CS.clearPressAnyKey = function()
    local n = 0
    for _, w in ipairs(safe(function() return FindAllOf("PressAnyKeyWidget_C") end, nil) or {}) do
        if dnValid(w) and safe(function() return w:IsInViewport() end, false) then
            if pcall(function() w:RemoveFromParent() end) then n = n + 1 end
        end
    end
    if n > 0 then log("UI: removed " .. n .. " PRESS ANY KEY widget(s)") end
end
RegisterConsoleCommandHandler("sdmp_widgets", function()
    ExecuteInGameThread(function() pcall(CS.widgetCensus, "console") end)
    return true
end)
-- Sky / weather state (hunting time-of-day sync: host at night, joiner by day)
CS.skyCensus = function(tag)
    for _, cn in ipairs({ "Ultra_Dynamic_Sky_C", "Ultra_Dynamic_Weather_C" }) do
        for _, a in ipairs(safe(function() return FindAllOf(cn) end, nil) or {}) do
            if dnValid(a) then
                local vals = {}
                local cls = safe(function() return a:GetClass() end, nil)
                pcall(function()
                    cls:ForEachProperty(function(prop)
                        local n = safe(function() return prop:GetFName():ToString() end, "")
                        local ln = n:lower()
                        if ln:find("time") or ln:find("rep") or ln:find("network") or ln:find("multiplayer")
                           or ln:find("server") or ln:find("authority") or ln:find("day") or ln:find("simulat")
                           or ln:find("weather") or ln:find("speed") or ln:find("cycle") then
                            local v = safe(function() return a[n] end, nil)
                            if type(v) == "number" then vals[#vals + 1] = ("%s=%.3f"):format(n, v)
                            elseif type(v) == "boolean" then vals[#vals + 1] = n .. "=" .. tostring(v)
                            elseif type(v) == "userdata" and dnValid(v) then vals[#vals + 1] = n .. "=" .. className(v) end
                        end
                    end)
                end)
                table.sort(vals)
                log(("SKY %s %s rep=%s role=%s: %s"):format(tag, cn, tostring(safe(function() return a.bReplicates end, "?")),
                    tostring(safe(function() return a:GetLocalRole() end, "?")), table.concat(vals, " ")))
            end
        end
    end
end
-- Safer probe: only plain float / double / bool / int properties, checked by
-- property type BEFORE reading (reading structs blindly crashed a joiner).
CS.weatherCensus = function(tag)
    local okTypes = { FloatProperty = true, DoubleProperty = true, BoolProperty = true, IntProperty = true }
    for _, a in ipairs(safe(function() return FindAllOf("Ultra_Dynamic_Weather_C") end, nil) or {}) do
        if dnValid(a) then
            local vals = {}
            local cls = safe(function() return a:GetClass() end, nil)
            pcall(function()
                cls:ForEachProperty(function(prop)
                    local pt = safe(function() return prop:GetClass():GetFName():ToString() end, "")
                    if okTypes[pt] then
                        local n = safe(function() return prop:GetFName():ToString() end, nil)
                        if n then
                            local v = safe(function() return a[n] end, nil)
                            if type(v) == "number" then
                                if v ~= 0 then vals[#vals + 1] = ("%s=%.3f"):format(n, v) end
                            elseif type(v) == "boolean" then
                                if v then vals[#vals + 1] = n end
                            end
                        end
                    end
                end)
            end)
            table.sort(vals)
            log(("WEATHER %s role=%s: %s"):format(tag, tostring(safe(function() return a:GetLocalRole() end, "?")), table.concat(vals, " | ")))
        end
    end
end
-- The joiner keeps the main menu's sky/weather actors alive (MainMenu level,
-- parked at 9999,9999,9999 and set to a storm). Anything that looks up the sky
-- or weather has to skip those.
local function inPlayWorld(a)
    local fn = safe(function() return a:GetFullName() end, "") or ""
    return not fn:find("/MainMenu", 1, true)
end
CS.inPlayWorld = inPlayWorld
local function playWeather()
    for _, a in ipairs(safe(function() return FindAllOf("Ultra_Dynamic_Weather_C") end, nil) or {}) do
        if dnValid(a) and inPlayWorld(a) then return a end
    end
    return nil
end
CS.playWeather = playWeather
-- Probe: drive a real weather change on the host (UDW's own Change Weather
-- with a stormy preset) and see whether the joiner's sky follows.
CS.wxForce = function()
    local w = playWeather()
    if not w then log("WXT host: no weather actor"); return end
    local names = {}
    pcall(function()
        w:GetClass():ForEachFunction(function(fn)
            local n = safe(function() return fn:GetFName():ToString() end, "")
            if n:find("Change") or n:find("Set ") or n:find("Rep") then names[#names + 1] = n end
        end)
    end)
    log("WXT fns: " .. table.concat(names, ", "))
    local presets, pick = {}, nil
    for _, o in ipairs(safe(function() return FindAllOf("UDS_Weather_Settings_C") end, nil) or {}) do
        local n = safe(function() return o:GetFName():ToString() end, "?")
        presets[#presets + 1] = n
        if n == "Rain_Thunderstorm" then pick = o end
    end
    if not pick then
        for _, o in ipairs(safe(function() return FindAllOf("UDS_Weather_Settings_C") end, nil) or {}) do
            local n = safe(function() return o:GetFName():ToString() end, "?")
            if n:find("Rain") then pick = o; break end
        end
    end
    log("WXT presets: " .. table.concat(presets, ", "))
    if not pick then log("WXT host: no stormy preset loaded"); return end
    local ok, err = pcall(function() w["Change Weather"](w, pick, 4.0) end)
    log(("WXT host: Change Weather(%s) -> %s %s"):format(safe(function() return pick:GetFName():ToString() end, "?"), tostring(ok), tostring(err or "")))
end
-- Which weather actor does each sky listen to? (ObjectProperty reads only.)
CS.skyLink = function(tag)
    for _, sky in ipairs(safe(function() return FindAllOf("Ultra_Dynamic_Sky_C") end, nil) or {}) do
        if dnValid(sky) then
            local links = {}
            pcall(function()
                sky:GetClass():ForEachProperty(function(prop)
                    local pt = safe(function() return prop:GetClass():GetFName():ToString() end, "")
                    if pt == "ObjectProperty" then
                        local n = safe(function() return prop:GetFName():ToString() end, "")
                        local o = safe(function() return sky[n] end, nil)
                        if dnValid(o) and className(o):find("Weather") then
                            local fn = safe(function() return o:GetFullName() end, "?")
                            links[#links + 1] = n .. "->" .. (fn:find("/MainMenu", 1, true) and "MAINMENU" or "play") .. ":" .. className(o)
                        end
                    end
                end)
            end)
            local sfn = safe(function() return sky:GetFullName() end, "?")
            log(("SKYLINK %s sky(%s): %s"):format(tag, sfn:find("/MainMenu", 1, true) and "MAINMENU" or "play", table.concat(links, ", ")))
        end
    end
end
-- Compact: which weather actors exist, where they came from, key values only.
CS.weatherBrief = function(tag)
    local keys = { "Cloud Coverage", "Rain", "Snow", "Fog", "Dust", "Wind Intensity", "Thunder/Lightning", "Material Wetness" }
    for _, a in ipairs(safe(function() return FindAllOf("Ultra_Dynamic_Weather_C") end, nil) or {}) do
        if dnValid(a) then
            local parts = {}
            for _, k in ipairs(keys) do
                local v = safe(function() return a[k] end, nil)
                if type(v) == "number" then parts[#parts + 1] = ("%s=%.2f"):format(k, v) end
            end
            local l = safe(function() return a:K2_GetActorLocation() end, nil)
            local owner = safe(function() return a:GetOwner() end, nil)
            log(("WX %s %s cls=%s role=%s rep=%s owner=%s at %s full=%s: %s"):format(tag,
                safe(function() return a:GetFName():ToString() end, "?"), className(a),
                tostring(safe(function() return a:GetLocalRole() end, "?")), tostring(safe(function() return a.bReplicates end, "?")),
                dnValid(owner) and className(owner) or "none",
                l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?",
                safe(function() return a:GetFullName() end, "?"):sub(1, 140),
                table.concat(parts, " ")))
        end
    end
end
-- host console: roll a thunderstorm to check the joiner follows
RegisterConsoleCommandHandler("sdmp_storm", function()
    ExecuteInGameThread(function() pcall(CS.wxForce) end)
    return true
end)
RegisterConsoleCommandHandler("sdmp_weather", function()
    ExecuteInGameThread(function() pcall(CS.weatherCensus, "console") end)
    return true
end)
RegisterConsoleCommandHandler("sdmp_sky", function()
    ExecuteInGameThread(function() pcall(CS.skyCensus, "console") end)
    return true
end)
RegisterConsoleCommandHandler("sdmp_gear", function()
    ExecuteInGameThread(function() pcall(CS.gearCensus, "console") end)
    return true
end)

RegisterConsoleCommandHandler("sdmp_clothes", function()
    ExecuteInGameThread(function() pcall(clothingResend, "console") end)
    return true
end)

-- The main menu's "PRESS ANY KEY" prompt survives into the game after a
-- listen travel / join. Once we have a player character, take it down.
local PAK = { t = 0, n = 0 }
local function pressAnyKeySweep()
    PAK.t = PAK.t + 1
    if PAK.t % 8 ~= 0 then return end   -- every 2s
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    if not (dnValid(me) and className(me) == "BP_PlayerCharacter_C") then return end
    for _, w in ipairs(safe(function() return FindAllOf("PressAnyKeyWidget_C") end, nil) or {}) do
        if dnValid(w) and safe(function() return w:IsInViewport() end, false) then
            local ok = pcall(function() w:RemoveFromParent() end)
            PAK.n = PAK.n + 1
            if PAK.n <= 3 then log("UI: removed leftover PRESS ANY KEY prompt -> " .. tostring(ok)) end
        end
    end
end

-- Joiner side: gear worn by OTHER players arrives as fresh copies of pickup
-- actors, which start out like a dropped item (physics/collision on). That
-- twists them off their attach point (the bat sticking out sideways) and
-- would let you "pick up" someone's equipped cap. Make them pure visuals.
local GV = { done = {}, t = 0, n = 0 }
local function gearVisualsSweep()
    GV.t = GV.t + 1
    if GV.t % 8 ~= 0 then return end
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) and safe(function() return p:IsLocallyControlled() end, true) == false then
            local list = {}
            pcall(function() p.Children:ForEach(function(_, e) list[#list + 1] = e:get() end) end)
            for _, a in ipairs(list) do
                if dnValid(a) and className(a):find("Pickup") then
                    local k = safe(function() return a:GetAddress() end, 0)
                    if not GV.done[k] then
                        GV.done[k] = true
                        local root = safe(function() return a.RootComponent end, nil)
                        if dnValid(root) then pcall(function() root:SetSimulatePhysics(false) end) end
                        pcall(function() a:SetActorEnableCollision(false) end)
                        -- the attach offset never replicates (socket does, offset
                        -- doesn't), so apply it ourselves the way the game does on
                        -- equip: the item's data asset holds EquippedTransform
                        local how = "no data"
                        pcall(function()
                            GV.pcCls = GV.pcCls or StaticFindObject("/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C")
                            local comp = dnValid(GV.pcCls) and a:GetComponentByClass(GV.pcCls) or nil
                            local da = dnValid(comp) and safe(function() return comp.ItemDataAsset end, nil) or nil
                            if not dnValid(da) and dnValid(comp) then da = safe(function() return comp.CurrentInfo.ItemInfo end, nil) end
                            if dnValid(da) then
                                local xf = da.EquippedTransform
                                local ok = pcall(function() a:K2_SetActorRelativeTransform(xf, false, {}, false) end)
                                how = safe(function() return da:GetFName():ToString() end, "?") .. " -> " .. tostring(ok)
                            elseif dnValid(comp) then
                                how = "component but no data asset"
                            else
                                how = "no pickup component"
                            end
                        end)
                        GV.n = GV.n + 1
                        if GV.n <= 10 then
                            local r = safe(function() return root:GetRelativeRotation() end, nil) or safe(function() return root.RelativeRotation end, nil)
                            local r2 = safe(function() return root.RelativeRotation end, nil)
                            log(("GEAR: %s on another player made visual-only, offset from %s (rel rot now %s)"):format(className(a), how,
                                r2 and ("%.0f,%.0f,%.0f"):format(r2.Pitch, r2.Yaw, r2.Roll) or "?"))
                        end
                    end
                end
            end
        end
    end
end

-- Joiner side of dying. The game shows a Respawn screen whose buttons run the
-- single-player respawn on the host (takes the host's body, wipes its stats),
-- so joiners never get to click it: take it down, say what's happening, and
-- when the host hands us a fresh body, set input and HUD up again.
local RS = { pawn = nil, msgAt = -99, t = 0 }
local function joinerRespawnSweep()
    RS.t = RS.t + 0.25
    for _, cls in ipairs({ "RespawnScreen_C", "ScreenPermadeath_C" }) do
        for _, w in ipairs(safe(function() return FindAllOf(cls) end, nil) or {}) do
            if dnValid(w) and safe(function() return w:IsInViewport() end, false) then
                pcall(function() w:RemoveFromParent() end)
                log("RS: hid the " .. cls .. " (the host respawns joiners)")
            end
        end
    end
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    if not dnValid(me) or className(me) ~= "BP_PlayerCharacter_C" then return end
    local addr = safe(function() return me:GetAddress() end, nil)
    local dead = safe(function() return me["PlayerDead?"] end, false) == true
    if dead and RS.t - RS.msgAt >= 5 then
        RS.msgAt = RS.t
        dnNotify("You died - respawning next to your partner shortly", me)
    end
    if RS.pawn and addr and addr ~= RS.pawn and not dead then
        log("RS: respawned into a new body - fixing input and HUD")
        pcall(function() pc.bShowMouseCursor = false end)
        pcall(fixInput2)
        pcall(buildUI)
        gameDelay(1500, function() pcall(dnNotify, "You're back - next to your partner", me) end)
    end
    if addr then RS.pawn = addr end
end

-- Time of day. Each machine runs its own Ultra Dynamic Sky; the plugin's own
-- replication never reaches joiners (the joiner's sky is a local copy, its
-- "Replicated Time of Day" sits at the default 900), so the host was at night
-- while the joiner had daylight. The host publishes its clock through its
-- PlayerState.Score (always relevant, already our downed channel): 10000 +
-- time of day (0-2400) while it isn't down. Joiners set their sky to it.
local TOD = { t = 0, last = nil, logged = 0 }
local function todSky()
    for _, a in ipairs(safe(function() return FindAllOf("Ultra_Dynamic_Sky_C") end, nil) or {}) do
        if dnValid(a) and CS.inPlayWorld(a) then return a end
    end
    return nil
end
local function todHostTick()
    TOD.t = TOD.t + 1
    if TOD.t % 4 ~= 0 then return end   -- once a second
    if not dnCoop() then return end
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    if not dnValid(me) or DN.isDown(me) then return end
    local sky = todSky()
    local tod = sky and safe(function() return sky["Time of Day"] end, nil)
    if type(tod) == "number" then dnPublish(me, 10000 + math.floor(tod * 10 + 0.5) / 10) end
end
local function todClientTick()
    TOD.t = TOD.t + 1
    if TOD.t % 4 ~= 0 then return end
    local tod
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        local ps = dnValid(p) and safe(function() return p.PlayerState end, nil)
        local sc = dnValid(ps) and safe(function() return ps.Score end, 0) or 0
        if sc >= 10000 then tod = sc - 10000; break end
    end
    if not tod then return end
    local sky = todSky()
    if not sky then return end
    local mine = safe(function() return sky["Time of Day"] end, nil)
    if type(mine) ~= "number" then return end
    local diff = math.abs(mine - tod)
    if diff > 2400 - diff then diff = 2400 - diff end   -- wrap at midnight
    if diff > 5 then
        pcall(function() sky["Time of Day"] = tod end)
        TOD.logged = TOD.logged + 1
        if TOD.logged <= 3 or diff > 100 then
            log(("TOD: sky %.0f -> host's %.0f"):format(mine, tod))
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
    local cmc = dnCMC(me)
    if st ~= "up" then
        if not DN.me then
            DN.me = { walk = cmc and safe(function() return cmc.MaxWalkSpeed end, nil),
                      crouch = cmc and safe(function() return cmc.MaxWalkSpeedCrouched end, nil),
                      jump = cmc and safe(function() return cmc.JumpZVelocity end, nil) }
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
                dnNotify(("You're down! Bleeding out in %ds - your partner can stand or crouch next to you to revive"):format(n), me)
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
                    dnNotify(("Your partner is down! Stay right next to them to revive (%ds)"):format(on), me)
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

-- Lethal hits become downed (host only, co-op only), and players can't hurt
-- each other unless friendly fire is switched on (sdmp_friendlyfire).
-- Weapons go through ApplyPointDamage / ApplyRadialDamage as well as plain
-- ApplyDamage, so all three are watched.
DN.friendlyFire = false
local function dnFromPlayer(victim, inst, causer)
    local vk = safe(function() return victim:GetAddress() end, 0)
    local c = inst and safe(function() return inst:get() end, nil)
    if dnValid(c) and className(c):find("PlayerController") then
        local cp = safe(function() return c.Pawn end, nil)
        if dnValid(cp) and cp:GetAddress() ~= vk then return true end
    end
    local a = causer and safe(function() return causer:get() end, nil)
    for _ = 1, 3 do   -- the causer, its owner, its owner's owner (gun -> player)
        if not dnValid(a) then break end
        if className(a) == "BP_PlayerCharacter_C" then return a:GetAddress() ~= vk end
        a = safe(function() return a:GetOwner() end, nil)
    end
    return false
end
local function dnOnDamage(damaged, dmg, inst, causer)
    if not worldSettled() or not dnIsHost() then return end
    local a = safe(function() return damaged:get() end, nil)
    if not (a and safe(function() return a:IsValid() end, false)) then return end
    if className(a) ~= "BP_PlayerCharacter_C" then return end
    if safe(function() return a.bCanBeDamaged end, true) == false then return end   -- god mode
    if safe(function() return a["PlayerDead?"] end, false) == true then return end
    local key = safe(function() return a:GetAddress() end, nil)
    if not key or DN.allowKill[key] then return end
    if not dnCoop() then return end
    local d = safe(function() return dmg:get() end, 0) or 0
    if d <= 0 then return end
    if not DN.friendlyFire and dnFromPlayer(a, inst, causer) then
        pcall(function() dmg:set(0.0) end)
        if not DN.ffSaid then DN.ffSaid = true; log("DN: blocked a player-on-player hit (friendly fire is off)") end
        return
    end
    local dd = DN.down[key]
    if dd then
        pcall(function() dmg:set(0.0) end)
        if (dd.rev or 0) == 0 then dd.t = dd.t - 2 end   -- hits don't count while being revived
        return
    end
    local h = dnHealth(a)
    if h and h - d <= 0 then
        if not dnHasReviver(a) then   -- nobody left to revive you: normal death
            if safe(function() return a:IsLocallyControlled() end, true) == false then pcall(DN.guardHostSkills, "joiner killed") end
            return
        end
        pcall(function() dmg:set(0.0) end)
        dnEnter(a)
    end
end
pcall(function()
    RegisterHook("/Script/Engine.GameplayStatics:ApplyDamage", function(ctx, damaged, dmg, inst, causer)
        dnOnDamage(damaged, dmg, inst, causer)
    end)
end)
pcall(function()
    RegisterHook("/Script/Engine.GameplayStatics:ApplyPointDamage", function(ctx, damaged, dmg, dir, hit, inst, causer)
        dnOnDamage(damaged, dmg, inst, causer)
    end)
end)
RegisterConsoleCommandHandler("sdmp_friendlyfire", function()
    DN.friendlyFire = not DN.friendlyFire
    log("friendly fire is now " .. (DN.friendlyFire and "ON" or "OFF"))
    ExecuteInGameThread(function()
        local pc = dnLocalPC()
        pcall(dnNotify, "Friendly fire " .. (DN.friendlyFire and "ON" or "OFF"), pc and safe(function() return pc.Pawn end, nil))
    end)
    return true
end)

gameLoop(250, function()
    do
        -- (spawn-function hooks retired: they found Survival_SpawnPlayer, and running
        -- code from GI hooks during the Entry hop is a crash risk)
        if not worldSettled() then return end
        if not dnIsHost() then pcall(dnGhostSweep); pcall(csClientWatch); pcall(gearVisualsSweep); pcall(joinerRespawnSweep); pcall(todClientTick) end
        if dnIsHost() then
            pcall(clothingSync)
            pcall(todHostTick)
            local ok, err = pcall(dnHostTick)
            if not ok then log("DN host error: " .. tostring(err)) end
        end
        pcall(pressAnyKeySweep)
        local PJm = CS.PJ
        if PJm then
            PJm.tk = (PJm.tk or 0) + 1
            if PJm.tk % 4 == 0 then
                if dnIsHost() then pcall(PJm.hostTick) else pcall(PJm.clientTick) end
            end
        end
        local DRm = CS.DR
        if DRm then
            DRm.ht = (DRm.ht or 0) + 1
            if DRm.ht % 20 == 1 then pcall(DRm.hook) end
            if dnIsHost() then pcall(DRm.hostTick) end
        end
        local BDm = CS.BD
        if BDm and not BDm.hooked then
            BDm.ht = (BDm.ht or 0) + 1
            if BDm.ht % 20 == 1 then pcall(BDm.hook) end
        end
        local ok, err = pcall(dnLocalTick)
        if not ok and not DN.lErr then DN.lErr = true; log("DN local error: " .. tostring(err)) end
    end
end)
RegisterConsoleCommandHandler("sdmp_down", function()   -- debug: down yourself / everyone on host
    ExecuteInGameThread(function()
        for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do if p:IsValid() then dnEnter(p) end end
    end)
    return true
end)

-- Doors. A lot of the game's doors only run on the machine that pressed E
-- (BP_LockedDoor and friends: a local timeline, nothing sent anywhere), so a
-- door the joiner opens stays shut on the host - and the host's collision
-- keeps rubber-banding the joiner back - and the host's doors never move for
-- the joiner. Two halves:
--   host -> joiner: the host makes doors near a joiner replicate, actor and
--     components, so the door leaf's transform follows the host's.
--   joiner -> host: when a door toggles on the joiner, it's forwarded through
--     the game's own reliable SERVER_ForwardInteract (Jig) and the host runs
--     the same toggle on its copy.
local DR = {
    classes = { "BP_LockedDoor_C", "BP_KeycardDoor_C", "BP_KeycardDoor_Child_C", "BP_KeypadDoor_C",
                "BP_HangarDoor_C", "BP_BarrierGate_C", "BP_ContainerDoors_C", "BP_WarehouseDoors_C",
                "BP_LaboratorySlidingDoor_C", "BP_LaboratorySecureDoors_C", "BP_LaboratoryEntranceDoors_C",
                "Buildable_WoodenDoor_C", "Buildable_WoodenDoor2_C", "Buildable_BarricadedMetalDoor_C",
                "Buildable_BunkerDoor_C", "Buildable_GarageDoor_C", "Buildable_WoodenGate_C",
                "Buildable_WoodenWallDoor_C", "Buildable_WoodenWallDoor2_C" },
    path = {
        BP_LockedDoor_C = "/Game/Blueprints/Other/Doors/BP_LockedDoor",
        BP_KeycardDoor_C = "/Game/Blueprints/Other/Doors/BP_KeycardDoor",
        BP_KeycardDoor_Child_C = "/Game/Blueprints/Other/Doors/BP_KeycardDoor_Child",
        BP_KeypadDoor_C = "/Game/Blueprints/Other/Doors/Keypad/BP_KeypadDoor",
        BP_HangarDoor_C = "/Game/Blueprints/Other/Doors/BP_HangarDoor",
        BP_BarrierGate_C = "/Game/Blueprints/Other/Doors/BP_BarrierGate",
        BP_ContainerDoors_C = "/Game/Blueprints/Other/Doors/BP_ContainerDoors",
        BP_WarehouseDoors_C = "/Game/Blueprints/Other/Doors/BP_WarehouseDoors",
        BP_LaboratorySlidingDoor_C = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySlidingDoor",
        BP_LaboratorySecureDoors_C = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratorySecureDoors",
        BP_LaboratoryEntranceDoors_C = "/Game/Blueprints/Laboratory/Blueprints/Doors/BP_LaboratoryEntranceDoors",
        Buildable_WoodenDoor_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_WoodenDoor",
        Buildable_WoodenDoor2_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_WoodenDoor2",
        Buildable_BarricadedMetalDoor_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_BarricadedMetalDoor",
        Buildable_BunkerDoor_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_BunkerDoor",
        Buildable_GarageDoor_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_GarageDoor",
        Buildable_WoodenGate_C = "/Game/Blueprints/BuildingSystem/Actors/Doors/Buildable_WoodenGate",
        Buildable_WoodenWallDoor_C = "/Game/Blueprints/BuildingSystem/Actors/Modular/Wood/Wall/Buildable_WoodenWallDoor",
        Buildable_WoodenWallDoor2_C = "/Game/Blueprints/BuildingSystem/Actors/Modular/Wood/Wall/Buildable_WoodenWallDoor2",
    },
    hookedCls = {},
    -- these already go through the server and multicast (MC_OpenDoor /
    -- MC_OnInteractBuildable); they only need to replicate
    native = { BP_WarehouseDoors_C = true, BP_BarrierGate_C = true, BP_ContainerDoors_C = true,
               BP_HangarDoor_C = true, BP_KeycardDoor_C = true, BP_KeycardDoor_Child_C = true,
               BP_KeypadDoor_C = true,
               Buildable_WoodenDoor_C = true, Buildable_WoodenDoor2_C = true, Buildable_BarricadedMetalDoor_C = true,
               Buildable_BunkerDoor_C = true, Buildable_GarageDoor_C = true, Buildable_WoodenGate_C = true,
               Buildable_WoodenWallDoor_C = true, Buildable_WoodenWallDoor2_C = true },
    rep = {}, t = 0, hooked = false, fwd = 0, rx = 0,
    stateFlags = { "Closed?", "IsClosed", "Closed", "IsOpen?", "Open?", "IsOpen", "DoorOpen?" },
}
CS.DR = DR
local function drAll()
    local out = {}
    for _, cn in ipairs(DR.classes) do
        for _, a in ipairs(safe(function() return FindAllOf(cn) end, nil) or {}) do
            if dnValid(a) and CS.inPlayWorld(a) then out[#out + 1] = a end
        end
    end
    return out
end
DR.all = drAll
-- open/closed as the door itself sees it (nil if we can't tell)
local function drIsOpen(a)
    for _, f in ipairs(DR.stateFlags) do
        local v = safe(function() return a[f] end, nil)
        if type(v) == "boolean" then
            if f:find("Close") then return not v else return v end
        end
    end
    return nil
end
DR.isOpen = drIsOpen
local function drMakeReplicated(a)
    local k = a:GetAddress()
    if DR.rep[k] then return end
    pcall(function() a:SetReplicates(true) end)
    pcall(function() a.NetUpdateFrequency = 10.0 end)
    local comps = safe(function() return a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent")) end, nil) or {}
    local n = 0
    for i = 1, #comps do
        local c = safe(function() return comps[i]:get() end, nil) or comps[i]
        if dnValid(c) then pcall(function() c:SetIsReplicated(true) end); n = n + 1 end
    end
    pcall(function() a:ForceNetUpdate() end)
    DR.rep[k] = true
    DR.nrep = (DR.nrep or 0) + 1
    if DR.nrep <= 5 then log(("DR: %s now replicates (%d components)"):format(className(a), n)) end
end
DR.makeRep = drMakeReplicated
-- host: doors within 60 m of any joiner replicate
local function drHostTick()
    DR.t = DR.t + 1
    if DR.t % 8 ~= 0 then return end   -- every 2s
    if not dnCoop() then return end
    local remotes = {}
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) and not safe(function() return p:IsLocallyControlled() end, true) then
            local l = safe(function() return p:K2_GetActorLocation() end, nil)
            if l then remotes[#remotes + 1] = l end
        end
    end
    if #remotes == 0 then return end
    for _, a in ipairs(drAll()) do
        if not DR.rep[a:GetAddress()] then
            local l = safe(function() return a:K2_GetActorLocation() end, nil)
            if l then
                for _, r in ipairs(remotes) do
                    if (l.X - r.X)^2 + (l.Y - r.Y)^2 < 6000 * 6000 then drMakeReplicated(a); break end
                end
            end
        end
    end
end
DR.hostTick = drHostTick
local function drTag(open)
    return { TagName = FName(open and "Jig.InteractOptions.Option1" or "Jig.InteractOptions.Option2") }
end
-- joiner: forward a local toggle to the host
local function drForward(a)
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    local jig = dnValid(me) and safe(function() return me.BP_JigMultiplayer end, nil)
    if not dnValid(jig) then log("DR: can't forward, no Jig component"); return false end
    local ok, err = pcall(function() jig:SERVER_ForwardInteract(a, drTag(true), {}) end)
    DR.fwd = DR.fwd + 1
    if DR.fwd <= 10 then log(("DR: asked the host to toggle %s -> %s %s"):format(className(a), tostring(ok), tostring(err or ""))) end
    return ok
end
DR.forward = drForward
local function drHook()
    for _, cn in ipairs(DR.classes) do
        if not DR.native[cn] and not DR.hookedCls[cn] then
            local base = DR.path[cn] .. "." .. cn
            -- only once the class is actually loaded
            local cls = safe(function() return StaticFindObject(base) end, nil)
            if cls and safe(function() return cls:IsValid() end, false) then
                DR.tries = DR.tries or {}
                DR.tries[cn] = (DR.tries[cn] or 0) + 1
                local got, errs = {}, {}
                -- joiner side: a door toggled here -> ask the host to toggle its copy
                local ok1, e1 = pcall(function()
                    RegisterHook(base .. ":Event_Door", function(ctx)
                        if dnIsHost() or DR.applying then return end
                        local a = safe(function() return ctx:get() end, nil)
                        if dnValid(a) then pcall(drForward, a) end
                    end)
                end)
                if ok1 then got[#got + 1] = "Event_Door" else errs[#errs + 1] = tostring(e1) end
                -- host side: a forwarded toggle arrives
                local ok2, e2 = pcall(function()
                    RegisterHook(base .. ":OnServerExecuteInteract", function(ctx, option, by, payload)
                        if not dnIsHost() then return end
                        local a = safe(function() return ctx:get() end, nil)
                        local who = safe(function() return by:get() end, nil)
                        if not (dnValid(a) and dnValid(who)) then return end
                        if safe(function() return who:IsLocallyControlled() end, true) then return end
                        DR.rx = DR.rx + 1
                        if DR.rx <= 10 then log(("DR: host got a toggle for %s from a joiner (host had open=%s)"):format(className(a), tostring(drIsOpen(a)))) end
                        drMakeReplicated(a)
                        DR.toggle(a, who)
                        -- once both animations are done, push the host's pose again so a
                        -- joiner whose copy went the other way snaps to the truth
                        gameDelay(2500, function() pcall(DR.nudge, a) end)
                    end)
                end)
                if ok2 then got[#got + 1] = "OnServerExecuteInteract" else errs[#errs + 1] = tostring(e2) end
                if #got == 2 or DR.tries[cn] >= 5 then DR.hookedCls[cn] = true end
                if #got == 2 or DR.tries[cn] == 1 or DR.tries[cn] >= 5 then
                    log(("DR: hooked %s: %s%s"):format(cn, #got > 0 and table.concat(got, ", ") or "nothing",
                        #errs > 0 and (" (err: " .. errs[1]:sub(1, 120) .. ")") or ""))
                end
            end
        end
    end
end
DR.hook = drHook
-- run a door's own open/close (some take the interacting pawn, some nothing)
-- wiggle every replicated part by a hair and back, so the host's current
-- pose is sent again even though it hasn't really changed
DR.nudge = function(a)
    local comps = safe(function() return a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent")) end, nil) or {}
    local saved = {}
    for i = 1, #comps do
        local c = safe(function() return comps[i]:get() end, nil) or comps[i]
        local r = dnValid(c) and safe(function() return c.RelativeRotation end, nil)
        if r then
            saved[#saved + 1] = { c = c, r = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
            pcall(function() c:K2_SetRelativeRotation({ Pitch = r.Pitch, Yaw = r.Yaw + 0.05, Roll = r.Roll }, false, {}, false) end)
        end
    end
    pcall(function() a:ForceNetUpdate() end)
    gameDelay(400, function()
        for _, s2 in ipairs(saved) do
            pcall(function() s2.c:K2_SetRelativeRotation(s2.r, false, {}, false) end)
        end
        pcall(function() a:ForceNetUpdate() end)
    end)
end
DR.toggle = function(a, who)
    DR.applying = true
    local ok = pcall(function() a:Event_Door(who) end)
    if not ok then ok = pcall(function() a:Event_Door() end) end
    DR.applying = false
    return ok
end
-- a short fingerprint of where a door's parts are (to see it move)
DR.pose = function(a)
    local comps = safe(function() return a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent")) end, nil) or {}
    local parts = {}
    for i = 1, math.min(#comps, 3) do
        local c = safe(function() return comps[i]:get() end, nil) or comps[i]
        if dnValid(c) then
            local r = safe(function() return c.RelativeRotation end, nil)
            local l = safe(function() return c.RelativeLocation end, nil)
            parts[#parts + 1] = ("%s yaw=%.0f x=%.0f y=%.0f z=%.0f"):format(safe(function() return c:GetFName():ToString() end, "?"),
                r and r.Yaw or 0, l and l.X or 0, l and l.Y or 0, l and l.Z or 0)
        end
    end
    return table.concat(parts, " | ")
end
DR.nearest = function(loc, wantEvent, only)
    local best, bd = nil, 1e18
    for _, a in ipairs(drAll()) do
        local cn = className(a)
        if (not wantEvent or not DR.native[cn]) and (not only or cn == only) then
            local l = safe(function() return a:K2_GetActorLocation() end, nil)
            if l and loc then
                local d = (l.X - loc.X)^2 + (l.Y - loc.Y)^2 + (l.Z - loc.Z)^2
                if d < bd then best, bd = a, d end
            end
        end
    end
    return best, best and math.sqrt(bd) or -1
end

-- Probe helpers for the joiner-save work: function signatures and struct
-- layouts, read from the reflection data at runtime.
-- Building. The game's building only works for whoever has authority:
--   joiner picks a build -> BuildingComponent.Event_LaunchBuildMode(DA, Replacing?, ReplacingActor)
--   runs on the joiner only (it's a client RPC), so the host's copy of the
--   joiner's component never learns WHAT is being built.
--   joiner clicks -> Svr_SpawnBuild(transform) -> host's SpawnBuild spawns
--   DARef.BuildActorClass = nothing, and the "move a build" path spawns a new
--   one instead of moving the old one.
--   SpawnBuild also only takes the item from the builder when the builder is
--   locally controlled, so a joiner build would be free.
-- Fix: the joiner tells the host what it's building through its Jig
-- SERVER_ForwardInteract (reliable, has a string payload), the host fills in
-- the joiner's component, and after a joiner's build the host takes the item.
local BD = { tag = "SDMP_BUILD", hooked = false, tries = 0, sent = 0, rx = 0, built = 0, pending = {} }
CS.BD = BD
local BD_COMP = "/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C:"
local BD_JIG = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
local function bdPath(o)
    local fn = safe(function() return o:GetFullName() end, "") or ""
    return fn:match("^%S+%s+(.+)$") or fn
end
-- Guid fields are unsigned on the engine side: a negative value we sent can
-- come back as a large positive one, so read every field as signed 32-bit
-- (hashes and negative map coordinates both depend on it)
local function bdS32(v)
    v = math.tointeger(tonumber(v) or 0) or math.floor(tonumber(v) or 0)
    v = v & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end
local function bdGuid(g)
    return { A = bdS32(safe(function() return g.A end, 0)), B = bdS32(safe(function() return g.B end, 0)),
             C = bdS32(safe(function() return g.C end, 0)), D = bdS32(safe(function() return g.D end, 0)) }
end
local function bdArr(arr)
    local out = {}
    pcall(function() arr:ForEach(function(_, e)
        local v = e:get()
        if type(v) ~= "string" and type(v) ~= "number" then v = safe(function() return v:ToString() end, v) end
        out[#out + 1] = v
    end) end)
    return out
end
-- The payload's string/number arrays arrive EMPTY when filled from Lua (UE4SS
-- doesn't fill TArrays inside a struct param), but its UID (a Guid, 4 ints)
-- gets through. So the message rides in the Guid:
--   A = "SDMB" (new build) / "SDMM" (moving a build), B = hash of the data
--   asset's path, C/D = X/Y of the build being moved.
-- A new build then sends a second forward whose Guid is the item's BuildUID.
-- Reliable RPCs arrive in order, so the host pairs them up.
BD.NEW, BD.MOVE = 0x53444D42, 0x53444D4D
local PK   -- joiners' own skills, further down
local function bdHash(str)
    local h = 2166136261
    for i = 1, #str do
        h = h ~ str:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
local function bdI32(n)
    n = math.floor(n + 0.5)
    if n > 2147483647 then n = 2147483647 elseif n < -2147483648 then n = -2147483648 end
    return n
end
local function bdForward(me, jig, guid)
    local pc = safe(function() return me.Controller end, nil)
    if not dnValid(pc) then pc = dnLocalPC() end
    -- the actor slot gets our controller: not an interactable, so the forward
    -- does nothing on the host except reach our hook
    return pcall(function()
        jig:SERVER_ForwardInteract(pc, { TagName = FName("Jig.InteractOptions.Option1") }, { UID_2_F97C1DB340A240E45E87AFB50172E1CA = guid })
    end)
end
-- joiner: build mode started -> tell the host
BD.send = function(comp)
    local da = safe(function() return comp.DARef end, nil)
    if not dnValid(da) then return end
    local me = safe(function() return comp:GetOwner() end, nil)
    local jig = dnValid(me) and safe(function() return me.BP_JigMultiplayer end, nil)
    if not dnValid(jig) then return end
    local rep = safe(function() return comp["ReplacingObject?"] end, false) == true
    local ra = rep and safe(function() return comp.ReplacingActor end, nil) or nil
    local rl = dnValid(ra) and safe(function() return ra:K2_GetActorLocation() end, nil) or { X = 0, Y = 0 }
    local ok, err = bdForward(me, jig, { A = rep and BD.MOVE or BD.NEW, B = bdHash(bdPath(da)), C = bdI32(rl.X), D = bdI32(rl.Y) })
    if not rep then bdForward(me, jig, bdGuid(safe(function() return comp.BuildUID end, nil) or {})) end
    BD.sent = BD.sent + 1
    log(("BD: told the host I'm building %s (move=%s) -> %s %s"):format(bdPath(da), tostring(rep), tostring(ok), tostring(err or ""):sub(1, 120)))
end
BD.daByHash = function(h)
    BD.daCache = BD.daCache or {}
    local c = BD.daCache[h]
    if dnValid(c) then return c end
    for _, cn in ipairs({ "JigsawItem_DataAsset_C", "PrimaryDataAsset" }) do
        for _, o in ipairs(safe(function() return FindAllOf(cn) end, nil) or {}) do
            if dnValid(o) then
                local hh = bdHash(bdPath(o))
                BD.daCache[hh] = o
                if hh == h then return o end
            end
        end
    end
    return nil
end
-- host: a joiner's build info arrives
BD.receive = function(jig, payload)
    local p = safe(function() return payload:get() end, nil) or payload
    local u = bdGuid(safe(function() return p.UID_2_F97C1DB340A240E45E87AFB50172E1CA end, nil) or {})
    local who = safe(function() return jig:GetOwner() end, nil)
    if not dnValid(who) or safe(function() return who:IsLocallyControlled() end, true) then return end
    local key = who:GetAddress()
    -- second half of a new build: the item's id
    if BD.wantUID and BD.wantUID[key] then
        BD.wantUID[key] = nil
        local pend = BD.pending[key]
        if pend then pend.uid = u end
        return
    end
    -- handled a moment later, outside the network call (object searches made
    -- from inside it came back empty)
    if u.A == BD.PICK then gameDelay(50, function() pcall(BD.pickedUp, who, u) end); return end
    if u.A == BD.PK_SKILL or u.A == BD.PK_TREE then
        local ok, err = pcall(PK.rx, who, u)
        if not ok then log("PK: " .. tostring(err):sub(1, 150)) end
        return
    end
    if u.A == BD.VEH_IN or u.A == BD.VEH_OUT or u.A == BD.VEH_INPUT then
        local function go()
            local ok, err = pcall(BD.vehRx, who, u)
            if not ok then log("VH: " .. tostring(err):sub(1, 150)) end
        end
        if u.A == BD.VEH_IN then gameDelay(50, go) else go() end
        return
    end
    if u.A ~= BD.NEW and u.A ~= BD.MOVE then return end
    local comp = safe(function() return who.BuildingComponent end, nil)
    if not dnValid(comp) then log("BD: joiner has no BuildingComponent"); return end
    local da = BD.daByHash(u.B)
    if not dnValid(da) then log(("BD: can't find the joiner's build data (hash %d)"):format(u.B)); return end
    local rep = u.A == BD.MOVE
    local ra = nil
    if rep then
        local best, bd = nil, 80 * 80
        for _, a in ipairs(safe(function() return FindAllOf("Buildable_MASTER_C") end, nil) or {}) do
            local l = dnValid(a) and safe(function() return a:K2_GetActorLocation() end, nil)
            if l then
                local d = (l.X - u.C)^2 + (l.Y - u.D)^2
                if d < bd then best, bd = a, d end
            end
        end
        ra = best
        if not ra then log("BD: joiner is moving a build I can't find - ignoring"); return end
    else
        BD.wantUID = BD.wantUID or {}
        BD.wantUID[key] = true
    end
    pcall(function() comp.DARef = da end)
    pcall(function() comp["ReplacingObject?"] = rep end)
    pcall(function() comp.ReplacingActor = ra end)
    BD.pending[key] = { rep = rep }
    BD.rx = BD.rx + 1
    log(("BD: joiner is building %s%s"):format(bdPath(da), rep and (" (moving " .. className(ra) .. ")") or ""))
end
-- host: after a joiner's Svr_SpawnBuild ran
BD.afterSpawn = function(comp)
    local who = safe(function() return comp:GetOwner() end, nil)
    if not dnValid(who) or safe(function() return who:IsLocallyControlled() end, true) then return end
    local pend = BD.pending[who:GetAddress()]
    BD.built = BD.built + 1
    if not pend then log("BD: joiner built without telling me what - nothing spawned"); return end
    BD.pending[who:GetAddress()] = nil
    if pend.rep then log("BD: joiner moved a build"); return end
    local u = pend.uid
    local jig = safe(function() return who.BP_JigMultiplayer end, nil)
    if u and (u.A ~= 0 or u.B ~= 0 or u.C ~= 0 or u.D ~= 0) and dnValid(jig) then
        local ok, err = pcall(function() jig:SERVER_RequestConsumeItem(jig, u, 1, "") end)
        log(("BD: joiner built; took the item -> %s %s"):format(tostring(ok), tostring(err or ""):sub(1, 100)))
    else
        log("BD: joiner built (no item id to take)")
    end
end
-- Ground pickups. A joiner's F press on an item reaches the host and the item
-- goes into its inventory, but the item stayed on the ground for everyone:
-- the game removes it in the success callback on the picking player's own
-- machine, and a joiner isn't allowed to remove a networked actor. So when
-- that callback fires on a joiner it tells the host which item it took
-- ("SDPK", hash of the item's class, X/Y) and the host hides it and turns its
-- collision off - which reaches every player. Hidden rather than destroyed:
-- some item actors are reused as the equipped item later.
BD.PICK = 0x5344504B
BD.picks = 0
BD.sendPicked = function(jig, actor)
    if dnIsHost() or not dnValid(actor) then return end
    local me = safe(function() return jig:GetOwner() end, nil)
    if not dnValid(me) or not safe(function() return me:IsLocallyControlled() end, false) then return end
    local l = safe(function() return actor:K2_GetActorLocation() end, nil)
    if not l then return end
    local ok = bdForward(me, jig, { A = BD.PICK, B = bdHash(className(actor)), C = bdI32(l.X), D = bdI32(l.Y) })
    -- the server parks a taken item at the map origin, out of our network
    -- range, so our copy would sit on the ground forever: hide it ourselves
    pcall(function() actor:SetActorHiddenInGame(true) end)
    pcall(function() actor:SetActorEnableCollision(false) end)
    log(("PK: told the host I picked up %s at %.0f,%.0f (hash %d) -> %s"):format(className(actor), l.X, l.Y, bdHash(className(actor)), tostring(ok)))
end
-- host: actors joiners asked to pick up, newest last. By the time the joiner
-- confirms, the server has already removed the item's pickup component, so
-- the leftover actor can't be found by searching components any more.
BD.reqs = {}
BD.noteReq = function(jig, actorParam)
    local who = safe(function() return jig:GetOwner() end, nil)
    if not dnValid(who) or safe(function() return who:IsLocallyControlled() end, true) then return end
    local a = safe(function() return actorParam:get() end, nil)
    if not dnValid(a) then return end
    local now = os.time()
    local keep = {}
    for _, r in ipairs(BD.reqs) do
        if now - r.t < 30 and dnValid(r.a) then keep[#keep + 1] = r end
    end
    keep[#keep + 1] = { a = a, t = now, h = bdHash(className(a)), who = who:GetAddress() }
    while #keep > 16 do table.remove(keep, 1) end
    BD.reqs = keep
end
BD.hide = function(a)
    pcall(function() a:SetReplicates(true) end)
    pcall(function() a:SetActorHiddenInGame(true) end)
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a:ForceNetUpdate() end)
    BD.picks = BD.picks + 1
end
BD.pickedUp = function(who, u)
    -- the joiner's newest request for this kind of item (the server may already
    -- have moved the leftover actor, so position is only logged)
    local best, bi
    for i, r in ipairs(BD.reqs) do
        if dnValid(r.a) and r.h == u.B and r.who == who:GetAddress() then best, bi = r.a, i end
    end
    if not best then
        local have = {}
        for _, r in ipairs(BD.reqs) do have[#have + 1] = ("%s/%d"):format(dnValid(r.a) and className(r.a) or "gone", r.h) end
        log(("PK: a joiner picked up hash %d at %d,%d but I have no matching request (%s)"):format(u.B, u.C, u.D, table.concat(have, ", ")))
        return
    end
    table.remove(BD.reqs, bi)
    local l = safe(function() return best:K2_GetActorLocation() end, nil)
    BD.hide(best)
    log(("PK: %s picked up by a joiner - removed from the ground (now at %s, joiner saw it %.0f away)"):format(className(best),
        l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?", l and math.sqrt((l.X - u.C)^2 + (l.Y - u.D)^2) or -1))
end
-- Loot All for joiners. The loot window sends one move per item in the same
-- frame, and picks each item's target slot from the joiner's own copy of
-- their inventory - which doesn't change until the host answers. So every
-- item asks for the same free slot, the host takes the first and refuses
-- the rest: one item per press. Fix on the host: collect a joiner's moves,
-- and once the burst is done move the refused items again ourselves, trying
-- "any slot" (-1) first and then the slots after the one they asked for.
BD.la = { q = {}, busy = false, fixed = 0 }
BD.laHas = function(jig, uid)
    local mc = safe(function() return jig.MainJigContainers end, nil)
    for i = 1, (mc and #mc or 0) do
        local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
        for j = 1, (items and #items or 0) do
            local it = safe(function() return items[j]:get() end, nil) or items[j]
            local g = bdGuid(safe(function() return it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] end, nil) or {})
            if g.A == uid.A and g.B == uid.B and g.C == uid.C and g.D == uid.D then return true end
        end
    end
    return false
end
-- the ToContainer struct only lives as long as the RPC call, so copy it into
-- a plain table (field names read off the function once)
BD.laFields = function()
    if BD.laF then return BD.laF end
    local out = {}
    pcall(function()
        StaticFindObject(BD_JIG .. "SERVER_RequestMoveItemToAnotherComp"):ForEachProperty(function(p)
            if p:GetFName():ToString() == "ToContainer" then
                p:GetStruct():ForEachProperty(function(f)
                    out[#out + 1] = { name = f:GetFName():ToString(), kind = f:GetClass():GetFName():ToString() }
                end)
            end
        end)
    end)
    local d = {}
    for _, f in ipairs(out) do d[#d + 1] = f.name .. ":" .. f.kind end
    log("LA: ToContainer fields " .. table.concat(d, ", "))
    BD.laF = out
    return out
end
BD.laCopy = function(c)
    if c == nil then return nil end
    local t = {}
    for _, f in ipairs(BD.laFields()) do
        local v = safe(function() return c[f.name] end, nil)
        if f.kind == "StructProperty" then
            -- Guids (the container's id) are the only structs in it
            t[f.name] = bdGuid(v or {})
        elseif f.kind == "NameProperty" then
            t[f.name] = FName(safe(function() return v:ToString() end, "None"))
        elseif f.kind == "StrProperty" then
            t[f.name] = safe(function() return v:ToString() end, "")
        elseif type(v) == "userdata" then
            t[f.name] = safe(function() return v:get() end, nil)
        else
            t[f.name] = v
        end
    end
    return t
end
BD.laNote = function(ctx, from, to, uid, rot, idx, cont)
    if BD.la.retrying then return end
    local caller = safe(function() return ctx:get() end, nil)
    local who = dnValid(caller) and safe(function() return caller:GetOwner() end, nil)
    if not dnValid(who) or safe(function() return who:IsLocallyControlled() end, true) then return end
    local r = {
        caller = caller,
        from = safe(function() return from:get() end, nil), to = safe(function() return to:get() end, nil),
        uid = bdGuid(safe(function() return uid:get() end, nil) or {}),
        rot = safe(function() return rot:get() end, false), idx = tonumber(safe(function() return idx:get() end, 0)) or 0,
        cont = BD.laCopy(safe(function() return cont:get() end, nil)),
    }
    -- only container -> player moves (Loot All); a player rearranging their own bag is left alone
    if not (dnValid(r.from) and dnValid(r.to)) or r.from:GetAddress() == r.to:GetAddress() then return end
    BD.la.q[#BD.la.q + 1] = r
    BD.la.stamp = (BD.la.stamp or 0) + 1
    local mine = BD.la.stamp
    gameDelay(300, function() if BD.la.stamp == mine then pcall(BD.laRun) end end)
end
BD.laRun = function()
    local q = BD.la.q
    BD.la.q = {}
    local left, seen = {}, {}
    for _, r in ipairs(q) do
        local k = ("%d.%d.%d.%d"):format(r.uid.A, r.uid.B, r.uid.C, r.uid.D)
        if not seen[k] and dnValid(r.from) and BD.laHas(r.from, r.uid) then left[#left + 1] = r end
        seen[k] = true
    end
    if #left == 0 then return end
    BD.la.fixed = 0
    log(("LA: %d Loot All item(s) were refused - moving them again"):format(#left))
    do
        local c, d = left[1].cont or {}, {}
        for k, v in pairs(c) do d[#d + 1] = k:match("^([%a]+)") .. "=" .. (type(v) == "table" and ("%d/%d"):format(v.A or 0, v.B or 0) or tostring(v)) end
        log("LA: container " .. table.concat(d, " "))
    end
    local step = 0
    local function tryOne(r, tries)
        if not (dnValid(r.from) and BD.laHas(r.from, r.uid)) then BD.la.fixed = BD.la.fixed + 1; return true end
        local idx = (tries == 0) and -1 or (r.idx + tries)
        BD.la.retrying = true
        local ok, err = pcall(function()
            r.caller:SERVER_RequestMoveItemToAnotherComp(r.from, r.to, r.uid, r.rot, idx, r.cont, 0, { A = 0, B = 0, C = 0, D = 0 }, 0)
        end)
        BD.la.retrying = false
        if not ok and tries == 0 then log("LA: re-move failed: " .. tostring(err):sub(1, 150)) end
        return false
    end
    -- one attempt per item per 0.15 s, up to 40 slots each, in order
    local i, tries = 1, 0
    gameLoop(150, function()
        local r = left[i]
        if not r then
            log(("LA: done, %d item(s) moved on retry"):format(BD.la.fixed))
            return true
        end
        if tryOne(r, tries) or tries >= 40 then
            if tries >= 40 then log("LA: no room for an item after 40 tries") end
            i, tries = i + 1, 0
        else
            tries = tries + 1
        end
    end)
end
-- Vehicles for joiners. Getting in is all single-player code: the vehicle
-- attaches GetPlayerCharacter(0) to itself and the driving component feeds
-- that player's keys into the vehicle's movement - on a joiner's machine
-- that only moves their own copy, which the host overwrites. So:
--   joiner gets in  -> tells the host ("SDVE" + class hash + X/Y); the host
--                      seats the joiner's character in that vehicle
--   joiner drives   -> their movement keys go to the host 20x a second
--                      ("SDVI"); the host sets throttle / brake / steering
--                      on the real vehicle, whose movement replicates back
--   joiner gets out -> "SDVX"; the host unseats them by the driver door
BD.VEH_IN, BD.VEH_OUT, BD.VEH_INPUT = 0x53445645, 0x53445658, 0x53445649
BD.vh = { seat = {}, keys = {}, ghost = {} }
BD.vehMove = function(v)
    return safe(function() return v.VehicleMovementComponent end, nil) or safe(function() return v:GetVehicleMovementComponent() end, nil)
end
BD.vehFind = function(u)
    local best, bd = nil, 600 * 600
    for _, v in ipairs(safe(function() return FindAllOf("BP_VehicleMaster_C") end, nil) or {}) do
        local l = dnValid(v) and safe(function() return v:K2_GetActorLocation() end, nil)
        if l and bdHash(className(v)) == u.B then
            local d = (l.X - u.C)^2 + (l.Y - u.D)^2
            if d < bd then best, bd = v, d end
        end
    end
    return best
end
BD.vehRx = function(who, u)
    local key = who:GetAddress()
    local seat = BD.vh.seat[key]
    if u.A == BD.VEH_IN then
        local v = BD.vehFind(u)
        if not v then log("VH: a joiner got into a vehicle I can't find"); return end
        BD.vh.seat[key] = { v = v, who = who }
        pcall(function() who.CharacterMovement:DisableMovement() end)
        pcall(function() who:SetActorEnableCollision(false) end)
        pcall(function() who:K2_AttachToActor(v, FName("None"), 2, 2, 1, false) end)
        log("VH: joiner is driving " .. className(v))
    elseif u.A == BD.VEH_INPUT and seat and dnValid(seat.v) then
        local mc = BD.vehMove(seat.v)
        if not dnValid(mc) then return end
        local b = u.B
        local throttle = (b & 1 ~= 0) and 1.0 or 0.0
        local brake = (b & 2 ~= 0) and 1.0 or 0.0
        local hand = (b & 4 ~= 0)
        local steer = math.max(-1.0, math.min(1.0, u.C / 1000.0))
        pcall(function() mc:SetThrottleInput(throttle) end)
        pcall(function() mc:SetBrakeInput(brake) end)
        pcall(function() mc:SetSteeringInput(steer) end)
        pcall(function() mc:SetHandbrakeInput(hand) end)
        BD.vh.inputs = (BD.vh.inputs or 0) + 1
    elseif u.A == BD.VEH_OUT and seat then
        BD.vh.seat[key] = nil
        local v = seat.v
        local mc = dnValid(v) and BD.vehMove(v)
        if dnValid(mc) then
            pcall(function() mc:SetThrottleInput(0.0) end); pcall(function() mc:SetSteeringInput(0.0) end)
            pcall(function() mc:SetHandbrakeInput(true) end)
        end
        pcall(function() who:K2_DetachFromActor(1, 1, 1) end)
        local l = dnValid(v) and safe(function() return v:K2_GetActorLocation() end, nil)
        local r = dnValid(v) and safe(function() return v:GetActorRightVector() end, nil)
        if l and r then
            pcall(function() who:K2_TeleportTo({ X = l.X - r.X * 250, Y = l.Y - r.Y * 250, Z = l.Z + 120 }, who:K2_GetActorRotation()) end)
        end
        pcall(function() who:SetActorEnableCollision(true) end)
        pcall(function() who.CharacterMovement:SetMovementMode(1, 0) end)
        log(("VH: joiner got out (%d inputs relayed)"):format(BD.vh.inputs or 0))
    end
end
-- joiner side
BD.vehSend = function(code, v, b, c)
    local me = (function()
        local pc = dnLocalPC()
        return pc and safe(function() return pc.Pawn end, nil)
    end)()
    local jig = dnValid(me) and safe(function() return me.BP_JigMultiplayer end, nil)
    if not dnValid(jig) then return false end
    if code == BD.VEH_INPUT then return bdForward(me, jig, { A = code, B = b, C = c, D = 0 }) end
    local l = safe(function() return v:K2_GetActorLocation() end, nil) or { X = 0, Y = 0 }
    return bdForward(me, jig, { A = code, B = bdHash(className(v)), C = bdI32(l.X), D = bdI32(l.Y) })
end
BD.vehKeys = function()
    if dnIsHost() or not BD.vh.mine then return end
    local now = os.clock()
    local function held(n) return (now - (BD.vh.keys[n] or -10)) < 0.15 end
    local b = (held("MoveForward") and 1 or 0) + (held("MoveBackwards") and 2 or 0) + (held("Jump") and 4 or 0)
    local steer = (held("MoveRight") and 1000 or 0) - (held("MoveLeft") and 1000 or 0)
    local sig = b * 10000 + steer
    if sig ~= BD.vh.lastSig or now - (BD.vh.lastSend or 0) > 0.5 then
        BD.vh.lastSig, BD.vh.lastSend = sig, now
        BD.vehSend(BD.VEH_INPUT, nil, b, steer)
    end
end
-- Joiners' own skills. The character's Blueprints look perks up through
-- GetPlayerController(self, 0) - on the host that's always the HOST, so a
-- joiner took damage through the host's Toughness, earned the host Toughness
-- XP when hit, and used the host's skill tree (Deathbringer etc). So on the
-- host:
--   * GetPlayerController(<a joiner's character or something it owns>, 0)
--     is turned into that joiner's controller (index 1, 2 ... on a listen
--     server). Not while the character is dead - the death code's
--     UnPossess() keeps going through the old path the respawn handling
--     already knows about.
--   * the joiner's controller copy on the host gets the joiner's real
--     numbers: the joiner sends its passive skills ("SDPS", one field per
--     message) and unlocked skill-tree skills ("SDTT", a bit mask).
--   * XP the host-side code gives that copy (Toughness when hit, ...) is
--     passed down to the joiner, riding on Client_UpdateOxygenUI with a
--     value no real oxygen level can have; the joiner adds it to its own
--     skills and puts its oxygen bar back.
PK = { on = false, idx = {}, ctx = {}, sent = {}, maskSent = nil, pend = {}, applied = 0, redir = 0, xpSent = 0, xpGot = 0 }
BD.PK_SKILL, BD.PK_TREE = 0x53445053, 0x53445454
PK.XP = { "Fitness", "Strength", "Toughness", "Sneaking", "FirstAid", "Marksmanship", "Reloading", "Thief", "Fishing", "Scavenging" }
PK.OXY = -1000000   -- carrier values are below this
PK.PS = "/Game/Blueprints/Components/PassiveSkillsComponent.PassiveSkillsComponent_C"
PK.fieldList = function()
    if PK.fields then return PK.fields end
    local cls = StaticFindObject(PK.PS)
    if not dnValid(cls) then return nil end
    local list = {}
    pcall(function() cls:ForEachProperty(function(pr)
        local n = pr:GetFName():ToString()
        local t = pr:GetClass():GetFName():ToString()
        if (t == "DoubleProperty" or t == "FloatProperty" or t == "IntProperty" or t == "BoolProperty")
           and not n:find("^CallFunc") and not n:find("^Temp_") and not n:find("^K2Node") then
            list[#list + 1] = { n = n, b = t == "BoolProperty" }
        end
    end) end)
    if #list > 0 then PK.fields = list end
    return PK.fields
end
PK.skills = function()
    local l = {}
    for _, a in ipairs(safe(function() return FindAllOf("BP_SkillTreeAsset_C") end, nil) or {}) do
        if dnValid(a) then l[#l + 1] = { a = a, n = a:GetFName():ToString() } end
    end
    table.sort(l, function(x, y) return x.n < y.n end)
    return l
end
PK.compOf = function(pc, cls)
    for _, c in ipairs(safe(function() return FindAllOf(cls) end, nil) or {}) do
        local o = dnValid(c) and safe(function() return c:GetOwner() end, nil)
        if o and dnValid(o) and o:GetAddress() == pc:GetAddress() then return c end
    end
end
-- the tree object can be missing on a controller copy; never touch it then
-- (a method call on a null object takes the game down, pcall can't catch it)
PK.treeOk = function(t)
    local tree = safe(function() return t.TechnologyTree end, nil)
    return dnValid(t) and tree ~= nil and dnValid(tree)
end
-- host: a joiner's controller copy never gets its tree set up (the game does
-- that with the skill-tree screen, on the joiner's machine), so give it one:
-- the same template, and a bare tree widget object the plugin wants with it
PK.giveTree = function(tt)
    local tpl = StaticFindObject("/Game/Blueprints/SkillTree/SkillTree.SkillTree")
    local wcls = StaticFindObject("/Script/TechTree.TechTreeWidget")
    if not (dnValid(tpl) and dnValid(wcls)) then return end
    local w = StaticConstructObject(wcls, tt)
    if not dnValid(w) then return end
    tt:AssignTechTree(tpl, w)
    local at = safe(function() return tt:GetAssignedTechTree() end, nil)
    if at and dnValid(at) then
        tt.TechnologyTree = at
        tt.TechTreeWidget = w
        log("PERK: set up the joiner's skill tree on the host")
    end
end
-- host: which GetPlayerController index each joiner's character answers to
PK.refresh = function()
    PK.on = false
    if not dnIsHost() then return end
    local world = UEHelpers.GetWorld()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local idx = {}
    for i = 1, 7 do
        local pc = safe(function() return gs:GetPlayerController(world, i) end, nil)
        if not dnValid(pc) then break end
        local p = safe(function() return pc.Pawn end, nil)
        if dnValid(p) and safe(function() return pc:IsLocalController() end, true) == false then
            idx[p:GetAddress()] = { i = i, p = p }
            PK.on = true
        end
    end
    PK.idx, PK.ctx = idx, {}
end
PK.target = function(w)
    local a = w:GetAddress()
    local c = PK.ctx[a]
    if c == nil then
        c = false
        local e = PK.idx[a]
        if not e then
            local o = safe(function() return w:GetOwner() end, nil)
            if o and dnValid(o) then e = PK.idx[o:GetAddress()] end
        end
        if e then c = e end
        PK.ctx[a] = c
    end
    if not c then return nil end
    -- leave the death sequence alone (see above)
    if safe(function() return c.p["PlayerDead?"] end, false) == true then return nil end
    if (safe(function() return c.p.MedicalComponent.Health end, 1) or 1) <= 0 then return nil end
    return c.i
end
PK.hook = function()
    if PK.hooked then return end
    PK.hooked = true
    local ok1 = pcall(RegisterHook, "/Script/Engine.GameplayStatics:GetPlayerController", function(ctx, wc, index)
        if not PK.on then return end
        if index:get() ~= 0 then return end
        local w = wc:get()
        if not w or not w:IsValid() then return end
        local i = PK.target(w)
        if i then index:set(i); PK.redir = PK.redir + 1 end
    end)
    -- host: XP the game hands a joiner's copy goes down to the joiner
    local okx = 0
    for k, sk in ipairs(PK.XP) do
        if pcall(RegisterHook, PK.PS .. ":AddXP_" .. sk, function(ctx, amt)
            if not PK.on then return end
            local c = ctx:get()
            local o = safe(function() return c:GetOwner() end, nil)
            if not dnValid(o) or safe(function() return o:IsLocalController() end, true) then return end
            local v = safe(function() return amt:get() end, 0) or 0
            if v <= 0 then return end
            local key = o:GetAddress()
            PK.pend[key] = PK.pend[key] or { pc = o, xp = {} }
            PK.pend[key].xp[k] = (PK.pend[key].xp[k] or 0) + v
        end) then okx = okx + 1 end
    end
    -- joiner: pick the XP up again
    local oko = pcall(RegisterHook, "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:Client_UpdateOxygenUI", function(ctx, oxy)
        if dnIsHost() then return end
        local v = safe(function() return oxy:get() end, 0) or 0
        if v > PK.OXY then PK.lastOxy = v; return end
        local me = ctx:get()
        local n = -v + PK.OXY          -- = k * 1e6 + xp * 1000
        local k = math.floor(n / 1000000)
        local xp = (n - k * 1000000) / 1000
        local sk = PK.XP[k]
        local comp = sk and PK.compOf(safe(function() return me.Controller end, nil) or dnLocalPC(), "PassiveSkillsComponent_C")
        if comp then
            local ok = pcall(function() comp["AddXP_" .. sk](comp, xp) end)
            PK.xpGot = PK.xpGot + 1
            if PK.xpGot <= 3 then log(("PERK: host sent %.2f %s XP -> %s"):format(xp, sk, tostring(ok))) end
        end
        local real = PK.lastOxy or 100.0
        gameDelay(10, function() pcall(function() me:Client_UpdateOxygenUI(real) end) end)
    end)
    log(("PERK: perk hooks controller=%s xp=%d oxygen=%s"):format(tostring(ok1), okx, tostring(oko)))
end
-- host: flush XP owed to joiners (one carrier call per skill)
PK.flush = function()
    for key, e in pairs(PK.pend) do
        PK.pend[key] = nil
        local p = dnValid(e.pc) and safe(function() return e.pc.Pawn end, nil)
        if dnValid(p) then
            for k, v in pairs(e.xp) do
                local x = math.min(v, 999.0)
                pcall(function() p:Client_UpdateOxygenUI(PK.OXY - (k * 1000000 + math.floor(x * 1000 + 0.5))) end)
                PK.xpSent = PK.xpSent + 1
            end
        end
    end
end
-- joiner: send our skills to the host when they change
PK.send = function()
    if dnIsHost() then return end
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    local jig = dnValid(me) and safe(function() return me.BP_JigMultiplayer end, nil)
    if not dnValid(jig) then return end
    local comp = PK.compOf(pc, "PassiveSkillsComponent_C")
    local fields = PK.fieldList()
    if comp and fields then
        local n = 0
        for i, fd in ipairs(fields) do
            local v = safe(function() return comp[fd.n] end, nil)
            local enc
            if fd.b then enc = v and 1 or 0
            elseif type(v) == "number" then enc = bdI32(v * 1000) end
            if enc and PK.sent[i] ~= enc and n < 25 then
                if bdForward(me, jig, { A = BD.PK_SKILL, B = i, C = enc, D = 0 }) then PK.sent[i] = enc; n = n + 1 end
            end
        end
        if n > 0 and not PK.saidSkills then PK.saidSkills = true; log(("PERK: sent the host my passive skills (%d fields)"):format(n)) end
    end
    local tt = PK.compOf(pc, "TechTreeComponent_C")
    if PK.treeOk(tt) then
        local mask, list = 0, PK.skills()
        for i, sk in ipairs(list) do
            if safe(function() return tt:IsTechnologyUnlocked(sk.a) end, false) == true then mask = mask | (1 << (i - 1)) end
        end
        local now = os.clock()
        if mask ~= PK.maskSent or now - (PK.maskT or 0) > 30 then
            if bdForward(me, jig, { A = BD.PK_TREE, B = mask, C = #list, D = 0 }) then
                if mask ~= PK.maskSent then log(("PERK: my skill tree -> host (mask %d of %d)"):format(mask, #list)) end
                PK.maskSent, PK.maskT = mask, now
            end
        end
    end
end
-- host: apply what a joiner sent to its controller copy
PK.rx = function(who, u)
    local pc = safe(function() return who.Controller end, nil)
    if not dnValid(pc) then return end
    if u.A == BD.PK_SKILL then
        local fd = (PK.fieldList() or {})[u.B]
        local comp = fd and PK.compOf(pc, "PassiveSkillsComponent_C")
        if not comp then return end
        pcall(function() comp[fd.n] = fd.b and (u.C ~= 0) or (u.C / 1000.0) end)
        PK.applied = PK.applied + 1
        if PK.applied == 1 then log("PERK: got a joiner's passive skills") end
    elseif u.A == BD.PK_TREE then
        local tt = PK.compOf(pc, "TechTreeComponent_C")
        if dnValid(tt) and not PK.treeOk(tt) then pcall(PK.giveTree, tt) end
        if not PK.treeOk(tt) then
            if not PK.saidNoTree then PK.saidNoTree = true; log("PERK: couldn't set up the joiner's skill tree on the host - skipped") end
            return
        end
        local list = PK.skills()
        if #list ~= u.C then log(("PERK: skill count differs (joiner %d, host %d) - skipped"):format(u.C, #list)); return end
        local ch = {}
        for i, sk in ipairs(list) do
            local want = (u.B >> (i - 1)) & 1 == 1
            local have = safe(function() return tt:IsTechnologyUnlocked(sk.a) end, false) == true
            if want ~= have then
                pcall(function() if want then tt:UnlockTechnology(sk.a) else tt:LockTechnology(sk.a) end end)
                ch[#ch + 1] = (want and "+" or "-") .. sk.n:gsub("^Skill_", "")
            end
        end
        if #ch > 0 then log("PERK: joiner's skill tree on the host: " .. table.concat(ch, " ")) end
    end
end
gameLoop(2000, function() pcall(PK.refresh); pcall(PK.flush) end)
gameLoop(3000, function() pcall(PK.send) end)

-- Crafting trace (cheap, crafting is rare): the Jig inventory already does
-- crafting as server requests (SERVER_RequestCraftItem -> host crafts ->
-- CLIENT_ItemCraftedResponse), so this only logs it. "CR:" lines.
BD.crHook = function()
    if BD.crHooked then return end
    BD.crHooked = true
    local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
    local ok1 = pcall(RegisterHook, J .. "HandleServerFuncRequestCraft", function(ctx, comp, idx)
        local jig = ctx:get()
        local o = safe(function() return jig:GetOwner() end, nil)
        log(("CR: craft request on the host from %s, recipe %s via %s"):format(
            (dnValid(o) and safe(function() return o:IsLocallyControlled() end, true) == false) and "a joiner" or "the host",
            tostring(safe(function() return idx:get() end, "?")), tostring(safe(function() return className(comp:get()) end, "?"))))
    end)
    local ok2 = pcall(RegisterHook, J .. "ClientFuncItemCrafted", function(ctx, tmp, added, success)
        if dnIsHost() then return end
        log("CR: host answered my craft: success=" .. tostring(safe(function() return success:get() end, "?")))
    end)
    log(("CR: crafting trace hooks %s/%s"):format(tostring(ok1), tostring(ok2)))
end

-- A joiner's game spawns its own vehicles too (they come up as ours - local
-- authority - not the host's). Those never sync with anything: getting into
-- one drives a car only we can see, and the host's real car sits in the same
-- spot. Hide them and switch their collision off so only the host's show.
BD.vehGhosts = function()
    if dnIsHost() then return end
    for _, v in ipairs(safe(function() return FindAllOf("BP_VehicleMaster_C") end, nil) or {}) do
        if dnValid(v) and not BD.vh.ghost[v:GetAddress()] and safe(function() return v:GetLocalRole() end, 0) == 3 then
            BD.vh.ghost[v:GetAddress()] = true
            if BD.vh.mine == v then BD.vh.mine = nil end
            pcall(function() v:SetActorHiddenInGame(true) end)
            pcall(function() v:SetActorEnableCollision(false) end)
            pcall(function() v:SetActorTickEnabled(false) end)
            BD.vh.ghosts = (BD.vh.ghosts or 0) + 1
            local l = safe(function() return v:K2_GetActorLocation() end, { X = 0, Y = 0 })
            log(("VH: hid our own copy of %s at %.0f,%.0f (only the host's vehicles are real)"):format(className(v), l.X, l.Y))
        end
    end
end
BD.vehHook = function()
    if BD.vh.hooked then return end
    local V = "/Game/Blueprints/Vehicles/BP_VehicleMaster.BP_VehicleMaster_C:"
    local P = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
    local okIn = pcall(RegisterHook, V .. "Interact_GetInVehicle", function(ctx)
        local v = safe(function() return ctx:get() end, nil)
        if not dnValid(v) then return end
        if dnIsHost() then log("VH: get-in ran on the host for " .. className(v)); return end
        BD.vh.mine = v
        log("VH: I got into " .. className(v) .. " -> " .. tostring(BD.vehSend(BD.VEH_IN, v)))
    end)
    local okOut = pcall(RegisterHook, V .. "ExitVehicle", function(ctx)
        if dnIsHost() or not BD.vh.mine then return end
        local v = BD.vh.mine
        BD.vh.mine = nil
        log("VH: I got out -> " .. tostring(BD.vehSend(BD.VEH_OUT, v)))
    end)
    -- movement keys, as the game's own bindings see them (they fire every frame while held)
    local nk = 0
    pcall(function() StaticFindObject(P):ForEachFunction(function(fn)
        local nm = fn:GetFName():ToString()
        for _, k in ipairs({ "MoveForward", "MoveBackwards", "MoveLeft", "MoveRight", "Jump" }) do
            if nm:find("^InpActEvt_IA_" .. k .. "_") then
                if pcall(RegisterHook, P .. ":" .. nm, function() BD.vh.keys[k] = os.clock() end) then nk = nk + 1 end
            end
        end
    end) end)
    BD.vh.hooked = okIn and okOut
    log(("VH: vehicle hooks in=%s out=%s keys=%d"):format(tostring(okIn), tostring(okOut), nk))
end
BD.hook = function()
    if BD.hooked or BD.tries >= 30 then return end
    local cls = safe(function() return StaticFindObject("/Game/Blueprints/Components/BuildingComponent.BuildingComponent_C") end, nil)
    if not dnValid(cls) then return end
    BD.tries = BD.tries + 1
    local ok1 = pcall(RegisterHook, BD_COMP .. "Event_LaunchBuildMode", function(ctx)
        if dnIsHost() then return end
        local comp = safe(function() return ctx:get() end, nil)
        if dnValid(comp) then pcall(BD.send, comp) end
    end)
    local ok2 = pcall(RegisterHook, BD_COMP .. "Svr_SpawnBuild", function(ctx)
        if not dnIsHost() then return end
        local comp = safe(function() return ctx:get() end, nil)
        if dnValid(comp) then pcall(BD.afterSpawn, comp) end
    end)
    local ok3 = pcall(RegisterHook, BD_JIG .. "SERVER_ForwardInteract", function(ctx, actor, option, payload)
        if not dnIsHost() then return end
        local jig = safe(function() return ctx:get() end, nil)
        if dnValid(jig) then
            local ok, err = pcall(BD.receive, jig, payload)
            if not ok then log("BD: receive error " .. tostring(err):sub(1, 150)) end
        end
    end)
    if not BD.vh.hooked then pcall(BD.vehHook) end
    if not PK.hooked then pcall(PK.hook) end
    if not BD.crHooked then pcall(BD.crHook) end
    if not BD.vh.loop then
        BD.vh.loop = true
        gameLoop(50, function() pcall(BD.vehKeys) end)
        gameLoop(2000, function() pcall(BD.vehGhosts) end)
    end
    if not BD.pkHooked then
        BD.pkHooked = pcall(RegisterHook, BD_JIG .. "CLIENT_AddActorToContainerSUCCESS", function(ctx, actor)
            if dnIsHost() then return end
            local jig = safe(function() return ctx:get() end, nil)
            local a = safe(function() return actor:get() end, nil)
            if dnValid(jig) and dnValid(a) then pcall(BD.sendPicked, jig, a) end
        end)
        -- picking up something you already carry (ammo) stacks instead
        local okS = pcall(RegisterHook, BD_JIG .. "CLIENT_AddStackActorResponse", function(ctx, success, uid, count, actor)
            if dnIsHost() then return end
            if safe(function() return success:get() end, false) ~= true then return end
            local jig = safe(function() return ctx:get() end, nil)
            local a = safe(function() return actor:get() end, nil)
            if dnValid(jig) and dnValid(a) then pcall(BD.sendPicked, jig, a) end
        end)
        local okLA = pcall(RegisterHook, BD_JIG .. "SERVER_RequestMoveItemToAnotherComp", function(ctx, from, to, uid, rot, idx, cont)
            if not dnIsHost() then return end
            local ok, err = pcall(BD.laNote, ctx, from, to, uid, rot, idx, cont)
            if not ok then log("LA: note error " .. tostring(err):sub(1, 120)) end
        end)
        log("LA: loot all hook -> " .. tostring(okLA))
        local okR1 = pcall(RegisterHook, BD_JIG .. "SERVER_RequestAddActorToContainer", function(ctx, actor)
            if not dnIsHost() then return end
            local jig = safe(function() return ctx:get() end, nil)
            if dnValid(jig) then pcall(BD.noteReq, jig, actor) end
        end)
        local okR2 = pcall(RegisterHook, BD_JIG .. "SERVER_RequestActorAddStackItem", function(ctx, actor)
            if not dnIsHost() then return end
            local jig = safe(function() return ctx:get() end, nil)
            if dnValid(jig) then pcall(BD.noteReq, jig, actor) end
        end)
        log(("PK: pickup hooks -> %s, stack %s, requests %s/%s"):format(tostring(BD.pkHooked), tostring(okS), tostring(okR1), tostring(okR2)))
    end
    BD.hooked = ok1 and ok2 and ok3
    if BD.hooked or BD.tries == 1 or BD.tries >= 30 then
        log(("BD: hooks launch=%s spawn=%s forward=%s"):format(tostring(ok1), tostring(ok2), tostring(ok3)))
    end
end

local PR = {}
CS.PR = PR
PR.sig = function(path)
    local fn = safe(function() return StaticFindObject(path) end, nil)
    if not (fn and safe(function() return fn:IsValid() end, false)) then return "missing" end
    local parts = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            if #parts < 14 then
                parts[#parts + 1] = safe(function() return p:GetFName():ToString() end, "?") .. ":" ..
                    safe(function() return p:GetClass():GetFName():ToString() end, "?")
            end
        end)
    end)
    return table.concat(parts, ", ")
end
PR.structOf = function(obj, propName)
    local out = {}
    pcall(function()
        obj:GetClass():ForEachProperty(function(p)
            if safe(function() return p:GetFName():ToString() end, "") == propName then
                local inner = safe(function() return p:GetInner() end, nil)
                local sp = inner or p
                local st = safe(function() return sp:GetStruct() end, nil)
                if st then
                    st:ForEachProperty(function(f)
                        out[#out + 1] = safe(function() return f:GetFName():ToString() end, "?") .. ":" ..
                            safe(function() return f:GetClass():GetFName():ToString() end, "?")
                    end)
                end
            end
        end)
    end)
    return table.concat(out, ", ")
end

-- Joiner saves. A joiner used to start naked every session. The host now
-- keeps each joiner's inventory with the game's own Jig save functions (one
-- save slot per container, "SDMP_<id>_<n>") plus a small text file of their
-- stats, and puts it back when they join again. A joiner is recognised by a
-- name it sets itself on connect ("SDMP-<computer>-<user>") since the plain
-- IP connection gives every session a random name.
--   * saved every 30s while they're alive and loaded
--   * a joiner who died starts fresh (their next save overwrites the old one)
-- On by default (joiner_saves=false in config.txt turns it off). Verified with
-- persisttest: a fresh body got 28 of 29 items and its clothes back and kept
-- them (the odd one out was a duplicate of an item the host still had).
local PJ = { st = {}, t = 0, said = {}, enabled = true }
CS.PJ = PJ
local function pjDir()
    local src = debug.getinfo(1, "S").source or ""
    return src:match("^@(.*)[/\\]Scripts[/\\]main%.lua$") or "ue4ss/Mods/SDMPDiag"
end
local function pjSlug(id) return (id:gsub("[^%w%-_]", "_")) end
PJ.myId = function()
    local c = os.getenv("COMPUTERNAME") or "pc"
    local u = os.getenv("USERNAME") or "user"
    return "SDMP-" .. pjSlug(c .. "-" .. u):sub(1, 40) .. "@" .. SDMP_VERSION
end
-- "SDMP-<machine>-<user>@<version>" -> id, version
PJ.idOf = function(p)
    local ps = safe(function() return p.PlayerState end, nil)
    local n = dnValid(ps) and safe(function() return ps:GetPlayerName():ToString() end, nil) or nil
    if n and n:sub(1, 5) == "SDMP-" then
        local id, ver = n:match("^(.-)@(.+)$")
        return pjSlug(id or n), ver
    end
    return nil
end
local function pjMetaPath(id) return pjDir() .. "\\sdmp_save_" .. id .. ".txt" end
PJ.readMeta = function(id)
    local f = io.open(pjMetaPath(id), "r"); if not f then return nil end
    local m = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then m[k] = tonumber(v) or v end
    end
    f:close()
    return m
end
local function pjWriteMeta(id, m)
    local f = io.open(pjMetaPath(id), "w"); if not f then return false end
    for k, v in pairs(m) do f:write(k .. "=" .. tostring(v) .. "\n") end
    f:close()
    return true
end
local PJ_STATS = {
    { "MedicalComponent", "Health" }, { "HungerThirstComponent", "CurrentHunger" },
    { "HungerThirstComponent", "CurrentThirst" }, { "StaminaComponent", "CurrentStamina" },
    { "LevellingComponent", "CurrentLevel" }, { "LevellingComponent", "CurrentXP" },
    { "RadiationComponent", "CurrentRadiation" },
}
PJ.itemCount = function(p)
    local jig = safe(function() return p.BP_JigMultiplayer end, nil)
    local mc = dnValid(jig) and safe(function() return jig.MainJigContainers end, nil)
    if not mc then return -1, 0 end
    local n = 0
    for i = 1, #mc do
        local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
        n = n + (items and #items or 0)
    end
    return n, #mc
end
-- The game keeps the host's character in one in-memory save object (Easy
-- Multi Save "Save_Player"), and the Jig inventory loads FROM that object
-- (LoadJigComponent). So a joiner is saved by copying their inventory arrays
-- into a fresh Save_Player object and writing it to its own slot, and loaded
-- by briefly swapping their arrays into the live save object, running the
-- game's own load (SERVER_RequestDataFromSave on their component), and
-- swapping the host's arrays straight back.
local PJ_FIELDS = { { "MainJigContainers", "MainJigContainers" }, { "MainContainersIDs", "MainUIDs" }, { "InventoryWeight", "Weights" } }
PJ.saveCls = function()
    return safe(function() return StaticFindObject("/Game/Blueprints/Saves/Save_Player.Save_Player_C") end, nil)
end
PJ.live = function()
    for _, o in ipairs(safe(function() return FindAllOf("Save_Player_C") end, nil) or {}) do
        if dnValid(o) and not safe(function() return o:GetFullName() end, ""):find("Default__", 1, true) then return o end
    end
    return nil
end
local function pjLen(v) return v and safe(function() return #v end, -1) or -1 end
local function pjNew()
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return safe(function() return GS:CreateSaveGameObject(PJ.saveCls()) end, nil)
end
-- copy the three save fields between two save objects
local function pjCopySave(dst, src)
    local ok = true
    for _, f in ipairs(PJ_FIELDS) do
        local good = pcall(function() dst[f[2]] = src[f[2]] end)
        if not good or pjLen(safe(function() return dst[f[2]] end, nil)) ~= pjLen(safe(function() return src[f[2]] end, nil)) then ok = false end
    end
    return ok
end
PJ.copySave = pjCopySave
PJ.writeMeta = function(id, m) return pjWriteMeta(id, m) end
PJ.saveSlot = function(p, slot)
    local jig = safe(function() return p.BP_JigMultiplayer end, nil)
    local obj = pjNew()
    if not (dnValid(jig) and obj) then return false, "no jig/save object" end
    local ok = true
    for _, f in ipairs(PJ_FIELDS) do
        local good = pcall(function() obj[f[2]] = jig[f[1]] end)
        if not good or pjLen(safe(function() return obj[f[2]] end, nil)) ~= pjLen(safe(function() return jig[f[1]] end, nil)) then ok = false end
    end
    if not ok then return false, "array copy failed" end
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local wrote = safe(function() return GS:SaveGameToSlot(obj, slot, 0) end, false)
    return wrote, wrote and "" or "SaveGameToSlot failed"
end
PJ.loadSlot = function(p, slot)
    local jig = safe(function() return p.BP_JigMultiplayer end, nil)
    local live = PJ.live()
    local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local L = safe(function() return GS:LoadGameFromSlot(slot, 0) end, nil)
    if not (dnValid(jig) and live and L) then
        return false, ("missing: jig=%s live=%s slot=%s"):format(tostring(dnValid(jig)), tostring(live ~= nil), tostring(L ~= nil))
    end
    local backup = pjNew()
    if not (backup and pjCopySave(backup, live)) then return false, "couldn't back up the host's save" end
    if not pjCopySave(live, L) then pjCopySave(live, backup); return false, "couldn't swap in the joiner's save" end
    local ok, err = pcall(function() jig:SERVER_RequestDataFromSave(jig) end)
    local restored = pjCopySave(live, backup)
    if not restored then log("PJ: WARNING couldn't put the host's save back") end
    return ok, tostring(err or "")
end
PJ.save = function(p, id)
    local ok, why = PJ.saveSlot(p, "SDMP_" .. id)
    local m = { items = (PJ.itemCount(p)), saved = os.time(), slot = "SDMP_" .. id }
    for _, sdef in ipairs(PJ_STATS) do
        local v = safe(function() return p[sdef[1]][sdef[2]] end, nil)
        if type(v) == "number" then m[sdef[1] .. "_" .. sdef[2]] = v end
    end
    if ok then pjWriteMeta(id, m) end
    return ok, why, m.items
end
PJ.load = function(p, id)
    local m = PJ.readMeta(id)
    if not m then return false, "no save" end
    local before = PJ.itemCount(p)
    local ok, why = PJ.loadSlot(p, m.slot or ("SDMP_" .. id))
    for _, sdef in ipairs(PJ_STATS) do
        local v = tonumber(m[sdef[1] .. "_" .. sdef[2]])
        if v then pcall(function() p[sdef[1]][sdef[2]] = v end) end
    end
    local h = tonumber(m.MedicalComponent_Health)
    if h and h > 0 then pcall(function() p:SendHealthToClient(h) end) end
    log(("PJ: load into %s: items %d -> %d right after (save says %s) %s"):format(id, before, (PJ.itemCount(p)), tostring(m.items), why or ""))
    return ok, why
end
-- host, once a second
PJ.hostTick = function()
    if not dnCoop() then return end
    local now = os.clock()
    for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
        if dnValid(p) and not safe(function() return p:IsLocallyControlled() end, true)
           and dnValid(safe(function() return p.Controller end, nil)) then
            local id, ver = PJ.idOf(p)
            if id then
                local st = PJ.st[id] or {}
                PJ.st[id] = st
                if ver ~= SDMP_VERSION and not st.verWarned then
                    st.verWarned = true
                    log(("PJ: %s is on mod version %s, host has %s"):format(id, tostring(ver), SDMP_VERSION))
                    pcall(dnNotify, ("A player joined with co-op mod %s - you have %s. Both of you need the same version."):format(tostring(ver), SDMP_VERSION), dnLocalPC() and dnLocalPC().Pawn)
                end
                if not PJ.enabled then goto continue end
                local addr = p:GetAddress()
                local dead = safe(function() return p["PlayerDead?"] end, false)
                if dead then
                    st.died = true
                elseif st.pawn ~= addr then
                    -- a new body for this joiner: a reconnect gets its things back,
                    -- a respawn after death starts over
                    st.pawn, st.ready, st.lastSave = addr, false, now
                    if st.died and not PJ.testReconnect then
                        st.died = false; st.ready = true
                        log("PJ: " .. id .. " respawned after dying - starting fresh")
                    elseif PJ.readMeta(id) then
                        st.died = false
                        st.loadAt = now + 8   -- let the game set the new body's inventory up first
                        st.tries = 0
                    else
                        st.ready = true
                        log("PJ: " .. id .. " has no save yet")
                    end
                elseif st.loadAt and now >= st.loadAt then
                    local m = PJ.readMeta(id) or {}
                    local _, nc = PJ.itemCount(p)
                    if nc < 1 and now < st.loadAt + 20 then goto continue end   -- inventory not built yet
                    st.loadAt = nil
                    local ok, why = PJ.load(p, id)
                    log(("PJ: loaded %s's save -> %s %s"):format(id, tostring(ok), tostring(why or "")))
                    st.readyAt = now + 4
                    st.want = tonumber(m.items)
                elseif st.readyAt and now >= st.readyAt then
                    -- (loading again on a shortfall made it worse: one load, then accept)
                    local have = PJ.itemCount(p)
                    st.readyAt, st.ready = nil, true
                    log(("PJ: %s now has %d items (save had %s)"):format(id, have, tostring(st.want)))
                    if have > 1 then pcall(dnNotify, "Welcome back - your things were restored", p) end
                elseif st.ready and not DN.isDown(p) and now - (st.lastSave or 0) >= 30 then
                    st.lastSave = now
                    local ok, why, items = PJ.save(p, id)
                    if not PJ.said[id] or PJ.said[id] ~= items or not ok then
                        PJ.said[id] = items
                        log(("PJ: saved %s (%s items) -> %s %s"):format(id, tostring(items), tostring(ok), tostring(why or "")))
                    end
                end
            end
        end
        ::continue::
    end
end
-- joiner: tell the host who we are (repeat until the name sticks)
PJ.clientTick = function()
    PJ.t = PJ.t + 1
    if PJ.t % 5 ~= 0 then return end
    local pc = dnLocalPC()
    local me = pc and safe(function() return pc.Pawn end, nil)
    if not dnValid(me) then return end
    local want = PJ.myId()
    local ps = safe(function() return pc.PlayerState end, nil)
    local cur = dnValid(ps) and safe(function() return ps:GetPlayerName():ToString() end, "") or ""
    if cur ~= want then
        local ok = pcall(function() pc:ServerChangeName(want) end)
        if not PJ.named then PJ.named = true; log("PJ: told the host my id " .. want .. " -> " .. tostring(ok)) end
    end
end

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
    -- Door test: host and joiner stand at the nearest local-only door. Host
    -- toggles it (joiner should see it move), then the joiner toggles it
    -- (host should get the forward and follow).
    A.doorTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local hp, cp = myPawn(), z.p
        if z.t == 3 then
            local counts = {}
            for _, a in ipairs(DR.all()) do local cn = className(a); counts[cn] = (counts[cn] or 0) + 1 end
            local parts = {}
            for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
            alog("DOOR census: " .. (#parts > 0 and table.concat(parts, " ") or "none loaded"))
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            z.door, z.dd = DR.nearest(hl, true, "BP_LockedDoor_C")
            if not z.door then alog("DOOR: FAIL no door found"); z.res = "nodoor"; z.t = 1000; return end
            alog(("DOOR: target %s %.0f away, open=%s pose: %s"):format(className(z.door), z.dd, tostring(DR.isOpen(z.door)), DR.pose(z.door)))
        elseif z.t == 5 then
            local dl = safe(function() return z.door:K2_GetActorLocation() end, nil)
            local fwd = safe(function() return z.door:GetActorForwardVector() end, { X = 1, Y = 0, Z = 0 })
            if dl then
                local dest = { X = dl.X + fwd.X * 250, Y = dl.Y + fwd.Y * 250, Z = dl.Z + 100 }
                pcall(function() hp:K2_TeleportTo(dest, hp:K2_GetActorRotation()) end)
                pcall(function() cp:K2_TeleportTo({ X = dest.X + 80, Y = dest.Y + 80, Z = dest.Z }, cp:K2_GetActorRotation()) end)
                alog("DOOR: host + joiner moved to the door")
            end
        elseif z.t == 10 then
            DR.makeRep(z.door)
        elseif z.t == 14 then
            z.before = DR.pose(z.door)
            local ok = DR.toggle(z.door, hp)
            alog(("DOOR: host toggles it -> %s"):format(tostring(ok)))
        elseif z.t == 18 then
            alog(("DOOR: host after its toggle open=%s pose: %s"):format(tostring(DR.isOpen(z.door)), DR.pose(z.door)))
            fwrite("sdmp_phase.txt", "door1")
        elseif z.t == 30 then
            alog(("DOOR: host after joiner's toggle open=%s pose: %s (forwards received=%d)"):format(tostring(DR.isOpen(z.door)), DR.pose(z.door), DR.rx))
            z.res = DR.rx > 0 and "forward-ok" or "no-forward"
        elseif z.t == 34 then
            alog("DOOR RESULT: " .. tostring(z.res))
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.doorClient = function()
        local ph = fread("sdmp_phase.txt") or ""
        if ph:find("door1") and not A.dc1 then
            A.dc1 = true
            local me = myPawn()
            local d = DR.nearest(safe(function() return me:K2_GetActorLocation() end, nil), true, "BP_LockedDoor_C")
            if not d then alog("DOOR(client): no door near me"); return end
            alog(("DOOR(client): sees %s open=%s pose: %s role=%s"):format(className(d), tostring(DR.isOpen(d)), DR.pose(d),
                tostring(safe(function() return d:GetLocalRole() end, "?"))))
            gameDelay(3000, function()
                local ok = pcall(function() d:Event_Door() end)   -- as if the joiner pressed E
                if not ok then ok = pcall(function() d:Event_Door(me) end) end
                alog("DOOR(client): toggled it locally -> " .. tostring(ok))
                gameDelay(6000, function()
                    alog(("DOOR(client): 6s after own toggle open=%s pose: %s"):format(tostring(DR.isOpen(d)), DR.pose(d)))
                end)
            end)
        end
    end
    -- Joiner-save probe: what the inventory looks like and what the Jig
    -- save/load/add functions want.
    A.persistTick = function()
        local z = A.ztest
        z.t = z.t + 1
        PJ.enabled = true
        local cp = z.p
        if z.t == 6 then
            local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
            for _, f in ipairs({ "AddNewItemSomewhere", "JigTryAddItemSomewhere", "GetContainerItems", "Save One Jig ContainerByIndex",
                                 "ReplaceLoadJigComponentByIndex", "SERVER_RequestLoadReplaceOneContainerByIndex",
                                 "SERVER_RequestSaveOneJigContainerByIndex", "SaveMultipleJigContainersByIndexes", "GetTotalCountOfItem" }) do
                alog("PJ sig " .. f .. ": " .. PR.sig(J .. f))
            end
            local jig = safe(function() return cp.BP_JigMultiplayer end, nil)
            local hp = myPawn()
            local hjig = safe(function() return hp.BP_JigMultiplayer end, nil)
            alog("PJ MainJigContainers struct: " .. PR.structOf(jig, "MainJigContainers"))
            local mc = safe(function() return jig.MainJigContainers end, nil)
            local hmc = safe(function() return hjig.MainJigContainers end, nil)
            alog(("PJ joiner containers=%s host containers=%s"):format(tostring(mc and #mc), tostring(hmc and #hmc)))
            local ps = safe(function() return cp.PlayerState end, nil)
            alog("PJ joiner PlayerName=" .. tostring(safe(function() return ps:GetPlayerName():ToString() end, "?")))
            -- one level down: the item struct inside a container
            pcall(function()
                local c1 = hmc[1]
                local names = {}
                for _, k in ipairs({ "ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B", "ReplicationUID_23_EB27D09649B6E02591DCA98708B06332" }) do
                    local v = safe(function() return c1[k] end, nil)
                    names[#names + 1] = k:sub(1, 20) .. "=" .. (type(v) == "userdata" and (safe(function() return tostring(#v) end, "obj")) or tostring(v))
                end
                alog("PJ host container[1]: " .. table.concat(names, " "))
            end)
        elseif z.t >= 8 and z.t < 40 and not z.id then
            z.id = PJ.idOf(cp)
            if not z.id then return end
            -- the host's inventory is the test cargo: save it to a slot and
            -- point the joiner's save at it, then give the joiner a fresh body
            local hp = myPawn()
            z.hostItems = PJ.itemCount(hp)
            local live = PJ.live()
            alog(("PJ: live save object=%s, its containers=%s"):format(tostring(live ~= nil), tostring(live and pjLen(safe(function() return live.MainJigContainers end, nil)))))
            local ok, why = PJ.saveSlot(hp, "SDMP_testhost")
            alog(("PJ: saved the host's %d items to SDMP_testhost -> %s %s"):format(z.hostItems, tostring(ok), why))
            PJ.writeMeta(z.id, { slot = "SDMP_testhost", items = z.hostItems, saved = os.time() })
            z.savedAt = z.t
            if not ok then alog("PJ RESULT: FAIL couldn't save"); z.t = 200 end
        elseif z.savedAt and z.t == z.savedAt + 2 then
            PJ.testReconnect = true
            DN.allowKill[cp:GetAddress()] = true
            pcall(function() cp.bCanBeDamaged = true end)
            pcall(function() StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(cp, 1000.0, nil, nil, nil) end)
            alog("PJ: joiner killed to get a fresh body")
        elseif z.savedAt and z.t > z.savedAt + 3 and z.t < 90 and not z.done then
            for _, p in ipairs(FindAllOf("BP_PlayerCharacter_C") or {}) do
                if dnValid(p) and p:GetAddress() ~= cp:GetAddress() and not safe(function() return p:IsLocallyControlled() end, true)
                   and dnValid(safe(function() return p.Controller end, nil)) then
                    local st = PJ.st[z.id] or {}
                    if st.ready and st.pawn == p:GetAddress() then
                        z.np = p
                        z.n1 = PJ.itemCount(p)
                        alog(("PJ: fresh body has %d items after load (host had %d)"):format(z.n1, z.hostItems))
                        z.done = true; z.endAt = z.t + 12
                    end
                end
            end
        elseif not z.finished and ((z.done and z.t >= z.endAt) or z.t >= 90) then
            z.finished = true   -- once: in "stay" mode the tick keeps running after this
            if not z.done then alog("PJ RESULT: FAIL no reload within 90s" .. (z.id and "" or " (no id from joiner)"))
            else
                local n2 = PJ.itemCount(z.np)
                alog(("PJ RESULT: host had %d, joiner got %d, 12s later %d -> %s"):format(z.hostItems, z.n1, n2,
                    (z.n1 >= z.hostItems - 1 and n2 == z.n1) and "PASS" or "FAIL"))
                pcall(CS.dumpSlots, "after load")
            end
            alog("PJ done")
            PJ.testReconnect = false
            fwrite("sdmp_done.txt", "1")
            z.t = 1000
        end
    end
    -- Well test: does a joiner drinking from a well (the game's own Jig
    -- interact, which asks the server) actually quench the joiner's thirst?
    A.wellTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local hp, cp = myPawn(), z.p
        if z.t == 4 then
            local best, bd = nil, 1e18
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            for _, w in ipairs(safe(function() return FindAllOf("BP_WaterWell_C") end, nil) or {}) do
                local l = dnValid(w) and safe(function() return w:K2_GetActorLocation() end, nil)
                if l and hl then
                    local d = (l.X - hl.X)^2 + (l.Y - hl.Y)^2
                    if d < bd then best, bd = w, d end
                end
            end
            if not best then alog("WELL RESULT: no well loaded"); z.t = 1000; fwrite("sdmp_done.txt", "1"); return end
            z.well = best
            local l = best:K2_GetActorLocation()
            pcall(function() hp:K2_TeleportTo({ X = l.X + 200, Y = l.Y, Z = l.Z + 100 }, hp:K2_GetActorRotation()) end)
            pcall(function() cp:K2_TeleportTo({ X = l.X + 120, Y = l.Y + 60, Z = l.Z + 100 }, cp:K2_GetActorRotation()) end)
            pcall(function() best.CurrentWater = best.MaxWater end)
            alog(("WELL: %.0f away, water %s/%s - both moved there"):format(math.sqrt(bd), tostring(safe(function() return best.CurrentWater end, "?")), tostring(safe(function() return best.MaxWater end, "?"))))
        elseif z.t == 8 then
            pcall(function() cp.HungerThirstComponent.CurrentThirst = 40.0 end)
            z.before = safe(function() return cp.HungerThirstComponent.CurrentThirst end, -1)
            alog("WELL: joiner thirst set to " .. tostring(z.before) .. " - joiner drinks next")
            fwrite("sdmp_phase.txt", "well1")
        elseif z.t == 20 then
            local after = safe(function() return cp.HungerThirstComponent.CurrentThirst end, -1)
            alog(("WELL RESULT: joiner thirst %s -> %s (server) -> %s"):format(tostring(z.before), tostring(after),
                (type(after) == "number" and after > (z.before or 0) + 5) and "PASS" or "FAIL"))
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.wellClient = function()
        if A.wc1 or not (fread("sdmp_phase.txt") or ""):find("well1") then return end
        A.wc1 = true
        local me = myPawn()
        local best, bd = nil, 1e18
        local ml = safe(function() return me:K2_GetActorLocation() end, nil)
        for _, w in ipairs(safe(function() return FindAllOf("BP_WaterWell_C") end, nil) or {}) do
            local l = dnValid(w) and safe(function() return w:K2_GetActorLocation() end, nil)
            if l and ml then
                local d = (l.X - ml.X)^2 + (l.Y - ml.Y)^2
                if d < bd then best, bd = w, d end
            end
        end
        if not best then alog("WELL(client): no well near me"); return end
        -- what pressing E on "Drink" does
        local ok, err = pcall(function() best:OnExecuteInteract(me, { TagName = FName("Jig.InteractOptions.Option1") }) end)
        alog(("WELL(client): drink at well %.0f away -> %s %s"):format(math.sqrt(bd), tostring(ok), tostring(err or ""):sub(1, 100)))
    end
    -- Loot test: the joiner picks an item up off the ground and opens a loot
    -- container, both with the game's own interact call (same as pressing E).
    -- class chain, matching functions and component properties of an actor
    A.describe = function(a, tag, pat)
        local cls, guard = safe(function() return a:GetClass() end, nil), 0
        while dnValid(cls) and guard < 10 do
            local cname = safe(function() return cls:GetFName():ToString() end, "?")
            if cname:match("^Actor$") or cname:match("^Object$") then break end
            local fns, props = {}, {}
            pcall(function() cls:ForEachFunction(function(fn)
                local n = safe(function() return fn:GetFName():ToString() end, "?")
                for alt in pat:gmatch("[^|]+") do
                    if n:find(alt) then fns[#fns + 1] = n; break end
                end
            end) end)
            pcall(function() cls:ForEachProperty(function(pr)
                local n = safe(function() return pr:GetFName():ToString() end, "?")
                local ok, v = pcall(function() return a[n] end)
                if ok and dnValid(v) and safe(function() return v:IsA(StaticFindObject("/Script/Engine.ActorComponent")) end, false) then
                    props[#props + 1] = n .. "=" .. className(v)
                end
            end) end)
            alog(("%s class %s | fns: %s | comps: %s"):format(tag, cname, table.concat(fns, ","), table.concat(props, ",")))
            cls = safe(function() return cls:GetSuperStruct() end, nil)
            guard = guard + 1
        end
    end
    local function nearestActor(list, loc, filter)
        local best, bd = nil, 1e18
        for _, a in ipairs(list or {}) do
            if dnValid(a) and (not filter or filter(a)) then
                local l = safe(function() return a:K2_GetActorLocation() end, nil)
                if l and loc then
                    local d = (l.X - loc.X)^2 + (l.Y - loc.Y)^2 + (l.Z - loc.Z)^2
                    if d < bd then best, bd = a, d end
                end
            end
        end
        return best, best and math.sqrt(bd) or -1
    end
    A.groundPickups = function(why)
        local out, n, noOwner, attached, hidden, other = {}, 0, 0, 0, 0, 0
        for _, c in ipairs(safe(function() return FindAllOf("BP_JigPickupComponent_C") end, nil) or {}) do
            n = n + 1
            local a = dnValid(c) and safe(function() return c:GetOwner() end, nil)
            if not dnValid(a) then noOwner = noOwner + 1
            elseif dnValid(safe(function() return a:GetAttachParentActor() end, nil)) then attached = attached + 1
            elseif safe(function() return a.bHidden end, false) then hidden = hidden + 1
            elseif not CS.inPlayWorld(a) then other = other + 1
            else out[#out + 1] = a end
        end
        if why then
            alog(("LOOT %s: %d pickup comps, %d usable (no owner %d, attached %d, hidden %d, other world %d)")
                :format(why, n, #out, noOwner, attached, hidden, other))
        end
        return out
    end
    A.lootTick = function()
        local z = A.ztest
        z.t = z.t + 1
        -- (A.ltAuto removed: scanning every object every 3 s froze both games)
        -- zombies wander over and down the joiner while someone holds F by hand
        if z.t == 2 then pcall(function() z.p.bCanBeDamaged = false end) end
        local hp, cp = myPawn(), z.p
        -- teleports fail when the spot overlaps something (the container's
        -- own mesh), so walk around it until one sticks
        local function tpNear(p, l, r0)
            for _, r in ipairs({ r0, r0 + 60, r0 + 120, r0 + 200 }) do
                for i = 0, 7 do
                    local an = i * math.pi / 4
                    local ok = safe(function()
                        return p:K2_TeleportTo({ X = l.X + r * math.cos(an), Y = l.Y + r * math.sin(an), Z = l.Z + 90 }, p:K2_GetActorRotation())
                    end, false)
                    if ok then return r end
                end
            end
            return -1
        end
        local function moveBoth(a, tag)
            local l = a:K2_GetActorLocation()
            local rh, rc = tpNear(hp, l, 260), tpNear(cp, l, 120)
            alog(("LOOT: moved to the %s (%s): host at %d, joiner at %d"):format(tag, className(a), rh, rc))
        end
        if z.t == 4 then
            pcall(A.lootHooks)
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            local list = A.groundPickups("host")
            local pk, d = nearestActor(list, hl)
            if pk then
                local cls = {}
                for i = 1, math.min(#list, 6) do cls[#cls + 1] = className(list[i]) end
                alog("LOOT: ground item classes e.g. " .. table.concat(cls, ", "))
            end
            if not pk then alog("LOOT: no ground pickup found"); z.t = 19; return end
            z.pk = pk
            alog(("LOOT: nearest ground item %s, %.0f away"):format(className(pk), d))
            moveBoth(pk, "ground item")
        elseif z.t == 8 then
            z.items0 = PJ.itemCount(cp)
            fwrite("sdmp_phase.txt", "loot1")
            alog("LOOT: joiner has " .. z.items0 .. " items - joiner picks up next")
        elseif z.t == 16 then
            local n = PJ.itemCount(cp)
            z.pickOk = n > z.items0
            alog(("LOOT RESULT pickup: joiner items %d -> %d (server) -> %s; item still on ground=%s"):format(z.items0, n,
                z.pickOk and "PASS" or "FAIL", tostring(dnValid(z.pk) and not safe(function() return z.pk.bHidden end, true))))
        elseif z.t == 20 then
            -- only a container nobody has searched yet tells us anything
            local hl = safe(function() return hp:K2_GetActorLocation() end, nil)
            local all = safe(function() return FindAllOf("BP_LootContainer_C") end, nil) or {}
            local looted = 0
            local function fresh(a)
                local l = safe(function() return a.BP_JigMultiplayer["Looted?"] end, true)
                if l then looted = looted + 1 end
                return not l
            end
            local lc, d = nearestActor(all, hl, fresh)
            alog(("LOOT: %d containers loaded, %d already searched"):format(#all, looted))
            if not lc then alog("LOOT: no unsearched container loaded"); z.t = 39; return end
            z.lc = lc
            alog(("LOOT: nearest unsearched container %.0f away"):format(d))
            -- every variable on the loot container class, to find its interact options
            pcall(function()
                local cls = StaticFindObject("/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C")
                local parts = {}
                cls:ForEachProperty(function(pr)
                    local n = safe(function() return pr:GetFName():ToString() end, "?")
                    local t = safe(function() return pr:GetClass():GetFName():ToString() end, "?")
                    local v = ""
                    if t == "MapProperty" then
                        local keys = {}
                        pcall(function() lc[n]:ForEach(function(k, _)
                            keys[#keys + 1] = safe(function() return k:get().TagName:ToString() end, nil)
                                or safe(function() return tostring(k:get()) end, "?")
                        end) end)
                        v = "{" .. table.concat(keys, ",") .. "}"
                    elseif t == "StructProperty" then
                        v = safe(function() return lc[n].TagName:ToString() end, "")
                    elseif t == "BoolProperty" or t == "FloatProperty" or t == "DoubleProperty" or t == "IntProperty" then
                        v = tostring(safe(function() return lc[n] end, "?"))
                    end
                    parts[#parts + 1] = n .. ":" .. t:gsub("Property", "") .. (v ~= "" and ("=" .. v) or "")
                end)
                alog("LOOT container vars: " .. table.concat(parts, " "))
            end)
            moveBoth(lc, "loot container")
        elseif z.t == 23 then
            alog("LOOT: container before the joiner opens it: " .. A.jigDump(z.lc))
            alog("LOOT: host faces it too -> " .. tostring(A.faceActor(z.lc, false)))
            A.aimAt = z.lc   -- keep the camera on it, so a real F hold works
            pcall(A.cmdLootProbe)
            local l = safe(function() return z.lc:K2_GetActorLocation() end, nil)
            local cl = safe(function() return cp:K2_GetActorLocation() end, nil)
            if l and cl then
                alog(("LOOT: joiner is %.0f from the container (server view)"):format(math.sqrt((l.X-cl.X)^2 + (l.Y-cl.Y)^2 + (l.Z-cl.Z)^2)))
            end
            fwrite("sdmp_phase.txt", l and ("loot2:%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "loot2")
        elseif z.t == 31 then
            -- A script can't fake the 4 s search hold, so loot never generates here
            -- (not for the host either). What it can check is the network half: the
            -- joiner's search request reaching the container on the host. The full
            -- search + take was checked by hand: items show for the joiner and land
            -- in its server-side inventory.
            local hits = A.lootFromJoiner or 0
            alog(("LOOT RESULT joiner search request reached the host: %d time(s) -> %s"):format(hits, hits > 0 and "PASS" or "FAIL"))
        elseif z.t == 40 then
            local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
            alog("LOOT sig SERVER_RequestMoveItemToAnotherComp: " .. PR.sig(J .. "SERVER_RequestMoveItemToAnotherComp"))
            alog("LOOT done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.lootClient = function()
        pcall(A.lootHooks)
        -- (A.ltAuto removed: scanning every object every 3 s froze both games)
        local ph = fread("sdmp_phase.txt") or ""
        local me = myPawn()
        local ml = safe(function() return me:K2_GetActorLocation() end, nil)
        local tag = { TagName = FName("Jig.InteractOptions.Option1") }
        if ph:find("loot1") and not A.lc1 then
            A.lc1 = true
            local pk, d = nearestActor(A.groundPickups("client"), ml)
            if not pk then alog("LOOT(client): no ground item near me"); return end
            local ok, err = pcall(function() pk:OnExecuteInteract(me, tag) end)
            alog(("LOOT(client): pick up %s %.0f away -> %s %s"):format(className(pk), d, tostring(ok), tostring(err or ""):sub(1, 100)))
        elseif ph:find("loot2") and not A.lc2 then
            A.lc2 = true
            local x, y, zz = ph:match("loot2:(%-?%d+),(%-?%d+),(%-?%d+)")
            local target = x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(zz) } or ml
            local lc = nearestActor(safe(function() return FindAllOf("BP_LootContainer_C") end, nil), target)
            if not lc then
                -- just teleported: the area may still be streaming in
                A.lcTries = (A.lcTries or 0) + 1
                if A.lcTries < 10 then A.lc2 = false; return end
                alog("LOOT(client): no container near me"); return
            end
            local l = safe(function() return lc:K2_GetActorLocation() end, nil)
            local d = (l and ml) and math.sqrt((l.X-ml.X)^2 + (l.Y-ml.Y)^2 + (l.Z-ml.Z)^2) or -1
            alog("LOOT(client): facing the container -> " .. tostring(A.faceActor(lc, false)))
            A.aimAt = lc
            gameDelay(15000, function() pcall(A.cmdLootProbe) end)
            local ok, err = pcall(function() lc:OnExecuteInteract(me, tag) end)
            alog(("LOOT(client): open %s %.0f away -> %s %s"):format(className(lc), d, tostring(ok), tostring(err or ""):sub(1, 100)))
            gameDelay(3000, function()
                -- the search bar filled: a joiner asks the server through its own jig
                local f1, ferr = pcall(function() me.BP_JigMultiplayer:SERVER_ForwardInteract(lc, tag, {}) end)
                alog(("LOOT(client): SERVER_ForwardInteract -> %s %s"):format(tostring(f1), tostring(ferr or ""):sub(1, 100)))
            end)
            gameDelay(4000, function()
                local e1 = pcall(function() lc:OpenContainer() end)
                alog(("LOOT(client): OpenContainer -> %s"):format(tostring(e1)))
            end)
            local function check(when)
                local seen = PJ.itemCount(lc)
                local wins = {}
                for _, w in ipairs(safe(function() return FindAllOf("UserWidget") end, nil) or {}) do
                    local n = className(w)
                    if dnValid(w) and (n:find("Loot") or n:find("Container") or n:find("Inventory"))
                       and safe(function() return w:IsInViewport() end, false) then wins[#wins + 1] = n end
                end
                alog(("LOOT(client) %s: container shows %s items here, open windows: %s | %s"):format(when, tostring(seen),
                    #wins > 0 and table.concat(wins, ",") or "none", A.lootWindows()))
                alog("LOOT(client) jig: " .. A.jigDump(lc))
            end
            gameDelay(2000, function() pcall(check, "+2s") end)
            gameDelay(6000, function() pcall(check, "+6s") end)
            gameDelay(9000, function() pcall(check, "+9s") end)
        end
    end
    A.lootWindows = function()
        local out = {}
        for _, cn in ipairs({ "BP_LootContainerWidget_C", "W_Inventory_C", "BP_InventoryWidget_C", "BP_JigInventoryWidget_C" }) do
            for _, w in ipairs(safe(function() return FindAllOf(cn) end, nil) or {}) do
                if dnValid(w) then
                    local vis = safe(function() return w:IsVisible() end, "?")
                    local vp = safe(function() return w:IsInViewport() end, "?")
                    out[#out + 1] = ("%s(vis=%s,vp=%s)"):format(cn, tostring(vis), tostring(vp))
                end
            end
        end
        return #out > 0 and table.concat(out, " ") or "none"
    end
    A.jigDump = function(a)
        local jig = safe(function() return a.BP_JigMultiplayer end, nil)
        if not dnValid(jig) then return "no jig" end
        local parts = {}
        pcall(function() jig:GetClass():ForEachProperty(function(pr)
            local n = safe(function() return pr:GetFName():ToString() end, "?")
            local ok, v = pcall(function() return jig[n] end)
            if ok and type(v) == "userdata" then
                local ok2, len = pcall(function() return #v end)
                if ok2 and type(len) == "number" and len > 0 then parts[#parts + 1] = n .. "#" .. len end
            elseif ok and (type(v) == "boolean" or type(v) == "number") then
                parts[#parts + 1] = n .. "=" .. tostring(v)
            end
        end) end)
        return table.concat(parts, " ")
    end
    -- log the loot container's interaction calls, so a real E press shows
    -- what the game itself calls (and on which side)
    A.lootHooks = function()
        if A.lootHooked then return end
        A.lootHooked = true
        local LC = "/Game/Inventory/Containers/BP_LootContainer.BP_LootContainer_C:"
        for _, f in ipairs({ "OnBeginInteract", "OnExecuteInteract", "OnExecuteInteractEnded", "OnStopExecuteInteract",
                             "OnRequestServerInteract", "OnServerExecuteInteract", "OpenContainer", "Event_HoldToInteract",
                             "OnEndInteract", "PauseInteract" }) do
            local ok, err = pcall(RegisterHook, LC .. f, function(ctx, a1, a2)
                local who = safe(function() return className(ctx:get()) end, "?")
                if f == "OnServerExecuteInteract" then
                    local by = safe(function() return a2:get() end, nil)
                    local same = by and A.ztest and A.ztest.p
                        and safe(function() return by:GetAddress() == A.ztest.p:GetAddress() end, false)
                    if same then A.lootFromJoiner = (A.lootFromJoiner or 0) + 1 end
                end
                alog(("LOOTHOOK %s on %s"):format(f, who))
            end)
            if not ok then alog("LOOTHOOK " .. f .. " not hooked: " .. tostring(err):sub(1, 80)) end
        end
        local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
        for _, f in ipairs({ "SERVER_ForwardInteract", "SERVER_RequestData", "CLIENT_ContainerDataResponse" }) do
            local ok, err = pcall(RegisterHook, J .. f, function(ctx)
                local who = safe(function() return className(ctx:get():GetOwner()) end, "?")
                alog(("LOOTHOOK jig %s (jig of %s)"):format(f, who))
            end)
            if not ok then alog("LOOTHOOK " .. f .. " not hooked: " .. tostring(err):sub(1, 80)) end
        end
        alog("LOOTHOOK hooks in")
    end
    -- dev: turn the local camera to the nearest loot container (no mouse look over remote control)
    -- dev (host): drop a campfire kit on the ground next to each joiner, made
    -- to replicate, so a joiner can pick it up and build with a real item.
    -- sdmp_items logs every player's item count (host side).
    A.GIVE_CLS = "/Game/Inventory/Items/Pickups/Buildable/Crafting/BP_CampfirePickup.BP_CampfirePickup_C"
    A.cmdGive = function()
            local cls = safe(function() return StaticFindObject(A.GIVE_CLS) end, nil)
            if not dnValid(cls) then
                safe(function() return LoadAsset(A.GIVE_CLS:gsub("_C$", "")) end, nil)
                cls = safe(function() return StaticFindObject(A.GIVE_CLS) end, nil)
            end
            if not dnValid(cls) then alog("give: no campfire pickup class"); return end
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
                if dnValid(p) and not safe(function() return p:IsLocallyControlled() end, true) then
                    local l = p:K2_GetActorLocation()
                    local f = p:GetActorForwardVector()
                    local tr = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                                 Translation = { X = l.X + f.X * 120, Y = l.Y + f.Y * 120, Z = l.Z - 40 },
                                 Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
                    local a = safe(function() return gs:BeginDeferredActorSpawnFromClass(p, cls, tr, 1, p, 0) end, nil)
                    if dnValid(a) then
                        pcall(function() gs:FinishSpawningActor(a, tr, 0) end)
                        pcall(function() a:SetReplicates(true) end)
                        pcall(function() a:SetReplicateMovement(true) end)
                        pcall(function() a:ForceNetUpdate() end)
                    end
                    local n0 = PJ.itemCount(p)
                    alog(("give: campfire kit next to %s -> %s; joiner has %s items"):format(className(p), tostring(dnValid(a)), tostring(n0)))
                    -- and pick it up for them on the host, the way the joiner's own
                    -- pickup request ends up on the host
                    gameDelay(1000, function()
                        local ok, err = pcall(function() a:OnServerExecuteInteract({ TagName = FName("Jig.InteractOptions.Option1") }, p, {}) end)
                        gameDelay(2000, function()
                            alog(("give: picked up for the joiner -> %s %s; joiner items %s -> %s"):format(tostring(ok),
                                tostring(err or ""):sub(1, 80), tostring(n0), tostring(PJ.itemCount(p))))
                        end)
                    end)
                end
            end
    end
    RegisterConsoleCommandHandler("sdmp_give", function() ExecuteInGameThread(function() pcall(A.cmdGive) end) return true end)
    -- dev: list each player's items (host view), marking the buildable ones
    A.cmdInv = function()
            for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
                local jig = dnValid(p) and safe(function() return p.BP_JigMultiplayer end, nil)
                local mc = dnValid(jig) and safe(function() return jig.MainJigContainers end, nil)
                local names = {}
                for i = 1, (mc and #mc or 0) do
                    local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
                    for j = 1, (items and #items or 0) do
                        local it = safe(function() return items[j]:get() end, nil) or items[j]
                        local da = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                        local nm = dnValid(da) and (safe(function() return da:GetFName():ToString() end, "?")) or "?"
                        local b = dnValid(da) and dnValid(safe(function() return da.BuildActorClass end, nil))
                        names[#names + 1] = nm .. (b and "[BUILD]" or "")
                    end
                end
                alog(("inv: %s local=%s: %s"):format(className(p), tostring(safe(function() return p:IsLocallyControlled() end, "?")), table.concat(names, ", ")))
            end
    end
    RegisterConsoleCommandHandler("sdmp_inv", function() ExecuteInGameThread(function() pcall(A.cmdInv) end) return true end)
    -- joiner: build the first buildable item in my own inventory the way the
    -- game's "Build" does it (BuildUID + build mode + Svr_SpawnBuild), so the
    -- host has a real item to take
    A.cmdBuildReal = function()
        local me = myPawn()
        local jig = safe(function() return me.BP_JigMultiplayer end, nil)
        local comp = safe(function() return me.BuildingComponent end, nil)
        local da, uid
        for _, arrName in ipairs({ "MainJigContainers", "LocalJSIContainers" }) do
        local mc = dnValid(jig) and safe(function() return jig[arrName] end, nil)
        for i = 1, (mc and #mc or 0) do
            local el = safe(function() return mc[i]:get() end, nil) or mc[i]
            local items = safe(function() return el["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
            if not safe(function() return #items end, nil) then items = nil end
            for j = 1, (items and #items or 0) do
                local it = safe(function() return items[j]:get() end, nil) or items[j]
                local d = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                if not da and dnValid(d) and dnValid(safe(function() return d.BuildActorClass end, nil)) then
                    da = d
                    uid = safe(function() return it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] end, nil)
                end
            end
        end
        end
        local g0
        if not (dnValid(da) and uid) then
            -- a joiner's own jig keeps items in container objects, not
            -- MainJigContainers; the host writes the item id to a file (test only)
            local line = fread("sdmp_uid.txt") or ""
            local a, b, c, d, path = line:match("^(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%S+)")
            if a then
                g0 = { A = tonumber(a), B = tonumber(b), C = tonumber(c), D = tonumber(d) }
                da = safe(function() return StaticFindObject(path) end, nil)
                if not dnValid(da) then da = safe(function() return LoadAsset(path) end, nil) end
                uid = g0
            end
        end
        if not (dnValid(da) and uid and dnValid(comp)) then
            alog("buildreal: no buildable item in my inventory; my jig: " .. A.jigDump(me))
            pcall(function() alog("buildreal: LocalJSIContainers element: " .. PR.structOf(jig, "LocalJSIContainers")) end)
            return
        end
        local g = g0 or bdGuid(uid)
        alog(("buildreal: building %s, item id %d/%d/%d/%d"):format(className(da) .. " " .. bdPath(da), g.A, g.B, g.C, g.D))
        pcall(function() comp.BuildUID = g end)
        local ws = safe(function() return UEHelpers.GetWorld():K2_GetWorldSettings() end, nil)
        local ok = pcall(function() comp:Event_LaunchBuildMode(da, false, ws) end)
        gameDelay(2000, function()
            local l = me:K2_GetActorLocation()
            local f = me:GetActorForwardVector()
            local tr = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                         Translation = { X = l.X + f.X * 400, Y = l.Y + f.Y * 400, Z = l.Z - 88 },
                         Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
            local ok2 = pcall(function() comp:Svr_SpawnBuild(tr) end)
            alog(("buildreal: launch=%s spawn=%s"):format(tostring(ok), tostring(ok2)))
            gameDelay(500, function() pcall(function() comp:Event_StopBuildMode() end) end)
        end)
    end
    A.cmdUid = function()
        for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
            if dnValid(p) and not safe(function() return p:IsLocallyControlled() end, true) and dnValid(safe(function() return p.Controller end, nil)) then
                local mc = safe(function() return p.BP_JigMultiplayer.MainJigContainers end, nil)
                for i = 1, (mc and #mc or 0) do
                    local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
                    for j = 1, (items and #items or 0) do
                        local it = safe(function() return items[j]:get() end, nil) or items[j]
                        local d = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                        if dnValid(d) and dnValid(safe(function() return d.BuildActorClass end, nil)) then
                            local g = bdGuid(safe(function() return it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] end, nil) or {})
                            fwrite("sdmp_uid.txt", ("%d %d %d %d %s"):format(g.A, g.B, g.C, g.D, bdPath(d)))
                            alog(("uid: joiner's %s is %d/%d/%d/%d"):format(bdPath(d), g.A, g.B, g.C, g.D))
                            return
                        end
                    end
                end
            end
        end
        alog("uid: no buildable item on a joiner")
    end
    -- joiner: move the nearest thing I built, the way the game's "Move" does it
    A.cmdMoveReal = function()
        local me = myPawn()
        local comp = safe(function() return me.BuildingComponent end, nil)
        local ml = me:K2_GetActorLocation()
        local best, bd = nil, 2000 * 2000
        for _, a in ipairs(safe(function() return FindAllOf("Buildable_MASTER_C") end, nil) or {}) do
            local l = dnValid(a) and safe(function() return a:K2_GetActorLocation() end, nil)
            if l then
                local d = (l.X - ml.X)^2 + (l.Y - ml.Y)^2
                if d < bd then best, bd = a, d end
            end
        end
        if not best then alog("movereal: nothing built near me"); return end
        local da = safe(function() return best.PickupDataAsset end, nil)
        local l = best:K2_GetActorLocation()
        alog(("movereal: moving %s at %.0f,%.0f (data %s)"):format(className(best), l.X, l.Y, tostring(dnValid(da))))
        local ok = pcall(function() comp:Event_LaunchBuildMode(da, true, best) end)
        gameDelay(2000, function()
            local tr = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                         Translation = { X = l.X + 300, Y = l.Y, Z = l.Z },
                         Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
            local ok2 = pcall(function() comp:Svr_SpawnBuild(tr) end)
            alog(("movereal: launch=%s spawn=%s"):format(tostring(ok), tostring(ok2)))
            gameDelay(500, function() pcall(function() comp:Event_StopBuildMode() end) end)
        end)
    end
    -- host: what's built near the joiner
    A.cmdBuilds = function()
        local jl
        for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
            if dnValid(p) and not safe(function() return p:IsLocallyControlled() end, true) and dnValid(safe(function() return p.Controller end, nil)) then
                jl = p:K2_GetActorLocation()
            end
        end
        if not jl then alog("builds: no joiner"); return end
        local out = {}
        for _, a in ipairs(safe(function() return FindAllOf("Buildable_MASTER_C") end, nil) or {}) do
            local l = dnValid(a) and safe(function() return a:K2_GetActorLocation() end, nil)
            if l and (l.X - jl.X)^2 + (l.Y - jl.Y)^2 < 2500 * 2500 then
                out[#out + 1] = ("%s@%.0f,%.0f"):format(className(a), l.X, l.Y)
            end
        end
        alog(("builds near the joiner (%d): %s"):format(#out, table.concat(out, " ")))
    end
    A.cmdJig = function()
        local me = myPawn()
        local jig = safe(function() return me.BP_JigMultiplayer end, nil)
        alog("jig: " .. A.jigDump(me))
        for _, n in ipairs({ "MainJigContainers", "LocalJSIContainers", "MainContainersIDs" }) do
            alog(("jig %s: %s"):format(n, tostring(safe(function() return PR.structOf(jig, n) end, "?"))))
        end
    end
    -- dev: commands from a file, for when the keyboard can't reach a window.
    -- sdmp_cmd.txt next to the mod: "host:inv", "host:give", "client:buildreal"
    A.cmdTick = function()
        local c = fread("sdmp_cmd.txt") or ""
        local role, cmd = c:match("^%s*(%a+):(%a+)")
        if not role then return end
        local me = dnIsHost() and "host" or "client"
        if role ~= me then return end
        fwrite("sdmp_cmd.txt", "")
        alog("cmd: " .. cmd)
        local fn = ({ inv = A.cmdInv, buildreal = A.cmdBuildReal, give = A.cmdGive, jig = A.cmdJig, uid = A.cmdUid, movereal = A.cmdMoveReal, builds = A.cmdBuilds, lootprobe = A.cmdLootProbe, lua = A.cmdLua, equipprobe = A.cmdEquipProbe, equipmelee = A.cmdEquipMelee, aimoff = function() A.aimAt = nil end, combattrace = function() A.cbHooks(dnIsHost() and "host" or "client") end })[cmd]
        if not fn then alog("cmd: unknown"); return end
        local ok, err = pcall(fn)
        if not ok then alog("cmd error: " .. tostring(err):sub(1, 300)) end
    end
    gameLoop(1000, function() pcall(A.cmdTick) end)
    RegisterConsoleCommandHandler("sdmp_items", function()
        ExecuteInGameThread(function()
            for _, p in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
                if dnValid(p) then
                    alog(("items: %s local=%s has %s items"):format(className(p), tostring(safe(function() return p:IsLocallyControlled() end, "?")), tostring(PJ.itemCount(p))))
                end
            end
        end)
        return true
    end)
    RegisterConsoleCommandHandler("sdmp_face", function()
        ExecuteInGameThread(function()
            local pc, me = UEHelpers.GetPlayerController(), myPawn()
            local ml = safe(function() return me:K2_GetActorLocation() end, nil)
            local lc = ml and nearestActor(safe(function() return FindAllOf("BP_LootContainer_C") end, nil), ml)
            if not lc then alog("face: nothing"); return end
            local l = lc:K2_GetActorLocation()
            -- step up to it first (this only sticks where we have authority, i.e. on the host)
            local d0 = math.sqrt((l.X-ml.X)^2 + (l.Y-ml.Y)^2)
            if d0 > 140 then
                local dest = { X = l.X + (ml.X - l.X) / d0 * 120, Y = l.Y + (ml.Y - l.Y) / d0 * 120, Z = ml.Z }
                pcall(function() me:K2_TeleportTo(dest, me:K2_GetActorRotation()) end)
                ml = safe(function() return me:K2_GetActorLocation() end, ml)
            end
            local yaw = math.deg(math.atan(l.Y - ml.Y, l.X - ml.X))
            local cam = safe(function() return pc.PlayerCameraManager:GetCameraLocation() end, nil) or { X = ml.X, Y = ml.Y, Z = ml.Z + 80 }
            local hd = math.sqrt((l.X-cam.X)^2 + (l.Y-cam.Y)^2)
            local pitch = math.deg(math.atan((l.Z + 40) - cam.Z, hd))
            local ok = pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0.0 }) end)
            pcall(A.lootHooks)
            alog(("face: %s %.0f away, yaw %.0f -> %s"):format(className(lc), math.sqrt((l.X-ml.X)^2 + (l.Y-ml.Y)^2), yaw, tostring(ok)))
        end)
        return true
    end)
    -- Build test: the joiner places a campfire the way the game does it
    -- (Event_LaunchBuildMode, then Svr_SpawnBuild with the spot) and the host
    -- checks a campfire appeared there.
    A.BUILD_DA = "/Game/Inventory/Items/DataAssets/Buildable/Crafting/DA_Campfire.DA_Campfire"
    local function countNear(cn, l, r)
        local n = 0
        for _, a in ipairs(safe(function() return FindAllOf(cn) end, nil) or {}) do
            local al = dnValid(a) and safe(function() return a:K2_GetActorLocation() end, nil)
            if al and l and (al.X - l.X)^2 + (al.Y - l.Y)^2 < r * r then n = n + 1 end
        end
        return n
    end
    A.buildTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp = z.p
        if z.t == 6 then
            z.cl = safe(function() return cp:K2_GetActorLocation() end, nil)
            z.n0 = countNear("Buildable_Campfire_C", z.cl, 1500)
            alog(("BUILD: %d campfires near the joiner before; hooks in=%s"):format(z.n0, tostring(CS.BD and CS.BD.hooked)))
            fwrite("sdmp_phase.txt", "build1")
        elseif z.t == 16 then
            local l = safe(function() return cp:K2_GetActorLocation() end, nil) or z.cl
            local n = countNear("Buildable_Campfire_C", l, 1500)
            alog(("BUILD RESULT joiner placed a campfire: near the joiner on the host %d -> %d (info from joiner %d, spawn requests %d) -> %s")
                :format(z.n0 or -1, n, CS.BD.rx, CS.BD.built, n > (z.n0 or 0) and "PASS" or "FAIL"))
        elseif z.t == 18 then
            alog("BUILD done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.buildClient = function()
        if A.bc1 or not (fread("sdmp_phase.txt") or ""):find("build1") then return end
        A.bc1 = true
        local me = myPawn()
        local comp = safe(function() return me.BuildingComponent end, nil)
        local da = safe(function() return StaticFindObject(A.BUILD_DA) end, nil)
        if not dnValid(da) then da = safe(function() return LoadAsset(A.BUILD_DA) end, nil) end
        if not (dnValid(comp) and dnValid(da)) then alog(("BUILD(client): comp=%s da=%s"):format(tostring(dnValid(comp)), tostring(dnValid(da)))); return end
        local ws = safe(function() return UEHelpers.GetWorld():K2_GetWorldSettings() end, nil)
        local ok, err = pcall(function() comp:Event_LaunchBuildMode(da, false, ws) end)
        alog(("BUILD(client): build mode for %s -> %s %s"):format(className(da), tostring(ok), tostring(err or ""):sub(1, 100)))
        gameDelay(2000, function()
            local l = me:K2_GetActorLocation()
            local f = me:GetActorForwardVector()
            local tr = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                         Translation = { X = l.X + f.X * 250, Y = l.Y + f.Y * 250, Z = l.Z - 88 },
                         Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
            local ok2, err2 = pcall(function() comp:Svr_SpawnBuild(tr) end)
            alog(("BUILD(client): Svr_SpawnBuild -> %s %s"):format(tostring(ok2), tostring(err2 or ""):sub(1, 100)))
            gameDelay(500, function() pcall(function() comp:Event_StopBuildMode() end) end)
            gameDelay(5000, function()
                local n = countNear("Buildable_Campfire_C", me:K2_GetActorLocation(), 1500)
                alog(("BUILD(client): campfires near me on the joiner's screen: %d"):format(n))
            end)
        end)
    end
    -- Ground pickups. A joiner's F press on an item goes pickup component ->
    -- the player's jig SERVER_RequestAddActorToContainer on the host. The
    -- pickup test drops a campfire kit by the joiner (one forced to replicate,
    -- one left as the game spawns it), has the joiner pick up the replicated
    -- one the way the interact key does, and hooks every step on both sides.
    A.pkHooks = function()
        if A.pkHooked then return end
        A.pkHooked = true
        local function argStr(v)
            local o = safe(function() return v:get() end, v)
            if type(o) == "userdata" then
                local n = safe(function() return o:GetFName():ToString() end, nil)
                if n then return n end
                local tn = safe(function() return o.TagName:ToString() end, nil)
                if tn then return tn end
            end
            return tostring(o):sub(1, 40)
        end
        local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
        local P = "/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C:"
        local list = {
            J .. "SERVER_RequestAddActorToContainer", J .. "SERVER_RequestActorAddStackItem",
            J .. "CLIENT_AddActorToContainerSUCCESS", J .. "CLIENT_RequestAddActorToContainerFAILED",
            J .. "CLIENT_AddStackActorResponse", J .. "SERVER_RequestDropItem", J .. "CLIENT_DropRequestFailed",
            J .. "JigMP_OnPickupAdded", J .. "SERVER_ForwardInteract", J .. "SERVER_RequestMoveItemToAnotherComp",
            P .. "OnExecuteInteract", P .. "OnPickupInteractExecuted", P .. "RequestServerData",
            P .. "OnInteractActorOverDistance", P .. "CheckDistanceFromActor", P .. "IsValidPickup",
        }
        for _, path in ipairs(list) do
            local short = path:match(":(.+)$")
            if dnValid(safe(function() return StaticFindObject(path) end, nil)) then
                local ok, err = pcall(RegisterHook, path, function(ctx, ...)
                    local args = {}
                    for i, v in ipairs({ ... }) do if i <= 5 then args[#args + 1] = argStr(v) end end
                    local who = safe(function() return className(ctx:get():GetOwner()) end, "?")
                    alog(("PKHOOK %s on %s (%s)"):format(short, who, table.concat(args, ", ")))
                end)
                if not ok then alog("PKHOOK " .. short .. " not hooked: " .. tostring(err):sub(1, 80)) end
            else
                alog("PKHOOK " .. short .. " not loaded")
            end
        end
        pcall(function()
            NotifyOnNewObject("/Game/JigSInventory/Jigsaw/Pickup/BP_JigPickupComponent.BP_JigPickupComponent_C", function(o)
                gameDelay(200, function()
                    local a = dnValid(o) and safe(function() return o:GetOwner() end, nil)
                    local l = dnValid(a) and safe(function() return a:K2_GetActorLocation() end, nil)
                    alog(("PKHOOK new pickup %s at %s: %s"):format(dnValid(a) and className(a) or "?",
                        l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?", dnValid(a) and A.pkState(a) or "no owner"))
                end)
            end)
        end)
        alog("PKHOOK hooks in")
    end
    A.pkSpawn = function(near, dx, dy, rep)
        local cls = safe(function() return StaticFindObject(A.GIVE_CLS) end, nil)
        if not dnValid(cls) then
            safe(function() return LoadAsset(A.GIVE_CLS:gsub("_C$", "")) end, nil)
            cls = safe(function() return StaticFindObject(A.GIVE_CLS) end, nil)
        end
        if not dnValid(cls) then return nil, "no class" end
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local l = near:K2_GetActorLocation()
        local tr = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                     Translation = { X = l.X + dx, Y = l.Y + dy, Z = l.Z - 40 },
                     Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
        local a = safe(function() return gs:BeginDeferredActorSpawnFromClass(near, cls, tr, 1, nil, 0) end, nil)
        if not dnValid(a) then return nil, "spawn failed" end
        pcall(function() gs:FinishSpawningActor(a, tr, 0) end)
        local def = safe(function() return a:GetIsReplicated() end, "?")
        if rep then
            pcall(function() a:SetReplicates(true) end)
            pcall(function() a:SetReplicateMovement(true) end)
            pcall(function() a:ForceNetUpdate() end)
        end
        return a, ("replicates by default=%s"):format(tostring(def))
    end
    -- what a pickup actor looks like right now (valid, hidden, picked flags, attached to)
    A.pkState = function(a)
        if not dnValid(a) then return "gone" end
        local c = safe(function() return a.BP_JigPickupComponent end, nil)
        local par = safe(function() return a:GetAttachParentActor() end, nil)
        local l = safe(function() return a:K2_GetActorLocation() end, nil)
        return ("at %s hidden=%s canBePicked=%s canInteract=%s attachedTo=%s owner=%s rep=%s"):format(
            l and ("%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z) or "?",
            tostring(safe(function() return a.bHidden end, "?")),
            tostring(dnValid(c) and safe(function() return c["CanBePicked?"] end, "?") or "nocomp"),
            tostring(dnValid(c) and safe(function() return c["CanInteract?"] end, "?") or "nocomp"),
            dnValid(par) and className(par) or "none",
            className(safe(function() return a:GetOwner() end, nil)),
            tostring(safe(function() return a.bReplicates end, "?")))
    end
    A.pkNames = function(p)
        local out = {}
        local mc = safe(function() return p.BP_JigMultiplayer.MainJigContainers end, nil)
        for i = 1, (mc and #mc or 0) do
            local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
            for j = 1, (items and #items or 0) do
                local it = safe(function() return items[j]:get() end, nil) or items[j]
                local d = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                if dnValid(d) then out[bdPath(d):match("([%w_]+)$") or "?"] = true end
            end
        end
        return out
    end
    A.pkUidOf = function(p, exclude)
        local mc = safe(function() return p.BP_JigMultiplayer.MainJigContainers end, nil)
        local last
        for i = 1, (mc and #mc or 0) do
            local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
            for j = 1, (items and #items or 0) do
                local it = safe(function() return items[j]:get() end, nil) or items[j]
                local g = bdGuid(safe(function() return it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] end, nil) or {})
                local d = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                local nm = dnValid(d) and bdPath(d):match("([%w_]+)$") or "?"
                -- attachments (a gun's loader or magazine) live inside another item, skip them
                if (g.A ~= 0 or g.B ~= 0) and not nm:find("Loader") and not nm:find("Mag") and not nm:find("Scope") and not nm:find("Sight")
                   and not (exclude and exclude[nm]) then
                    last = { g = g, name = nm }
                    if dnValid(d) and dnValid(safe(function() return d.BuildActorClass end, nil)) then return last end
                end
            end
        end
        return last
    end
    A.pkNear = function(l, r)
        local out = {}
        for _, a in ipairs(A.groundPickups()) do
            local al = safe(function() return a:K2_GetActorLocation() end, nil)
            if al and l and (al.X - l.X)^2 + (al.Y - l.Y)^2 < r * r then out[#out + 1] = a end
        end
        return out
    end
    -- dev: list the SteamCore functions a Steam join would use, with their
    -- class paths and parameters, plus any live SteamCore subsystem objects
    A.steamProbe = function()
        local want = { GetSteamID = 1, GetSteamID_Pure = 1, SetRichPresence = 1, ClearRichPresence = 1,
            GetFriendRichPresence = 1, RequestFriendRichPresence = 1, GetFriendCount = 1, GetFriendByIndex = 1,
            GetFriendPersonaName = 1, GetPersonaName = 1, ActivateGameOverlayInviteDialogConnectString = 1,
            ActivateGameOverlayInvitedialog = 1, GetLaunchCommandLine = 1, MakeSteamID = 1, GetSteamIdFromPlayerState = 1,
            CreateLobby = 1, JoinLobby = 1, SetLobbyData = 1, GetLobbyData = 1, GetLobbyOwner = 1 }
        local found, insts = {}, {}
        ForEachUObject(function(o)
            local fn = safe(function() return o:GetFullName() end, "") or ""
            if fn:find("/Script/SteamCore", 1, true) then
                if fn:sub(1, 9) == "Function " then
                    local name = fn:match(":([%w_]+)$")
                    if name and want[name] then found[#found + 1] = fn:sub(10) end
                elseif not fn:find("Default__", 1, true) and not fn:find("^Class ") and not fn:find("^Script") then
                    if #insts < 40 then insts[#insts + 1] = fn end
                end
            end
        end)
        table.sort(found)
        for _, f in ipairs(found) do alog("STEAMFN " .. f .. " (" .. PR.sig(f) .. ")") end
        alog(("STEAM probe: %d functions; SteamCore objects: %s"):format(#found, table.concat(insts, " | "):sub(1, 1500)))
    end
    -- Real key presses for tests: Enhanced Input lets us inject an action the
    -- same way a key does, so the game's own handlers run (scripted calls to
    -- the interact functions skip part of the real path).
    A.IA = "/Game/Input/InventoryPlayerActions/"
    A.inputSub = function()
        for _, o in ipairs(safe(function() return FindAllOf("EnhancedInputLocalPlayerSubsystem") end, nil) or {}) do
            if dnValid(o) and not safe(function() return o:GetFullName() end, ""):find("Default__", 1, true) then return o end
        end
        return nil
    end
    A.press = function(ia, secs, tag)
        local act = safe(function() return StaticFindObject(A.IA .. ia .. "." .. ia) end, nil)
        if not dnValid(act) then act = safe(function() return LoadAsset(A.IA .. ia .. "." .. ia) end, nil) end
        local sub = A.inputSub()
        if not (dnValid(act) and dnValid(sub)) then
            alog(("INJ %s: action=%s subsystem=%s"):format(ia, tostring(dnValid(act)), tostring(dnValid(sub)))); return false
        end
        if not A.injSig then
            A.injSig = true
            local E = "/Script/EnhancedInput.EnhancedInputSubsystemInterface:"
            alog("INJ sig Start: " .. PR.sig(E .. "StartContinuousInputInjectionForAction"))
            alog("INJ sig Inject: " .. PR.sig(E .. "InjectInputForAction"))
        end
        -- FInputActionValue keeps its value in a field Lua can't fill, so use
        -- the vector form and repeat it every frame for as long as the key is held
        if not A.injSig2 then
            A.injSig2 = true
            alog("INJ sig Vector: " .. PR.sig("/Script/EnhancedInput.EnhancedInputSubsystemInterface:InjectInputVectorForAction"))
        end
        local want, n, okAny, lastErr = math.max(1, math.ceil(secs * 1000 / 16)), 0, false, nil
        local function once()
            local ok, err = pcall(function() sub:InjectInputVectorForAction(act, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {}) end)
            n = n + 1
            okAny = okAny or ok
            if not ok then lastErr = err end
        end
        once()
        gameLoop(16, function()
            if n >= want then
                alog(("INJ %s held %.1fs (%s): %d injections, ok=%s %s"):format(ia, secs, tag or "", n, tostring(okAny), tostring(lastErr or ""):sub(1, 100)))
                return true
            end
            once()
        end)
        local ok = true
        return ok
    end
    -- turn the local camera at an actor (host also steps next to it first)
    A.faceActor = function(a, step, zoff)
        local pc, me = UEHelpers.GetPlayerController(), myPawn()
        local l = safe(function() return a:K2_GetActorLocation() end, nil)
        if l and zoff then l = { X = l.X, Y = l.Y, Z = l.Z + zoff } end
        local ml = safe(function() return me:K2_GetActorLocation() end, nil)
        if not (l and ml) then return false end
        local d0 = math.sqrt((l.X - ml.X)^2 + (l.Y - ml.Y)^2)
        if step and d0 > 160 then
            local dest = { X = l.X + (ml.X - l.X) / d0 * 140, Y = l.Y + (ml.Y - l.Y) / d0 * 140, Z = ml.Z }
            pcall(function() me:K2_TeleportTo(dest, me:K2_GetActorRotation()) end)
            ml = safe(function() return me:K2_GetActorLocation() end, ml)
        end
        local cam = safe(function() return pc.PlayerCameraManager:GetCameraLocation() end, nil) or { X = ml.X, Y = ml.Y, Z = ml.Z + 70 }
        local yaw = math.deg(math.atan(l.Y - cam.Y, l.X - cam.X))
        local pitch = math.deg(math.atan(l.Z - cam.Z, math.sqrt((l.X - cam.X)^2 + (l.Y - cam.Y)^2)))
        return pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0.0 }) end)
    end
    -- dev: every loaded function whose name matches one of the patterns
    A.fnProbe = function(pats, tag)
        local found = {}
        ForEachUObject(function(o)
            local fn = safe(function() return o:GetFullName() end, "") or ""
            if fn:sub(1, 9) == "Function " then
                local low = fn:lower()
                for _, p in ipairs(pats) do
                    if low:find(p, 1, true) then found[#found + 1] = fn:sub(10); break end
                end
            end
        end)
        table.sort(found)
        alog(("FNPROBE %s: %d functions"):format(tag or "", #found))
        for i = 1, math.min(#found, 40) do alog("FNPROBE " .. found[i] .. " (" .. PR.sig(found[i]) .. ")") end
    end
    -- dev (file command "lootprobe", run while a loot window is open): find the
    -- Loot All handler and trace every item move and its reply, to see why a
    -- joiner's Loot All only moves one item per press
    A.cmdLootProbe = function()
        if A.ltHooked then alog("LT: already tracing"); return end
        A.ltHooked = true
        local J = "/Game/JigSInventory/Jigsaw/Components/BP_JigMultiplayer.BP_JigMultiplayer_C:"
        local n = 0
        for _, f in ipairs({ "SERVER_RequestMoveItemToAnotherComp", "CLIENT_MoveItemToIndex", "CLIENT_MoveToIndexFailed",
                             "MC_MoveItemToIndex", "MC_ItemRemoved", "CLIENT_ItemRemoved", "CLIENT_NewItemAdded", "MC_NewItemAdded",
                             "CLIENT_AddNewItem", "MC_AddNewItem", "CLIENT_ContainerDataResponse", "SERVER_RequestData",
                             "CLIENT_SwapContainersResponse", "CLIENT_UpdateCounts", "MC_UpdateCounts" }) do
            if dnValid(safe(function() return StaticFindObject(J .. f) end, nil)) then
                local ok = pcall(RegisterHook, J .. f, function(ctx)
                    local who = safe(function() return className(ctx:get():GetOwner()) end, "?")
                    alog(("LT %s on %s"):format(f, who))
                end)
                if ok then n = n + 1 end
            end
        end
        -- (walking every object to find the Loot All handler froze the game
        -- ~2 s; it lives in W_LootContainerUI_C under no "lootall" name)
        alog("LT sig MoveToIndexFailed: " .. PR.sig(J .. "CLIENT_MoveToIndexFailed"))
        alog("LT sig MoveItemToAnotherComp: " .. PR.sig(J .. "SERVER_RequestMoveItemToAnotherComp"))
        -- what each move asks for (host side: the RPC arrives)
        pcall(RegisterHook, J .. "SERVER_RequestMoveItemToAnotherComp", function(ctx, from, to, uid, rot, idx, cont)
            local function o(v) local x = safe(function() return v:get() end, nil); return className(x) end
            local g = bdGuid(safe(function() return uid:get() end, nil) or {})
            local ci = safe(function() return cont:get() end, nil)
            local cs = {}
            pcall(function() ci:GetStruct():ForEachProperty(function(pr) local nm = pr:GetFName():ToString(); cs[#cs + 1] = nm:match("^([%a]+)") .. "=" .. tostring(safe(function() return ci[nm] end, "?")) end) end)
            alog(("LT move %s -> %s item %d index %s container {%s}"):format(o(from), o(to), g.A, tostring(safe(function() return idx:get() end, "?")), table.concat(cs, ",")))
        end)
        pcall(RegisterHook, J .. "CLIENT_MoveToIndexFailed", function(ctx, a1, a2, a3)
            local function v(x) local y = safe(function() return x:get() end, nil); if type(y) == "userdata" then return className(y) end return tostring(y) end
            alog(("LT failed reply: %s %s %s"):format(v(a1), v(a2), v(a3)))
        end)
        alog(("LT: tracing %d functions - press Loot All now"):format(n))
    end
    -- dev: keep the local camera on A.aimAt (tests set it; file command
    -- "aimoff" stops it), so a real key held by hand hits the right thing
    gameLoop(100, function()
        if A.aimAt and dnValid(A.aimAt) then pcall(A.faceActor, A.aimAt, false, 60) end
    end)
    -- loot test: switch the Loot All trace on by itself as soon as the loot
    -- window's code has loaded (it loads the first time a window opens)
    A.ltAuto = function()
        if A.ltHooked then return end
        A.ltN = (A.ltN or 0) + 1
        if A.ltN % 3 ~= 0 then return end
        local hit = false
        ForEachUObject(function(o)
            if hit then return end
            local fn = safe(function() return o:GetFullName() end, "") or ""
            if fn:sub(1, 9) == "Function " and fn:lower():find("lootall", 1, true) then hit = true end
        end)
        if hit then alog("LT: loot window code is loaded - tracing"); pcall(A.cmdLootProbe) end
    end
    -- Steam helpers (SteamCore is linked into the game). Its classes are
    -- either subsystems (find the live instance) or static libraries (call the
    -- class default object); try the instance first.
    A.steamObj = function(cls)
        for _, o in ipairs(safe(function() return FindAllOf(cls) end, nil) or {}) do
            if dnValid(o) and not safe(function() return o:GetFullName() end, ""):find("Default__", 1, true)
               and safe(function() return o:GetFullName() end, ""):find("/Script/SteamCore", 1, true) == nil then return o end
        end
        return safe(function() return StaticFindObject("/Script/SteamCore.Default__" .. cls) end, nil)
    end
    -- Steam joining. SteamCore's Steam-id struct has no fields Lua can see,
    -- so anything that takes a Steam id comes through blank. What works: the
    -- host's own id from Steam's loginusers.vdf, rich presence (plain
    -- strings) and the invite dialog with a connect string. A friend who
    -- clicks Join Game or accepts the invite gets their game started with
    -- "+sdmpjoin=steam.<id>", which boot() picks up. Steam's own P2P relay
    -- carries the game (SteamSocketsNetDriver), so no port forwarding.
    A.steamUp = function()
        local fr = A.steamObj("Friends")
        local n = dnValid(fr) and safe(function() return fr:GetPersonaName():ToString() end, "") or ""
        return #n > 0, n
    end
    A.mySteamId = function()
        if A.steamId64 then return A.steamId64 end
        local up, persona = A.steamUp()
        if not up then return nil, "Steam isn't running for this game (start it from Steam)" end
        local roots = {}
        local lib = pjDir():match("^(.-)[/\\][Ss]team[Aa]pps[/\\]")
        if lib then roots[#roots + 1] = lib end
        roots[#roots + 1] = "C:\\Program Files (x86)\\Steam"
        roots[#roots + 1] = "C:\\Program Files\\Steam"
        for _, root in ipairs(roots) do
            local f = io.open(root .. "\\config\\loginusers.vdf", "r")
            if f then
                local txt = f:read("*a") or ""
                f:close()
                local byName, recent
                for id, body in txt:gmatch('"(7656119%d+)"%s*(%b{})') do
                    if body:match('"PersonaName"%s*"([^"]*)"') == persona then byName = id end
                    if body:match('"MostRecent"%s*"1"') then recent = id end
                end
                if byName or recent then A.steamId64 = byName or recent; return A.steamId64 end
            end
        end
        return nil, "couldn't find your Steam id in loginusers.vdf"
    end
    A.steamHost = function()
        local id, why = A.mySteamId()
        if not id then alog("STEAM: can't host over Steam - " .. tostring(why)); return false end
        local fr = A.steamObj("Friends")
        A.steamConnect = "+sdmpjoin=steam." .. id
        local ok1 = safe(function() return fr:SetRichPresence("connect", A.steamConnect) end, false)
        local ok2 = safe(function() return fr:SetRichPresence("status", "Hosting co-op") end, false)
        alog(("STEAM: hosting as Steam id ...%s, Join Game on -> %s %s"):format(id:sub(-4), tostring(ok1), tostring(ok2)))
        return ok1 == true
    end
    A.steamInvite = function()
        if A.role ~= "host" or not A.steamConnect then log("SDMP: F9 invites friends while you host over Steam"); return end
        local fr = A.steamObj("Friends")
        local ok = pcall(function() fr:ActivateGameOverlayInviteDialogConnectString(A.steamConnect) end)
        log("STEAM: invite dialog -> " .. tostring(ok))
    end
    A.steamProbe2 = function()
        local fr, us = A.steamObj("Friends"), A.steamObj("User")
        alog(("STEAM2 Friends=%s User=%s"):format(dnValid(fr) and fr:GetFullName() or "none", dnValid(us) and us:GetFullName() or "none"))
        local function str(v) return safe(function() return v:ToString() end, nil) or tostring(v) end
        local ok, id = pcall(function() return us:GetSteamID() end)
        local keys = {}
        if type(id) == "table" then for k, v in pairs(id) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end end
        alog(("STEAM2 GetSteamID -> %s %s {%s}"):format(tostring(ok), type(id), table.concat(keys, ",")))
        A.myId = id
        local pn = str(safe(function() return fr:GetPersonaName() end, ""))
        alog(("STEAM2 persona name length %d"):format(#(pn or "")))
        local ok1, r1 = pcall(function() return fr:SetRichPresence("status", "Testing co-op") end)
        local ok1b, r1b = pcall(function() return fr:SetRichPresence("sdmp_host", "test") end)
        local ok2, r2 = pcall(function() return fr:GetFriendRichPresence(id, "sdmp_host") end)
        alog(("STEAM2 rich presence status -> %s %s, sdmp_host -> %s %s; read back on self -> %s '%s'"):format(
            tostring(ok1), tostring(r1), tostring(ok1b), tostring(r1b), tostring(ok2), str(r2)))
        pcall(function() fr:ClearRichPresence() end)
        for _, flags in ipairs({ { 3 }, { 11 } }) do
            local okc, n = pcall(function() return fr:GetFriendCount(flags) end)
            alog(("STEAM2 GetFriendCount({%s}) -> %s %s"):format(table.concat(flags, ","), tostring(okc), tostring(n)))
        end
        local eng = UEHelpers.GetEngine()
        local defs = safe(function() return eng.NetDriverDefinitions end, nil)
        for i = 1, (defs and #defs or 0) do
            alog(("STEAM2 net driver %s = %s (fallback %s)"):format(
                tostring(safe(function() return defs[i].DefName:ToString() end, "?")),
                tostring(safe(function() return defs[i].DriverClassName:ToString() end, "?")),
                tostring(safe(function() return defs[i].DriverClassNameFallback:ToString() end, "?"))))
        end
    end
    -- Steam test (game started through Steam): can an id struct survive a trip
    -- through Lua, does rich presence work, and does the host listen on Steam
    A.steamProbe3 = function()
        local function str(v) return safe(function() return v:ToString() end, nil) or tostring(v) end
        local fr, us = A.steamObj("Friends"), A.steamObj("User")
        local su = safe(function() return StaticFindObject("/Script/SteamCore.Default__SteamUtilities") end, nil)
        alog(("STEAM3 objects: friends=%s user=%s utilities=%s"):format(tostring(dnValid(fr)), tostring(dnValid(us)), tostring(dnValid(su))))
        alog("STEAM3 persona name length " .. #(str(safe(function() return fr:GetPersonaName() end, "")) or ""))
        local id = safe(function() return us:GetSteamID() end, nil)
        local keys = {}
        if type(id) == "table" then for k in pairs(id) do keys[#keys + 1] = tostring(k) end end
        alog(("STEAM3 GetSteamID -> %s {%s}"):format(type(id), table.concat(keys, ",")))
        pcall(function()
            local st = StaticFindObject("/Script/SteamCore.SteamID")
            local f = {}
            st:ForEachProperty(function(pr) f[#f + 1] = pr:GetFName():ToString() .. ":" .. pr:GetClass():GetFName():ToString() end)
            alog("STEAM3 FSteamID reflected fields: " .. (#f > 0 and table.concat(f, ", ") or "none"))
        end)
        alog("STEAM3 BreakSteamID sig: " .. PR.sig("/Script/SteamCore.SteamUtilities:BreakSteamID"))
        local okb, br = pcall(function() return su:BreakSteamID(id) end)
        local bs = okb and str(br) or nil
        alog(("STEAM3 BreakSteamID -> %s %s, digits=%d"):format(tostring(okb), type(br), bs and #(bs:gsub("%D", "")) or -1))
        local okr = safe(function() return fr:SetRichPresence("sdmp_test", "roundtrip") end, "err")
        alog("STEAM3 SetRichPresence -> " .. tostring(okr))
        local back1 = str(safe(function() return fr:GetFriendRichPresence(id, "sdmp_test") end, "err"))
        alog("STEAM3 read back through GetSteamID's struct -> '" .. tostring(back1) .. "'")
        if bs and #bs > 5 then
            local mk = safe(function() return su:MakeSteamID(bs) end, nil)
            local back2 = str(safe(function() return fr:GetFriendRichPresence(mk, "sdmp_test") end, "err"))
            alog("STEAM3 read back through MakeSteamID(BreakSteamID) -> '" .. tostring(back2) .. "'")
        end
        local nf = safe(function() return fr:GetFriendCount({ 3 }) end, -1)
        alog("STEAM3 friends: " .. tostring(nf))
        if (tonumber(nf) or 0) > 0 then
            local f0 = safe(function() return fr:GetFriendByIndex(0, { 3 }) end, nil)
            local nm = str(safe(function() return fr:GetFriendPersonaName(f0) end, ""))
            alog(("STEAM3 first friend's name through the struct: length %d"):format(#(nm or "")))
        end
        local sid, why = A.mySteamId()
        alog(("STEAM3 own Steam id from loginusers.vdf: %s"):format(sid and ("found, 17 digits=" .. tostring(#sid == 17) .. ", ends " .. sid:sub(-4)) or tostring(why)))
        local okH, hosted = pcall(A.steamHost)
        alog(("STEAM3 Join Game set up -> %s %s (%s)"):format(tostring(okH), tostring(hosted), tostring(A.steamConnect and A.steamConnect:gsub("%d%d%d%d%d%d%d%d%d%d%d%d%d", "...") or "-")))
        local nd = safe(function() return UEHelpers.GetWorld().NetDriver end, nil)
        alog("STEAM3 host net driver: " .. (dnValid(nd) and className(nd) or "none"))
    end
    -- dev, test runs only (-sdmpauto): "lua" file command runs the code in
    -- sdmp_lua.txt next to the mod, so probes don't need a game restart.
    -- The chunk gets A, CS, BD, PR, PJ, alog, safe, dnValid, className,
    -- myPawn, gameDelay, bdGuid, bdPath through its environment.
    A.cmdLua = function()
        if not A.auto then alog("lua: only in test runs"); return end
        local src = fread("sdmp_lua.txt")
        if not src or src == "" then alog("lua: sdmp_lua.txt is empty"); return end
        local env = setmetatable({ A = A, CS = CS, BD = BD, PR = PR, PJ = PJ, alog = alog, safe = safe, dnValid = dnValid,
            className = className, myPawn = myPawn, gameDelay = gameDelay, bdGuid = bdGuid, bdPath = bdPath }, { __index = _G })
        local fn, err = load(src, "sdmp_lua", "t", env)
        if not fn then alog("lua: compile error " .. tostring(err)); return end
        local ok, res = pcall(fn)
        alog("lua: " .. (ok and ("ok " .. tostring(res)) or ("error " .. tostring(res))):sub(1, 1500))
    end
    -- dev (file command "equipprobe"): hook every equip / slot / hotbar /
    -- fire / melee function on the player character, to see which ones a
    -- real key press runs on a joiner
    A.cmdEquipProbe = function()
        if A.eqHooked then alog("EQ: already tracing"); return end
        A.eqHooked = true
        local P = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C"
        local cls = StaticFindObject(P)
        local n, names = 0, {}
        cls:ForEachFunction(function(fn)
            local nm = fn:GetFName():ToString()
            local low = nm:lower()
            if (low:find("equip") or low:find("activeslot") or low:find("hotbar") or low:find("fire") or low:find("melee")
                or low:find("shoot") or low:find("attack") or low:find("weapon")) and not low:find("ubergraph") then
                names[#names + 1] = nm
                if pcall(RegisterHook, P .. ":" .. nm, function(ctx)
                    local me = safe(function() return ctx:get() end, nil)
                    A.eqCount = A.eqCount or {}
                    A.eqCount[nm] = (A.eqCount[nm] or 0) + 1
                    if A.eqCount[nm] <= 6 then
                        alog(("EQ %s (%s pawn) #%d"):format(nm, safe(function() return me:IsLocallyControlled() end, false) and "my" or "other", A.eqCount[nm]))
                    end
                end) then n = n + 1 end
            end
        end)
        alog(("EQ: hooked %d: %s"):format(n, table.concat(names, " "):sub(1, 1500)))
        alog("EQ sig SERVER_ChangeActiveSlot: " .. PR.sig(P .. ":SERVER_ChangeActiveSlot"))
        alog("EQ sig ServerFuncChangeActiveSlot: " .. PR.sig(P .. ":ServerFuncChangeActiveSlot"))
    end
    -- dev (file command "equipmelee"): ask the server to put the melee slot in hand
    A.cmdEquipMelee = function()
        local me = myPawn()
        for _, tag in ipairs({ "Jig.PlayerSlot.MeleeWeapon", "Jig.PlayerSlot.Melee" }) do
            local ok, err = pcall(function() me:SERVER_ChangeActiveSlot({ TagName = FName(tag) }) end)
            alog(("EQ: SERVER_ChangeActiveSlot(%s) -> %s %s"):format(tag, tostring(ok), tostring(err or ""):sub(1, 100)))
        end
        gameDelay(2000, function()
            local w = safe(function() return me:GetCurrentActiveWeapon() end, nil)
            alog("EQ: weapon in hand now: " .. (type(w) == "userdata" and className(w) or tostring(w)))
        end)
    end
    -- ------------------------------------------------------------- combat
    -- Network functions (RPCs) of a class and its parents, with direction.
    A.netFns = function(path)
        local cls = safe(function() return StaticFindObject(path) end, nil)
        if not dnValid(cls) then return nil end
        local out = {}
        local c, depth = cls, 0
        while dnValid(c) and depth < 6 do
            local cn = safe(function() return c:GetFName():ToString() end, "?")
            if cn:find("^Actor$") or cn:find("^Pawn$") or cn:find("^Character$") or cn:find("^Object$") then break end
            pcall(function() c:ForEachFunction(function(fn)
                local fl = safe(function() return fn:GetFunctionFlags() end, 0) or 0
                if fl & 0x40 ~= 0 then
                    local kind = (fl & 0x200000 ~= 0) and "server" or (fl & 0x1000000 ~= 0) and "client" or (fl & 0x4000 ~= 0) and "multicast" or "net"
                    out[#out + 1] = { name = fn:GetFName():ToString(), kind = kind, path = c:GetFullName():match("%s(%S+)$") .. ":" .. fn:GetFName():ToString(),
                                      reliable = fl & 0x80 ~= 0 }
                end
            end) end)
            c = safe(function() return c:GetSuperStruct() end, nil)
            depth = depth + 1
        end
        return out
    end
    A.CB_CLASSES = {
        "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C",
        "/Game/Inventory/Items/Pickups/Weapons/Firearms/BP_FirearmPickup.BP_FirearmPickup_C",
        "/Game/Inventory/Items/Pickups/Weapons/Melee/BP_MeleePickup.BP_MeleePickup_C",
        "/Game/Inventory/Items/Other/Components/BP_WeaponsPickupComponent.BP_WeaponsPickupComponent_C",
        "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C",
    }
    -- noisy every-frame RPCs: count them, don't log them
    A.CB_QUIET = { Grass = true, Svr_ReduceStamina = true, Client_UpdateStaminaUI = true, Svr_SetMovement = true, Svr_FlashlightRotation = true,
                   MC_FlashlightRotation = true, Svr_SetActorRotation = true, Svr_UpdateSpeed = true, MC_UpdateSpeed = true,
                   Client_UpdateHungerUI = true, Client_UpdateThirstUI = true, Client_UpdateHealthUI = true, Client_UpdateRadiationUI = true,
                   Client_UpdateOxygenUI = true, MC_AttachClothing = true }
    A.cbCount = {}
    A.cbHooks = function(tag)
        if A.cbHooked then return end
        A.cbHooked = true
        local n = 0
        for _, path in ipairs(A.CB_CLASSES) do
            local fns = A.netFns(path)
            if not fns then alog(("CB %s: %s not loaded"):format(tag, path:match("([%w_]+)$")))
            else
                local names = {}
                for _, f in ipairs(fns) do
                    names[#names + 1] = f.name .. "(" .. f.kind:sub(1, 1) .. (f.reliable and "R" or "") .. ")"
                    if not A.CB_QUIET[f.name] then
                        local ok = pcall(RegisterHook, f.path, function(ctx)
                            A.cbCount[f.name] = (A.cbCount[f.name] or 0) + 1
                            if A.cbCount[f.name] <= 4 then
                                local o = safe(function() return ctx:get() end, nil)
                                local own = dnValid(o) and safe(function() return o:GetOwner() end, nil)
                                alog(("CBRPC %s %s on %s (owner %s) #%d"):format(f.kind, f.name, className(o), className(own), A.cbCount[f.name]))
                            end
                        end)
                        if ok then n = n + 1 end
                    end
                end
                alog(("CB %s: %s rpcs: %s"):format(tag, path:match("([%w_]+)$"), table.concat(names, " ")))
            end
        end
        -- every damage call, both sides
        local function dmgLog(kind, damaged, dmg, causer, inst)
            local t = safe(function() return damaged:get() end, nil)
            local tn = className(t)
            if not (tn:find("Zombie") or tn:find("Player") or tn:find("Infected") or tn:find("Bandit")) then return end
            A.cbCount["dmg"] = (A.cbCount["dmg"] or 0) + 1
            if A.cbCount["dmg"] > 40 then return end
            local c = safe(function() return causer:get() end, nil)
            local i = safe(function() return inst:get() end, nil)
            local ic = dnValid(i) and safe(function() return i.Pawn end, nil)
            local function side(a) if not dnValid(a) then return "" end return safe(function() return a:IsLocallyControlled() end, false) and "(local)" or "(remote)" end
            alog(("CBDMG %s %s %.1f to %s, causer %s owner %s, instigator %s %s"):format(tag, kind,
                tonumber(safe(function() return dmg:get() end, -1)) or -1, tn, className(c),
                className(dnValid(c) and safe(function() return c:GetOwner() end, nil) or nil), className(ic), side(ic)))
        end
        pcall(RegisterHook, "/Script/Engine.GameplayStatics:ApplyDamage", function(ctx, damaged, dmg, inst, causer) pcall(dmgLog, "ApplyDamage", damaged, dmg, causer, inst) end)
        pcall(RegisterHook, "/Script/Engine.GameplayStatics:ApplyPointDamage", function(ctx, damaged, dmg, dir, hit, inst, causer) pcall(dmgLog, "ApplyPointDamage", damaged, dmg, causer, inst) end)
        pcall(RegisterHook, "/Script/Engine.GameplayStatics:ApplyRadialDamage", function(ctx) alog("CBDMG " .. tag .. " ApplyRadialDamage") end)
        -- XP: who gets it
        for _, f in ipairs({ "/Game/AI/Zombies/BP_MasterZombie.BP_MasterZombie_C:Event_XP" }) do
            pcall(RegisterHook, f, function(ctx) alog("CBXP " .. tag .. " zombie Event_XP") end)
        end
        alog(("CB %s: hooked %d rpcs + damage"):format(tag, n))
    end
    A.zHealth = function(zb)
        local dc = safe(function() return zb.DamageComponent end, nil)
        local h = dnValid(dc) and safe(function() return dc.CurrentHealth end, nil)
        local dead = safe(function() return zb["IsDead?"] end, nil)
        return tonumber(h) or -1, dead
    end
    A.xpOf = function(p)
        local lc = safe(function() return p.LevellingComponent end, nil)
        return dnValid(lc) and (tonumber(safe(function() return lc.CurrentXP end, -1)) or -1) or -1,
               dnValid(lc) and (tonumber(safe(function() return lc.CurrentLevel end, -1)) or -1) or -1
    end
    A.cbTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp, hp = z.p, myPawn()
        z.ph = z.ph or "wait"
        if z.t == 2 then
            pcall(A.cbHooks, "host")
            pcall(A.cmdEquipProbe)
            pcall(function() cp.bCanBeDamaged = false end)   -- the joiner mustn't die mid-test
        end
        local pid = PJ.idOf(cp)
        local loaded = not PJ.enabled or not pid or (PJ.st[pid] and PJ.st[pid].ready)
        if z.ph == "wait" and z.t >= 12 and (loaded or z.t >= 60) then
            -- arm the joiner: the host stands next to it and drops its weapons and ammo.
            -- Only after the joiner's save has loaded - the load replaces whatever
            -- they picked up before it (and picking up mid-load emptied them once).
            local cl = cp:K2_GetActorLocation()
            pcall(function() hp:K2_TeleportTo({ X = cl.X + 150, Y = cl.Y, Z = cl.Z + 30 }, hp:K2_GetActorRotation()) end)
            local jig = hp.BP_JigMultiplayer
            local mc = safe(function() return jig.MainJigContainers end, nil)
            local drops = {}
            for i = 1, (mc and #mc or 0) do
                local items = safe(function() return mc[i]["ContainerItems_16_16E3D87B4C0AC5D6C9C861B96B5ABA8B"] end, nil)
                for j = 1, (items and #items or 0) do
                    local it = safe(function() return items[j]:get() end, nil) or items[j]
                    local d = safe(function() return it["ItemInfo_25_937A083B4BD3D9B590E0A69C76A4F6F7"]["ItemID_28_01CA27D84AF7D1014D9E2E83894C1848"] end, nil)
                    local path = dnValid(d) and bdPath(d) or ""
                    if (path:find("/Weapons/") or path:find("Ammo")) and not path:find("Loader") and not path:find("Mag") and #drops < 6 then
                        drops[#drops + 1] = { g = bdGuid(safe(function() return it["UniqueServerID_37_C49AE0DA449ACAE3BE4633A263303B68"] end, nil) or {}), name = path:match("([%w_]+)$") }
                    end
                end
            end
            for _, d in ipairs(drops) do pcall(function() jig:SERVER_RequestDropItem(d.g, 1, jig) end) end
            local names = {}
            for _, d in ipairs(drops) do names[#names + 1] = d.name end
            -- and fresh ones from the item classes, in case the host has none left
            local W = "/Game/Inventory/Items/Pickups/"
            for i, cp2 in ipairs({ W .. "Weapons/Melee/2Handed/BP_BaseballBatPickup.BP_BaseballBatPickup_C",
                                   W .. "Weapons/Firearms/Sidearm/BP_M9Pickup.BP_M9Pickup_C",
                                   W .. "Attachments/Ammo/BP_9mmAmmoPickup.BP_9mmAmmoPickup_C" }) do
                A.GIVE_CLS = cp2
                local a = A.pkSpawn(cp, 60 * i - 120, 90, true)
                names[#names + 1] = cp2:match("([%w_]+)$") .. (dnValid(a) and "(spawned)" or "(spawn failed)")
            end
            alog("CB: host drops for the joiner: " .. (#names > 0 and table.concat(names, ", ") or "nothing (no weapons)"))
            z.ph, z.tp = "arming", z.t
        elseif z.ph == "arming" and z.t == z.tp + 3 then
            fwrite("sdmp_phase.txt", "arm")
        elseif z.ph == "arming" and z.t >= z.tp + 14 then
            local cl = cp:K2_GetActorLocation()
            local best, bd = nil, 1e18
            for _, a in ipairs(safe(function() return FindAllOf("BP_MasterZombie_C") end, nil) or {}) do
                if dnValid(a) and not safe(function() return a["IsDead?"] end, false) then
                    local l = a:K2_GetActorLocation()
                    local d = (l.X - cl.X)^2 + (l.Y - cl.Y)^2
                    if d < bd then best, bd = a, d end
                end
            end
            if not best then alog("CB: no live zombie loaded"); z.ph, z.tp = "end", z.t; return end
            z.zb = best
            -- bring it in front of the joiner and hold it there
            local f = cp:GetActorForwardVector()
            z.spot = { X = cl.X + f.X * 150, Y = cl.Y + f.Y * 150, Z = cl.Z }
            pcall(function() best:K2_TeleportTo(z.spot, best:K2_GetActorRotation()) end)
            pcall(function() best.CustomTimeDilation = 0.001 end)
            z.h0 = A.zHealth(best)
            z.hx0, z.cx0 = A.xpOf(hp), A.xpOf(cp)
            alog(("CB: zombie %s (%.0f away) held in front of the joiner, health %.1f; XP host %.0f joiner %.0f")
                :format(className(best), math.sqrt(bd), z.h0, z.hx0, z.cx0))
            local l = best:K2_GetActorLocation()
            fwrite("sdmp_phase.txt", ("combat:%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z))
            z.ph, z.tp = "fighting", z.t
        elseif z.ph == "fighting" then
            if dnValid(z.zb) and z.spot then pcall(function() z.zb:K2_TeleportTo(z.spot, z.zb:K2_GetActorRotation()) end) end
            if (z.t - z.tp) % 4 == 0 then
                local h, dead = A.zHealth(z.zb)
                alog(("CB: zombie health %.1f dead=%s"):format(h, tostring(dead)))
            end
            if z.t == z.tp + 75 then
                local h, dead = A.zHealth(z.zb)
                local hx, cx = A.xpOf(hp), A.xpOf(cp)
                alog(("CB RESULT joiner hurts a zombie: health %.1f -> %.1f dead=%s -> %s"):format(z.h0, h, tostring(dead),
                    (h < z.h0 or dead == true or not dnValid(z.zb)) and "PASS" or "FAIL"))
                alog(("CB RESULT xp: host %.0f -> %.0f, joiner %.0f -> %.0f"):format(z.hx0, hx, z.cx0, cx))
                local c = {}
                for k, v in pairs(A.cbCount) do c[#c + 1] = k .. "=" .. v end
                table.sort(c)
                alog("CB host rpc counts: " .. table.concat(c, " "))
                z.ph, z.tp = "end", z.t
            end
        elseif z.ph == "end" and z.t == z.tp + 4 then
            alog("CB done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    -- vehicle test: the host parks the nearest vehicle beside the joiner, the
    -- joiner gets in, "holds" W for 5 s (D for the last 2), lets go, gets out.
    -- PASS = the host's copy of the car moved while the joiner drove it and
    -- the joiner ended up back on foot next to it.
    A.vhTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp = z.p
        z.ph = z.ph or "wait"
        if z.t == 2 then pcall(function() cp.bCanBeDamaged = false end) end
        local pid = PJ.idOf(cp)
        local loaded = not PJ.enabled or not pid or (PJ.st[pid] and PJ.st[pid].ready)
        if z.ph == "wait" and z.t >= 12 and (loaded or z.t >= 60) then
            local cl = cp:K2_GetActorLocation()
            local best, bd = nil, 1e18
            for _, v in ipairs(safe(function() return FindAllOf("BP_VehicleMaster_C") end, nil) or {}) do
                local l = dnValid(v) and safe(function() return v:K2_GetActorLocation() end, nil)
                if l then
                    local d = (l.X - cl.X)^2 + (l.Y - cl.Y)^2
                    if d < bd then best, bd = v, d end
                end
            end
            if not best then alog("VT: no vehicle loaded"); z.ph, z.tp = "end", z.t; return end
            local r = cp:GetActorRightVector()
            local spot = { X = cl.X + r.X * 400, Y = cl.Y + r.Y * 400, Z = cl.Z + 60 }
            pcall(function() best:K2_TeleportTo(spot, cp:K2_GetActorRotation()) end)
            z.v = best
            alog(("VT: parked %s (was %.0f away) beside the joiner"):format(className(best), math.sqrt(bd)))
            z.ph, z.tp = "parked", z.t
        elseif z.ph == "parked" and z.t == z.tp + 4 then
            local l = z.v:K2_GetActorLocation()
            z.l0 = l
            fwrite("sdmp_phase.txt", ("veh:%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z))
            z.ph, z.tp = "driving", z.t
        elseif z.ph == "driving" then
            local seat = BD.vh.seat[cp:GetAddress()]
            if seat and not z.seated then z.seated, z.ls = true, z.v:K2_GetActorLocation() end
            if seat == nil and z.seated and not z.out then z.out = true end
            if (z.t - z.tp) % 4 == 0 then
                local l = z.v:K2_GetActorLocation()
                local pl = cp:K2_GetActorLocation()
                local par = safe(function() return cp:GetAttachParentActor() end, nil)
                alog(("VT: car at %.0f,%.0f speed %.0f | joiner seated=%s attached=%s %.0f from car | inputs %d")
                    :format(l.X, l.Y, safe(function() return z.v:GetVelocity():Size() end, -1) or -1, tostring(seat ~= nil),
                        tostring(dnValid(par)), math.sqrt((pl.X - l.X)^2 + (pl.Y - l.Y)^2), BD.vh.inputs or 0))
            end
            if z.t == z.tp + 60 then
                local l = z.v:K2_GetActorLocation()
                local l0 = z.ls or z.l0
                local moved = math.sqrt((l.X - l0.X)^2 + (l.Y - l0.Y)^2)
                local pl = cp:K2_GetActorLocation()
                local near = math.sqrt((pl.X - l.X)^2 + (pl.Y - l.Y)^2)
                alog(("VT RESULT joiner drives: seated=%s, car moved %.0f, %d inputs -> %s"):format(tostring(z.seated == true), moved,
                    BD.vh.inputs or 0, (z.seated and moved > 500) and "PASS" or "FAIL"))
                alog(("VT RESULT joiner gets out: out=%s, %.0f from the car -> %s"):format(tostring(z.out == true), near,
                    (z.out and near < 800) and "PASS" or "FAIL"))
                z.ph, z.tp = "end", z.t
            end
        elseif z.ph == "end" and z.t == z.tp + 4 then
            alog("VT done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    -- skills test: does a joiner take damage through its OWN Toughness, does
    -- the XP for it reach the joiner (not the host), does the tree sync
    A.skTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp, hp = z.p, myPawn()
        z.ph = z.ph or "wait"
        if z.t == 2 then pcall(function() cp.bCanBeDamaged = false end) end
        local pid = PJ.idOf(cp)
        local loaded = not PJ.enabled or not pid or (PJ.st[pid] and PJ.st[pid].ready)
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local hpc = safe(function() return hp.Controller end, nil)
        local jpc = safe(function() return cp.Controller end, nil)
        local hs, js = PK.compOf(hpc, "PassiveSkillsComponent_C"), PK.compOf(jpc, "PassiveSkillsComponent_C")
        local function hit(n)
            pcall(function() cp.bCanBeDamaged = true end)
            local h0 = cp.MedicalComponent.Health
            pcall(function() gs:ApplyDamage(cp, n, nil, nil, nil) end)
            local h1 = cp.MedicalComponent.Health
            pcall(function() cp.MedicalComponent.Health = h0 end)
            pcall(function() cp.bCanBeDamaged = false end)
            return h0 - h1
        end
        if z.ph == "wait" and z.t >= 12 and ((loaded and PK.applied > 0) or z.t >= 60) then
            if not (hs and js) then alog("SK: can't find the passive skills components"); z.ph, z.tp = "end", z.t; return end
            z.jt = js.ToughnessMultiplier
            z.ht = hs.ToughnessMultiplier
            alog(("SK: %d joiner skill fields applied, redirects so far %d; toughness host %.2f joiner %.2f"):format(PK.applied, PK.redir, z.ht, z.jt))
            hs.ToughnessMultiplier = 0.25
            local took = hit(10.0)
            hs.ToughnessMultiplier = z.ht
            local want = 10.0 / (z.jt ~= 0 and z.jt or 1)
            alog(("SK RESULT joiner's own toughness: 10 dmg took %.2f (own %.2f, host's would be %.2f) -> %s"):format(took, want, 10.0 / 0.25,
                math.abs(took - want) < 0.6 and "PASS" or "FAIL"))
            z.hx0 = hs.CurrentToughessXP
            z.sent0 = PK.xpSent
            for _ = 1, 3 do hit(10.0) end
            z.ph, z.tp = "xp", z.t
        elseif z.ph == "xp" and z.t == z.tp + 2 then
            z.jx0 = js.CurrentToughessXP   -- after the host-side add, before the joiner's numbers come back
        elseif z.ph == "xp" and z.t == z.tp + 16 then
            alog(("SK RESULT toughness XP: host's own %.2f -> %.2f, %d XP message(s) sent down, joiner now %.2f -> %s"):format(z.hx0,
                hs.CurrentToughessXP, PK.xpSent - z.sent0, js.CurrentToughessXP,
                (math.abs(hs.CurrentToughessXP - z.hx0) < 0.01 and PK.xpSent > z.sent0) and "PASS" or "FAIL"))
            local tt = PK.compOf(jpc, "TechTreeComponent_C")
            alog("SK: joiner's tree on the host usable=" .. tostring(PK.treeOk(tt)) .. ", redirects " .. PK.redir)
            z.ph, z.tp = "end", z.t
        elseif z.ph == "end" and z.t == z.tp + 4 then
            alog("SK done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.vhClient = function()
        if A.vc1 then return end
        local ph = fread("sdmp_phase.txt") or ""
        if not ph:find("^veh:") then return end
        A.vc1 = true
        local x, y, zz = ph:match("veh:(%-?%d+),(%-?%d+),(%-?%d+)")
        local at = { X = tonumber(x), Y = tonumber(y), Z = tonumber(zz) }
        local v = nearestActor(safe(function() return FindAllOf("BP_VehicleMaster_C") end, nil), at)
        local me = myPawn()
        if not dnValid(v) then alog("VT(client): can't see the car"); return end
        A.aimAt = v
        -- the way F does it first; straight to the get-in function if that didn't
        local ok = pcall(function() v:OnExecuteInteract(me, { TagName = FName("Jig.InteractOptions.Option1") }) end)
        alog("VT(client): interact with " .. className(v) .. " -> " .. tostring(ok))
        gameDelay(1500, function()
            A.aimAt = nil
            if not BD.vh.mine then
                local ok2, e2 = pcall(function() v:Interact_GetInVehicle() end)
                alog("VT(client): interact didn't seat me - Interact_GetInVehicle -> " .. tostring(ok2) .. " " .. tostring(e2 or ""):sub(1, 100))
            end
            local t0 = os.clock()
            gameLoop(50, function()
                local s = os.clock() - t0
                if s < 5 then
                    BD.vh.keys.MoveForward = os.clock()
                    if s > 3 then BD.vh.keys.MoveRight = os.clock() end
                    return false
                end
                return true
            end)
            gameDelay(8000, function()
                local l = safe(function() return v:K2_GetActorLocation() end, at)
                alog(("VT(client): car moved %.0f on my screen - getting out"):format(math.sqrt((l.X - at.X)^2 + (l.Y - at.Y)^2)))
                local ok3, e3 = pcall(function() v:ExitVehicle({}) end)
                alog("VT(client): ExitVehicle -> " .. tostring(ok3) .. " " .. tostring(e3 or ""):sub(1, 100))
            end)
        end)
    end
    -- joiner: try every way the game might start an attack, 4 s apart
    A.cbClient = function()
        local ph = fread("sdmp_phase.txt") or ""
        if A.cc1 then return end
        if not A.cbHooked then pcall(A.cbHooks, "client"); pcall(A.cmdEquipProbe) end
        if ph == "arm" and not A.ccArm then
            A.ccArm = true
            local me = myPawn()
            local list = A.pkNear(me:K2_GetActorLocation(), 500)
            alog(("CB(client): %d items on the ground by me - picking them up"):format(#list))
            local tag = { TagName = FName("Jig.InteractOptions.Option1") }
            for i, a in ipairs(list) do
                gameDelay(i * 800, function()
                    local ok = pcall(function() a:OnExecuteInteract(me, tag) end)
                    alog(("CB(client): pick up %s -> %s"):format(className(a), tostring(ok)))
                end)
            end
            gameDelay(#list * 800 + 1500, function()
                local w = safe(function() return me:GetCurrentActiveWeapon() end, nil)
                alog("CB(client): armed, weapon in hand: " .. (type(w) == "userdata" and className(w) or tostring(w)))
            end)
            return
        end
        if not ph:find("^combat:") then return end
        A.cc1 = true
        local me = myPawn()
        local x, y, zz = ph:match("combat:(%-?%d+),(%-?%d+),(%-?%d+)")
        local zl = { X = tonumber(x), Y = tonumber(y), Z = tonumber(zz) + 60 }
        local P = "/Game/Blueprints/BP_PlayerCharacter.BP_PlayerCharacter_C:"
        for _, f in ipairs({ "Event_Fire", "Local_StartShooting", "Local_StopShooting", "EquipMelee", "ServerFuncChangeActiveSlot",
                             "GetCurrentActiveWeapon", "Svr_WeaponShove", "Svr_Montage", "Svr_UpdateCombatState", "Event_MeleeAim" }) do
            alog("CB(client) sig " .. f .. ": " .. PR.sig(P .. f))
        end
        local w = safe(function() return me:GetCurrentActiveWeapon() end, nil)
        alog("CB(client) active weapon: " .. tostring(type(w) == "userdata" and className(w) or w))
        local function face()
            local pc = UEHelpers.GetPlayerController()
            local cam = safe(function() return pc.PlayerCameraManager:GetCameraLocation() end, nil) or me:K2_GetActorLocation()
            local yaw = math.deg(math.atan(zl.Y - cam.Y, zl.X - cam.X))
            local pitch = math.deg(math.atan(zl.Z - cam.Z, math.sqrt((zl.X - cam.X)^2 + (zl.Y - cam.Y)^2)))
            pcall(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0.0 }) end)
        end
        -- keep the camera on the zombie, so clicks made by hand land too
        A.aimAt = nearestActor(safe(function() return FindAllOf("BP_MasterZombie_C") end, nil), zl)
        alog("CB(client) aiming at " .. className(A.aimAt))
        local function weapon()
            local w = safe(function() return me:GetCurrentActiveWeapon() end, nil)
            return type(w) == "userdata" and className(w) or tostring(w)
        end
        local tries = {
            { "EquipMelee", function() me:EquipMelee() end },
            { "Event_Fire (melee in hand?)", function() me:Event_Fire() end },
            { "Event_Fire again", function() me:Event_Fire() end },
            { "Event_MeleeAim + Event_Fire", function() me:Event_MeleeAim(); me:Event_Fire() end },
        }
        for i, tr in ipairs(tries) do
            gameDelay(1000 + (i - 1) * 4500, function()
                face()
                local ok, err = pcall(tr[2])
                alog(("CB(client) try %s -> %s %s (weapon in hand: %s)"):format(tr[1], tostring(ok), tostring(err or ""):sub(1, 120), weapon()))
                if tr[3] then gameDelay(1200, function() pcall(tr[3]) end) end
            end)
        end
        for _, ms in ipairs({ 20000, 70000 }) do
            gameDelay(ms, function()
                local c = {}
                for k, v in pairs(A.cbCount) do c[#c + 1] = k .. "=" .. v end
                table.sort(c)
                alog("CB(client) rpc counts: " .. table.concat(c, " ") .. " | weapon in hand: " .. weapon())
            end)
        end
    end
    -- newest pickup near l that wasn't in the before-list
    A.pkNew = function(l, before)
        local seen = {}
        for _, x in ipairs(before or {}) do seen[safe(function() return x:GetAddress() end, 0)] = true end
        local hl = safe(function() return myPawn():K2_GetActorLocation() end, nil)
        local found
        for _, x in ipairs(A.groundPickups()) do
            if not seen[safe(function() return x:GetAddress() end, 0)] then
                local xl = x:K2_GetActorLocation()
                local function dist(p) return p and math.sqrt((xl.X - p.X)^2 + (xl.Y - p.Y)^2) or -1 end
                alog(("PICK new ground item %s: %.0f from the joiner, %.0f from the host"):format(className(x), dist(l), dist(hl)))
                found = found or x
            end
        end
        return found
    end
    A.pkTick = function()
        local z = A.ztest
        z.t = z.t + 1
        local cp, hp = z.p, myPawn()
        local tag = { TagName = FName("Jig.InteractOptions.Option1") }
        z.ph = z.ph or "wait"
        if z.t == 3 then
            pcall(A.pkHooks)
        end
        if z.ph == "wait" and z.t >= 8 then
            -- the joiner's saved inventory arrives ~8-15 s after its body
            if PJ.itemCount(cp) > 3 or z.t >= 45 then
                local u = A.pkUidOf(cp)
                if not u then alog("PICK: joiner has no item to drop"); z.ph = "end"; z.tp = z.t; return end
                z.before = A.groundPickups("before drop")
                z.d0 = PJ.itemCount(cp)
                z.dropName = u.name
                alog(("PICK: joiner drops %s; %d items, %d ground items near it"):format(u.name, z.d0, #z.before))
                fwrite("sdmp_phase.txt", ("drop:%d,%d,%d,%d"):format(u.g.A, u.g.B, u.g.C, u.g.D))
                z.ph, z.tp = "dropped", z.t
            end
        elseif z.ph == "dropped" and z.t == z.tp + 6 then
            A.groundPickups("after drop")
            z.dk = A.pkNew(cp:K2_GetActorLocation(), z.before)
            z.d1 = PJ.itemCount(cp)
            alog(("PICK RESULT joiner drop lands on the host: joiner items %d -> %d, new ground item %s -> %s"):format(
                z.d0, z.d1, z.dk and (className(z.dk) .. "{" .. A.pkState(z.dk) .. "}") or "none", z.dk and "PASS" or "FAIL"))
            -- give the joiner something to pick up: the host steps next to it and drops one of its own items
            local cl = cp:K2_GetActorLocation()
            pcall(function() hp:K2_TeleportTo({ X = cl.X + 200, Y = cl.Y, Z = cl.Z + 30 }, hp:K2_GetActorRotation()) end)
            z.before2 = A.groundPickups()
            local ex = A.pkNames(cp)
            if z.dropName then ex[z.dropName] = true end
            local u = A.pkUidOf(hp, ex) or A.pkUidOf(hp)
            if u then
                local jig = hp.BP_JigMultiplayer
                alog(("PICK: host drops %s next to the joiner -> %s"):format(u.name, tostring(pcall(function() jig:SERVER_RequestDropItem(u.g, 1, jig) end))))
            end
            z.ph, z.tp = "hostgift", z.t
        elseif z.ph == "hostgift" and z.t == z.tp + 4 then
            z.dk = A.pkNew(cp:K2_GetActorLocation(), z.before2)
            z.d1 = PJ.itemCount(cp)
            if not z.dk then alog("PICK: the host's drop didn't land either"); z.ph = "end"; z.tp = z.t; return end
            local l = z.dk:K2_GetActorLocation()
            alog("PICK: item for the joiner: " .. className(z.dk) .. " " .. A.pkState(z.dk))
            fwrite("sdmp_phase.txt", ("pick1:%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z))
            z.ph, z.tp = "picking", z.t
        elseif z.ph == "picking" and z.t == z.tp + 8 then
            local n = PJ.itemCount(cp)
            local dl = dnValid(z.dk) and safe(function() return z.dk:K2_GetActorLocation() end, nil)
            local cl0 = cp:K2_GetActorLocation()
            local left = dl and not safe(function() return z.dk.bHidden end, true) and (dl.X - cl0.X)^2 + (dl.Y - cl0.Y)^2 < 5000 * 5000
            alog(("PICK RESULT joiner picks it back up: joiner items %d -> %d, item on the host's ground after: %s -> %s"):format(
                z.d1, n, left and A.pkState(z.dk) or "gone", (n > z.d1 and not left) and "PASS" or "FAIL"))
            -- now what the host's own pickup does to a really dropped item
            local u = A.pkUidOf(hp)
            z.hbefore = A.groundPickups()
            z.h0 = PJ.itemCount(hp)
            if u then
                local jig = hp.BP_JigMultiplayer
                local ok = pcall(function() jig:SERVER_RequestDropItem(u.g, 1, jig) end)
                alog(("PICK: host drops %s -> %s"):format(u.name, tostring(ok)))
            end
            z.ph, z.tp = "hostdrop", z.t
        elseif z.ph == "hostdrop" and z.t == z.tp + 4 then
            z.hk = A.pkNew(hp:K2_GetActorLocation(), z.hbefore)
            z.h1 = PJ.itemCount(hp)
            alog(("PICK: host's drop: items %d -> %d, item %s"):format(z.h0, z.h1, z.hk and A.pkState(z.hk) or "none"))
            if z.hk then
                local l = z.hk:K2_GetActorLocation()
                fwrite("sdmp_phase.txt", ("see:%.0f,%.0f,%.0f"):format(l.X, l.Y, l.Z))
                alog("PICK host faces its drop -> " .. tostring(A.faceActor(z.hk, true)))
                gameDelay(400, function() A.press("IA_Interact", 0.3, "host pick up") end)
            end
        elseif z.ph == "hostdrop" and z.t == z.tp + 9 then
            local hl0 = dnValid(z.hk) and safe(function() return z.hk:K2_GetActorLocation() end, nil)
            local left = hl0 and not safe(function() return z.hk.bHidden end, true) and (hl0.X - hp:K2_GetActorLocation().X)^2 < 5000 * 5000
            alog(("PICK RESULT host picks up its own drop: host items %d -> %d, item after: %s"):format(
                z.h1 or -1, PJ.itemCount(hp), left and A.pkState(z.hk) or "gone"))
            z.ph, z.tp = "end", z.t
        elseif z.ph == "end" and z.t == z.tp + 3 then
            alog("PICK done")
            fwrite("sdmp_done.txt", "1")
        end
    end
    A.pkClient = function()
        local ph = fread("sdmp_phase.txt") or ""
        local me = myPawn()
        local tag = { TagName = FName("Jig.InteractOptions.Option1") }
        local function at(s)
            local x, y, zz = s:match(":(%-?%d+),(%-?%d+),(%-?%d+)")
            return x and { X = tonumber(x), Y = tonumber(y), Z = tonumber(zz) }
        end
        if ph:find("^drop:") and not A.pc2 then
            A.pc2 = true
            pcall(A.pkHooks)
            local ga, gb, gc, gd = ph:match("drop:(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)")
            local jig = me.BP_JigMultiplayer
            local ok, err = pcall(function() jig:SERVER_RequestDropItem({ A = tonumber(ga), B = tonumber(gb), C = tonumber(gc), D = tonumber(gd) }, 1, jig) end)
            alog(("PICK(client): drop request -> %s %s"):format(tostring(ok), tostring(err or ""):sub(1, 100)))
        elseif ph:find("^pick1:") and not A.pc1 then
            A.pc1 = true
            local target = at(ph)
            local pk, d = nearestActor(A.groundPickups("client"), target)
            if not pk or d > 300 then
                alog(("PICK(client): the dropped item isn't on my screen (nearest %.0f away)"):format(d or -1)); return
            end
            alog(("PICK(client): I can see the dropped %s (%.0f from the host's spot, role %s), picking it up"):format(
                className(pk), d, tostring(safe(function() return pk:GetLocalRole() end, "?"))))
            local ok, err = pcall(function() pk:OnExecuteInteract(me, tag) end)
            alog(("PICK(client): OnExecuteInteract -> %s %s"):format(tostring(ok), tostring(err or ""):sub(1, 100)))
            gameDelay(1500, function() alog("PICK(client): +1s item: " .. A.pkState(pk)) end)
            gameDelay(6000, function()
                alog("PICK(client): +6s item: " .. A.pkState(pk))
                local still = dnValid(pk) and not safe(function() return pk.bHidden end, true)
                alog(("PICK RESULT(client) the item is gone from my screen after picking it up -> %s"):format(still and "FAIL" or "PASS"))
            end)
        elseif ph:find("^see:") and not A.pc3 then
            A.pc3 = true
            local target = at(ph)
            gameDelay(3000, function()
                local pk, d = nearestActor(A.groundPickups(), target)
                alog(("PICK(client): host's dropped item on my screen: %s (%.0f away)"):format(pk and A.pkState(pk) or "none", d or -1))
            end)
            gameDelay(7000, function()
                local pk, d = nearestActor(A.groundPickups(), target)
                alog(("PICK(client): after the host picked it up: %s (%.0f away)"):format(
                    (pk and d < 300) and A.pkState(pk) or "gone", d or -1))
            end)
        end
    end
    -- crouch the way the player's key does: the server RPC, not Crouch()
    A.realCrouch = function(p, on)
        local fn = on and "Svr_Crouch" or "Svr_UnCrouch"
        local ok = pcall(function() p[fn](p) end)
        if not ok then pcall(function() if on then p:Crouch(false) else p:UnCrouch(false) end end) end
        return ok
    end
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
        if z.t == 6 then   -- friendly fire: the host hits the joiner, it should bounce off
            local before = safe(function() return cp.MedicalComponent.Health end, -1)
            local hpc = dnLocalPC()
            pcall(function()
                StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(cp, 40.0, hpc, hp, nil)
            end)
            local after = safe(function() return cp.MedicalComponent.Health end, -1)
            z.ffBlocked = (before == after)
            alog(("DT: host hits joiner for 40: health %s -> %s (friendly fire blocked=%s)"):format(tostring(before), tostring(after), tostring(z.ffBlocked)))
        end
        if z.ph == "down1" or z.ph == "down2" then
            if down then
                alog(("DT: client DOWN at %ds (phase %s), health=%s"):format(z.t, z.ph, tostring(safe(function() return cp.MedicalComponent.Health end, "?"))))
                if z.ph == "down1" then toHost() else
                    -- bleed-out run: keep the host well away, standing next to a
                    -- downed partner revives them now
                    local l = safe(function() return hp:K2_GetActorLocation() end, nil)
                    if l then pcall(function() cp:K2_TeleportTo({ X = l.X + 1500, Y = l.Y, Z = l.Z + 30 }, cp:K2_GetActorRotation()) end) end
                end
                z.pt = z.t
                z.since = nil
                if z.ph == "down1" then
                    z.ph = "revive"
                    alog("DT: host just stands next to the joiner (no crouch) to revive")
                else
                    z.ph = "bleed"
                end
            elseif z.t % 8 == 2 then
                toZombie()
                alog(("DT: (%s) client -> next to a zombie"):format(z.ph))
            end
            -- zombies don't always notice; the test is about downing, not the AI
            z.since = z.since or z.t
            if not down and z.t - z.since >= 20 then
                local ok = pcall(function()
                    StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(cp, 25.0, nil, nil, nil)
                end)
                if (z.t - z.since) % 5 == 0 then alog("DT: no zombie hit yet - test damages the client itself -> " .. tostring(ok)) end
            end
        elseif z.ph == "revive" then
            if not down then
                alog(("DT: client REVIVED after %ds, health=%s"):format(z.t - z.pt,
                    tostring(safe(function() return cp.MedicalComponent.Health end, "?"))))
                z.revived = true
                A.realCrouch(hp, false)
                z.ph, z.pt = "hostdown", z.t
            elseif z.t - z.pt > 20 then
                alog("DT: FAIL revive didn't finish in 20s")
                A.realCrouch(hp, false)
                z.ph, z.pt = "hostdown", z.t
            end
        elseif z.ph == "hostdown" then
            -- the other way round: the HOST goes down and the joiner revives
            -- it with its own crouch key (client side watches for this)
            local hdown = DN.isDown(hp)
            if z.t - z.pt == 3 then
                toHost()
                pcall(function() hp.bCanBeDamaged = true end)
                pcall(function() cp.bCanBeDamaged = false end)   -- zombies mustn't kill the reviver mid-test
                local ok = pcall(function()
                    StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(hp, 1000.0, nil, nil, nil)
                end)
                alog(("DT: hitting the host for 1000 -> %s, host down=%s"):format(tostring(ok), tostring(DN.isDown(hp))))
            elseif z.t - z.pt > 3 then
                if hdown then z.hostWasDown = true end
                if z.hostWasDown and not hdown then
                    alog(("DT: HOST REVIVED by the joiner after %ds, health=%s"):format(z.t - z.pt - 3,
                        tostring(safe(function() return hp.MedicalComponent.Health end, "?"))))
                    z.hostRevived = true
                end
                if z.hostRevived or z.t - z.pt > 30 then
                    if not z.hostRevived then alog("DT: FAIL host wasn't revived in 27s (was down=" .. tostring(z.hostWasDown) .. ")") end
                    if DN.isDown(hp) then   -- don't leave the host to bleed out
                        local k = hp:GetAddress(); local d = DN.down[k]
                        DN.down[k] = nil; if d then dnRestoreMove(hp, d) end
                        dnSetHealth(hp, DN.UP_HP); dnPublish(hp, 0)
                    end
                    pcall(function() hp.bCanBeDamaged = false end)
                    pcall(function() cp.bCanBeDamaged = true end)
                    DN.BLEED = 20
                    z.ph, z.pt = "down2", z.t
                end
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
                DN.census("host after bleed-out")
                z.oldAddr = safe(function() return cp:GetAddress() end, 0)
                z.ph, z.pt = "respawn", z.t
            elseif z.t - z.pt > 45 then
                alog("DT: FAIL no bleed-out after 45s")
                z.ph, z.pt = "end", z.t
            end
        end
        if z.ph == "respawn" then
            for _, c in ipairs(FindAllOf("PlayerController") or {}) do
                if c:IsValid() and safe(function() return c:IsLocalController() end, true) == false then
                    local np = safe(function() return c.Pawn end, nil)
                    if np and safe(function() return np:IsValid() end, false) and safe(function() return np:GetAddress() end, 0) ~= z.oldAddr
                       and not safe(function() return np["PlayerDead?"] end, false) then
                        local a, b = safe(function() return np:K2_GetActorLocation() end, nil), safe(function() return hp:K2_GetActorLocation() end, nil)
                        local dist = (a and b) and math.sqrt((a.X - b.X)^2 + (a.Y - b.Y)^2) or -1
                        if dist >= 0 and dist < 1000 then
                            z.respawned = true
                            -- check the host still has its own body now (the re-possess after
                            -- the joiner's death lands a tick after the death itself)
                            for _, lc in ipairs(FindAllOf("PlayerController") or {}) do
                                if lc:IsValid() and safe(function() return lc:IsLocalController() end, false) then
                                    z.hostOk = safe(function() return lc.Pawn:GetAddress() == hp:GetAddress() end, false)
                                end
                            end
                            alog(("DT: client RESPAWNED %ds after death, %.0f from host, health=%s"):format(z.t - z.pt, dist,
                                tostring(safe(function() return np.MedicalComponent.Health end, "?"))))
                            z.ph, z.pt = "hostdeath", z.t
                        end
                    end
                end
            end
            if z.ph == "respawn" and z.t - z.pt > 30 then alog("DT: FAIL no respawn next to the host within 30s"); z.ph, z.pt = "end", z.t end
        end
        if z.ph == "hostdeath" then
            -- the host dies for real (nobody can revive it) and uses the game's
            -- own Respawn: it must come back in a new body, joiner untouched
            local dt = z.t - z.pt
            if dt == 2 then
                z.oldHost = hp:GetAddress()
                pcall(function() hp.bCanBeDamaged = true end)
                DN.allowKill[z.oldHost] = true
                pcall(function() StaticFindObject("/Script/Engine.Default__GameplayStatics"):ApplyDamage(hp, 1000.0, nil, nil, nil) end)
                alog("DT: killing the host for real")
            elseif dt == 14 then
                local pc = dnLocalPC()
                local cur = pc and safe(function() return pc.Pawn end, nil)
                local live = dnValid(cur) and not safe(function() return cur["PlayerDead?"] end, false) and cur:GetAddress() ~= z.oldHost
                z.hostNotAutoRestarted = not live
                alog(("DT: 12s after host death: host body %s (should still be dead, waiting on its Respawn button)"):format(live and "ALREADY REPLACED" or "dead/none"))
                local gi = safe(function() return UEHelpers.GetGameInstance() end, nil)
                local ok, err = pcall(function() gi:Survival_Respawn(false) end)
                alog("DT: host presses Respawn (Survival_Respawn) -> " .. tostring(ok) .. " " .. tostring(err or ""):sub(1, 120))
            elseif dt == 22 then
                local pc = dnLocalPC()
                local cur = pc and safe(function() return pc.Pawn end, nil)
                z.hostRespawned = dnValid(cur) and cur:GetAddress() ~= z.oldHost and not safe(function() return cur["PlayerDead?"] end, false)
                local jok = false
                for _, c in ipairs(FindAllOf("PlayerController") or {}) do
                    if c:IsValid() and safe(function() return c:IsLocalController() end, true) == false then
                        local jp = safe(function() return c.Pawn end, nil)
                        jok = dnValid(jp) and not safe(function() return jp["PlayerDead?"] end, false)
                    end
                end
                z.joinerOkAfterHostDeath = jok
                alog(("DT: host respawned=%s, joiner still fine=%s"):format(tostring(z.hostRespawned), tostring(jok)))
                if z.hostRespawned then pcall(function() cur.bCanBeDamaged = false end) end
                z.ph, z.pt = "end", z.t
            end
        end
        if z.ph == "end" and z.t - z.pt == 4 then DN.census("host +4s") end
        if (z.ph == "end" and z.t - z.pt >= 8) or z.t > 240 then
            if not z.reported then
                z.reported = true
                if not A.quit then console("god"); alog("DT: host god mode toggled back off") end
                alog(("DT RESULT: hostDeath=%s ffBlocked=%s revived=%s hostRevivedByJoiner=%s bledOut=%s hostKeptCharacter=%s respawnedNextToHost=%s (t=%ds)"):format(
                    tostring(z.hostNotAutoRestarted and z.hostRespawned and z.joinerOkAfterHostDeath and "ok" or "FAIL"),
                    tostring(z.ffBlocked), tostring(z.revived or false), tostring(z.hostRevived or false), tostring(z.bled or false), tostring(z.hostOk), tostring(z.respawned or false), z.t))
                DN.BLEED = 60
                fwrite("sdmp_done.txt", "1")
            end
        end
    end

    -- where it's safe to put a joiner: next to a live host, or the last place
    -- a live host stood
    A.hostSpot = function()
        local hp = myPawn()
        if hp and not safe(function() return hp["PlayerDead?"] end, false) then
            local l = safe(function() return hp:K2_GetActorLocation() end, nil)
            if l and math.abs(l.Z) < 200000 and math.abs(l.X) + math.abs(l.Y) > 1000 then
                A.lastSpot = { X = l.X, Y = l.Y, Z = l.Z }
                A.lastRot = safe(function() return hp:K2_GetActorRotation() end, { Pitch = 0, Yaw = 0, Roll = 0 })
            end
        end
        return A.lastSpot, A.lastRot or { Pitch = 0, Yaw = 0, Roll = 0 }
    end
    -- ---------------------------------------------------------------- host
    local function hostTick()
        pcall(A.hostSpot)
        if A.step == "init" then
            if not A.play or A.pt then
                fwrite("sdmp_ready.txt", "0"); fwrite("sdmp_done.txt", "0"); fwrite("sdmp_phase.txt", "0"); fwrite("sdmp_htrace.txt", "0")
            end
            -- No need to get past "press any key": the listen travel reloads
            -- the map and the menu comes back up without it.
            if not UEHelpers.GetPlayerController() then return end
            A.boot = (A.boot or 0) + 1
            -- Wait for the main menu to finish loading before the listen reload.
            -- Reloading while the game's own first load is still going left the
            -- new level stuck on its loading screen with no menu (it happened on
            -- most first launches of the day).
            local ready = false
            pcall(function()
                local hasMenuLevel = false
                for _, l in ipairs(FindAllOf("MainMenu_C") or {}) do if l:IsValid() then hasMenuLevel = true end end
                local loading = false
                for _, w in ipairs(FindAllOf("LoadingScreenWidget_C") or {}) do
                    if w:IsValid() and safe(function() return w:IsInViewport() end, false) then loading = true end
                end
                ready = hasMenuLevel and not loading
            end)
            A.readyFor = ready and (A.readyFor or 0) + 1 or 0
            if A.readyFor < 3 and A.boot < 90 then return end
            alog(("main menu settled after %ds - starting the listen reload"):format(A.boot))
            if not A.useSteam then ExecuteInGameThread(setIpDriver) end
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
            A.ct = (A.ct or 0) + 1
            -- Sometimes (first launch after a while) the listen reload comes up
            -- as a bare PersistentLevel with no main menu streamed in, and it
            -- never recovers. Do the listen reload again.
            if A.ct == 40 and not menu() and not myPawn() and (A.relisten or 0) < 2
               and #(safe(function() return FindAllOf("Actor") end, nil) or {}) < 200 then   -- bare level, not a slow load
                A.relisten = (A.relisten or 0) + 1
                alog("no main menu 40s after the listen reload - reloading again (try " .. A.relisten .. ")")
                if not A.useSteam then ExecuteInGameThread(setIpDriver) end
                A.worldAddr = worldAddr()
                A.waitMenu, A.lt = 0, 0
                ExecuteInGameThread(hostListen)
                A.step, A.t, A.ct = "listening", 0, 0
                return
            end
            if A.play and not A.pt then return end   -- the host picks Continue / Load themselves
            -- a slow cold start can leave the menu on "press any key" past the
            -- listening step's timeout: keep nudging that until the menu shows
            if not menu() and A.t % 5 == 0 then pressAnyKey() end
            if A.t % 10 == 0 then pressContinue() end
            A.t = A.t + 1

            if A.t > 150 then alog("FAIL: no host pawn 150s after Continue"); A.step = "dead" end
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
            if A.play and A.useSteam then
                pcall(CS.clearPressAnyKey)
                local okH, hosted = pcall(A.steamHost)
                if okH and hosted then
                    pcall(dnNotify, "Co-op: hosting over Steam. Friends click Join Game on your Steam profile, or press F9 to invite them", myPawn())
                else
                    pcall(dnNotify, "Co-op: hosting over Steam, but Join Game couldn't be set up - see sdmp_host.log", myPawn())
                end
                if A.pt then fwrite("sdmp_ready.txt", "1") end
            elseif A.play then
                alog("hosting - friends join with F8 (your IP as join_ip in their config.txt)")
                pcall(CS.clearPressAnyKey)
                pcall(dnNotify, "Co-op: you're hosting. Friends put your IP in their config.txt and press F8 (UDP port 7777)", myPawn())
                if A.pt then fwrite("sdmp_ready.txt", "1") end
            else
                -- test runs shouldn't end with the host dead in a ditch
                console("god")
                -- unpacked movement RPCs both sides, so the client log can tell
                -- ClientAckGoodMove (fine) from ClientAdjustPosition (correction)
                console("net.UsePackedMovementRPCs 0")
                fwrite("sdmp_ready.txt", "1")
                alog("host is in game and listening - client may join")
            end
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
                -- never the host's own controller: a dead host is pawnless too, and
                -- restarting it here put the host in a fresh body behind its own
                -- death screen (whose Respawn buttons then did nothing)
                if safe(function() return c:IsLocalController() end, true) then key = nil end
                if key and not (p and p:IsValid()) then
                    A.seen[key] = (A.seen[key] or 0) + 1
                    local n = A.seen[key]
                    if n >= 8 and n % 5 == 3 and n <= 60 then
                        local ok, err = pcall(function() c:ServerRestartPlayer() end)
                        local p2 = safe(function() return c.Pawn end, nil)
                        if not (p2 and safe(function() return p2:IsValid() end, false)) and gm and safe(function() return gm:IsValid() end, false) then
                            pcall(function() gm:RestartPlayer(c) end)
                            p2 = safe(function() return c.Pawn end, nil)
                        end
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
                    -- (only to a sane spot: if the host is dead/respawning its body
                    -- can sit at the origin, and a joiner sent there falls forever)
                    local hl, rot = A.hostSpot()
                    if hl then
                        local dest = { X = hl.X + 250.0, Y = hl.Y + 150.0, Z = hl.Z + 50.0 }
                        local ok = safe(function() return p:K2_TeleportTo(dest, rot) end, false)
                        alog(("moved joiner next to host -> %s"):format(tostring(ok)))
                    else
                        alog("no safe spot by the host yet - joiner stays where it spawned")
                    end
                    if (A.test == "zombie" or A.test == "downed" or A.test == "door" or A.test == "persist" or A.test == "well" or A.test == "loot" or A.test == "build" or A.test == "pick" or A.test == "combat" or A.test == "vehicle" or A.test == "skills") and not A.ztest then
                        A.ztest = { p = p, t = 0 }
                    elseif not A.play then
                        pcall(function() p.bCanBeDamaged = false end)
                    end
                    if A.play then
                        pcall(dnNotify, "A player joined", myPawn())
                        gameDelay(20000, function() pcall(CS.gearCensus, "host"); pcall(CS.widgetCensus, "host"); pcall(CS.weatherBrief, "host") end)
                        gameDelay(50000, function() pcall(CS.weatherBrief, "host+50"); pcall(CS.skyLink, "host+50") end)
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
            -- Respawning a dead joiner. The game's own respawn (the joiner's
            -- Respawn button -> Svr_RequestRespawn -> GameInstance
            -- Survival_Respawn) is single-player code: it has PLAYER 0 - the
            -- host - possess the new body and wipes the host's stats. Joiners
            -- hide that screen instead, and the host respawns them here: free
            -- the controller from the corpse, GameMode RestartPlayer, and the
            -- join handling above moves the new body next to the host.
            A.dead = A.dead or {}
            for _, c in ipairs(listControllers()) do
                local key = safe(function() return c:GetAddress() end, nil)
                local rp = safe(function() return c.Pawn end, nil)
                if key and safe(function() return c:IsLocalController() end, true) == false
                   and rp and safe(function() return rp:IsValid() end, false)
                   and safe(function() return rp["PlayerDead?"] end, false) == true then
                    A.dead[key] = (A.dead[key] or 0) + 1
                    if A.dead[key] == 1 then alog("joiner died - respawning them in 10s") end
                    if A.dead[key] >= 10 then
                        A.dead[key] = nil
                        pcall(function() c:UnPossess() end)
                        local ok, err = pcall(function() gm:RestartPlayer(c) end)
                        local np = safe(function() return c.Pawn end, nil)
                        alog(("respawned joiner: RestartPlayer -> %s, pawn=%s"):format(ok and "ok" or tostring(err),
                            (np and safe(function() return np:IsValid() end, false)) and className(np) or "none"))
                        -- a fresh body sits at 0 health until a save loads into it (none
                        -- will for a joiner), and its PlayerState still says "down"
                        if np and safe(function() return np:IsValid() end, false) then
                            pcall(function()
                                local mc = np.MedicalComponent
                                local mx = safe(function() return mc.MaxHealth end, 100) or 100
                                mc.Health = mx
                                np:SendHealthToClient(mx)
                            end)
                            pcall(dnPublish, np, 0)
                        end
                        if A.handled then A.handled[key] = nil end   -- move the new body next to the host
                        if A.seen then A.seen[key] = 0 end
                    end
                elseif key then
                    A.dead[key] = nil
                end
            end
            if A.play then return end   -- the rest is test-run plumbing
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
            if A.ztest then (A.test == "downed" and A.dTick or (A.test == "door" and A.doorTick) or (A.test == "persist" and A.persistTick) or (A.test == "well" and A.wellTick) or (A.test == "loot" and A.lootTick) or (A.test == "build" and A.buildTick) or (A.test == "pick" and A.pkTick) or (A.test == "combat" and A.cbTick) or (A.test == "vehicle" and A.vhTick) or (A.test == "skills" and A.skTick) or A.zTick)() end
            A.serveT = (A.serveT or 0) + 1
            if A.test == "steam" then
                if A.serveT == 5 then pcall(A.steamProbe3) end
                if A.serveT == 8 then fwrite("sdmp_done.txt", "1") end
            end
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
            if (not A.play or A.pt) and not (fread("sdmp_ready.txt") or ""):find("1") then
                A.t = A.t + 1
                if A.t % 10 == 1 then alog("waiting for host to be ready") end
                if A.t > 480 then alog("FAIL: host never became ready"); A.step = "dead" end
                return
            end
            if not A.useSteam then ExecuteInGameThread(setIpDriver) end
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
            if A.t % 45 == 0 then
                local addr = A.joinAddr or "127.0.0.1"
                if not addr:find(":") then addr = addr .. ":7777" end
                alog("connecting to " .. addr)
                console("open " .. addr)
            end
            A.t = A.t + 1
            if A.t > 120 then
                alog("FAIL: never got a pawn after 2 min"); A.step = "dead"
                if A.play then pcall(dnNotify, "Couldn't join - check the IP and that the host's UDP port 7777 is open", UEHelpers.GetPlayerController()) end
            end
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
            if A.play then
                alog("joined - playing")
                pcall(CS.clearPressAnyKey)
                gameDelay(3000, function() pcall(CS.clearPressAnyKey) end)
                gameDelay(2000, function() pcall(dnNotify, "Joined the host's game", myPawn()) end)
                A.step, A.t = "playing", 0
                return
            end
            if A.test == "zombie" or A.test == "downed" or A.test == "door" or A.test == "persist" or A.test == "well" or A.test == "loot" or A.test == "build" or A.test == "pick" or A.test == "combat" or A.test == "vehicle" or A.test == "skills" then
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
        elseif A.step == "playing" then
            -- nothing to drive; just notice if we lose the host
            A.t = A.t + 1
            if A.t == 20 then pcall(CS.gearCensus, "client"); pcall(CS.widgetCensus, "client"); pcall(CS.weatherBrief, "client") end
            if A.t == 60 or A.t == 90 then pcall(CS.weatherBrief, "client+" .. A.t); pcall(CS.skyLink, "client+" .. A.t) end
            if not myPawn() then
                A.lost = (A.lost or 0) + 1
                if A.lost == 15 then alog("no pawn for 15s - disconnected?") end
            else
                A.lost = 0
            end
        elseif A.step == "zwait" then
            A.t = A.t + 1
            if A.test == "downed" and A.t % 6 == 0 then DN.census("client t=" .. A.t) end
            if A.test == "downed" then
                local me = myPawn()
                local ml = me and safe(function() return me:K2_GetActorLocation() end, nil)
                local want = false
                for _, o in ipairs(safe(function() return FindAllOf("BP_PlayerCharacter_C") end, nil) or {}) do
                    if dnValid(o) and me and o:GetAddress() ~= me:GetAddress() and dnState(o) ~= "up" then
                        local ol = safe(function() return o:K2_GetActorLocation() end, nil)
                        if ml and ol and math.sqrt((ol.X - ml.X)^2 + (ol.Y - ml.Y)^2) < 400 then want = true end
                    end
                end
                if want and not A.cRev then alog("DT(client): partner down next to me - crouching via Svr_Crouch -> " .. tostring(A.realCrouch(me, true))) end
                if want and A.t % 3 == 0 and not DN.isCrouching(me) then A.realCrouch(me, true) end
                if not want and A.cRev then alog("DT(client): partner back up - uncrouch"); A.realCrouch(me, false) end
                A.cRev = want
            end
            if A.t == 20 or A.t == 40 then pcall(CS.dumpSlots, "client t=" .. A.t) end
            if A.test == "door" then pcall(A.doorClient) end
            if A.test == "well" then pcall(A.wellClient) end
            if A.test == "loot" then pcall(A.lootClient) end
            if A.test == "build" then pcall(A.buildClient) end
            if A.test == "pick" then pcall(A.pkClient) end
            if A.test == "combat" then pcall(A.cbClient) end
            if A.test == "vehicle" then pcall(A.vhClient) end
            if (fread("sdmp_done.txt") or ""):find("1") or A.t > (A.test == "downed" and 260 or 120) then
                if A.test == "downed" then DN.census("client final") end
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
        if A.role then
            LOGF.path = modDir() .. "\\sdmp_" .. A.role .. ".log"
            pcall(function() local f = io.open(LOGF.path, "w"); if f then f:close() end end)
        end
        A.auto = cl:find("%-sdmpauto") ~= nil
        if A.auto or A.role then LOGF.verbose = true end
        A.quit = cl:find("%-sdmpquit") ~= nil
        A.test = cl:match("%-sdmptest=(%a+)")
        A.useSteam = A.test == "steam"
        -- co-op straight from the command line (shortcuts, playtest.bat)
        if cl:find("%-sdmplowgfx") then console("scalability 0"); console("r.ScreenPercentage 50") end
        A.pt = cl:find("%-sdmpplaytest") ~= nil   -- one-PC play test: host auto-Continues, joiner waits for it
        -- Steam "Join Game" / accepted invite: Steam starts us with the host's connect string
        local sj = cl:match("[%+%-]sdmpjoin=(%S+)")
        if sj and not A.role then
            log("SDMP: started from a Steam join - joining " .. sj)
            A.startPlay("client", sj)
            return
        end
        local pm = cl:match("%-sdmpplay=(%S+)")
        if pm and not A.role then
            if pm == "host" then A.startPlay("host", nil)
            else
                local addr = pm:match("^join:(.+)$")
                if addr then A.startPlay("client", addr) end
            end
            return
        end
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
        A.startLoop()
    end

    A.startLoop = function()
        if A.looping then return end
        A.looping = true
        gameLoop(1000, function()
            local ok, err = pcall(A.role == "host" and hostTick or clientTick)
            if not ok then alog("tick error in step " .. A.step .. ": " .. tostring(err)) end
            if A.step == "dead" and A.quit then A.step = "quit"; console("quit") end
            local stop = A.step == "dead" or A.step == "quit"
            if stop then A.looping = false end
            return stop
        end)
    end

    -- ------------------------------------------------------------- play
    -- The same steps as the test runs, minus the test parts, started from the
    -- main menu console:
    --   host:   sdmp_host            then Continue / Load your save as usual
    --   joiner: sdmp_join <ip>       (or ip:port; default port 7777)
    local function startPlay(role, addr)
        A.startPlayCalled = true
        if A.looping then log("SDMP: co-op is already running (" .. tostring(A.role) .. ")"); return end
        A.role, A.play, A.auto, A.quit, A.test = role, true, false, false, nil
        A.joinAddr = addr
        if role == "host" then
            A.useSteam = (A.cfg.connection or "ip"):lower() == "steam"
            if A.useSteam and not A.steamUp() then
                A.useSteam = false
                log("SDMP: connection=steam but Steam isn't running for this game - hosting over IP instead")
            end
        else
            A.useSteam = (addr or ""):lower():find("^steam%.") ~= nil
        end
        A.step, A.t, A.boot, A.lt = "init", 0, 0, 0
        A.handled, A.seen, A.dpSet = {}, {}, false
        LOGF.path = modDir() .. "\\sdmp_" .. role .. ".log"
        pcall(function() local f = io.open(LOGF.path, "w"); if f then f:close() end end)
        alog(role == "host" and "co-op: hosting" or ("co-op: joining " .. tostring(addr)))
        A.startLoop()
    end
    A.startPlay = startPlay
    RegisterConsoleCommandHandler("sdmp_host", function()
        ExecuteInGameThread(function() startPlay("host", nil) end)
        return true
    end)
    RegisterConsoleCommandHandler("sdmp_join", function(cmd, params)
        local addr = params and params[1]
        if not addr or addr == "" then
            log("SDMP: usage: sdmp_join <host IP>   e.g. sdmp_join 203.0.113.5")
            return true
        end
        ExecuteInGameThread(function() startPlay("client", addr) end)
        return true
    end)

    -- Settings file next to the mod (made with defaults the first time):
    --   join_ip         who F8 joins
    --   friendly_fire   players can hurt each other (default off)
    --   bleed_out_seconds / revive_seconds
    local CFG_DEFAULT = [[
# SurrounDead Co-op settings. Lines starting with # are ignored.
#
# In the main menu: F7 = host a game, F8 = join the game at join_ip.
# The host needs UDP port 7777 forwarded on their router (or use a LAN /
# virtual LAN like Radmin VPN, ZeroTier or Tailscale and put that IP here).

# How friends reach you when you host (F7):
#   steam = through Steam, no port forwarding. Start the game from Steam.
#           Friends click "Join Game" on your Steam profile, or accept your
#           invite (press F9 while hosting). Their game must be closed when
#           they click it - Steam starts it and joins you.
#   ip    = they put your IP in join_ip and press F8 (needs UDP 7777
#           forwarded, or a virtual LAN like Radmin VPN, ZeroTier, Tailscale)
connection=ip

# IP address of the friend you're joining (add :port if they changed it).
# steam.<their Steam id> also works and goes through Steam.
join_ip=127.0.0.1

# can players hurt each other?
friendly_fire=false

# seconds a downed player has before bleeding out, and how long a revive takes
bleed_out_seconds=60
revive_seconds=5

# the host keeps joiners' characters (inventory, clothes, health) between
# sessions. Saved every 30 seconds while they play.
joiner_saves=true

# extra logging for bug reports (sdmp_host.log / sdmp_client.log)
debug=false
]]
    A.cfg = { join_ip = "127.0.0.1", friendly_fire = "false", bleed_out_seconds = "60", revive_seconds = "5" }
    local function loadCfg()
        local txt = fread("config.txt")
        if not txt then fwrite("config.txt", CFG_DEFAULT); txt = CFG_DEFAULT end
        for line in txt:gmatch("[^\r\n]+") do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and not line:match("^%s*#") then A.cfg[k] = v end
        end
        DN.friendlyFire = (A.cfg.friendly_fire or ""):lower() == "true"
        if (A.cfg.debug or ""):lower() == "true" then LOGF.verbose = true end
        PJ.enabled = (A.cfg.joiner_saves or "true"):lower() ~= "false"
        DN.BLEED = tonumber(A.cfg.bleed_out_seconds) or 60
        DN.REVIVE = tonumber(A.cfg.revive_seconds) or 5
        log(("settings: join_ip=%s friendly_fire=%s bleed_out=%ds revive=%ds"):format(
            tostring(A.cfg.join_ip), tostring(DN.friendlyFire), DN.BLEED, DN.REVIVE))
    end
    pcall(loadCfg)
    A.loadCfg = loadCfg
    local function inMenu()
        local pc = dnLocalPC()
        return not dnValid(pc and safe(function() return pc.Pawn end, nil))
    end
    RegisterKeyBind(Key.F7, function()
        ExecuteInGameThread(function()
            if A.looping then log("SDMP: co-op is already running"); return end
            if not inMenu() then log("SDMP: F7 hosts from the main menu"); return end
            pcall(loadCfg)
            startPlay("host", nil)
        end)
    end)
    RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(function()
            if A.looping then log("SDMP: co-op is already running"); return end
            if not inMenu() then log("SDMP: F8 joins from the main menu"); return end
            pcall(loadCfg)
            local ip = A.cfg.join_ip
            if not ip or ip == "" then log("SDMP: set join_ip in config.txt first"); return end
            startPlay("client", ip)
        end)
    end)
    RegisterKeyBind(Key.F9, function()
        ExecuteInGameThread(function() pcall(A.steamInvite) end)
    end)
    RegisterConsoleCommandHandler("sdmp_reload", function()
        ExecuteInGameThread(function() pcall(loadCfg) end)
        return true
    end)

    -- the command line is readable once the engine is up; give it a moment
    gameDelay(3000, boot)
end

log("SDMPDiag: auto mode - launch with -sdmprole=host|client -sdmpauto (tools/test.bat).")
