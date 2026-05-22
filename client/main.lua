-- ============================================================================

-- State variables
local isOnDuty = false
local dutyVehicle = nil
local dutyVehicleBlip = nil
local hqBlip = nil
local currentTask = nil       -- Active task data
local isTaskActive = false    -- Whether a task is currently in progress
local lastIdleTime = 0        -- Timestamp of last idle state
local isDispatching = false   -- Whether dispatch system is active
local missionBlip = nil       -- GPS route blip for current mission
local activeDispatchMessage = nil  -- Persistent dispatch HUD text (nil = hidden)

-- ============================================================================
-- HQ BLIP CREATION
-- ============================================================================

local function CreateHQBlip()
    if hqBlip then return end
    local cfg = Config.HQ
    hqBlip = AddBlipForCoord(cfg.coords.x, cfg.coords.y, cfg.coords.z)
    SetBlipSprite(hqBlip, cfg.blip.sprite)
    SetBlipColour(hqBlip, cfg.blip.color)
    SetBlipScale(hqBlip, cfg.blip.scale)
    SetBlipAsShortRange(hqBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(cfg.blip.label)
    EndTextCommandSetBlipName(hqBlip)
end

-- ============================================================================
-- CLOCK IN / OUT
-- ============================================================================

local function ClockIn()
    if isOnDuty then return end
    isOnDuty = true
    lastIdleTime = GetGameTimer()
    DPW.Utils.Notify(Config.Labels.dutyOn)
    -- Notify server for salary tracking
    TriggerServerEvent('dpw:clockIn')
    -- Start dispatch loop
    isDispatching = true
end

local function ClockOut()
    if not isOnDuty then return end
    isOnDuty = false
    isDispatching = false

    -- Cancel current task if active
    if isTaskActive and currentTask then
        DPW.Tasks.CleanupCurrentTask()
        isTaskActive = false
        currentTask = nil
    end

    -- Clear dispatch HUD
    activeDispatchMessage = nil

    -- Remove mission blip / GPS route
    if missionBlip then
        DPW.Utils.RemoveBlip(missionBlip)
        missionBlip = nil
    end

    -- Remove duty vehicle
    if dutyVehicle and DoesEntityExist(dutyVehicle) then
        DPW.Utils.DeleteEntitySafe(dutyVehicle)
        dutyVehicle = nil
    end
    if dutyVehicleBlip then
        DPW.Utils.RemoveBlip(dutyVehicleBlip)
        dutyVehicleBlip = nil
    end

    -- Cleanup all spawned entities
    DPW.Utils.CleanupAll()

    -- Notify server for salary tracking
    TriggerServerEvent('dpw:clockOut')

    DPW.Utils.Notify(Config.Labels.dutyOff)
end

-- ============================================================================
-- VEHICLE SPAWNER
-- ============================================================================

local function SpawnDutyVehicle()
    if dutyVehicle and DoesEntityExist(dutyVehicle) then
        DPW.Utils.Notify('You already have a DPW truck. Return it first.')
        return
    end

    local cfg = Config.Vehicle
    local modelHash = DPW.Utils.LoadModel(cfg.model)
    if not modelHash then
        DPW.Utils.Notify('Failed to load vehicle model.')
        return
    end

    local ped = PlayerPedId()
    local coords = cfg.spawnCoords

    dutyVehicle = CreateVehicle(modelHash, coords.x, coords.y, coords.z, coords.w, true, true)
    if dutyVehicle and dutyVehicle ~= 0 then
        SetEntityAsMissionEntity(dutyVehicle, true, true)
        local plateText = cfg.platePrefix .. math.random(1000, 9999)
        SetVehicleNumberPlateText(dutyVehicle, plateText)
        SetVehicleOnGroundProperly(dutyVehicle)
        SetVehicleColours(dutyVehicle, 111, 111) -- Yellow-ish utility color
        SetVehicleLivery(dutyVehicle, 0)

        -- Create vehicle blip
        dutyVehicleBlip = AddBlipForEntity(dutyVehicle)
        SetBlipSprite(dutyVehicleBlip, 326) -- Car symbol
        SetBlipColour(dutyVehicleBlip, 5)
        SetBlipScale(dutyVehicleBlip, 0.7)
        SetBlipAsShortRange(dutyVehicleBlip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName('DPW Truck')
        EndTextCommandSetBlipName(dutyVehicleBlip)

        -- Put player in driver seat
        SetPedIntoVehicle(ped, dutyVehicle, -1)

        -- Wait for vehicle to be fully networked before requesting keys
        Wait(500)

        -- Give player keys via server event (more reliable than client callback)
        local netId = VehToNet(dutyVehicle)
        if netId and netId ~= 0 then
            TriggerServerEvent('dpw:giveVehicleKeys', netId)
        end
        DPW.Utils.Notify('DPW utility truck dispatched!')
    end

    SetModelAsNoLongerNeeded(modelHash)
end

-- ============================================================================
-- DISPATCH SYSTEM
-- ============================================================================

local taskTypes = { 'hydrant', 'sidewalk', 'traffic_signal', 'streetlight', 'pothole' }
local taskConfigKeys = {
    hydrant = 'Hydrant',
    sidewalk = 'Sidewalk',
    traffic_signal = 'TrafficSignal',
    streetlight = 'Streetlight',
    pothole = 'Pothole',
}

local function PickRandomTask()
    -- Build list of enabled task types
    local enabledTasks = {}
    for _, taskType in ipairs(taskTypes) do
        local key = taskConfigKeys[taskType]
        if Config.Tasks[key] and Config.Tasks[key].enabled then
            table.insert(enabledTasks, taskType)
        end
    end

    if #enabledTasks == 0 then
        print('[DPW] No tasks enabled in config!')
        return nil
    end

    -- Pick a random task type
    local taskType = enabledTasks[math.random(1, #enabledTasks)]
    local key = taskConfigKeys[taskType]
    local taskCfg = Config.Tasks[key]

    -- Pick a random location
    local locations = taskCfg.locations
    if not locations or #locations == 0 then
        print(('[DPW] No locations defined for task: %s'):format(taskType))
        return nil
    end

    local location = locations[math.random(1, #locations)]

    return {
        type = taskType,
        configKey = key,
        coords = location,
        config = taskCfg,
    }
end

local function DispatchMission()
    if isTaskActive then return end

    local task = PickRandomTask()
    if not task then return end

    currentTask = task
    isTaskActive = true
    lastIdleTime = GetGameTimer()

    -- Set GPS route
    if missionBlip then
        DPW.Utils.RemoveBlip(missionBlip)
    end
    missionBlip = DPW.Utils.SetGPSRoute(
        task.coords,
        Config.Dispatch.gpsBlipColor,
        Config.Dispatch.gpsBlipSprite
    )

    -- Show dispatch notification and store persistent HUD message
    local labelMap = {
        hydrant = Config.Labels.dispatchHydrant,
        sidewalk = Config.Labels.dispatchSidewalk,
        traffic_signal = Config.Labels.dispatchSignal,
        streetlight = Config.Labels.dispatchStreetlight,
        pothole = Config.Labels.dispatchPothole,
    }
    activeDispatchMessage = labelMap[task.type] or 'Dispatch: New task assigned!'
    DPW.Utils.Notify(activeDispatchMessage, Config.Dispatch.notifyDuration)

    -- Setup the task (calls into tasks.lua)
    DPW.Tasks.SetupTask(task)
end

-- ============================================================================
-- TASK COMPLETION HANDLER
-- ============================================================================

-- Called from tasks.lua when a task is fully completed
function DPW.CompleteTask()
    if not isTaskActive or not currentTask then return end

    local taskType = currentTask.type
    local taskCoords = currentTask.coords

    -- Remove mission blip / GPS
    if missionBlip then
        DPW.Utils.RemoveBlip(missionBlip)
        missionBlip = nil
    end

    -- Clean up task-specific props/particles
    DPW.Tasks.CleanupCurrentTask()

    -- Calculate task completion bonus (salary is paid periodically server-side)
    local taskBonus = (Config.Payout.taskBonus[taskType] or 25)
    local randomBonus = math.random(0, 15)
    local totalBonus = math.max(0, taskBonus + randomBonus)

    -- Trigger server event to give task bonus
    TriggerServerEvent('dpw:completeTask', taskType, totalBonus)

    -- Notification
    DPW.Utils.NotifySuccess(Config.Labels.taskComplete)
    DPW.Utils.Notify(Config.Labels.payoutReceived:format(totalBonus))

    -- Clear dispatch HUD
    activeDispatchMessage = nil

    -- Reset state
    isTaskActive = false
    currentTask = nil
    lastIdleTime = GetGameTimer()
end

-- ============================================================================
-- DISPATCH HUD RENDER THREAD (top-right persistent display while task active)
-- ============================================================================

CreateThread(function()
    while true do
        if activeDispatchMessage then
            -- Screen dimensions
            local screenW, screenH = GetActiveScreenResolution()
            local buffer = 50  -- 50px from corner
            local boxWidth = 0.22
            local boxHeight = 0.065

            -- Position: top-right with buffer (normalized 0-1)
            local boxX = 1.0 - (buffer / screenW) - boxWidth
            local boxY = (buffer / screenH)

            -- Draw background box (dark)
            DrawRect(boxX + boxWidth / 2, boxY + boxHeight / 2, boxWidth, boxHeight, 10, 10, 10, 200)

            -- Draw header accent bar (amber/yellow)
            DrawRect(boxX + boxWidth / 2, boxY + 0.012, boxWidth, 0.024, 200, 150, 0, 220)

            -- Header text
            SetTextScale(0.38, 0.38)
            SetTextFont(4)
            SetTextColour(0, 0, 0, 255)
            SetTextEntry('STRING')
            AddTextComponentString('DPW DISPATCH')
            DrawText(boxX + 0.008, boxY + 0.004)

            -- Dispatch message text
            SetTextScale(0.32, 0.32)
            SetTextFont(4)
            SetTextColour(255, 255, 255, 230)
            SetTextEntry('STRING')
            AddTextComponentString(activeDispatchMessage)
            DrawText(boxX + 0.008, boxY + 0.032)

            Wait(0) -- Must be 0 for continuous rendering
        else
            Wait(500) -- Sleep when no dispatch active
        end
    end
end)

-- ============================================================================
-- HQ INTERACTION THREAD
-- ============================================================================

CreateThread(function()
    -- Create HQ blip on load
    CreateHQBlip()

    while true do
        local sleep = Config.Optimization.lazyInterval
        local ped = PlayerPedId()
        local pedCoords = GetEntityCoords(ped)
        local hqCoords = vector3(Config.HQ.coords.x, Config.HQ.coords.y, Config.HQ.coords.z)
        local distToHQ = #(pedCoords - hqCoords)
        local vehicleSpawnCoords = vector3(Config.Vehicle.spawnCoords.x, Config.Vehicle.spawnCoords.y, Config.Vehicle.spawnCoords.z)
        local distToVehicleSpawn = #(pedCoords - vehicleSpawnCoords)

        -- Draw HQ marker and handle interaction
        if distToHQ < 30.0 then
            sleep = Config.Optimization.activeInterval

            local markerCfg = Config.HQ.marker
            DrawMarker(
                markerCfg.type,
                Config.HQ.coords.x, Config.HQ.coords.y, Config.HQ.coords.z - 0.9,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                markerCfg.size.x, markerCfg.size.y, markerCfg.size.z,
                markerCfg.color.r, markerCfg.color.g, markerCfg.color.b, markerCfg.color.a,
                markerCfg.bobUpAndDown, false, 2, false, nil, nil, false
            )

            if distToHQ < Config.Optimization.interactionRange then
                if not isOnDuty then
                    DPW.Utils.DrawText3D(hqCoords + vector3(0, 0, 1.0), Config.Labels.clockIn)
                    if DPW.Utils.IsEPressed() then
                        ClockIn()
                    end
                else
                    DPW.Utils.DrawText3D(hqCoords + vector3(0, 0, 1.0), Config.Labels.clockOut)
                    if DPW.Utils.IsEPressed() then
                        ClockOut()
                    end
                end
            end
        end

        -- Draw vehicle spawn marker
        if isOnDuty and distToVehicleSpawn < 20.0 then
            sleep = Config.Optimization.activeInterval
            DrawMarker(
                1, vehicleSpawnCoords.x, vehicleSpawnCoords.y, vehicleSpawnCoords.z - 0.9,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.5, 1.5, 1.0,
                200, 200, 50, 100,
                true, false, 2, false, nil, nil, false
            )

            if distToVehicleSpawn < Config.Optimization.interactionRange then
                DPW.Utils.DrawText3D(vehicleSpawnCoords + vector3(0, 0, 1.0), Config.Labels.spawnVehicle)
                if DPW.Utils.IsEPressed() then
                    SpawnDutyVehicle()
                end
            end
        end

        Wait(sleep)
    end
end)

-- ============================================================================
-- DISPATCH TIMER THREAD
-- ============================================================================

CreateThread(function()
    while true do
        Wait(Config.Dispatch.checkIntervalSeconds * 1000)

        if isOnDuty and isDispatching and not isTaskActive then
            local timeSinceIdle = GetGameTimer() - lastIdleTime
            local idleThreshold = Config.Dispatch.idleTimerMinutes * 60 * 1000

            if Config.Dispatch.autoDispatch and timeSinceIdle >= idleThreshold then
                DispatchMission()
            end
        end
    end
end)

-- ============================================================================
-- MANUAL DISPATCH COMMAND (for testing)
-- ============================================================================

RegisterCommand('dpwdispatch', function()
    if isOnDuty and not isTaskActive then
        DispatchMission()
    else
        DPW.Utils.Notify('You must be on duty and idle to dispatch.')
    end
end, false)

-- ============================================================================
-- RESOURCE STOP CLEANUP
-- ============================================================================

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- Clock out to clean up vehicles/blips
    if isOnDuty then
        ClockOut()
    end

    -- Nuclear cleanup
    DPW.Utils.CleanupAll()

    -- Remove HQ blip
    if hqBlip then
        RemoveBlip(hqBlip)
        hqBlip = nil
    end

    print('[DPW] Resource stopped — all entities cleaned up.')
end)

-- ============================================================================
-- UTILITY: Get duty vehicle
-- ============================================================================

--- Get the current duty vehicle entity
---@return number|nil
function DPW.GetDutyVehicle()
    if dutyVehicle and DoesEntityExist(dutyVehicle) then
        return dutyVehicle
    end
    return nil
end

--- Get duty vehicle coords
---@return vector3|nil
function DPW.GetDutyVehicleCoords()
    local veh = DPW.GetDutyVehicle()
    if veh then
        return GetEntityCoords(veh)
    end
    return nil
end

--- Check if player is near duty vehicle trunk
---@return boolean
function DPW.IsNearVehicleTrunk()
    local veh = DPW.GetDutyVehicle()
    if not veh then return false end
    local pedCoords = DPW.Utils.GetPedCoords()
    local vehCoords = GetEntityCoords(veh)
    return #(pedCoords - vehCoords) <= Config.Optimization.truckRetrieveRange
end

-- ============================================================================
-- SERVER EVENT HANDLERS (admin messages)
-- Salary notifications are handled natively by Qbox paycheck system
-- ============================================================================

--- Receive notification from server (admin command feedback)
RegisterNetEvent('dpw:notify', function(message)
    DPW.Utils.Notify(message)
end)
