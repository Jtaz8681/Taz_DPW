-- ============================================================================
-- Taz_DPW - Client Task Implementations
-- All 5 mission types (A–E) with standardized inspect → cones → repair flow
-- ============================================================================

DPW.Tasks = {}

-- Local state for the current active task
local activeTaskData = {
    task = nil,
    step = 0,
    props = {},
    particles = {},
    attachedProp = nil,
    entities = {},
    coneEntities = {},
    conesPlaced = 0,
    threadRunning = false,
}

-- ============================================================================
-- TASK ROUTING
-- ============================================================================

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
    activeTaskData.coneEntities = {}
    activeTaskData.conesPlaced = 0

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

function DPW.Tasks.CleanupCurrentTask()
    for _, prop in ipairs(activeTaskData.props) do
        DPW.Utils.DeleteEntitySafe(prop)
    end
    activeTaskData.props = {}

    for _, ptfx in ipairs(activeTaskData.particles) do
        DPW.Utils.StopParticle(ptfx)
    end
    activeTaskData.particles = {}

    if activeTaskData.attachedProp and DoesEntityExist(activeTaskData.attachedProp) then
        DetachEntity(activeTaskData.attachedProp, false, false)
        DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
        activeTaskData.attachedProp = nil
    end

    -- Clean up cones
    for _, cone in ipairs(activeTaskData.coneEntities) do
        DPW.Utils.DeleteEntitySafe(cone)
    end
    activeTaskData.coneEntities = {}
    activeTaskData.conesPlaced = 0

    activeTaskData.entities = {}
    ClearPedTasks(PlayerPedId())

    activeTaskData.task = nil
    activeTaskData.step = 0
    activeTaskData.threadRunning = false
end

-- ============================================================================
-- HELPERS
-- ============================================================================
local function TrackProp(entity)
    if entity then table.insert(activeTaskData.props, entity) end
    return entity
end

local function TrackParticle(handle)
    if handle then table.insert(activeTaskData.particles, handle) end
    return handle
end

local function TrackCone(entity)
    if entity then
        table.insert(activeTaskData.coneEntities, entity)
        table.insert(activeTaskData.props, entity)
    end
    return entity
end

local function AttachToolToPed(ped, model, posX, posY, posZ, rotX, rotY, rotZ, bone)
    if activeTaskData.attachedProp and DoesEntityExist(activeTaskData.attachedProp) then
        DetachEntity(activeTaskData.attachedProp, false, false)
        DeleteEntity(activeTaskData.attachedProp)
        activeTaskData.attachedProp = nil
    end

    local modelHash = GetHashKey(model)
    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) do
        timeout = timeout + 1
        if timeout > 100 then
            print(('[DPW] ERROR: Failed to load tool model: %s'):format(model))
            SetModelAsNoLongerNeeded(modelHash)
            return nil
        end
        Wait(100)
    end

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

-- Shared cone target positions
local function GetConeTargets(coords)
    local targets = {}
    for _, offset in ipairs(Config.SharedCones.offsets) do
        table.insert(targets, coords + offset)
    end
    return targets
end

-- ============================================================================
-- TASK A: BURST FIRE HYDRANTS
-- Steps: 1=Inspect, 2=FetchCones, 3=PlaceCones, 4=ShutOff, 5=FetchHydrant, 6=Install
-- ============================================================================

