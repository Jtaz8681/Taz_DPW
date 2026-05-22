-- ============================================================================
-- Taz_DPW - Client Task Implementations
-- All 5 mission types (A–E) with multi-step logic
-- ============================================================================

DPW.Tasks = {}

-- Local state for the current active task
local activeTaskData = {
    task = nil,          -- The task info from dispatch
    step = 0,            -- Current step in the task sequence
    props = {},          -- Task-specific props (cleaned up on completion/abort)
    particles = {},      -- Task-specific particle handles
    attachedProp = nil,  -- Currently attached prop to player
    entities = {},       -- Task-specific entities (traffic lights, etc.)
    threadRunning = false,
}

-- ============================================================================
-- TASK ROUTING
-- ============================================================================

--- Setup a task based on its type (called from main.lua dispatch)
---@param task table Task data { type, configKey, coords, config }
function DPW.Tasks.SetupTask(task)
    if activeTaskData.threadRunning then
        DPW.Tasks.CleanupCurrentTask()
    end

    activeTaskData.task = task
    activeTaskData.step = 1
    activeTaskData.props = {}
    activeTaskData.particles = {}
    activeTaskData.attachedProp = nil
    activeTaskData.entities = {}

    local setupMap = {
        hydrant = DPW.Tasks.SetupHydrant,
        sidewalk = DPW.Tasks.SetupSidewalk,
        traffic_signal = DPW.Tasks.SetupTrafficSignal,
        streetlight = DPW.Tasks.SetupStreetlight,
        pothole = DPW.Tasks.SetupPothole,
    }

    local setupFn = setupMap[task.type]
    if setupFn then
        setupFn(task)
        activeTaskData.threadRunning = true
    else
        print(('[DPW] Unknown task type: %s'):format(task.type))
    end
end

