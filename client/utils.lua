-- ============================================================================
-- Taz_DPW - Client Utility Functions
-- ============================================================================

DPW = {}
DPW.Utils = {}
DPW.Props = {}       -- Track all spawned props for cleanup
DPW.Particles = {}   -- Track all active particles for cleanup
DPW.Blips = {}       -- Track all created blips for cleanup

-- ============================================================================
-- MODEL LOADING
-- ============================================================================

--- Load a model and wait for it to be available
---@param model string|number The model name or hash
function DPW.Utils.LoadModel(model)
    local modelHash = type(model) == 'string' and joaat(model) or model
    if HasModelLoaded(modelHash) then return modelHash end
    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) do
        timeout = timeout + 1
        if timeout > 100 then
            print(('[DPW] Failed to load model: %s'):format(model))
            return nil
        end
        Wait(100)
    end
    return modelHash
end

-- ============================================================================
-- ANIMATION DICTIONARY LOADING
-- ============================================================================

--- Load an animation dictionary
---@param animDict string The animation dictionary name
function DPW.Utils.LoadAnimDict(animDict)
    if HasAnimDictLoaded(animDict) then return end
    RequestAnimDict(animDict)
    local timeout = 0
    while not HasAnimDictLoaded(animDict) do
        timeout = timeout + 1
        if timeout > 100 then
            print(('[DPW] Failed to load anim dict: %s'):format(animDict))
            return
        end
        Wait(100)
    end
end

-- ============================================================================
-- PARTICLE EFFECT LOADING
-- ============================================================================

--- Load a particle FX asset
---@param asset string The particle asset name
function DPW.Utils.LoadParticleAsset(asset)
    if HasNamedPtfxAssetLoaded(asset) then return end
    RequestNamedPtfxAsset(asset)
    local timeout = 0
    while not HasNamedPtfxAssetLoaded(asset) do
        timeout = timeout + 1
        if timeout > 100 then
            print(('[DPW] Failed to load particle asset: %s'):format(asset))
            return
        end
        Wait(100)
    end
end

-- ============================================================================
-- PROP SPAWNING
-- ============================================================================

--- Spawn a prop at given coordinates with optional network sync
---@param model string The prop model name
---@param coords vector3|vector4 Spawn position
---@param networked boolean Whether to network sync this prop
---@param placeOnGround boolean Whether to place the prop on the ground
---@return number|nil entity The spawned entity handle
function DPW.Utils.SpawnProp(model, coords, networked, placeOnGround)
    local modelHash = DPW.Utils.LoadModel(model)
    if not modelHash then return nil end

    local x, y, z = coords.x, coords.y, coords.z
    local heading = coords.w or 0.0

    if placeOnGround then
        local groundZ
        local success, _groundZ = GetGroundZAndNormalFor_3dCoord(x, y, z)
        if success then
            groundZ = _groundZ
        else
            groundZ = z
        end
        z = groundZ
    end

    local entity
    if networked then
        -- Network-synced prop creation
        local netId = -1
        local created = false

        -- Use CreateObject for networked props
        entity = CreateObject(modelHash, x, y, z, true, true, false)
        if entity then
            SetEntityHeading(entity, heading)
            SetEntityAsMissionEntity(entity, true, true)
            NetworkRegisterEntityAsNetworked(entity)
            local netId = NetworkGetNetworkIdFromEntity(entity)
            SetNetworkIdExistsOnAllMachines(netId, true)
            SetNetworkIdCanMigrate(netId, true)
        end
    else
        entity = CreateObject(modelHash, x, y, z, false, false, false)
        if entity then
            SetEntityHeading(entity, heading)
            SetEntityAsMissionEntity(entity, true, true)
        end
    end

    if entity and entity ~= 0 then
        FreezeEntityPosition(entity, true)
        table.insert(DPW.Props, entity)
        return entity
    end

    return nil
end

--- Spawn a non-networked local prop
---@param model string The prop model name
---@param coords vector3|vector4 Spawn position
---@param placeOnGround boolean
---@return number|nil
function DPW.Utils.SpawnLocalProp(model, coords, placeOnGround)
    return DPW.Utils.SpawnProp(model, coords, false, placeOnGround)
end