function DPW.Tasks.SetupHydrant(task)
    local cfg = task.config
    local coords = task.coords

    -- Delete existing hydrant, spawn water particle
    local existingHydrant = DPW.Utils.GetClosestObjectOfType(coords, cfg.hydrantModel, 3.0)
    if existingHydrant then DPW.Utils.DeleteEntitySafe(existingHydrant) end

    local ptfxPos = coords + vector3(0, 0, cfg.waterParticle.zOffset or 3.0)
    DPW.Utils.LoadParticleAsset(cfg.waterParticle.asset)
    UseParticleFxAssetNextCall(cfg.waterParticle.asset)
    local waterPtfx = StartParticleFxLoopedAtCoord(
        cfg.waterParticle.effect, ptfxPos.x, ptfxPos.y, ptfxPos.z,
        0.0, 0.0, 0.0, cfg.waterParticle.scale or 1.0, false, false, false, false)
    if waterPtfx and waterPtfx ~= 0 then TrackParticle(waterPtfx) end

    local coneTargets = GetConeTargets(coords)

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'hydrant' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 2: Fetch cones at truck
            if step == 2 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchCones) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing traffic cones...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 3
                            activeTaskData.conesPlaced = 0
                            DPW.Utils.Notify('Place 4 traffic cones around the work area.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for traffic cones') end
                end

            -- STEP 5: Fetch hydrant at truck
            elseif step == 5 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchHydrant) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Fetching hydrant...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            local offset = cfg.carryHydrantOffset
                            local rot = cfg.carryHydrantRotation
                            AttachToolToPed(ped, cfg.hydrantModel, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z, cfg.carryBone)
                            activeTaskData.step = 6
                            DPW.Utils.Notify('Carry the hydrant back to the burst location.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck to fetch hydrant') end
                end

            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if step == 1 and dist < Config.Optimization.interactionRange then
                    -- Inspect
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.0), Config.Labels.inspectSite)
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Inspecting burst hydrant...', 5000, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 2
                            DPW.Utils.Notify('Hydrant is burst. Get traffic cones from your truck.')
                        end
                    end

                elseif step == 3 and dist < Config.Optimization.activeRange then
                    -- Place cones
                    local conesPlaced = activeTaskData.conesPlaced
                    if conesPlaced < Config.SharedCones.requiredCones then
                        local nextTarget = coneTargets[conesPlaced + 1]
                        if nextTarget then
                            local distToTarget = #(pedCoords - nextTarget)
                            DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0), Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, Config.SharedCones.requiredCones))
                            if distToTarget < Config.Optimization.interactionRange and DPW.Utils.IsEPressed() then
                                local success = DPW.Utils.ProgressBar('Placing traffic cone...', Config.Anims.placeItem.duration, Config.Anims.placeItem.dict, Config.Anims.placeItem.anim)
                                if success then
                                    local cone = DPW.Utils.SpawnNetworkedProp(Config.SharedCones.model, nextTarget, true)
                                    TrackCone(cone)
                                    activeTaskData.conesPlaced = conesPlaced + 1
                                end
                            end
                        end
                    end
                    if activeTaskData.conesPlaced >= Config.SharedCones.requiredCones then
                        activeTaskData.step = 4
                        DPW.Utils.Notify('Cones placed. Shut off the main valve.')
                    end

                elseif step == 4 and dist < Config.Optimization.interactionRange then
                    -- Shut off valve
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.0), Config.Labels.shutOffValve)
                    if DPW.Utils.IsEPressed() then
                        local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                        if passed then
                            local success = DPW.Utils.ProgressBar('Shutting off main valve...', cfg.shutOffAnim.duration, cfg.shutOffAnim.dict, cfg.shutOffAnim.anim)
                            if success then
                                if waterPtfx then DPW.Utils.StopParticle(waterPtfx); waterPtfx = nil end
                                activeTaskData.step = 5
                                DPW.Utils.Notify('Valve shut off. Fetch a new hydrant from your truck.')
                            end
                        else
                            DPW.Utils.Notify('Failed to shut off valve. Try again.')
                        end
                    end

                elseif step == 6 and dist < Config.Optimization.interactionRange then
                    -- Install hydrant
                    DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.0), Config.Labels.installHydrant)
                    if DPW.Utils.IsEPressed() then
                        AttachToolToPed(ped, 'prop_weld_torch', 0.1, 0.0, 0.0, 280.0, 0.0, 225.0)
                        local success = DPW.Utils.ProgressBar('Installing new hydrant...', cfg.installAnim.duration, cfg.installAnim.dict, cfg.installAnim.anim)
                        if success then
                            if activeTaskData.attachedProp then
                                DetachEntity(activeTaskData.attachedProp, false, false)
                                DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                activeTaskData.attachedProp = nil
                            end
                            local replacementHydrant = DPW.Utils.SpawnNetworkedProp(cfg.hydrantModel, coords, true)
                            if replacementHydrant then
                                SetTimeout(cfg.replacementHydrantDuration or 120000, function()
                                    if DoesEntityExist(replacementHydrant) then DPW.Utils.DeleteEntitySafe(replacementHydrant) end
                                end)
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
-- Steps: 1=Inspect, 2=FetchCones, 3=PlaceCones, 4=FetchJackhammer, 5=Drill, 6=Smooth
-- ============================================================================

