Config = {}

-- ============================================================================
-- FRAMEWORK SETTINGS
-- ============================================================================
-- Options: 'qbox', 'qb-core', 'esx', 'standalone'
Config.Framework = 'qbox'

-- Job name used for duty checks (only applies to framework modes)
Config.JobName = 'dpw'

-- Admin command to give a player the DPW job
-- Usage in chat/console: /setdpw [playerId] [rank 1-4]
-- Rank 1 = Worker, Rank 2 = Senior Worker, Rank 3 = Supervisor, Rank 4 = Director
Config.AdminSetJobCommand = 'setdpw'

-- ============================================================================
-- HEADQUARTERS SETTINGS
-- ============================================================================
-- DPW HQ location (blip + clock-in marker)
Config.HQ = {
    coords = vector4(715.0, -1082.0, 22.0, 90.0), -- x, y, z, heading
    blip = {
        sprite = 68,        -- radar_tow_truck (see blips.json)
        color = 17,         -- Yellow-ish
        scale = 0.8,
        label = 'DPW Headquarters',
    },
    marker = {
        type = 1,           -- MarkerTypeVerticalCylinder (see markers.json)
        size = vector3(1.5, 1.5, 1.0),
        color = { r = 255, g = 200, b = 50, a = 120 },
        bobUpAndDown = true,
    },
}

-- ============================================================================
-- VEHICLE SPAWNER
-- ============================================================================
Config.Vehicle = {
    model = 'utillitruck4',     -- DPW utility truck model (Utility Truck)
    spawnCoords = vector4(720.0, -1085.0, 22.0, 90.0),
    platePrefix = 'DPW',
}

-- ============================================================================
-- DISPATCH SYSTEM
-- ============================================================================
Config.Dispatch = {
    idleTimerMinutes = 1,            -- Minutes before auto-dispatch when idle
    checkIntervalSeconds = 30,      -- How often to check if player is idle
    autoDispatch = true,            -- Automatically dispatch when idle
    notifyDuration = 8000,          -- Notification display duration (ms)
    gpsBlipColor = 5,               -- Blip route color
    gpsBlipSprite = 1,             -- Blip sprite for mission waypoint
}

-- ============================================================================
-- PAYOUT SETTINGS
-- Salary: Handled by framework native paycheck system (qbx_core loops.lua)
--   - Paycheck interval configured in qbx_core/config/server.lua (paycheckTimeout)
--   - Pay rates defined in qbx_core/shared/jobs.lua (grade payment values)
--   - Players must be ON DUTY to receive paychecks (offDutyPay = false)
-- Task Bonus: Small bonus per task completion, handled by this script
-- ============================================================================
Config.Payout = {
    account = 'bank',               -- 'bank' or 'cash'

    -- Reference only: actual interval is in qbx_core/config/server.lua paycheckTimeout
    salaryIntervalMinutes = 15,     -- Keep in sync with framework config

    -- Pay ranks based on job grade (4 ranks)
    -- Rank 1 = Worker (grade 0), Rank 2 = Senior Worker (grade 1),
    -- Rank 3 = Supervisor (grade 2), Rank 4 = Director (grade 3)
    payRanks = {
        [1] = { grade = 0, title = 'Worker',         salary = 250  },
        [2] = { grade = 1, title = 'Senior Worker',  salary = 400  },
        [3] = { grade = 2, title = 'Supervisor',     salary = 600  },
        [4] = { grade = 3, title = 'Director',       salary = 850  },
    },

    -- Bonus per task completed (small flat bonus on top of salary)
    taskBonus = {
        hydrant = 50,
        sidewalk = 40,
        traffic_signal = 60,
        streetlight = 45,
        pothole = 35,
    },
}

-- ============================================================================
-- OPTIMIZATION
-- ============================================================================
Config.Optimization = {
    lazyInterval = 1000,            -- Citizen.Wait when far from site
    activeInterval = 0,             -- Citizen.Wait when near site
    activeRange = 10.0,             -- Distance to switch to active interval
    interactionRange = 2.5,         -- Max distance to interact with tasks
    truckRetrieveRange = 5.0,       -- Distance to retrieve tools from truck
}

-- ============================================================================
-- TASK A: BURST FIRE HYDRANTS
-- ============================================================================
Config.Tasks = Config.Tasks or {}