--- Clean up all task-specific entities and reset state
function DPW.Tasks.CleanupCurrentTask()
    -- Delete task-specific props
    for _, prop in ipairs(activeTaskData.props) do
        DPW.Utils.DeleteEntitySafe(prop)
    end
    activeTaskData.props = {}

    -- Stop task-specific particles
    for _, ptfx in ipairs(activeTaskData.particles) do
        DPW.Utils.StopParticle(ptfx)
    end
    activeTaskData.particles = {}

    -- Remove attached prop
    if activeTaskData.attachedProp and DoesEntityExist(activeTaskData.attachedProp) then
        DetachEntity(activeTaskData.attachedProp, false, false)
        DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
        activeTaskData.attachedProp = nil
    end

    -- Clean up entity references (don't delete world entities like traffic lights)
    activeTaskData.entities = {}

    -- Clear ped tasks
    ClearPedTasks(PlayerPedId())

    activeTaskData.task = nil
    activeTaskData.step = 0
    activeTaskData.threadRunning = false
end

-- ============================================================================
-- HELPER: Track a task prop
-- ============================================================================
local function TrackProp(entity)
    if entity then
        table.insert(activeTaskData.props, entity)
    end
    return entity
end

local function TrackParticle(handle)
    if handle then
        table.insert(activeTaskData.particles, handle)
    end
    return handle
end

-- ============================================================================
-- HELPER: Create a prop and attach it to ped's hand (direct approach)
-- Uses CreateObject at 0,0,0 then AttachEntityToEntity — bypasses
-- SpawnProp which freezes position and breaks attachment
-- ============================================================================
local function AttachToolToPed(ped, model, posX, posY, posZ, rotX, rotY, rotZ, bone)
    -- Remove any existing attached prop
    if activeTaskData.attachedProp and DoesEntityExist(activeTaskData.attachedProp) then
        DetachEntity(activeTaskData.attachedProp, false, false)
        DeleteEntity(activeTaskData.attachedProp)
        activeTaskData.attachedProp = nil
    end

    local modelHash = GetHashKey(model)
    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        Wait(0)
    end

    -- Create object at 0,0,0 like the working medkit pattern
    local tool = CreateObject(modelHash, 0, 0, 0, true, true, true)
    if tool and tool ~= 0 then
        SetEntityAsMissionEntity(tool, true, true)
        local boneIdx = GetPedBoneIndex(ped, bone or 57005)
        AttachEntityToEntity(tool, ped, boneIdx,
            posX or 0.4, posY or 0.0, posZ or 0.0,
            rotX or 0.0, rotY or 270.0, rotZ or 60.0,
            true, true, false, true, 1, true)
        activeTaskData.attachedProp = tool
        table.insert(activeTaskData.props, tool)
        SetModelAsNoLongerNeeded(modelHash)
        return tool
    end
    SetModelAsNoLongerNeeded(modelHash)
    return nil
end

-- ============================================================================
-- TASK A: BURST FIRE HYDRANTS
-- Steps: 1=ShutOffValve, 2=FetchHydrant, 3=InstallHydrant
-- ============================================================================

function DPW.Tasks.SetupHydrant(task)
    local cfg = task.config
    local coords = task.coords

    -- Step 1: Delete any existing hydrant at location, spawn water particle
    local existingHydrant = DPW.Utils.GetClosestObjectOfType(coords, cfg.hydrantModel, 3.0)
    if existingHydrant then
        DPW.Utils.DeleteEntitySafe(existingHydrant)
    end

    -- Spawn massive water particle effect (looped) — tall geyser spray
    local ptfxPos = coords + vector3(0, 0, cfg.waterParticle.zOffset or 3.0)
    DPW.Utils.LoadParticleAsset(cfg.waterParticle.asset)
    UseParticleFxAssetNextCall(cfg.waterParticle.asset)
    local waterPtfx = StartParticleFxLoopedAtCoord(
        cfg.waterParticle.effect,
        ptfxPos.x, ptfxPos.y, ptfxPos.z,
        0.0, 0.0, 0.0,
        cfg.waterParticle.scale or 1.0,
        false, false, false, false
    )
    if waterPtfx and waterPtfx ~= 0 then
        TrackParticle(waterPtfx)
        print(('[DPW] Water particle spawned at %s (handle: %s)'):format(tostring(ptfxPos), tostring(waterPtfx)))
    else
        print('[DPW] WARNING: Water particle failed to spawn!')
    end

    -- Start interaction thread
    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'hydrant' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 2 is handled OUTSIDE the hydrant-distance check (player is at truck)
            if step == 2 then
                sleep = Config.Optimization.activeInterval

                if DPW.IsNearVehicleTrunk() then
                    DPW.Utils.DrawText3D(pedCoords + vector3(0, 0, 1.5), Config.Labels.fetchHydrant)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Fetching hydrant...',
                            Config.Anims.grabFromTruck.duration,
                            Config.Anims.grabFromTruck.dict,
                            Config.Anims.grabFromTruck.anim
                        )
                        if success then
                            -- Attach hydrant prop to player (direct create+attach)
                            local offset = cfg.carryHydrantOffset
                            local rot = cfg.carryHydrantRotation
                            AttachToolToPed(ped, cfg.hydrantModel,
                                offset.x, offset.y, offset.z,
                                rot.x, rot.y, rot.z,
                                cfg.carryBone)
                            activeTaskData.step = 3
                            DPW.Utils.Notify('Carry the hydrant back to the burst location.')
                        end
                    end
                else
                    -- Hint to go to truck
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then
                        DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck to fetch hydrant')
                    end
                end

            -- Steps 1 and 3 require being near the hydrant location
            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if step == 1 and dist < Config.Optimization.interactionRange then
                    -- Shut off valve
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.0), Config.Labels.shutOffValve)
                    if DPW.Utils.IsEPressed() then
                        -- Skill check
                        local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                        if passed then
                            local success = DPW.Utils.ProgressBar(
                                'Shutting off main valve...',
                                cfg.shutOffAnim.duration,
                                cfg.shutOffAnim.dict,
                                cfg.shutOffAnim.anim
                            )
                            if success then
                                -- Stop water
                                if waterPtfx then
                                    DPW.Utils.StopParticle(waterPtfx)
                                    waterPtfx = nil
                                end
                                activeTaskData.step = 2
                                DPW.Utils.Notify('Valve shut off. Fetch a new hydrant from your truck.')
                            end
                        else
                            DPW.Utils.Notify('Failed to shut off valve. Try again.')
                        end
                    end

                elseif step == 3 and dist < Config.Optimization.interactionRange then
                    -- Install hydrant at location
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.0), Config.Labels.installHydrant)
                    if DPW.Utils.IsEPressed() then
                        -- Attach welding tool for installation animation
                        AttachToolToPed(ped, 'prop_welding_torch', 0.4, 0.0, 0.0, 0.0, 270.0, 60.0)

                        local success = DPW.Utils.ProgressBar(
                            'Installing new hydrant...',
                            cfg.installAnim.duration,
                            cfg.installAnim.dict,
                            cfg.installAnim.anim
                        )
                        if success then
                            -- Remove attached prop
                            if activeTaskData.attachedProp then
                                DetachEntity(activeTaskData.attachedProp, false, false)
                                DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                activeTaskData.attachedProp = nil
                            end

                            -- Spawn permanent network-synced hydrant
                            local newHydrant = DPW.Utils.SpawnNetworkedProp(cfg.hydrantModel, coords, true)
                            if newHydrant then
                                TrackProp(newHydrant)
                            end

                            DPW.Utils.NotifySuccess('Hydrant repaired successfully!')
                            DPW.CompleteTask()
                            return
                        end
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ============================================================================
-- TASK B: BROKEN SIDEWALKS
-- Steps: 1=FetchJackhammer, 2=Drill, 3=Smooth
-- ============================================================================