function DPW.Tasks.SetupSidewalk(task)
    local cfg = task.config
    local coords = task.coords

    local damagedProp = DPW.Utils.SpawnLocalProp(cfg.damagedProp, coords, true)
    TrackProp(damagedProp)

    local coneTargets = GetConeTargets(coords)

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'sidewalk' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            -- STEP 2: Fetch cones at truck
            if step == 2 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchCones) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing traffic cones...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 3
                            activeTaskData.conesPlaced = 0
                            DPW.Utils.Notify('Place 4 traffic cones around the work area.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for traffic cones') end
                end

            -- STEP 4: Fetch jackhammer at truck
            elseif step == 4 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchJackhammer) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing jackhammer...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            AttachToolToPed(ped, cfg.jackhammerModel, 0.1, 0.0, 0.0, 280.0, 0.0, 0.0)
                            activeTaskData.step = 5
                            DPW.Utils.Notify('Jackhammer ready. Start drilling the sidewalk!')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck to grab jackhammer') end
                end

            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if dist < Config.Optimization.interactionRange + 2.0 then
                    if step == 1 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.5), Config.Labels.inspectSite)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar('Inspecting sidewalk damage...', 5000, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                            if success then
                                activeTaskData.step = 2
                                DPW.Utils.Notify('Sidewalk needs repair. Get traffic cones from your truck.')
                            end
                        end

                    elseif step == 3 and dist < Config.Optimization.activeRange then
                        local conesPlaced = activeTaskData.conesPlaced
                        if conesPlaced < Config.SharedCones.requiredCones then
                            local nextTarget = coneTargets[conesPlaced + 1]
                            if nextTarget then
                                local distToTarget = #(pedCoords - nextTarget)
                                DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0), Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, Config.SharedCones.requiredCones))
                                if distToTarget < Config.Optimization.interactionRange and DPW.Utils.IsEPressed() then
                                    local success = DPW.Utils.ProgressBar('Placing traffic cone...', Config.Anims.placeItem.duration, Config.Anims.placeItem.dict, Config.Anims.placeItem.anim)
                                    if success then
                                        local cone = DPW.Utils.SpawnNetworkedProp(Config.SharedCones.model, nextTarget, true)
                                        TrackCone(cone)
                                        activeTaskData.conesPlaced = conesPlaced + 1
                                    end
                                end
                            end
                        end
                        if activeTaskData.conesPlaced >= Config.SharedCones.requiredCones then
                            activeTaskData.step = 4
                            DPW.Utils.Notify('Cones placed. Grab a jackhammer from your truck.')
                        end

                    elseif step == 5 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.5), Config.Labels.startDrilling)
                        if DPW.Utils.IsEPressed() then
                            ShakeGameplayCam('ROAD_VIBRATION_SHAKE', cfg.screenShake.intensity)
                            local success = DPW.Utils.ProgressBar('Drilling broken sidewalk...', cfg.drillAnim.duration, cfg.drillAnim.dict, cfg.drillAnim.anim)
                            StopGameplayCamShaking(true)
                            if success then
                                activeTaskData.step = 6
                                DPW.Utils.Notify('Drilling complete. Smooth the surface now.')
                            end
                        end

                    elseif step == 6 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.5), Config.Labels.startSmoothing)
                        if DPW.Utils.IsEPressed() then
                            if activeTaskData.attachedProp then
                                DetachEntity(activeTaskData.attachedProp, false, false)
                                DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                activeTaskData.attachedProp = nil
                            end
                            local success = DPW.Utils.ProgressBar('Smoothing and pouring concrete...', cfg.smoothAnim.duration, cfg.smoothAnim.dict, cfg.smoothAnim.anim)
                            if success then
                                if damagedProp then DPW.Utils.DeleteEntitySafe(damagedProp) end
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
-- Steps: 1=Inspect, 2=FetchCones, 3=PlaceCones, 4=FetchWires, 5=FixSignal
-- ============================================================================

