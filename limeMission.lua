--=======================================================================================================
-- SCRIPT
--
-- Purpose:     Lime contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    15.02.2025  initial port from FS22
--  v1.0.0.1    17.04.2025  console cmd limission, doubled reward (#7)
--=======================================================================================================
LimeMission = {
	NAME = "limeMission",
	REWARD_PER_HA = 3000,
	REIMBURSEMENT_PER_HA = 2020, 
	-- price for 1000 sec: 	Fert: .006 l/s * 1920 = 11520
	-- 						Lime: .090 l/s *  225 = 20250
	debug = false,
}
function debugPrint(text, ...)
	if LimeMission.debug == true then
		Logging.info(text,...)
	end
end

local LimeMission_mt = Class(LimeMission, AbstractFieldMission)
InitObjectClass(LimeMission, "LimeMission")

function LimeMission:registerXMLPaths(key)
	LimeMission:superClass().registerXMLPaths(self, key)
	self:register(XMLValueType.INT, key .. "#rewardPerHa", "Reward per ha")
end

function LimeMission.new(isServer, isClient, customMt)
	local self = AbstractFieldMission.new(isServer, isClient, 
		g_i18n:getText("contract_field_lime_title"),
		g_i18n:getText("contract_field_lime_description"),
		customMt or LimeMission_mt)
	self.workAreaTypes = {
		[WorkAreaType.SPRAYER] = true
	}
	return self
end
function LimeMission:createModifier()
	local limeLevelMax = g_fieldManager.limeLevelMaxValue
	local map, firstChannel, numChannels = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.LIME_LEVEL)
	self.completionModifier = DensityMapModifier.new(map, firstChannel, numChannels, g_terrainNode)
	self.completionFilter = DensityMapFilter.new(self.completionModifier)
	self.completionFilter:setValueCompareParams(DensityValueCompareType.EQUAL, limeLevelMax)
end
function LimeMission:getFieldFinishTask()
	self.field:getFieldState().limeLevel = g_fieldManager.limeLevelMaxValue
	return LimeMission:superClass().getFieldFinishTask(self)
end
function LimeMission.getRewardPerHa(_)
	return g_missionManager:getMissionTypeDataByName(LimeMission.NAME).rewardPerHa
end
function LimeMission:calculateReimbursement()
	-- add value of left over lime in leased vehicles
	LimeMission:superClass().calculateReimbursement(self)
	local reimb = 0
	for _, vec in pairs(self.vehicles) do
		if vec.spec_fillUnit ~= nil then
			for k, _ in pairs(vec:getFillUnits()) do
				local ft = vec:getFillUnitFillType(k)
				if ft == FillType.LIME then
					reimb = reimb + vec:getFillUnitFillLevel(k) * g_fillTypeManager:getFillTypeByIndex(ft).pricePerLiter
				end
			end
		end
	end
	self.reimbursement = self.reimbursement + reimb * AbstractMission.REIMBURSEMENT_FACTOR
end
function LimeMission.getMissionTypeName(_)
	return LimeMission.NAME
end
function LimeMission:validate()
	if LimeMission:superClass().validate(self) then
		return (self:getIsFinished() or LimeMission.isAvailableForField(self.field, self)) and true or false
	else
		return false
	end
end
function LimeMission.tryGenerateMission()
	if LimeMission.canRun() then
		local field = g_fieldManager:getFieldForMission()
		if field == nil then
			return
		end
		if field.currentMission ~= nil then
			return
		end
		if not LimeMission.isAvailableForField(field, nil) then
			return
		end
		local mission = LimeMission.new(true, g_client ~= nil)
		if mission:init(field) then
			mission:setDefaultEndDate()
			return mission
		end
		mission:delete()
	end
	return nil
end
function LimeMission.isAvailableForField(field, mission)
	-- mission nil: original call when generating missions
	-- else: 2nd call when upadting existing missions
	if mission == nil then
		local fieldState = field:getFieldState()
		if not fieldState.isValid then
			return false
		end
		--[[ -- we can lime on a freshly fertilized field
		if fieldState.sprayType ~= FieldSprayType.NONE then
			return false
		end]]
		local limeLevel = fieldState.limeLevel
		if not g_currentMission.missionInfo.limeRequired or limeLevel > 0 then 
			-- no lime required, or already limed
			return false 
		end
		-- we can run on an empty field (no fruit defined)
		local fruitIndex = fieldState.fruitTypeIndex
		local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
		
		if fruitDesc == nil then 
			debugPrint("* limeMission on empty field %s", field.farmland.name)
			return true
		end
		if fruitDesc:getIsCatchCrop() then return false end

		local maxGrowthState = fieldState.growthState
		if fruitDesc:getIsHarvestable(maxGrowthState) then return false end

		-- we can run on a seeded field (growth 1), or a stubble field (growth = cutState)
		debugPrint("f%s, growth %d, spray %s, sprayType %s, plow %s, lime %s, weed %s, roller %s",
			field.farmland.name, maxGrowthState, fieldState.sprayLevel, fieldState.sprayType, fieldState.plowLevel, limeLevel, fieldState.weedState, fieldState.rollerLevel)
		if maxGrowthState and maxGrowthState < 2 then
			debugPrint("* can run")
			return true
		elseif maxGrowthState == fruitDesc.cutState then
			debugPrint("* can run (stubble)")
			return true
		end
		return false
	end
	local v44 = g_currentMission.environment
	return v44 == nil or v44.currentSeason ~= Season.WINTER
end
function LimeMission.canRun()
	local type = g_missionManager:getMissionTypeDataByName(LimeMission.NAME)
	if type.numInstances >= type.maxNumInstances then
		return false
	else
		return not g_currentMission.growthSystem:getIsGrowingInProgress()
	end
end
-- ---------------------------------------------------------------
LimeMissions = {}
local LimeMissions_mt = Class(LimeMissions)

function LimeMissions:new(default)
	local self = {}
	setmetatable(self, LimeMissions_mt)
	self.isServer = g_server ~= nil 
	self.isClient = g_dedicatedServerInfo == nil

	g_missionManager:registerMissionType(LimeMission, LimeMission.NAME, 4)
	
	-- rewardPerHa for other mission types are loaded from map
	g_missionManager:getMissionTypeDataByName(LimeMission.NAME).rewardPerHa = 
		LimeMission.REWARD_PER_HA
	addConsoleCommand("limission", "Force generating a lime mission for given field", 
		"consoleGenMission", self, "fieldId")
	return self 
end
function LimeMissions:consoleGenMission(fieldNo)
	-- generate Lime mission on given field
	return g_missionManager:consoleGenerateMission(fieldNo, "limeMission")
end

g_LimeMissions = LimeMissions:new()