function DPW.Tasks.SetupSidewalk(task)
    local cfg = task.config
    local coords = task.coords

    -- Spawn damaged prop and cones
    local damagedProp = DPW.Utils.SpawnLocalProp(cfg.damagedProp, coords, true)
    TrackProp(damagedProp)

    local coneEntities = {}
    for _, offset in ipairs(cfg.coneOffsets) do
        local cone = DPW.Utils.SpawnNetworkedProp(cfg.coneModel, coords + offset, true)
        if cone then
            TrackProp(cone)
            table.insert(coneEntities, cone)
        end
    end

    -- Start interaction thread
    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'sidewalk' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 1 is fetch from truck — handled OUTSIDE sidewalk-distance check
            if step == 1 then
                sleep = Config.Optimization.activeInterval

                if DPW.IsNearVehicleTrunk() then
                    DPW.Utils.DrawText3D(pedCoords + vector3(0, 0, 1.5), Config.Labels.fetchJackhammer)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Grabbing jackhammer...',
                            Config.Anims.grabFromTruck.duration,
                            Config.Anims.grabFromTruck.dict,
                            Config.Anims.grabFromTruck.anim
                        )
                        if success then
                            -- Attach jackhammer prop to player (direct create+attach)
                            AttachToolToPed(ped, cfg.jackhammerModel, 0.1, 0.0, -0.2, -90.0, 0.0, 0.0)
                            activeTaskData.step = 2
                            DPW.Utils.Notify('Jackhammer ready. Start drilling the sidewalk!')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then
                        DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck to grab jackhammer')
                    end
                end

            -- Steps 2 and 3 require being near the sidewalk
            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if dist < Config.Optimization.interactionRange + 2.0 then
                    if step == 2 then
                        -- Drill the damaged sidewalk
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.5), Config.Labels.startDrilling)
                        if DPW.Utils.IsEPressed() then
                            -- Screen shake during drilling
                            ShakeGameplayCam('ROAD_VIBRATION_SHAKE', cfg.screenShake.intensity)

                            local success = DPW.Utils.ProgressBar(
                                'Drilling broken sidewalk...',
                                cfg.drillAnim.duration,
                                cfg.drillAnim.dict,
                                cfg.drillAnim.anim
                            )

                            StopGameplayCamShaking(true)

                            if success then
                                activeTaskData.step = 3
                                DPW.Utils.Notify('Drilling complete. Smooth the surface now.')
                            end
                        end

                    elseif step == 3 then
                        -- Smooth the surface
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.5), Config.Labels.startSmoothing)
                        if DPW.Utils.IsEPressed() then
                            -- Remove jackhammer attachment
                            if activeTaskData.attachedProp then
                                DetachEntity(activeTaskData.attachedProp, false, false)
                                DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                activeTaskData.attachedProp = nil
                            end

                            local success = DPW.Utils.ProgressBar(
                                'Smoothing and pouring concrete...',
                                cfg.smoothAnim.duration,
                                cfg.smoothAnim.dict,
                                cfg.smoothAnim.anim
                            )

                            if success then
                                -- Delete damaged prop and cones
                                if damagedProp then
                                    DPW.Utils.DeleteEntitySafe(damagedProp)
                                end
                                for _, cone in ipairs(coneEntities) do
                                    DPW.Utils.DeleteEntitySafe(cone)
                                end

                                DPW.Utils.NotifySuccess('Sidewalk repaired successfully!')
                                DPW.CompleteTask()
                                return
                            end
                        end
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ============================================================================
-- TASK C: MALFUNCTIONING TRAFFIC SIGNALS
-- Steps: 1=Investigate, 2=GetWiresRelays (from truck), 3=FixSignal
-- ============================================================================