Config.Tasks.Hydrant = {
    enabled = true,
    -- Predefined locations for burst hydrants (vector3)
    locations = {
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
        vector3(799.6417, -1065.695, 26.91528),
    },
    -- Props
    hydrantModel = 'prop_fire_hydrant_1',
    hydrantBrokenModel = 'prop_fire_hydrant_1', -- same model, we delete and re-spawn
    -- Particle effects
    waterParticle = {
        asset = 'core',
        effect = 'ent_sht_water',
        scale = 3.0,           -- Large scale for dramatic geyser
        zOffset = 3.0,         -- Height above ground (must be high to be visible)
    },
    -- Animations
    shutOffAnim = {
        dict = 'amb@prop_human_bum_bin@idle_b',
        anim = 'idle_d',
        duration = 10000, -- 10 seconds
    },
    installAnim = {
        dict = 'amb@world_human_welding@male@base',
        anim = 'base',
        duration = 15000, -- 15 seconds
    },
    -- Skill check for shut off
    skillCheck = { 'easy', 'medium' },
    -- How long the replacement hydrant stays before despawning (ms) — avoids model-in-model when game respawns original
    replacementHydrantDuration = 120000, -- 2 minutes

    -- Prop attachment offsets
    carryHydrantOffset = vector3(0.15, -0.1, -0.1),
    carryHydrantRotation = vector3(0.0, 0.0, 90.0),
    carryBone = 57005, -- right hand
}

-- ============================================================================
-- TASK B: BROKEN SIDEWALKS
-- ============================================================================
Config.Tasks.Sidewalk = {
    enabled = true,
    locations = {
        vector3(-545.0, -260.0, 35.0),
        vector3(150.0, -1030.0, 29.0),
        vector3(-1200.0, -900.0, 14.0),
        vector3(900.0, -200.0, 74.0),
        vector3(-300.0, -150.0, 44.0),
        vector3(50.0, -1700.0, 29.0),
        vector3(-1400.0, -500.0, 34.0),
        vector3(600.0, -800.0, 26.0),
    },
    -- Props
    coneModel = 'prop_roadcone02a',
    damagedProp = 'prop_rubble_03a',
    jackhammerModel = 'prop_tool_jackham',
    shovelModel = 'prop_ld_shovel',
    -- Cone placement offsets around the damaged area
    coneOffsets = {
        vector3(2.0, 2.0, 0.0),
        vector3(-2.0, 2.0, 0.0),
        vector3(2.0, -2.0, 0.0),
        vector3(-2.0, -2.0, 0.0),
    },
    -- Animations
    drillAnim = {
        dict = 'amb@world_human_const_drill@male@drill@base',
        anim = 'base',
        duration = 15000, -- 15 seconds
    },
    smoothAnim = {
        dict = 'amb@prop_human_bum_bin@idle_b',
        anim = 'idle_d',
        duration = 10000, -- 10 seconds
    },
    -- Audio
    drillSound = 'Jackhammer',
    drillSoundset = 'EXILE_1_SOUNDS',
    -- Screen shake
    screenShake = {
        intensity = 0.3,
        duration = 15000,
    },
}

-- ============================================================================
-- TASK C: MALFUNCTIONING TRAFFIC SIGNALS
-- ============================================================================
Config.Tasks.TrafficSignal = {
    enabled = true,
    locations = {
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
        vector3(770.6545, -1026.164, 25.00012),
    },
    -- Traffic light model
    trafficLightModel = 'prop_traffic_01a',
    controlBoxModel = 'prop_traffic_light_02',
    -- Welding tool model (used during repair animations)
    welderModel = 'prop_weld_torch',
    -- Electronic component box to carry
    componentBoxModel = 'ex_prop_ex_toolchest_01',
    -- Spark particle
    sparkParticle = {
        asset = 'core',
        effect = 'ent_dst_electrical',
    },
    -- Animations
    wiringAnim = {
        dict = 'amb@world_human_welding@male@base',
        anim = 'base',
        duration = 10000,
    },
    installAnim = {
        dict = 'amb@world_human_welding@male@base',
        anim = 'base',
        duration = 20000,
    },
    -- Skill check (hacking/wiring minigame)
    skillCheck = { 'easy', 'easy', 'medium' },
    -- Component carry offset
    carryBoxOffset = vector3(0.2, 0.0, -0.15),
    carryBoxRotation = vector3(0.0, 0.0, 0.0),
    carryBone = 57005,
}