function DPW.Tasks.SetupTrafficSignal(task)
    local cfg = task.config
    local coords = task.coords

    local trafficLight = DPW.Utils.GetClosestObjectOfType(coords, cfg.trafficLightModel, 15.0)
    activeTaskData.entities.trafficLight = trafficLight

    local sparkOffset = vector3(0.0, 0.0, 3.5)
    local sparkPtfx = nil
    if trafficLight and trafficLight ~= 0 then
        sparkPtfx = DPW.Utils.StartParticleOnEntity(cfg.sparkParticle.asset, cfg.sparkParticle.effect, trafficLight, sparkOffset)
    else
        sparkPtfx = DPW.Utils.StartParticle(cfg.sparkParticle.asset, cfg.sparkParticle.effect, coords + sparkOffset, true)
    end
    TrackParticle(sparkPtfx)

    local coneTargets = GetConeTargets(coords)

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'traffic_signal' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            if step == 2 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchCones) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing traffic cones...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 3
                            activeTaskData.conesPlaced = 0
                            DPW.Utils.Notify('Place 4 traffic cones around the work area.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for traffic cones') end
                end

            elseif step == 4 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchWiresRelays) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing wires and relays...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 5
                            DPW.Utils.Notify('Got the parts! Head back to the traffic signal and fix it.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for wires & relays') end
                end

            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval

                if dist < Config.Optimization.interactionRange + 3.0 then
                    if step == 1 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.5), Config.Labels.inspectSite)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar('Investigating signal malfunction...', 5000, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                            if success then
                                activeTaskData.step = 2
                                DPW.Utils.Notify('Signal needs repair. Get traffic cones from your truck.')
                            end
                        end

                    elseif step == 3 and dist < Config.Optimization.activeRange then
                        local conesPlaced = activeTaskData.conesPlaced
                        if conesPlaced < Config.SharedCones.requiredCones then
                            local nextTarget = coneTargets[conesPlaced + 1]
                            if nextTarget then
                                local distToTarget = #(pedCoords - nextTarget)
                                DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0), Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, Config.SharedCones.requiredCones))
                                if distToTarget < Config.Optimization.interactionRange and DPW.Utils.IsEPressed() then
                                    local success = DPW.Utils.ProgressBar('Placing traffic cone...', Config.Anims.placeItem.duration, Config.Anims.placeItem.dict, Config.Anims.placeItem.anim)
                                    if success then
                                        local cone = DPW.Utils.SpawnNetworkedProp(Config.SharedCones.model, nextTarget, true)
                                        TrackCone(cone)
                                        activeTaskData.conesPlaced = conesPlaced + 1
                                    end
                                end
                            end
                        end
                        if activeTaskData.conesPlaced >= Config.SharedCones.requiredCones then
                            activeTaskData.step = 4
                            DPW.Utils.Notify('Cones placed. Get wires and relays from your truck.')
                        end

                    elseif step == 5 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 2.5), Config.Labels.fixSignal)
                        if DPW.Utils.IsEPressed() then
                            local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                            if passed then
                                AttachToolToPed(ped, cfg.welderModel, 0.1, 0.0, 0.0, 280.0, 0.0, 225.0)
                                local success = DPW.Utils.ProgressBar('Repairing traffic signal...', cfg.wiringAnim.duration, cfg.wiringAnim.dict, cfg.wiringAnim.anim)
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end
                                if success then
                                    if sparkPtfx then DPW.Utils.StopParticle(sparkPtfx) end
                                    DPW.Utils.NotifySuccess('Traffic signal repaired successfully!')
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
-- TASK D: DEAD STREETLIGHTS
-- Steps: 1=Inspect, 2=FetchCones, 3=PlaceCones, 4=FetchParts, 5=RepairLight
-- ============================================================================