--- Spawn a network-synced prop visible to all players
---@param model string The prop model name
---@param coords vector3|vector4 Spawn position
---@param placeOnGround boolean
---@return number|nil
function DPW.Utils.SpawnNetworkedProp(model, coords, placeOnGround)
    return DPW.Utils.SpawnProp(model, coords, true, placeOnGround)
end

-- ============================================================================
-- ENTITY HELPERS
-- ============================================================================

--- Safely delete an entity
---@param entity number The entity handle
function DPW.Utils.DeleteEntitySafe(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    SetEntityAsMissionEntity(entity, true, true)
    DeleteEntity(entity)
    -- Also remove from tracked props
    for i, e in ipairs(DPW.Props) do
        if e == entity then
            table.remove(DPW.Props, i)
            break
        end
    end
end

--- Find the closest entity of a given model near coordinates
---@param coords vector3 Center position to search
---@param model string Model name to search for
---@param radius number Search radius
---@return number|nil entity
function DPW.Utils.GetClosestObjectOfType(coords, model, radius)
    local modelHash = joaat(model)
    local entity = GetClosestObjectOfType(coords.x, coords.y, coords.z, radius, modelHash, false, false, false)
    if entity and entity ~= 0 then
        return entity
    end
    return nil
end

-- ============================================================================
-- PROP ATTACHMENT
-- ============================================================================

--- Attach a prop to the player ped
---@param prop number The prop entity
---@param ped number The ped to attach to
---@param bone number Bone index (default: right hand = 57005)
---@param offset vector3 Position offset
---@param rotation vector3 Rotation offset
function DPW.Utils.AttachPropToPed(prop, ped, bone, offset, rotation)
    if not prop or not DoesEntityExist(prop) then return end
    local boneIdx = GetPedBoneIndex(ped, bone or 57005)
    AttachEntityToEntity(prop, ped, boneIdx,
        offset.x or 0.0, offset.y or 0.0, offset.z or 0.0,
        rotation.x or 0.0, rotation.y or 0.0, rotation.z or 0.0,
        true, true, false, true, 1, true
    )
end

--- Detach a prop from ped but keep it alive
---@param prop number The prop entity
function DPW.Utils.DetachPropFromPed(prop)
    if not prop or not DoesEntityExist(prop) then return end
    DetachEntity(prop, false, false)
end

-- ============================================================================
-- PARTICLE EFFECTS
-- ============================================================================

--- Start a looped particle effect at coordinates
---@param asset string Particle asset name
---@param effect string Particle effect name
---@param coords vector3 Position
---@param looped boolean Whether the effect loops
---@return number|nil ptfxHandle
function DPW.Utils.StartParticle(asset, effect, coords, looped)
    DPW.Utils.LoadParticleAsset(asset)
    UseParticleFxAssetNextCall(asset)

    local handle
    if looped then
        handle = StartParticleFxLoopedAtCoord(effect, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 1.0, false, false, false, false)
    else
        handle = StartParticleFxAtCoord(effect, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 1.0)
    end

    if handle and handle ~= 0 then
        table.insert(DPW.Particles, handle)
        return handle
    end
    return nil
end

--- Start a looped particle on an entity
---@param asset string
---@param effect string
---@param entity number
---@param offset vector3
---@return number|nil
function DPW.Utils.StartParticleOnEntity(asset, effect, entity, offset)
    DPW.Utils.LoadParticleAsset(asset)
    UseParticleFxAssetNextCall(asset)

    local handle = StartParticleFxLoopedOnEntity(effect, entity,
        offset.x or 0.0, offset.y or 0.0, offset.z or 0.0,
        0.0, 0.0, 0.0, 1.0, false, false, false)

    if handle and handle ~= 0 then
        table.insert(DPW.Particles, handle)
        return handle
    end
    return nil
end

--- Stop a specific particle effect
---@param ptfxHandle number The particle handle
function DPW.Utils.StopParticle(ptfxHandle)
    if not ptfxHandle or ptfxHandle == 0 then return end
    StopParticleFxLooped(ptfxHandle, false)
    RemoveParticleFx(ptfxHandle, false)
    for i, h in ipairs(DPW.Particles) do
        if h == ptfxHandle then
            table.remove(DPW.Particles, i)
            break
        end
    end
end

-- ============================================================================
-- ANIMATIONS
-- ============================================================================

--- Play an animation on the player ped
---@param animDict string Animation dictionary
---@param animName string Animation name
---@param duration number Duration in ms (-1 for infinite with task flag)
---@param flag number Animation flag (default: 1 = upper body only)
---@return boolean Whether the animation completed
function DPW.Utils.PlayAnim(animDict, animName, duration, flag)
    DPW.Utils.LoadAnimDict(animDict)
    local ped = PlayerPedId()
    local animFlag = flag or 1

    TaskPlayAnim(ped, animDict, animName, 8.0, 8.0, duration or -1, animFlag, 0, false, false, false)

    if duration and duration > 0 then
        local startTime = GetGameTimer()
        while (GetGameTimer() - startTime) < duration do
            Wait(0)
            if not IsEntityPlayingAnim(ped, animDict, animName, 3) then
                return false
            end
            DisablePlayerFiring(PlayerId(), true)
        end
        ClearPedTasks(ped)
        return true
    end

    return true
end

--- Play a grab animation (short interaction with truck)
---@param duration number Duration in ms
function DPW.Utils.PlayGrabAnim(duration)
    local anim = Config.Anims.grabFromTruck
    DPW.Utils.PlayAnim(anim.dict, anim.anim, duration or anim.duration)
end

-- ============================================================================
-- 3D TEXT DRAWING
-- ============================================================================

--- Draw 3D text at coordinates (fallback when no target system)
---@param coords vector3 Position
---@param text string Text to display
function DPW.Utils.DrawText3D(coords, text)
    local onScreen, _x, _y = World3dToScreen2d(coords.x, coords.y, coords.z)
    if not onScreen then return end

    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    SetTextEntry('STRING')
    SetTextCentre(1)
    AddTextComponentString(text)
    DrawText(_x, _y)

    local factor = #text / 370
    DrawRect(_x, _y + 0.0125, 0.015 + factor, 0.03, 41, 11, 11, 68)
end

-- ============================================================================
-- NOTIFICATIONS
-- ============================================================================

--- Show a notification to the player
---@param message string The message
---@param duration number Duration in ms (default: 4000)
function DPW.Utils.Notify(message, duration)
    if lib and lib.notify then
        lib.notify({
            title = 'DPW',
            description = message,
            type = 'inform',
            duration = duration or 8000,
            position = 'top-right',
        })
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(message)
        EndTextCommandThefeedPostTicker(false, false)
    end
end

--- Show a success notification
---@param message string
function DPW.Utils.NotifySuccess(message)
    if lib and lib.notify then
        lib.notify({
            title = 'DPW',
            description = message,
            type = 'success',
            duration = 8000,
            position = 'top-right',
        })
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('~g~' .. message)
        EndTextCommandThefeedPostTicker(false, false)
    end
end

-- ============================================================================
-- SKILL CHECK (via ox_lib)
-- ============================================================================

--- Run a skill check minigame
---@param difficulty string|table The difficulty level(s)
---@return boolean Whether the player passed
function DPW.Utils.SkillCheck(difficulty)
    if lib and lib.skillCheck then
        return lib.skillCheck(difficulty)
    end
    -- Fallback: always pass if no ox_lib
    return true
end

-- ============================================================================
-- PROGRESS BAR (via ox_lib)
-- ============================================================================

--- Run a progress bar with animation
---@param label string The label text
---@param duration number Duration in ms
---@param animDict string Animation dictionary
---@param anim string Animation name
---@param flag number Animation flag
---@return boolean Whether it completed
function DPW.Utils.ProgressBar(label, duration, animDict, anim, flag)
    if lib and lib.progressBar then
        local success = lib.progressBar({
            duration = duration,
            label = label,
            useWhileDead = false,
            canCancel = true,
            disable = {
                car = true,
                move = true,
                combat = true,
            },
            anim = {
                dict = animDict,
                clip = anim,
                flag = flag or 1,
            },
        })
        return success
    else
        -- Fallback: simple animation with timer
        return DPW.Utils.PlayAnim(animDict, anim, duration, flag or 1)
    end
end

-- ============================================================================
-- BLIP HELPERS
-- ============================================================================

--- Create a blip at coordinates
---@param coords vector3 Position
---@param sprite number Blip sprite ID
---@param color number Blip color
---@param scale number Blip scale
---@param label string Blip label
---@return number blip
function DPW.Utils.CreateBlip(coords, sprite, color, scale, label)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite)
    SetBlipColour(blip, color)
    SetBlipScale(blip, scale)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
    table.insert(DPW.Blips, blip)
    return blip
