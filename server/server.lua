-- ============================================================================
-- Taz_DPW - Server-side Logic
-- Task bonuses, admin setjob command, duty state tracking, framework bridge
-- Salary is handled natively by Qbox/QB-Core paycheck system
-- ============================================================================

-- ============================================================================
-- FRAMEWORK DETECTION
-- ============================================================================

local Framework = nil
local FrameworkName = Config.Framework

-- Initialize framework bridge
local function InitializeFramework()
    if FrameworkName == 'qb-core' then
        local QBCore = exports['qb-core']:GetCoreObject()
        if QBCore then
            Framework = {
                type = 'qb-core',
                getPlayer = function(source)
                    return QBCore.Functions.GetPlayer(source)
                end,
                addMoney = function(player, account, amount, reason)
                    if account == 'bank' then
                        player.Functions.AddMoney('bank', amount, reason)
                    else
                        player.Functions.AddMoney('cash', amount, reason)
                    end
                end,
                getName = function(player)
                    local data = player.PlayerData
                    return ('%s %s'):format(data.charinfo.firstname, data.charinfo.lastname)
                end,
                setJob = function(player, jobName, grade)
                    player.Functions.SetJob(jobName, grade)
                end,
                setDuty = function(player, onDuty)
                    player.Functions.SetJobDuty(onDuty)
                end,
            }
        end
    elseif FrameworkName == 'qbox' then
        local success, QBCore = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        if success and QBCore then
            Framework = {
                type = 'qbox',
                getPlayer = function(source)
                    return QBCore.Functions.GetPlayer(source)
                end,
                addMoney = function(player, account, amount, reason)
                    if account == 'bank' then
                        player.Functions.AddMoney('bank', amount, reason)
                    else
                        player.Functions.AddMoney('cash', amount, reason)
                    end
                end,
                getName = function(player)
                    local data = player.PlayerData
                    return ('%s %s'):format(data.charinfo.firstname, data.charinfo.lastname)
                end,
                setJob = function(player, jobName, grade)
                    player.Functions.SetJob(jobName, grade)
                end,
                setDuty = function(player, onDuty)
                    player.Functions.SetJobDuty(onDuty)
                end,
            }
        end
    elseif FrameworkName == 'esx' then
        local ESX = exports['es_extended']:getSharedObject()
        if ESX then
            Framework = {
                type = 'esx',
                getPlayer = function(source)
                    return ESX.GetPlayerFromId(source)
                end,
                addMoney = function(player, account, amount, reason)
                    if account == 'bank' then
                        player.addAccountMoney('bank', amount, reason)
                    else
                        player.addMoney(amount, reason)
                    end
                end,
                getName = function(player)
                    return player.getName()
                end,
                setJob = function(player, jobName, grade)
                    player.setJob(jobName, grade)
                end,
                setDuty = function(player, onDuty)
                    -- ESX doesn't have a native duty toggle in the same way
                    -- This can be extended with ESX duty management
                end,
            }
        end
    elseif FrameworkName == 'standalone' then
        Framework = {
            type = 'standalone',
            getPlayer = function(source)
                return { source = source }
            end,
            addMoney = function(player, account, amount, reason)
                print(('[DPW] [Standalone] Would pay $%d to player %d (%s) — %s'):format(
                    amount, player.source, account, reason or ''))
            end,
            getName = function(player)
                return GetPlayerName(player.source) or ('Player %d'):format(player.source)
            end,
            setJob = function(player, jobName, grade)
                print(('[DPW] [Standalone] Set player %d job to %s grade %d'):format(
                    player.source, jobName, grade))
            end,
            setDuty = function(player, onDuty)
                -- No-op for standalone
            end,
        }
    end

    if Framework then
        print(('[DPW] Framework initialized: %s'):format(Framework.type))
    else
        print('[DPW] WARNING: Failed to initialize framework. Payouts will not work!')
    end
end

-- Initialize on resource start
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Wait(1000) -- Wait for framework to load
    InitializeFramework()
end)

-- ============================================================================
-- DUTY STATE TRACKING (server-side)
-- ============================================================================

-- Tracks which players are on DPW duty (source -> true)
local dutyPlayers = {}