function DPW.Tasks.SetupStreetlight(task)
    local cfg = task.config
    local coords = task.coords

    local streetlight = DPW.Utils.GetClosestObjectOfType(coords, cfg.streetlightModel, 10.0)
    activeTaskData.entities.streetlight = streetlight

    local sparkOffsetTop = vector3(0.0, 0.0, 5.0)
    local sparkPtfx = nil
    if streetlight and streetlight ~= 0 then
        sparkPtfx = DPW.Utils.StartParticleOnEntity(cfg.sparkParticle.asset, cfg.sparkParticle.effect, streetlight, sparkOffsetTop)
    else
        sparkPtfx = DPW.Utils.StartParticle(cfg.sparkParticle.asset, cfg.sparkParticle.effect, coords + sparkOffsetTop, true)
    end
    TrackParticle(sparkPtfx)

    local coneTargets = GetConeTargets(coords)

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'streetlight' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            if step == 2 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchCones) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing traffic cones...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 3
                            activeTaskData.conesPlaced = 0
                            DPW.Utils.Notify('Place 4 traffic cones around the work area.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for traffic cones') end
                end

            elseif step == 4 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchLightParts) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing replacement parts...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 5
                            DPW.Utils.Notify('Got the parts! Head back to the streetlight and repair it.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for replacement parts') end
                end

            elseif dist < 30.0 then
                sleep = Config.Optimization.activeInterval
                local baseCoords = coords + vector3(0, 0, 0.5)
                local distToBase = #(pedCoords - baseCoords)

                if distToBase < Config.Optimization.interactionRange + 1.5 then
                    if step == 1 then
                        DPW.Utils.DrawText3D(baseCoords + vector3(0, 0, 1.0), Config.Labels.inspectSite)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar('Inspecting streetlight...', 5000, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                            if success then
                                activeTaskData.step = 2
                                DPW.Utils.Notify('The bulb and ballast are dead. Get traffic cones from your truck.')
                            end
                        end

                    elseif step == 3 then
                        local conesPlaced = activeTaskData.conesPlaced
                        if conesPlaced < Config.SharedCones.requiredCones then
                            local nextTarget = coneTargets[conesPlaced + 1]
                            if nextTarget then
                                local distToTarget = #(pedCoords - nextTarget)
                                DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0), Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, Config.SharedCones.requiredCones))
                                if distToTarget < Config.Optimization.interactionRange and DPW.Utils.IsEPressed() then
                                    local success = DPW.Utils.ProgressBar('Placing traffic cone...', Config.Anims.placeItem.duration, Config.Anims.placeItem.dict, Config.Anims.placeItem.anim)
                                    if success then
                                        local cone = DPW.Utils.SpawnNetworkedProp(Config.SharedCones.model, nextTarget, true)
                                        TrackCone(cone)
                                        activeTaskData.conesPlaced = conesPlaced + 1
                                    end
                                end
                            end
                        end
                        if activeTaskData.conesPlaced >= Config.SharedCones.requiredCones then
                            activeTaskData.step = 4
                            DPW.Utils.Notify('Cones placed. Get replacement parts from your truck.')
                        end

                    elseif step == 5 then
                        DPW.Utils.DrawText3D(baseCoords + vector3(0, 0, 1.0), Config.Labels.repairLight)
                        if DPW.Utils.IsEPressed() then
                            local passed = DPW.Utils.SkillCheck(cfg.skillCheck)
                            if passed then
                                AttachToolToPed(ped, 'prop_weld_torch', 0.1, 0.0, 0.0, 280.0, 0.0, 225.0)
                                local success = DPW.Utils.ProgressBar('Replacing bulb and repairing ballast...', cfg.repairAnim.duration, cfg.repairAnim.dict, cfg.repairAnim.anim)
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end
                                if success then
                                    if sparkPtfx then DPW.Utils.StopParticle(sparkPtfx) end
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
-- Steps: 1=Inspect, 2=FetchCones, 3=PlaceCones, 4=GrabRake, 5=RepairPothole
-- ============================================================================