end

--- Set a GPS route to coordinates
---@param coords vector3
---@param color number Route color
---@param sprite number Waypoint sprite
---@return number blip The waypoint blip
function DPW.Utils.SetGPSRoute(coords, color, sprite)
    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, sprite or 1)
    SetBlipColour(blip, color or 5)
    SetBlipScale(blip, 0.8)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, color or 5)
    table.insert(DPW.Blips, blip)
    return blip
end

--- Remove a specific blip
---@param blip number Blip handle
function DPW.Utils.RemoveBlip(blip)
    if not blip or blip == 0 then return end
    RemoveBlip(blip)
    for i, b in ipairs(DPW.Blips) do
        if b == blip then
            table.remove(DPW.Blips, i)
            break
        end
    end
end

-- ============================================================================
-- CLEANUP
-- ============================================================================

--- Clean up all spawned props, particles, and blips
function DPW.Utils.CleanupAll()
    -- Delete all tracked props
    for _, entity in ipairs(DPW.Props) do
        if DoesEntityExist(entity) then
            SetEntityAsMissionEntity(entity, true, true)
            DeleteEntity(entity)
        end
    end
    DPW.Props = {}

    -- Stop all particles
    for _, ptfx in ipairs(DPW.Particles) do
        StopParticleFxLooped(ptfx, false)
        RemoveParticleFx(ptfx, false)
    end
    DPW.Particles = {}

    -- Remove all blips
    for _, blip in ipairs(DPW.Blips) do
        RemoveBlip(blip)
    end
    DPW.Blips = {}
