--------------------------------------------| Notes |-------------------------------------------
--|    => This system was entirely scripted by @eyado2122_1 on roblox,                       |--
--|    ID: hehe_boiaguy#1321 on discord (Don't mind the username lol)						 |--
--| 																						 |--
--|    <| This script intentionally avoids ModuleScripts to keep all related mining |>       |--
--|    <| logic in one place (for application).                                     |>       |--
--| 																						 |--
--|	   SmallNote: I have added nearly a comment on each line, I am tired of getting declined |--
--|               because "there is not enough comments explaining my code".                 |--
--|    -Setup:                            													 |--
--|         - Pickaxe name is expected to be "Iron Pickaxe", "Gold Pickaxe", etc..           |--
--|		    - Ore model name is expected to be "IronOre", "GoldOre", etc..                   |--
--|		    - Ore Drops must be a model and has 1 part/mesh named 'root'.                    |--
--|    -Design Goals:                                                                        |--
--|         - Prevent remote abuse and prompt spoofing                                       |--
--|         - Avoid race conditions during mining                                            |--
--|         - Maintain O(1) cooldown validation                                              |--
--|         - Avoid unnecessary replication                                                  |--
--|         - Centralize ore state outside Instances                                         |--
--|         - Guarantee cleanup even under failure cases                                     |--
--|     																					 |--
--|    -Architecture:																		 |--
--|         - OreState: Tracks all active ores using sequential IDs							 |--
--|         - World: Manages spawn slot allocation											 |--
--|         - CooldownManager: Uses absolute timestamps to prevent drift					 |--
--|         - Attributes: Used for debug visibility and future UI integration 				 |--
--|    																						 |--
--|    -Modules:																			 |--
--|    		- Validation Layer																 |--
--|    		- Ore State Management															 |--
--|   		- Cooldown System                                                                |--
--|   		- Spawn Allocation                                                               |--
--|   		- Rarity Distribution                                                            |--
--|   		- Cleanup Pipeline                                                               |--
--|                                                                                          |--
--|   	-All validation is server-side.                                                      |--
--|		-No animations are implemented here because a client script would be needed.         |--    
------------------------------------------------------------------------------------------------
--// Services \\--
-- Get ReplicatedStorage.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Get ServerStorage.
local ServerStorage = game:GetService("ServerStorage")
-- Get Players.
local Players = game:GetService("Players")
-- Get Debris.
local Debris = game:GetService("Debris")

--// References \\--
local ServerAssets = ServerStorage:WaitForChild("Assets") --// Server storage for assets

local OreTemplates = ServerAssets:WaitForChild("OreModels")   --// Folder with ore models
local OreDropTemplates = ServerAssets:WaitForChild("OreDrops") --// Folder with ore drop templates
local OreSpawnLocations = workspace:WaitForChild("OreSpawnLocations"):GetChildren() --// Folder with spawn locations for ores
local OresTools_Folder = ServerAssets:WaitForChild("OresTools") --// Folder to store tools for ores  (Tools are created dynamically!)

--// Tables \\--
-- Make a table to store ore names by rarity.
local OresByRarity = {}
-- Settings are centralized here to make system balancing adjustable
-- without touching core mining logic. This prevents variables
-- from being scattered across the script.
-- Start the settings table.
local Settings = {
	SpawnOreCooldown = 3      -- Spawn Ore every ... seconds
	,MaxDistanceToOre = 10    -- Maximum distance that the ore can be from the player to be mined (ProximityPrompt range and distance checks)
	,MaxOres = 10             -- Maximum number of ores that can be spawned at once
	,OreDespawnTime = 50      -- Despawn ore after ... seconds (if mined, cooldown will reset)
	,OreDropsDespawnTime = 60 -- Despawn ore drops after ... seconds (if not picked up) 
	,MaxPickupDistance = 10   -- Maximum distance that the player can be from the ore to pick up drops (ProximityPrompt range and distance checks)
}
-----------------------------
-------- Ore Config ---------
-----------------------------
local RarityChances = {    --// Chance of each rarity to spawn
	-- Set VeryCommon.
	VeryCommon = 50,
	-- Set Common.
	Common = 30,
	-- Set Uncommon.
	Uncommon = 15,
	-- Set Rare.
	Rare = 4,
	-- Set VeryRare.
	VeryRare = 1,
}
-- OreData acts as a single source of truth for all ore balancing. No gameplay values are 
-- hardcoded outside this table.
-- This makes adding new ores scale without changing system logic.
-- Start the table that stores each ore's data.
local OreData = {
	-- Set ["Copper"].
	["Copper"] = {
		Health = 50              -- Health of the ore
		,CashReward = 5          -- Amount of money the player gets for mining this ore
		,DropAmount = 3          -- Amount of ores that the ore drops when mined
		,ModelName = "CopperOre" -- Name of the ore model in ReplicatedStorage.OreAssets
		,Rarity = "VeryCommon"   -- Rarity of the ore
		,MinRequiredTier = 1     -- Minimum Required tier to mine this ore
	}
	-- Set ,["Iron"].
	,["Iron"] = {
		-- Set Health.
		Health = 100
		-- Set ,CashReward.
		,CashReward = 10
		-- Set ,DropAmount.
		,DropAmount = 2
		-- Set ,ModelName.
		,ModelName = "IronOre"
		-- Set ,Rarity.
		,Rarity = "Common"
		-- Set ,MinRequiredTier.
		,MinRequiredTier = 1
	}
	-- Set ,["Gold"].
	,["Gold"] = {
		-- Set Health.
		Health = 200
		-- Set ,CashReward.
		,CashReward = 25
		-- Set ,DropAmount.
		,DropAmount = 1
		-- Set ,ModelName.
		,ModelName = "GoldOre"
		-- Set ,Rarity.
		,Rarity = "Uncommon"
		-- Set ,MinRequiredTier.
		,MinRequiredTier = 2
	}
}