function DPW.Tasks.SetupTrafficSignal(task)
    local cfg = task.config
    local coords = task.coords

    -- Find existing traffic light entity near the coordinate
    local trafficLight = DPW.Utils.GetClosestObjectOfType(coords, cfg.trafficLightModel, 15.0)
    activeTaskData.entities.trafficLight = trafficLight

    -- Spawn spark particles on traffic light
    local sparkOffset = vector3(0.0, 0.0, 3.5)
    local sparkPtfx = nil
    if trafficLight and trafficLight ~= 0 then
        sparkPtfx = DPW.Utils.StartParticleOnEntity(cfg.sparkParticle.asset, cfg.sparkParticle.effect, trafficLight, sparkOffset)
        TrackParticle(sparkPtfx)
    else
        sparkPtfx = DPW.Utils.StartParticle(cfg.sparkParticle.asset, cfg.sparkParticle.effect, coords + sparkOffset, true)
        TrackParticle(sparkPtfx)
    end

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'traffic_signal' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 2 is fetch from truck — handled OUTSIDE signal-distance check
            if step == 2 then
                sleep = Config.Optimization.activeInterval

                if DPW.IsNearVehicleTrunk() then
                    DPW.Utils.DrawText3D(pedCoords + vector3(0, 0, 1.5), Config.Labels.fetchWiresRelays)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Grabbing wires and relays...',
                            Config.Anims.grabFromTruck.duration,
                            Config.Anims.grabFromTruck.dict,
                            Config.Anims.grabFromTruck.anim
                        )
                        if success then
                            activeTaskData.step = 3
                            DPW.Utils.Notify('Got the parts! Head back to the traffic signal and fix it.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then
                        DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for wires & relays')
                    end
                end

            -- Steps 1 and 3 require being near the traffic signal
            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if step == 1 and dist < Config.Optimization.interactionRange + 3.0 then
                    -- STEP 1: Investigate the signal
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.5), Config.Labels.investigateSignal)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Investigating signal malfunction...',
                            5000,
                            Config.Anims.grabFromTruck.dict,
                            Config.Anims.grabFromTruck.anim
                        )
                        if success then
                            activeTaskData.step = 2
                            DPW.Utils.Notify('Signal needs new wires and relays. Get them from your truck.')
                        end
                    end

                elseif step == 3 and dist < Config.Optimization.interactionRange + 3.0 then
                    -- STEP 3: Fix the traffic signal
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.5), Config.Labels.fixSignal)
                    if DPW.Utils.IsEPressed() then
                        -- Skill check (wiring minigame)
                        local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                        if passed then
                            -- Attach welding tool before repair animation
                            AttachToolToPed(ped, cfg.welderModel, 0.4, 0.0, 0.0, 0.0, 270.0, 60.0)

                            local success = DPW.Utils.ProgressBar(
                                'Repairing traffic signal...',
                                cfg.wiringAnim.duration,
                                cfg.wiringAnim.dict,
                                cfg.wiringAnim.anim
                            )
                            if success then
                                -- Remove welding tool
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end

                                -- Stop sparks
                                if sparkPtfx then
                                    DPW.Utils.StopParticle(sparkPtfx)
                                end

                                DPW.Utils.NotifySuccess('Traffic signal repaired successfully!')
                                DPW.CompleteTask()
                                return
                            else
                                -- Progress bar cancelled — remove welder
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end
                            end
                        else
                            DPW.Utils.Notify('Repair failed. Try again.')
                        end
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ============================================================================
-- TASK D: DEAD STREETLIGHTS
-- Steps: 1=DeployLadder/Interact, 2=RepairLight
-- ============================================================================