end

-- ============================================================================
-- FRAMEWORK HELPERS
-- ============================================================================

--- Check if the player has the DPW job (framework-dependent)
---@return boolean
function DPW.Utils.HasJob()
    local fw = Config.Framework
    if fw == 'standalone' then
        return true -- Always allow in standalone mode
    end

    local PlayerData = nil

    if fw == 'qb-core' then
        local QBCore = exports['qb-core']:GetCoreObject()
        PlayerData = QBCore.Functions.GetPlayerData()
        if PlayerData and PlayerData.job and PlayerData.job.name == Config.JobName then
            return true
        end
    elseif fw == 'qbox' then
        -- Qbox uses QB bridge or ox bridge
        local QBCore = exports['qb-core']:GetCoreObject()
        if QBCore then
            PlayerData = QBCore.Functions.GetPlayerData()
            if PlayerData and PlayerData.job and PlayerData.job.name == Config.JobName then
                return true
            end
        end
    elseif fw == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        if ESX then
            local xPlayer = ESX.GetPlayerData()
            if xPlayer and xPlayer.job and xPlayer.job.name == Config.JobName then
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- DISTANCE HELPERS
-- ============================================================================

--- Get distance between two vector3 positions
---@param a vector3
---@param b vector3
---@return number
function DPW.Utils.Distance(a, b)
    return #(a - b)
end

--- Check if player ped is within range of coordinates
---@param coords vector3
---@param range number
---@return boolean
function DPW.Utils.IsInRange(coords, range)
    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    return #(pedCoords - coords) <= range
end

-- ============================================================================
-- KEY PRESS HELPERS
-- ============================================================================

--- Check if the E key is just pressed (for interaction)
---@return boolean
function DPW.Utils.IsEPressed()
    return IsControlJustReleased(0, 38) -- 38 = E key / INPUT_SELECT_WEAPON_UNARMED / DTB_Y
end

--- Get the player ped coordinates
---@return vector3
function DPW.Utils.GetPedCoords()
    return GetEntityCoords(PlayerPedId())
end

--- Get the player ped heading
---@return number
function DPW.Utils.GetPedHeading()
    return GetEntityHeading(PlayerPedId())
end

-- ============================================================================
-- TARGET SYSTEM INTEGRATION
-- ============================================================================

--- Check if ox_target or qb-target is available
---@return string|nil 'ox_target', 'qb-target', or nil
function DPW.Utils.GetTargetSystem()
    local oxTarget = GetResourceState('ox_target')
    if oxTarget == 'started' or oxTarget == 'starting' then
        return 'ox_target'
    end
    local qbTarget = GetResourceState('qb-target')
    if qbTarget == 'started' or qbTarget == 'starting' then
        return 'qb-target'
    end
    return nil
end