-----------------------------
------ Pickaxe Config -------
-----------------------------
-- Start the table that stores each pickaxe's data.
local PickaxesData = {
	-- Set ["Wooden Pickaxe"].
	["Wooden Pickaxe"] = {
		-- Set Damage.
		Damage = 25
		-- Set ,Cooldown.
		,Cooldown = 3
		-- Set ,Tier.
		,Tier = 1
	}
	-- Set ,["Iron Pickaxe"].
	,["Iron Pickaxe"] = {
		-- Set Damage.
		Damage = 40
		-- Set ,Cooldown.
		,Cooldown = 2.5
		-- Set ,Tier.
		,Tier = 2
	}
}
-----------------------------
------ Debug and info -------
-----------------------------
local LOG_LEVEL = { --// Used to determine whether the log category is printed or hidden
	-- Set Debug.
	Debug = false,
	-- Set Info.
	Info = true,
	-- Set Security.
	Security = true,
	-- Set Warn.
	Warn = true,
	-- Set Error.
	Error = true,
}

--// Debug / Logging Utility
-- Make a function for printing messages at different log levels.
local function Debug_Print(Level:"Debug" | "Info" | "Security" | "Warn" | "Error", Message:string, Context)
	if not LOG_LEVEL[Level] then -- Check in LOG_LEVEL if logs should be shown or not
		-- Stop here if this log level is turned off.
		return
	end

	-- Make the log prefix.
	local prefix = "[Mining]["..Level.."]"
	-- Add the message after the prefix.
	local output = prefix .. " " .. tostring(Message)

	-- Check whether extra context was provided.
	if Context ~= nil and typeof(Context) == "table" then
		-- Start an empty string for the context.
		local Str = ""
		-- Go through each context entry.
		for key, value in pairs(Context) do
			-- Add this entry to the context text.
			Str ..= "\n      > "..tostring(key).." = "..tostring(value)
		end
		-- Set output
		output ..= "\n Context: " .. tostring(Str) 
	end
	-- Check whether this is an error message.
	if Level == "Error" then                           
		-- Raise the error.
		error(output)
	-- Check whether this is a warning.
	elseif Level == "Warn" then 
		-- Show the warning.
		warn(output)
	else
		-- Print the message normally.
		print(output)
	end
end

-----------------------------
-------- Player Init --------
-----------------------------
-- Start the table of leaderboard values.
local LeaderboardValues = {
	-- Set Cash.
	Cash = {DefaultValue = 0, Type = "IntValue"},
}
Players.PlayerAdded:Connect(function(player) --When player joins
	local leaderstats = Instance.new("Folder") --Create leaderstats
	-- Set the folder's name.
	leaderstats.Name = "leaderstats"
	-- Put the folder inside the player.
	leaderstats.Parent = player
	for statName, Data in pairs(LeaderboardValues) do --And fill it with the LeaderboardValues
		-- Make a variable for the stat instance.
		local stat
		-- Try to create the stat instance safely.
		local success,_ = pcall(function()
			-- Create the requested instance type.
			stat = Instance.new(Data.Type)
		end)
		-- Check whether creating the instance worked.
		if success then	
			-- Set the stat's name.
			stat.Name = statName
			-- Set the stat's starting value.
			stat.Value = Data.DefaultValue
			-- Put the stat inside leaderstats.
			stat.Parent = leaderstats
		else
			-- Warn if the stat type was invalid.
			Debug_Print("Warn","Please set a valid instance type for leaderstat value '"..(statName or "nil").."'!", {DataType = Data.Type or "nil"})
			-- Stop setting up this player's stats.
			return
		end
	end
end)