function DPW.Tasks.SetupStreetlight(task)
    local cfg = task.config
    local coords = task.coords

    -- Find the streetlight entity near the coordinate
    local streetlight = DPW.Utils.GetClosestObjectOfType(coords, cfg.streetlightModel, 10.0)
    activeTaskData.entities.streetlight = streetlight

    -- Spawn spark particles at the bulb (top) or base
    local sparkOffsetTop = vector3(0.0, 0.0, 5.0)
    local sparkPtfx = nil

    if streetlight and streetlight ~= 0 then
        sparkPtfx = DPW.Utils.StartParticleOnEntity(cfg.sparkParticle.asset, cfg.sparkParticle.effect, streetlight, sparkOffsetTop)
        TrackParticle(sparkPtfx)
    else
        sparkPtfx = DPW.Utils.StartParticle(cfg.sparkParticle.asset, cfg.sparkParticle.effect, coords + sparkOffsetTop, true)
        TrackParticle(sparkPtfx)
    end

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'streetlight' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)

            if dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                -- Use base panel position for interaction
                local baseCoords = coords + vector3(0, 0, 0.5)
                local distToBase = #(pedCoords - baseCoords)

                if distToBase < Config.Optimization.interactionRange + 1.5 then
                    local step = activeTaskData.step

                    if step == 1 then
                        -- Deploy ladder / lower control panel
                        DPW.Utils.DrawText3D(baseCoords + vector3(0, 0, 1.0), Config.Labels.deployLadder)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar(
                                'Deploying ladder...',
                                5000,
                                Config.Anims.grabFromTruck.dict,
                                Config.Anims.grabFromTruck.anim
                            )
                            if success then
                                activeTaskData.step = 2
                                DPW.Utils.Notify('Ladder deployed. Repair the streetlight now.')
                            end
                        end

                    elseif step == 2 then
                        -- Repair light (skill check + animation)
                        DPW.Utils.DrawText3D(baseCoords + vector3(0, 0, 1.0), Config.Labels.repairLight)
                        if DPW.Utils.IsEPressed() then
                            local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                            if passed then
                                -- Attach welding tool before repair animation
                                AttachToolToPed(ped, 'prop_welding_torch', 0.4, 0.0, 0.0, 0.0, 270.0, 60.0)

                                local success = DPW.Utils.ProgressBar(
                                    'Replacing bulb and repairing ballast...',
                                    cfg.repairAnim.duration,
                                    cfg.repairAnim.dict,
                                    cfg.repairAnim.anim
                                )

                                -- Remove welding tool
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end

                                if success then
                                    -- Stop sparks
                                    if sparkPtfx then
                                        DPW.Utils.StopParticle(sparkPtfx)
                                    end

                                    DPW.Utils.NotifySuccess('Streetlight repaired successfully!')
                                    DPW.CompleteTask()
                                    return
                                end
                            else
                                DPW.Utils.Notify('Repair failed. Try again.')
                            end
                        end
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ============================================================================
-- TASK E: DAMAGED ROADS & POTHOLES
-- Steps: 1=PlaceCones, 2=GrabRake, 3=RepairPothole
-- ============================================================================