-- ============================================================================
-- TASK D: DEAD STREETLIGHTS
-- ============================================================================
Config.Tasks.Streetlight = {
    enabled = true,
    locations = {
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        vector3(775.8523, -1068.495, 27.05835),
        
    },
    -- Streetlight model
    streetlightModel = 'prop_streetlight_01b',
    -- Spark particle at bulb / base
    sparkParticle = {
        asset = 'core',
        effect = 'ent_dst_electrical',
    },
    -- Animations
    repairAnim = {
        dict = 'amb@world_human_welding@male@base',
        anim = 'base',
        duration = 12000,
    },
    -- Skill check
    skillCheck = { 'easy', 'medium' },
}

-- ============================================================================
-- TASK E: DAMAGED ROADS & POTHOLES
-- ============================================================================
Config.Tasks.Pothole = {
    enabled = true,
    locations = {
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
        vector3(797.3267, -1068.805, 27.03551),
    },
    -- Props
    potholeModel = 'bkr_prop_asphalt_cracks_01a',
    coneModel = 'prop_roadcone02a',
    rakeModel = 'prop_ld_shovel',
    -- Cone placement positions around pothole (3 cones)
    coneOffsets = {
        vector3(2.5, 0.0, 0.0),
        vector3(-1.25, 2.0, 0.0),
        vector3(-1.25, -2.0, 0.0),
    },
    -- Animations
    shovelAnim = {
        dict = 'amb@world_human_gardener_plant@male@base',
        anim = 'base',
        duration = 20000,
    },
    -- Cone placement range
    placeConeRange = 5.0,
    -- Number of cones to place
    requiredCones = 3,
}

-- ============================================================================
-- GENERAL ANIMATIONS
-- ============================================================================
Config.Anims = {
    grabFromTruck = {
        dict = 'amb@medic@standing@timeofdeath@base',
        anim = 'base',
        duration = 3000,
    },
    placeItem = {
        dict = 'amb@medic@standing@timeofdeath@base',
        anim = 'base',
        duration = 3000,
    },
}

-- ============================================================================
-- INTERACTION TEXT / NOTIFICATIONS
-- ============================================================================
Config.Labels = {
    clockIn = '~g~[E]~w~ Clock In',
    clockOut = '~r~[E]~w~ Clock Out',
    spawnVehicle = '~y~[E]~w~ Spawn DPW Truck',
    -- Task A
    shutOffValve = '~g~[E]~w~ Shut Off Main Valve',
    fetchHydrant = '~g~[E]~w~ Fetch New Hydrant',
    installHydrant = '~g~[E]~w~ Install New Hydrant',
    -- Task B
    inspectSidewalk = '~g~[E]~w~ Inspect Sidewalk',
    fetchJackhammer = '~g~[E]~w~ Grab Jackhammer',
    startDrilling = '~g~[E]~w~ Start Drilling',
    startSmoothing = '~g~[E]~w~ Smooth Surface',
    -- Task C
    investigateSignal = '~g~[E]~w~ Investigate Signal',
    fetchWiresRelays = '~g~[E]~w~ Get Wires & Relays',
    fixSignal = '~g~[E]~w~ Fix Traffic Signal',
    -- Task D
    inspectStreetlight = '~g~[E]~w~ Inspect Streetlight',
    fetchLightParts = '~g~[E]~w~ Get Replacement Parts',
    repairLight = '~g~[E]~w~ Repair Light',
    -- Task E
    grabRake = '~g~[E]~w~ Grab Shovel',
    placeCones = '~g~[E]~w~ Place Cones',
    startRepair = '~g~[E]~w~ Repair Pothole',
    -- Dispatch
    dispatchHydrant = 'Dispatch: Burst fire hydrant reported nearby!',
    dispatchSidewalk = 'Dispatch: Broken sidewalk needs repair!',
    dispatchSignal = 'Dispatch: Malfunctioning traffic signal reported!',
    dispatchStreetlight = 'Dispatch: Dead streetlight reported!',
    dispatchPothole = 'Dispatch: Road damage / pothole needs filling!',
    -- Notifications
    dutyOn = 'You are now on duty with the Department of Public Works.',
    dutyOff = 'You have clocked out of the DPW.',
    taskComplete = 'Task complete! Returning to standby.',
    payoutReceived = 'You received $%d for completing the job.',
}