-- Client notifies server when clocking in — toggles framework duty ON
RegisterNetEvent('dpw:clockIn', function()
    local src = source
    dutyPlayers[src] = true

    -- Toggle framework duty state so native paycheck system pays them
    if Framework then
        local player = Framework.getPlayer(src)
        if player then
            Framework.setDuty(player, true)
        end
    end

    print(('[DPW] Player %d clocked in (duty toggled ON).'):format(src))
end)

-- Client notifies server when clocking out — toggles framework duty OFF
RegisterNetEvent('dpw:clockOut', function()
    local src = source
    dutyPlayers[src] = nil

    -- Toggle framework duty state so native paycheck system stops paying
    if Framework then
        local player = Framework.getPlayer(src)
        if player then
            Framework.setDuty(player, false)
        end
    end

    print(('[DPW] Player %d clocked out (duty toggled OFF).'):format(src))
end)

-- Clean up on disconnect
AddEventHandler('playerDropped', function()
    local src = source
    dutyPlayers[src] = nil
end)

-- ============================================================================
-- TASK COMPLETION BONUS EVENT
-- Salary is handled by the framework's native paycheck system (qbx_core loops)
-- This only handles the per-task completion bonus
-- ============================================================================

RegisterNetEvent('dpw:completeTask', function(taskType, bonusAmount)
    local source = source

    -- Basic validation
    if not taskType or not bonusAmount then
        print(('[DPW] Invalid task completion from player %d'):format(source))
        return
    end

    -- Clamp bonus to reasonable range (anti-cheat)
    bonusAmount = math.floor(tonumber(bonusAmount) or 0)
    if bonusAmount <= 0 or bonusAmount > 500 then
        print(('[DPW] Suspicious bonus amount %d from player %d — rejecting'):format(bonusAmount, source))
        return
    end

    -- Must be on duty
    if not dutyPlayers[source] then
        print(('[DPW] Player %d tried to complete task while off duty — rejecting'):format(source))
        return
    end

    -- Apply payout via framework
    if not Framework then
        print(('[DPW] Framework not initialized — cannot pay player %d'):format(source))
        return
    end

    local player = Framework.getPlayer(source)
    if not player then
        print(('[DPW] Could not find player data for source %d'):format(source))
        return
    end

    local account = Config.Payout.account or 'bank'
    local playerName = Framework.getName(player) or ('Player %d'):format(source)

    -- Add task bonus money
    Framework.addMoney(player, account, bonusAmount, 'dpw-task-bonus')

    -- Log to server console
    print(('[DPW] %s completed task "%s" — bonus $%d (%s)'):format(
        playerName, taskType, bonusAmount, account))
end)

-- ============================================================================
-- ADMIN COMMAND: /setdpw [playerId] [rank 1-4]
-- Gives the player the DPW job at the specified rank
-- ============================================================================