function DPW.Tasks.SetupPothole(task)
    local cfg = task.config
    local coords = task.coords

    -- Spawn pothole / cracked road prop
    local potholeProp = DPW.Utils.SpawnNetworkedProp(cfg.potholeModel, coords, true)
    TrackProp(potholeProp)

    -- Pre-defined cone positions around the pothole
    local coneEntities = {}
    local conesPlaced = 0

    local coneTargets = {}
    for _, offset in ipairs(cfg.coneOffsets) do
        table.insert(coneTargets, coords + offset)
    end

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'pothole' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 2 is fetch from truck — handled OUTSIDE pothole-distance check
            if step == 2 then
                sleep = Config.Optimization.activeInterval

                if DPW.IsNearVehicleTrunk() then
                    DPW.Utils.DrawText3D(pedCoords + vector3(0, 0, 1.5), Config.Labels.grabRake)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Grabbing asphalt rake...',
                            Config.Anims.grabFromTruck.duration,
                            Config.Anims.grabFromTruck.dict,
                            Config.Anims.grabFromTruck.anim
                        )
                        if success then
                            -- Attach rake to player (direct create+attach)
                            AttachToolToPed(ped, cfg.rakeModel, 0.2, 0.0, -0.15, -80.0, 0.0, 0.0)
                            activeTaskData.step = 3
                            DPW.Utils.Notify('Rake ready. Repair the pothole!')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then
                        DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for asphalt rake')
                    end
                end

            -- Steps 1 and 3 require being near the pothole
            elseif dist < 40.0 then
                sleep = Config.Optimization.activeInterval

                if step == 1 and dist < Config.Optimization.activeRange then
                    -- Place cones around the pothole
                    if conesPlaced < cfg.requiredCones then
                        local nextTarget = coneTargets[conesPlaced + 1]
                        if nextTarget then
                            local distToTarget = #(pedCoords - nextTarget)
                            DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0),
                                Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, cfg.requiredCones))

                            if distToTarget < Config.Optimization.interactionRange then
                                if DPW.Utils.IsEPressed() then
                                    local success = DPW.Utils.ProgressBar(
                                        'Placing traffic cone...',
                                        Config.Anims.placeItem.duration,
                                        Config.Anims.placeItem.dict,
                                        Config.Anims.placeItem.anim
                                    )
                                    if success then
                                        local cone = DPW.Utils.SpawnNetworkedProp(cfg.coneModel, nextTarget, true)
                                        if cone then
                                            TrackProp(cone)
                                            table.insert(coneEntities, cone)
                                        end
                                        conesPlaced = conesPlaced + 1
                                    end
                                end
                            end
                        end
                    end

                    -- All cones placed, advance
                    if conesPlaced >= cfg.requiredCones then
                        activeTaskData.step = 2
                        DPW.Utils.Notify('Cones placed. Grab an asphalt rake from the truck.')
                    end

                elseif step == 3 and dist < Config.Optimization.interactionRange + 1.0 then
                    -- Repair the pothole
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.0), Config.Labels.startRepair)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar(
                            'Repairing pothole...',
                            cfg.shovelAnim.duration,
                            cfg.shovelAnim.dict,
                            cfg.shovelAnim.anim
                        )
                        if success then
                            -- Remove attached rake
                            if activeTaskData.attachedProp then
                                DetachEntity(activeTaskData.attachedProp, false, false)
                                DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                activeTaskData.attachedProp = nil
                            end

                            -- Delete pothole prop
                            if potholeProp then
                                DPW.Utils.DeleteEntitySafe(potholeProp)
                            end

                            -- Delete cones
                            for _, cone in ipairs(coneEntities) do
                                DPW.Utils.DeleteEntitySafe(cone)
                            end

                            DPW.Utils.NotifySuccess('Road repaired successfully!')
                            DPW.CompleteTask()
                            return
                        end
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ============================================================================
-- DEBUG: Get active task info
-- ============================================================================

--- Get info about the currently active task
---@return table|nil
function DPW.Tasks.GetActiveTaskInfo()
    if not activeTaskData.task then return nil end
    return {
        type = activeTaskData.task.type,
        step = activeTaskData.step,
        coords = activeTaskData.task.coords,
    }
end

-- Debug command to check task state
RegisterCommand('dpwtaskinfo', function()
    local info = DPW.Tasks.GetActiveTaskInfo()
    if info then
        print(('[DPW] Active Task: %s | Step: %d | Coords: %s'):format(info.type, info.step, tostring(info.coords)))
        DPW.Utils.Notify(('Task: %s, Step: %d'):format(info.type, info.step))
    else
        print('[DPW] No active task.')
        DPW.Utils.Notify('No active task.')
    end
end, false)