-----------------------------
------ Cooldown Manager -----
-----------------------------
-- Start the cooldown manager.
local CooldownManager = {
	Players = {} -- [Player] = nextAllowedTime
}
-- Server time is used instead of tick() to prevent desync issues caused by lag or client side time differences
-- Make a function that checks whether the player can mine.
function CooldownManager:CanMine(Player)
	-- Get the current server time.
	local now = workspace:GetServerTimeNow() 
	if not self.Players[Player] then   -- First time player using CooldownManager:CanMine, so
		return true                    -- return true (can mine)
	end
	return now >= self.Players[Player] -- Comparing absolute timestamps avoids edge cases where cooldowns
	-- could be bypassed if the server lags or frame timing fluctuates
end

-- Make a function that starts a player's cooldown.
function CooldownManager:StartCooldown(Player, Cooldown)
	self.Players[Player] = workspace:GetServerTimeNow() + Cooldown -- Store absolute timestamp instead of remaining time
	-- This avoids drift and allows O(1) cooldown validation
end

Players.PlayerRemoving:Connect(function(Player) -- Cooldown data is cleared on PlayerRemoving to prevent memory leaks
	-- Check whether this player has a cooldown entry.
	if CooldownManager.Players[Player] then
		-- Remove the player's cooldown entry.
		CooldownManager.Players[Player] = nil
	end
end)

-----------------------------
--------- Ore State --------- -- Centralized state table used instead of Instances to avoid unnecessary replication and improve server-side control
----------------------------- -- OreState is intentionally separate from Instances. This avoids relying on workspace traversal
-- and allows constant-time ore lookup by ID.
local OreState = { -- Ore IDs are generated sequentially to guarantee uniqueness without relying on Instance:GetDebugId()
	ByID = {} -- [OreID] -> Ore
	-- Set ,NextID.
	,NextID = 0
	,SpawnedOres = 0 --// Number of spawned ores
}

-- Make a function that adds an ore to the tracking table.
function OreState:AddOre(Ore:Model)
	OreState.NextID += 1       -- Increment the next ID
	OreState.SpawnedOres += 1  -- Increment the spawned ores count
	-- Save the new ore ID in a variable.
	local OreID = OreState.NextID 
	OreState.ByID[OreID] = Ore -- Store the ore with its ID 
	-- Save the ID as an attribute on the ore.
	Ore:SetAttribute("OreID", OreID)
	-- Return the new ID.
	return OreID
end

function OreState:RemoveOre(OreID) -- Removing both the counter and ID entry keeps OreState consistent,
	-- preventing desync between actual instances and tracked state
	-- Decrease the spawned ore count.
	OreState.SpawnedOres -= 1
	-- Remove the ore from the ID table.
	OreState.ByID[OreID] = nil
end