RegisterCommand(Config.AdminSetJobCommand, function(source, args)
    local callerSource = source -- 0 if from server console

    -- Permission check: only server console or admins can use this
    if callerSource ~= 0 then
        local isAllowed = IsPlayerAceAllowed(callerSource, 'command.setdpw')
            or IsPlayerAceAllowed(callerSource, 'admin')
        if not isAllowed then
            print(('[DPW] Player %d tried to use /%s but lacks permission.'):format(callerSource, Config.AdminSetJobCommand))
            TriggerClientEvent('dpw:notify', callerSource, 'You do not have permission to use this command.')
            return
        end
    end

    if not args[1] or not args[2] then
        local usage = ('/%s [playerId] [rank 1-4]'):format(Config.AdminSetJobCommand)
        if callerSource == 0 then
            print(('[DPW] Usage: %s'):format(usage))
        else
            TriggerClientEvent('dpw:notify', callerSource, usage)
        end
        return
    end

    local targetId = tonumber(args[1])
    local rank = tonumber(args[2])

    if not targetId or not rank then
        if callerSource == 0 then
            print('[DPW] Invalid arguments. Must be numbers.')
        else
            TriggerClientEvent('dpw:notify', callerSource, 'Invalid arguments.')
        end
        return
    end

    -- Validate rank range
    rank = math.floor(rank)
    if rank < 1 or rank > 4 then
        local msg = 'Rank must be between 1 and 4.'
        if callerSource == 0 then
            print(('[DPW] %s'):format(msg))
        else
            TriggerClientEvent('dpw:notify', callerSource, msg)
        end
        return
    end

    local rankData = Config.Payout.payRanks[rank]
    if not rankData then
        print('[DPW] Rank data not found in config!')
        return
    end

    if not Framework then
        print('[DPW] Framework not initialized — cannot set job.')
        return
    end

    local targetPlayer = Framework.getPlayer(targetId)
    if not targetPlayer then
        local msg = ('Player %d not found or not online.'):format(targetId)
        if callerSource == 0 then
            print(('[DPW] %s'):format(msg))
        else
            TriggerClientEvent('dpw:notify', callerSource, msg)
        end
        return
    end

    -- Set the job
    Framework.setJob(targetPlayer, Config.JobName, rankData.grade)

    local targetName = Framework.getName(targetPlayer) or ('Player %d'):format(targetId)
    local msg = ('%s has been given the DPW job as %s (Rank %d, Grade %d, Salary $%d/paycheck)'):format(
        targetName, rankData.title, rank, rankData.grade, rankData.salary)

    print(('[DPW] %s'):format(msg))

    -- Notify caller
    if callerSource ~= 0 then
        TriggerClientEvent('dpw:notify', callerSource, msg)
    end

    -- Notify target player
    TriggerClientEvent('dpw:notify', targetId,
        ('You have been hired as a %s for the Department of Public Works! (Rank %d)'):format(
            rankData.title, rank))
end, false)

-- ============================================================================
-- VEHICLE KEYS EVENT
-- Gives the spawning player keys to their DPW truck via qbx_vehiclekeys
-- ============================================================================

RegisterNetEvent('dpw:giveVehicleKeys', function(netId)
    local src = source
    if not netId or netId == 0 then return end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 then
        print(('[DPW] Could not resolve vehicle from netId %d for player %d'):format(netId, src))
        return
    end

    local success, err = pcall(function()
        exports.qbx_vehiclekeys:GiveKeys(src, vehicle)
    end)

    if success then
        print(('[DPW] Keys granted to player %d for vehicle netId %d'):format(src, netId))
    else
        print(('[DPW] Failed to give keys to player %d: %s'):format(src, tostring(err)))
    end
end)

-- ============================================================================
-- CLIENT NOTIFICATION BRIDGE
-- ============================================================================

RegisterNetEvent('dpw:notify', function(message)
    -- This is a server-to-client relay; clients trigger this locally
end)

-- ============================================================================
-- RESOURCE STARTUP LOG
-- ============================================================================

CreateThread(function()
    Wait(2000)
    local rankInfo = ''
    for i = 1, 4 do
        local r = Config.Payout.payRanks[i]
        if r then
            rankInfo = rankInfo .. ('  Rank %d: %s (Grade %d) — $%d/paycheck (native)\n'):format(
                i, r.title, r.grade, r.salary)
        end
    end

    print([[
    ========================================
    Taz_DPW - Department of Public Works
    Version 1.0.0
    Framework: ]] .. (Config.Framework or 'unknown') .. [[
    
    Salary: Handled by framework native paycheck system
    
    Tasks Enabled:
      Hydrant:         ]] .. tostring(Config.Tasks.Hydrant.enabled) .. [[
      Sidewalk:        ]] .. tostring(Config.Tasks.Sidewalk.enabled) .. [[
      Traffic Signal:  ]] .. tostring(Config.Tasks.TrafficSignal.enabled) .. [[
      Streetlight:     ]] .. tostring(Config.Tasks.Streetlight.enabled) .. [[
      Pothole:         ]] .. tostring(Config.Tasks.Pothole.enabled) .. [[
    
    Pay Ranks:
]] .. rankInfo .. [[
    Task Bonus: $35-$75 + random $0-$15 per task
    
    Dispatch Interval: ]] .. Config.Dispatch.idleTimerMinutes .. [[ minutes
    Admin Command:     /]] .. (Config.AdminSetJobCommand or 'setdpw') .. [[ [playerId] [rank 1-4]
    ========================================
    ]])
end)