function DPW.Tasks.SetupPothole(task)
    local cfg = task.config
    local coords = task.coords

    local potholeProp = DPW.Utils.SpawnNetworkedProp(cfg.potholeModel, coords, true)
    TrackProp(potholeProp)

    local coneTargets = GetConeTargets(coords)

    CreateThread(function()
        while activeTaskData.task and activeTaskData.task.type == 'pothole' do
            local sleep = Config.Optimization.lazyInterval
            local ped = PlayerPedId()
            local pedCoords = GetEntityCoords(ped)
            local dist = #(pedCoords - coords)
            local step = activeTaskData.step

            if step == 2 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.fetchCones) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing traffic cones...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            activeTaskData.step = 3
                            activeTaskData.conesPlaced = 0
                            DPW.Utils.Notify('Place 4 traffic cones around the work area.')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for traffic cones') end
                end

            elseif step == 4 then
                sleep = Config.Optimization.activeInterval
                if DPW.IsNearVehicleTrunk() then
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), Config.Labels.grabRake) end
                    if DPW.Utils.IsEPressed() then
                        local success = DPW.Utils.ProgressBar('Grabbing asphalt rake...', Config.Anims.grabFromTruck.duration, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                        if success then
                            AttachToolToPed(ped, cfg.rakeModel, 0.1, 0.0, 0.0, 280.0, 0.0, 0.0)
                            activeTaskData.step = 5
                            DPW.Utils.Notify('Rake ready. Repair the pothole!')
                        end
                    end
                else
                    local vehCoords = DPW.GetDutyVehicleCoords()
                    if vehCoords then DPW.Utils.DrawText3D(vehCoords + vector3(0, 0, 1.5), '~y~Go to truck for asphalt rake') end
                end

            elseif dist < 40.0 then
                sleep = Config.Optimization.activeInterval

                if dist < Config.Optimization.interactionRange + 1.0 then
                    if step == 1 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.0), Config.Labels.inspectSite)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar('Inspecting road damage...', 5000, Config.Anims.grabFromTruck.dict, Config.Anims.grabFromTruck.anim)
                            if success then
                                activeTaskData.step = 2
                                DPW.Utils.Notify('Pothole needs repair. Get traffic cones from your truck.')
                            end
                        end

                    elseif step == 3 and dist < Config.Optimization.activeRange then
                        local conesPlaced = activeTaskData.conesPlaced
                        if conesPlaced < Config.SharedCones.requiredCones then
                            local nextTarget = coneTargets[conesPlaced + 1]
                            if nextTarget then
                                local distToTarget = #(pedCoords - nextTarget)
                                DPW.Utils.DrawText3D(nextTarget + vector3(0, 0, 1.0), Config.Labels.placeCones .. (' (%d/%d)'):format(conesPlaced + 1, Config.SharedCones.requiredCones))
                                if distToTarget < Config.Optimization.interactionRange and DPW.Utils.IsEPressed() then
                                    local success = DPW.Utils.ProgressBar('Placing traffic cone...', Config.Anims.placeItem.duration, Config.Anims.placeItem.dict, Config.Anims.placeItem.anim)
                                    if success then
                                        local cone = DPW.Utils.SpawnNetworkedProp(Config.SharedCones.model, nextTarget, true)
                                        TrackCone(cone)
                                        activeTaskData.conesPlaced = conesPlaced + 1
                                    end
                                end
                            end
                        end
                        if activeTaskData.conesPlaced >= Config.SharedCones.requiredCones then
                            activeTaskData.step = 4
                            DPW.Utils.Notify('Cones placed. Grab a shovel from the truck.')
                        end

                    elseif step == 5 then
                        DPW.Utils.DrawText3D(coords + vector3(0, 0, 1.0), Config.Labels.startRepair)
                        if DPW.Utils.IsEPressed() then
                            local success = DPW.Utils.ProgressBar('Repairing pothole...', cfg.shovelAnim.duration, cfg.shovelAnim.dict, cfg.shovelAnim.anim)
                            if success then
                                if activeTaskData.attachedProp then
                                    DetachEntity(activeTaskData.attachedProp, false, false)
                                    DPW.Utils.DeleteEntitySafe(activeTaskData.attachedProp)
                                    activeTaskData.attachedProp = nil
                                end
                                if potholeProp then DPW.Utils.DeleteEntitySafe(potholeProp) end
                                DPW.Utils.NotifySuccess('Road repaired successfully!')
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
-- DEBUG
-- ============================================================================

function DPW.Tasks.GetActiveTaskInfo()
    if not activeTaskData.task then return nil end
    return {
        type = activeTaskData.task.type,
        step = activeTaskData.step,
        coords = activeTaskData.task.coords,
        conesPlaced = activeTaskData.conesPlaced,
    }
end

RegisterCommand('dpwtaskinfo', function()
    local info = DPW.Tasks.GetActiveTaskInfo()
    if info then
        print(('[DPW] Active Task: %s | Step: %d | Cones: %d | Coords: %s'):format(info.type, info.step, info.conesPlaced, tostring(info.coords)))
        DPW.Utils.Notify(('Task: %s, Step: %d, Cones: %d'):format(info.type, info.step, info.conesPlaced))
    else
        print('[DPW] No active task.')
        DPW.Utils.Notify('No active task.')
    end
end, false)