-----------------------------
-------- World Data ---------	-- World handles spatial spawn allocation.
-----------------------------	-- Separation from OreState prevents logical coupling
-- between instance tracking and spawn management.
-- Start the table that manages spawn slots.
local World = {
	AvailableSlots = {} --// List of spawn available locations for ores  (dynamic)
	,TakenSlots = {}    --// List of taken spawn locations for ores (dynamic)
}
--// Get A Random Spawn Location (For OreID)
--// OreID: number
function World:GetRandomSpawnSlot(OreID) -- Random index selection ensures uniform distribution
	-- while keeping slot allocation O(1)
	-- Pick a random index from the available slots.
	local Index = math.random(1, #World.AvailableSlots)
	-- Get the slot at that index.
	local ChosenSlot = World.AvailableSlots[Index]
	-- Check whether a slot was found.
	if ChosenSlot then
		-- Mark the slot with this ore's ID.
		ChosenSlot.SpawnedOre = OreID
		table.insert(World.TakenSlots, ChosenSlot) --// Store the taken slot
		table.remove(World.AvailableSlots, Index) --// Remove the slot from available slots
	end
	-- Return the chosen slot.
	return ChosenSlot
end

function World:RemoveFromSlot(OreID) -- Spawn slot is freed to prevent dead slots after ore removal
	for Index, Slot in pairs(World.TakenSlots) do -- search for slot with OreID
		-- Check whether this slot belongs to the ore.
		if Slot.SpawnedOre == OreID then
			-- Clear the ore ID from the slot.
			Slot.SpawnedOre = nil
			-- Return slot back to AvailableSlots so future ores
			-- can reuse this location without overlapping
			-- Put the slot back in the available list.
			table.insert(World.AvailableSlots, Slot)
			-- Remove the slot from the taken list.
			table.remove(World.TakenSlots, Index)
			-- Stop once the matching slot is handled.
			return
		end
	end
end

-----------------------------
--------- Functions ---------
-----------------------------
--// Safely delete ore
--// OreID: number
--// Order: boolean. Default: false. (if true, it will delete the ore, if false, will check for TimeSinceLastMined.
--// true should be used when you want to delete the ore, and false should be used for despawning logic)
local function DeleteOre(OreID, Order:boolean)	-- DeleteOre centralizes all cleanup logic.
	-- No ore is destroyed directly outside this function,
	-- ensuring slot state and OreState remain consistent.
	-- Look up the ore using its ID.
	local Ore = OreState.ByID[OreID]
	-- Check whether the ore still exists.
	if Ore then
		-- Get the last time the ore was mined.
		local LastMined = Ore:GetAttribute("LastMined")
		if not Order and LastMined then -- Prevent ores from despawning while actively being mined
			-- unless an explicit deletion order is issued.
			-- This avoids resetting the despawn timer on every hit
			-- while still allowing active mining to block deletion.
			-- Calculate how long it has been since the last mining action.
			local TimeSinceLastMined = workspace:GetServerTimeNow() - LastMined
			-- Check whether the ore was mined recently.
			if TimeSinceLastMined < Settings.OreDespawnTime then
				task.delay(Settings.OreDespawnTime, function()	-- Recursive delayed check ensures ores only despawn
					-- after being inactive for the full despawn duration
					-- Call the delete function again.
					DeleteOre(OreID, false)                     
				-- Stop this deletion attempt for now.
				end)
				-- Return from this function.
				return
			end
		end
		-- Destroy the ore instance.
		Ore:Destroy()
		-- Free the ore's spawn slot.
		World:RemoveFromSlot(OreID)
		-- Remove the ore from the tracking table.
		OreState:RemoveOre(OreID)
	end	
end
--// Register an ore
--// Use this function to register a new ore, will add health, ID, etc...
--// Ore: Model
-- Make a function that registers a newly spawned ore.
local function RegisterOre(Ore:Model)
	-- Add the ore to the tracking table and get its ID.
	local OreID = OreState:AddOre(Ore)
	Ore:SetAttribute("LastMined", workspace:GetServerTimeNow())   -- Initialize LastMined immediately so newly spawned ores
	-- participate correctly in despawn timing logic
	-- Schedule the ore's despawn check.
	task.delay(Settings.OreDespawnTime, function()
		-- Delete the ore when the delay finishes if it is inactive.
		DeleteOre(OreID, false)
	end)
	-- Return the ore's ID.
	return OreID
end
--// Randomly select a Rarity
--// Returns a string of the rarity
local function GetRandomRarity() -- Weighted random selection ensures rarer ores appear less frequently without hardcoding spawn limits
	-- Start the total chance at zero.
	local total = 0
	-- Add all rarity chances together.
	for _, chance in pairs(RarityChances) do total += chance end
	-- Pick a random number within the total chance.
	local RandomNumber = math.random(1,total)
	-- Start the running chance total at zero.
	local cumulative = 0
	-- Go through each rarity and its chance.
	for rarity, chance in pairs(RarityChances) do
		-- Add this rarity's chance to the running total.
		cumulative += chance
		-- Check whether the random number falls in this rarity.
		if RandomNumber <= cumulative then return rarity end
	-- Return the selected rarity.
	end
	-- Use VeryCommon as a fallback.
	return "VeryCommon"
end
------------------------------------| Game Initialization |------------------------------------
-- Init performs one-time system bootstrapping:
-- - Builds rarity lookup table
-- - Registers spawn slots
-- - Generates dynamic ore tools
-- - Sanitizes spawn location visibility
-- Make the function that sets up the mining system.
local function Init()
	--// Init OreRarityTable
	-- Use the shared table for the rarity groups.
	local OreRarityTable = OresByRarity
	-- Go through every ore and its settings.
	for oreName, oreInfo in pairs(OreData) do
		if not OreRarityTable[oreInfo.Rarity] then -- Ore rarity group doesn't exist?
			OreRarityTable[oreInfo.Rarity] = {} -- Create rarity group
		end
		-- Add this ore name to its rarity group.
		table.insert(OreRarityTable[oreInfo.Rarity], oreName)
	end

	--// Init OreSpawnLocations
	-- Go through all spawn locations.
	for Index, SpawnLocation in pairs(OreSpawnLocations) do
		-- Add each location as an available slot.
		table.insert(World.AvailableSlots, {['SpawnLocation'] = SpawnLocation, SpawnedOre = nil})
	end

	--// Make Tools for ore
	-- Tools are generated dynamically from drop templates
	-- to prevent manual duplication and reduce maintenance overhead.
	for _, Ore in pairs(OreDropTemplates:GetChildren()) do -- loop through the templates
		-- Copy this drop template.
		local OreClone = Ore:Clone()
		local OreTool = Instance.new("Tool") -- Create a new tool
		local root = OreClone:FindFirstChild("root") -- Make sure there is a "root"; as it will be the handle of the tool
		-- Check whether the handle part exists.
		if not root then 
			-- Warn that the root part is missing.
			Debug_Print("Warn","Ore model " .. Ore.Name .. " is missing a 'root' part!")
			-- Remind what the drop model needs.
			Debug_Print("Warn","Ore Drop must be a model, has 1 part/mesh named 'root'")
			-- Skip this template if it is missing the root part.
			continue
		end
		-- Rename the root part to Handle.
		root.Name = "Handle"
		-- Unanchor the handle.
		root.Anchored = false
		-- Put the handle inside the tool.
		root.Parent = OreTool
		-- Turn off collisions for the handle.
		root.CanCollide = false
		-- Make the handle massless.
		root.Massless = true
		-- Delete the temporary model copy.
		OreClone:Destroy()

		-- Give the tool the template's name.
		OreTool.Name = Ore.Name
		-- Require the tool to have a handle.
		OreTool.RequiresHandle = true
		-- Prevent the tool from being dropped.
		OreTool.CanBeDropped = false
		-- Put the tool in the tools folder.
		OreTool.Parent = OresTools_Folder
	end

	--// Hide Spawn locations
	-- Go through all spawn locations again.
	for _, SpawnLocation in pairs(OreSpawnLocations) do
		-- Make the spawn location invisible.
		SpawnLocation.Transparency = 1
		-- Turn off collisions on the spawn location.
		SpawnLocation.CanCollide = false
	end
end
-- Run initialization safely and capture any error.
local Success, ErrorMsg = pcall(Init)
-- Check whether initialization failed.
if not Success then
	-- Log the initialization error.
	Debug_Print("Error","Initialization Failed!", {ErrorMessage = ErrorMsg})
end
-----------------------------------------------------------------------------------------------
--// Drop ores at the ore's position
--// Player: Player that will own the ores
--// Ore: Ore model that will be dropped
local function DropOres(Player:Player, Ore:Model) -- DropOres is called only after successful ore destruction.
	-- Ownership is embedded into drops to prevent multiplayer exploitation.
	-- Get the settings for this ore by removing the Ore suffix.
	local Data_ForOre = OreData[Ore.Name:split("Ore")[1]]
	-- Find the matching drop template.
	local OreDropTemplate = OreDropTemplates[Ore.Name]
	-- Check whether the drop template exists.
	if not OreDropTemplate then 
		-- Warn that the drop template is missing.
		Debug_Print("Warn","No Ore Drop Template found in 'OreDropTemplate' folder \nPlease add a model for this ore", {OreName = Ore.Name})
		-- Stop if there is no template to clone.
		return 
	end

	-- Repeat once for each drop this ore should give.
	for i = 1, Data_ForOre.DropAmount do
		-- Copy the drop model.
		local DropOre_Clone = OreDropTemplate:Clone()
		-- Small random offset prevents stacked drops which could
		-- cause physics jitter or make individual pickups unreadable
		-- Choose a position near the ore with a random offset.
		local Position = Ore.PrimaryPart.Position + Vector3.new(math.random(2,5), math.random(2,5), math.random(2,5)) 
		-- Put the drop in the workspace.
		DropOre_Clone.Parent = workspace
		DropOre_Clone.root.CanCollide = true -- Enable physics interaction so dropped ores behave
		DropOre_Clone.root.Anchored = false  -- like real world items and are visually readable
		-- Move the drop model to the chosen position.
		DropOre_Clone:PivotTo(CFrame.new(Position))

		-- Save which player owns this drop.
		DropOre_Clone:SetAttribute("Owner", Player.UserId)
		-- Mark the drop as not picked up yet.
		DropOre_Clone:SetAttribute("PickedUp", false)


		-- Create a ProximityPrompt for picking up the drop.
		local pp = Instance.new("ProximityPrompt")
		-- Put the prompt on the root part.
		pp.Parent = DropOre_Clone.root
		-- Set the prompt's action text.
		pp.ActionText = "Pick Up"
		pp.ObjectText = Ore.Name:split("Ore")[1] --Example: Ore.Name = "Iron Ore", then Ore.Name:split("Ore")[1] = Iron
		-- Allow the prompt to work without line of sight.
		pp.RequiresLineOfSight = false
		-- Set how long the player must hold the prompt.
		pp.HoldDuration = 0.1
		-- Set F as the prompt key.
		pp.KeyboardKeyCode = Enum.KeyCode.F
		-- Set the maximum pickup distance.
		pp.MaxActivationDistance = Settings.MaxPickupDistance

		pp.Triggered:Connect(function(Player) -- Prompt validation is fully server-side. Even if client triggers the prompt remotely,
			-- distance and ownership are validated.
			-- Stop if the drop was already picked up.
			if DropOre_Clone:GetAttribute("PickedUp") then return end
			if DropOre_Clone:GetAttribute("Owner") ~= Player.UserId then return end -- Ownership validation prevents other players from
			-- stealing drops via prompt spoofing or lag abuse
			-- Check whether the player has a character and root part.
			if not Player.Character or not Player.Character:FindFirstChild("HumanoidRootPart") then
				-- Log that the character or root part is missing.
				Debug_Print("Debug", "Player has no character or humanoid root part", {UserId = Player.UserId})
				-- Stop if the character is not ready.
				return 
			end
			-- Distance is rechecked server side to prevent exploiters from triggering prompts remotely
			-- Calculate the distance between the player and the drop.
			local Distance = (Player.Character.HumanoidRootPart.Position - DropOre_Clone.root.Position).Magnitude
			if Distance > Settings.MaxPickupDistance + 2 then -- Small buffer accounts for character movement and latency
				-- without meaningfully expanding the allowed pickup range
				-- Log the distance validation failure.
				Debug_Print("Security", "Player is too far from prompt", {UserId = Player.UserId, DistanceFromOre = Distance})
				-- Stop if the player is too far away.
				return
			end
			-- Mark the drop as picked up before removing it.
			DropOre_Clone:SetAttribute("PickedUp", true)
			-- Destroy the drop from the world.
			DropOre_Clone:Destroy()
			-- Find the tool that matches this drop.
			local OreTool = OresTools_Folder:FindFirstChild(Ore.Name)
			-- Stop if the tool was not found.
			if not OreTool then return end
			-- Give the player a copy of the tool.
			OreTool:Clone().Parent = Player.Backpack
		end)

		Debris:AddItem(DropOre_Clone, Settings.OreDropsDespawnTime) -- Debris is used instead of manual cleanup to guarantee
		-- removal even if references are lost or script errors
	end
end

--// Mine Ore
--// Use this function to mine an ore, after checking pickaxe equipped, cooldown, etc...
--// Player: Player mining the ore
--// OreID: number
--// PickaxeData: table
local function MineOre(Player:Player, OreID:number, PickaxeData) -- MineOre contains all mining validation logic.
	-- This prevents mining behavior from being duplicated
	-- across multiple event connections.
	-- Look up the ore using its ID.
	local Ore:Model = OreState.ByID[OreID]
	-- Stop if the ore no longer exists.
	if not Ore then return end
	-- Check whether the player has a character and root part.
	if not Player.Character or not Player.Character:FindFirstChild("HumanoidRootPart") then 
		-- Log that the character or root part is missing.
		Debug_Print("Debug", "Player has no character or humanoid root part", {UserId = Player.UserId})
		-- Stop if the character is not ready.
		return 
	end
	-- Distance is rechecked server-side to prevent exploiters from triggering prompts remotely
	-- Calculate the distance between the player and the ore.
	local Distance = (Player.Character.HumanoidRootPart.Position - Ore.PrimaryPart.Position).Magnitude
	-- Check whether the player is too far away to mine.
	if Distance > Settings.MaxDistanceToOre + 2 then
		-- Log the distance validation failure.
		Debug_Print("Security", "Player is too far from prompt", {UserId = Player.UserId, DistanceFromOre = Distance})
		-- Stop if the player is too far away.
		return 
	end
	-- Get the ore's current health.
	local Health = Ore:GetAttribute("OreHealth")
	-- Get the ore's maximum health.
	local MaxHealth = Ore:GetAttribute("OreMaxHealth")
	local NewHealth = math.max(0, Health - PickaxeData.Damage) -- Clamp health to zero to avoid negative values,
															   -- which would break UI and despawn logic
	-- Check whether the ore has run out of health.
	if NewHealth == 0 then
		if Player:FindFirstChild("leaderstats") and Player.leaderstats:FindFirstChild("Cash") then --Make sure leaderstats and cash exists
			-- Give the player the cash reward for this ore.
			Player.leaderstats.Cash.Value += OreData[Ore.Name:split("Ore")[1]].CashReward
			-- Create the ore drops for the player.
			DropOres(Player, Ore)
		else
			-- Warn if the player's Cash value is missing.
			Debug_Print("Warn","Please make sure players has a 'Cash' of type: IntValue in leaderstats!")
		end
		-- Delete the mined ore and clean up its state.
		DeleteOre(OreID, true)
		-- Stop after the ore has been mined.
		return
	else
		-- Update the prompt text to show the remaining health.
		Ore.Root:FindFirstChild("ProximityPrompt").ObjectText = Ore.Name .. "("..NewHealth.."/"..MaxHealth..")"
	end
	-- Save the ore's new health.
	Ore:SetAttribute("OreHealth", NewHealth)
	Ore:SetAttribute("LastMined", workspace:GetServerTimeNow()) -- Update activity timestamp so the ore is not
	-- despawned while actively being mined
end
--// Attempt to spawn an ore
-- Make a function that tries to spawn an ore.
local function AttemptToSpawnOre() 
	-- AttemptToSpawnOre is intentionally isolated
	-- to keep spawning logic separate from mining logic.
	-- (This is to improve readability and maintainability)
	local RandomRarity = GetRandomRarity() --Pick a random Rarity
	-- Get the table of ore names grouped by rarity.
	local OreRarityTable = OresByRarity
	local OresList = OreRarityTable[RandomRarity] --Get the Ore Rarity Table (something like this: {Common = {"Iron", "Copper"}})
	if not OresList then return end --[[There is no Ore with Rarity 'RandomRarity']]
	local RandomOre = OresList[math.random(1, #OresList)] --Choose 1 random from the Ore Rarity Table
	-- Get the settings for the chosen ore.
	local OreData_ForOre = OreData[RandomOre]

	-- Add the Ore suffix to the chosen ore name.
	local OreName = RandomOre.."Ore"
	-- Find the matching ore model template.
	local OreTemplate = OreTemplates:FindFirstChild(OreName)
	-- Check whether the model template exists.
	if not OreTemplate then 
		-- Warn if the model is missing.
		Debug_Print("Warn","There is no Ore named '".. OreName .."' found in OreTemplates! \nPlease add your model for this ore in OreTemplates folder.", {OreName = OreName})
		-- Stop if there is no model to spawn.
		return
	end
	-- Make a copy of the ore model.
	local Ore:Model = OreTemplate:Clone()
	-- Put the ore model in the workspace.
	Ore.Parent = workspace
	-- Get the model's PrimaryPart.
	local PrimaryPart = Ore.PrimaryPart
	-- Check whether a PrimaryPart is set.
	if not PrimaryPart then
		-- Warn if the model has no PrimaryPart.
		Debug_Print("Warn","Ore model '".. OreName .."' has no set PrimaryPart \nPlease set a PrimaryPart for your Ore model(s).", {OreName = OreName})
		-- Stop if the PrimaryPart is missing.
		return
	end
	-- Register the ore and get its ID.
	local OreID = RegisterOre(Ore)
	-- Choose a spawn slot for this ore.
	local SpawnSlot = World:GetRandomSpawnSlot(OreID)
	-- Check whether a free spawn slot was found.
	if not SpawnSlot then 
		-- Warn that no spawn locations are available.
		Debug_Print("Warn","No available spawn locations!")
		-- Suggest ways to make a spawn slot available.
		Debug_Print("Warn","Consider increasing the number of spawn locations or decreasing the number of maximum spawnable ores in settings.")
		-- Stop if there is no free spawn slot.
		return
	end
	-- Get the chosen spawn location's CFrame.
	local BaseCFrame = SpawnSlot.SpawnLocation.CFrame
	-- Choose a random angle for the ore.
	local RandomAngle = math.rad(math.random(0, 360))

	-- Move the ore to its spawn location.
	Ore:PivotTo(
		-- Rotate the ore by the random angle.
		BaseCFrame * CFrame.Angles(0, RandomAngle, 0)
	)
	-- Get the ore's starting health.
	local Ore_Health = OreData_ForOre.Health
	Ore:SetAttribute("OreHealth", Ore_Health) -- Health and MaxHealth are stored as an attribute to allow easy debugging and future UI integration
	-- Save the maximum health on the ore.
	Ore:SetAttribute("OreMaxHealth", Ore_Health)

	-- Create the prompt used to mine this ore.
	local Prompt = Instance.new("ProximityPrompt")
	-- Put the prompt on the ore's PrimaryPart.
	Prompt.Parent = PrimaryPart
	-- Set the prompt's action text.
	Prompt.ActionText = "Mine"
	-- Show the ore name and its current health.
	Prompt.ObjectText = OreName .. "("..Ore_Health.."/"..Ore_Health..")"
	-- Allow the prompt to work without line of sight.
	Prompt.RequiresLineOfSight = false
	-- Make the prompt trigger immediately.
	Prompt.HoldDuration = 0
	-- Set the maximum mining distance.
	Prompt.MaxActivationDistance = Settings.MaxDistanceToOre
	-- Run this function when the mining prompt is triggered.
	Prompt.Triggered:Connect(function(Player)
		--// Check if player has a pickaxe equipped
		-- Find the tool currently equipped by the player.
		local EquippedTool = Player.Character:FindFirstChildOfClass("Tool")
		-- Checks intentionally fail silently to avoid revealing internal validation logic to exploiters
		-- Stop if the player has no tool equipped.
		if not EquippedTool then return end
		if EquippedTool.Name:split(" ")[2] ~= "Pickaxe" then return end --Example: EquippedTool.Name = "Iron Pickaxe", this means EquippedTool.Name:split(" ")[2] = "Pickaxe"

		if Ore:GetAttribute("Owner") then --// Check if ore is already 'claimed'
			-- Stop if this ore belongs to someone else.
			if Ore:GetAttribute("Owner") ~= Player.UserId then return end
		end
		-- Save this player's ID as the ore's owner.
		Ore:SetAttribute("Owner",  Player.UserId)
		-- Ownership is locked to the first miner to prevent multi-player race conditions
		-- and reward duplication when multiple prompts trigger simultaneously

		local Data = PickaxesData[EquippedTool.Name] --Get the Pickaxe data to apply cooldown and damage
		-- Check whether settings exist for this pickaxe.
		if not Data then 
			-- Warn if this pickaxe has no settings.
			Debug_Print("Warn","No pickaxe data found in 'PickaxesData' for pickaxe '".. EquippedTool.Name .."'!\nConsider adding data for this pickaxe or remove it.")
			-- Stop if the pickaxe settings are missing.
			return 
		end
		-- Check whether the player is still on cooldown.
		if not CooldownManager:CanMine(Player) then 
			-- Stop if the player cannot mine yet.
			return
		end

		-- Check whether the pickaxe tier is high enough.
		if Data.Tier < OreData_ForOre.MinRequiredTier then
			-- Log that the pickaxe is too weak.
			Debug_Print('Debug','Your pickaxe is too weak to mine this ore', {["Player"] = Player, ['PickaxeTier'] = Data.Tier, ['OreTier'] = OreData_ForOre.MinRequiredTier})
			-- Stop if the pickaxe tier is too low.
			return 
		end
		Prompt.Enabled = false -- Disable prompt globally to prevent concurrent triggered events from corrupting ore state
		-- Wait for the pickaxe cooldown before re-enabling the prompt.
		task.delay(Data.Cooldown, function()
			-- Enable the prompt again.
			Prompt.Enabled = true
		end)
		-- Start this player's mining cooldown.
		CooldownManager:StartCooldown(Player, Data.Cooldown)

		-- Apply the mining hit to the ore.
		MineOre(Player, OreID, Data)
	end)
end	

-- Run the ore spawning loop in its own task.
task.spawn(function()
	-- Keep the spawning loop running.
	while true do
		-- Wait for the configured spawn cooldown.
		task.wait(Settings.SpawnOreCooldown) 

		-- SpawnedOres acts as a global cap to prevent uncontrolled ore growth,
		-- which protects both server performance and spawn slot consistency
		if OreState.SpawnedOres >= Settings.MaxOres then --// Max ores spawned?
			continue       --// *skip* spawning a new ore
		end

		-- Try to spawn another ore.
		AttemptToSpawnOre()
	end
end)
