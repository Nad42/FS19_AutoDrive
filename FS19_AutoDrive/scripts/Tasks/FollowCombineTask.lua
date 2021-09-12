FollowCombineTask = ADInheritsFrom(AbstractTask)
FollowCombineTask.debug = false

FollowCombineTask.STATE_CHASING = 1
FollowCombineTask.STATE_WAIT_FOR_TURN = 2
FollowCombineTask.STATE_REVERSING = 3
FollowCombineTask.STATE_WAIT_FOR_PASS_BY = 4
FollowCombineTask.STATE_CIRCLING_PATHPLANNING = 5
FollowCombineTask.STATE_CIRCLING = 6
FollowCombineTask.STATE_FINISHED = 7
FollowCombineTask.STATE_WAIT_BEFORE_FINISH = 8

FollowCombineTask.MAX_REVERSE_DISTANCE = 25
FollowCombineTask.MIN_COMBINE_DISTANCE = 25
FollowCombineTask.MAX_REVERSE_TIME = 8000

function FollowCombineTask:new(vehicle, combine)
    local o = FollowCombineTask:create()
    o.vehicle = vehicle
    o.combine = combine
    o.state = FollowCombineTask.STATE_CHASING
    o.reverseStartLocation = nil
    o.angleWrongTimer = AutoDriveTON:new()
    o.waitForTurnTimer = AutoDriveTON:new()
    o.stuckTimer = AutoDriveTON:new()
    o.lastChaseSide = -10
    o.waitForPassByTimer = AutoDriveTON:new()
    o.chaseTimer = AutoDriveTON:new()
    o.startedChasing = false
    o.reverseTimer = AutoDriveTON:new()
    o.waitTimer = AutoDriveTON:new()
    o.chasePos, o.chaseSide = vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeChasePosition()
    o.angleToCombineHeading = vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
    o.angleToCombine = vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombine()
    o.trailers = nil
    return o
end

function FollowCombineTask:setUp()
    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "Setting up FollowCombineTask")
    self.lastChaseSide = self.chaseSide
    self.trailers, _ = AutoDrive.getTrailersOf(self.vehicle, false)
    AutoDrive.setTrailerCoverOpen(self.vehicle, self.trailers, true)
end

function FollowCombineTask:update(dt)
    if self.combine == nil or g_currentMission.nodeToObject[self.combine.components[1].node] == nil then
        self:finished()
        return
    end

    self:updateStates(dt)

    if self.state == FollowCombineTask.STATE_CHASING then
        self.chaseTimer:timer(true, 4000, dt)
        self.stuckTimer:timer(true, 30000, dt)
        if (self.filled or self.filledToUnload) and self.combine:getIsBufferCombine() then
            if self.chaseSide ~= nil and self.chaseSide ~= AutoDrive.CHASEPOS_REAR then
                --skip reversing
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "I am filled and driving on the side - skip reversing and finish now")
                self.state = FollowCombineTask.STATE_FINISHED -- finish immediate
                return
            else
                local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
                self.reverseStartLocation = {x = x, y = y, z = z}
                self.state = FollowCombineTask.STATE_REVERSING -- reverse to get room from harvester
                return
            end
        elseif self.filled or (self.combineFillPercent <= 0.1 and not self.combine:getIsBufferCombine()) then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "I am filled - reversing now")
            self.state = FollowCombineTask.STATE_WAIT_BEFORE_FINISH -- unload after some time to let harvester drive away
            return
        end

        if not self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide() then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "I am not on the correct side - set finished now")
            self:finished()
            return
        end

        -- ??? relevant only for CP ???
        if (not self.combine:getIsBufferCombine()) and self.combineFillPercent > 90 
            and AutoDrive.getDistanceBetween(self.vehicle, self.combine) > self.MIN_COMBINE_DISTANCE 
            then
            -- Stop chasing and wait for a normal unload call while standing
            self:finished()
            return
        end

        if self:isCaughtCurrentChaseSide() or AutoDrive.getDistanceBetween(self.vehicle, self.combine) > self.MAX_REVERSE_DISTANCE then
            -- should not be stuck -> reset timer
            self.stuckTimer:timer(false)
        elseif self.stuckTimer:done() or self.angleWrongTimer.elapsedTime > 15000 then
            -- if stuck with harvester - try reverse
            self.stuckTimer:timer(false)
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "got stuck - reversing now")
            local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
            self.reverseStartLocation = {x = x, y = y, z = z}
            self.state = FollowCombineTask.STATE_REVERSING
            return
        end

        -- harvester turns
        if AutoDrive.combineIsTurning(self.combine) then
            --print("Waiting for turn now - 1- t:" ..  AutoDrive.boolToString(AutoDrive.combineIsTurning(self.combine)) .. " anglewrongtimer: " .. AutoDrive.boolToString(self.angleWrongTimer.elapsedTime > 10000))      
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "Detected combine turning: " ..  AutoDrive.boolToString(AutoDrive.combineIsTurning(self.combine)) .. " - waiting for turn to be finished next")
            self.state = FollowCombineTask.STATE_WAIT_FOR_TURN
            return
        elseif ((self.combine.lastSpeedReal * self.combine.movingDirection) <= -0.00005) then
            self.vehicle.ad.specialDrivingModule:driveReverse(dt, self.combine.lastSpeedReal * 3600 * 1.3, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
        else
            self:followChasePoint(dt)
        end
        if self.filledToUnload then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "filled until filllevel - finishing now")
            self:finished()
            return
        end
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_TURN then
        self.waitForTurnTimer:timer(true, 60000, dt)
        if self.waitForTurnTimer:done() then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "combine turn took to long - set finished now")
            self.waitForTurnTimer:timer(false)
            self:finished()
            return
        end

        if AutoDrive.combineIsTurning(self.combine) then
            if self.distanceToCombine < ((self.vehicle.sizeLength + self.combine.sizeLength) / 2 + 15) then
                -- if combine drive reverse to turn -> reverse to keep distance
                self:reverse(dt)
            else
                -- stop while combine is turning
                self.vehicle.ad.specialDrivingModule:stopVehicle()
                self.vehicle.ad.specialDrivingModule:update(dt)
            end
        end

        -- check if we could continue
        if not AutoDrive.combineIsTurning(self.combine) and 
            (
                (
                    self.combine.ad.sensors.frontSensorFruit:pollInfo() and 
                    (
                        self.combine:getIsBufferCombine() -- chopper
                        or self.combine.ad.driveForwardTimer.elapsedTime > 8000 -- Harvester moves
                    ) 
                ) 
                or self.waitForTurnTimer.elapsedTime > 15000 -- turn longer than 15 sec
            ) then
            if (self.angleToCombineHeading + self.angleToCombine) < 180 and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide(self.chaseSide) then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "combine turn finished - Heading looks good - start chasing again")
                self.waitForTurnTimer:timer(false)
                self.chaseTimer:timer(false)
                self.state = FollowCombineTask.STATE_CHASING
                return
            else
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "combine turn finished - Heading looks bad - stop to be able to start pathfinder")
                self.stayOnField = true
                self:finished()
                return
            end
        end
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_PASS_BY then
        self.waitForPassByTimer:timer(true, 2200, dt)
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
        if self.waitForPassByTimer:done() then
            self.waitForPassByTimer:timer(false)
            self.chaseTimer:timer(false)
            if (self.angleToCombineHeading + self.angleToCombine) < 180 and self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide() then
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "passby timer elapsed - heading looks good - chasing again")
                self.stuckTimer:timer(false)
                self.state = FollowCombineTask.STATE_CHASING
                return
            else
                AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "passby timer elapsed - heading looks bad - set finished now")
                self.stayOnField = true
                self:finished()
                return
            end
        end
    elseif self.state == FollowCombineTask.STATE_REVERSING then
        local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
        local distanceToReverseStart = MathUtil.vector2Length(x - self.reverseStartLocation.x, z - self.reverseStartLocation.z)
        self.reverseTimer:timer(true, self.MAX_REVERSE_TIME, dt)
        local doneReversing = distanceToReverseStart > self.MAX_REVERSE_DISTANCE or self.distanceToCombine > self.MIN_COMBINE_DISTANCE or (not self.startedChasing)
        if doneReversing or self.reverseTimer:done() then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "done reversing - set finished")
            self.reverseTimer:timer(false)
            self.state = FollowCombineTask.STATE_WAIT_BEFORE_FINISH
            return
        else
            self:reverse(dt)
        end
    elseif self.state == FollowCombineTask.STATE_WAIT_BEFORE_FINISH then
        self.waitTimer:timer(true, FollowCombineTask.MAX_REVERSE_TIME, dt)
        if self.waitTimer:done() then
            self.waitTimer:timer(false)
            self.state = FollowCombineTask.STATE_FINISHED
            return
        else
            self.vehicle.ad.specialDrivingModule:stopVehicle()
            self.vehicle.ad.specialDrivingModule:update(dt)
        end
    elseif self.state == FollowCombineTask.STATE_FINISHED then
        self:finished()
        return
    end
end

function FollowCombineTask:startPathPlanningForCircling()
    local sideOffset = 0
    if self.chaseSide ~= nil and self.chaseSide == AutoDrive.CHASEPOS_LEFT then
        sideOffset = 8
    elseif self.chaseSide ~= nil and self.chaseSide == AutoDrive.CHASEPOS_RIGHT then
        sideOffset = -8
    end

    local targetPos = AutoDrive.createWayPointRelativeToVehicle(self.vehicle, sideOffset, 0)
    local directionX, directionY, directionZ = localToWorld(self.vehicle.components[1].node, 0, 0, 0)
    local direction = {x = directionX - targetPos.x, z = directionZ - targetPos.z}
    self.vehicle.ad.pathFinderModule:startPathPlanningTo(targetPos, direction)
end

function FollowCombineTask:updateStates(dt)
    local x, y, z = getWorldTranslation(self.vehicle.components[1].node)
    local cx, cy, cz = getWorldTranslation(self.combine.components[1].node)

    self.chasePos, self.chaseSide = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getPipeChasePosition()

    self.angleToCombineHeading = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombineHeading()
    self.angleToCombine = self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:getAngleToCombine()

    if (not self.vehicle.ad.modes[AutoDrive.MODE_UNLOAD]:isUnloaderOnCorrectSide(self.chaseSide)) and (not AutoDrive.combineIsTurning(self.combine)) then
        if self.lastChaseSide ~= CombineUnloaderMode.CHASEPOS_REAR then
            AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "switching chase side from side to elsewhere - let's wait for passby next")
            self.state = FollowCombineTask.STATE_WAIT_FOR_PASS_BY
        end
    end
    self.lastChaseSide = self.chaseSide

    self.distanceToCombine = MathUtil.vector2Length(x - cx, z - cz)

    if (g_updateLoopIndex  % AutoDrive.PERF_FRAMES == 0) or self.updateStatesFirst ~= true then
        self.updateStatesFirst = true

        self.cfillLevel, self.cleftCapacity = AutoDrive.getFilteredFillLevelAndCapacityOfAllUnits(self.combine)
        self.cmaxCapacity = self.cfillLevel + self.cleftCapacity
        self.combineFillPercent = (self.cfillLevel / self.cmaxCapacity) * 100

        self.fillLevel, self.leftCapacity = AutoDrive.getFillLevelAndCapacityOfAll(self.trailers)
        local maxCapacity = self.fillLevel + self.leftCapacity
        self.filledToUnload = (self.leftCapacity <= (maxCapacity * (1 - AutoDrive.getSetting("unloadFillLevel", self.vehicle) + 0.001)))
        self.filled = self.leftCapacity <= 1
    end
    self:shouldWaitForChasePos(dt)
end

function FollowCombineTask:reverse(dt)
    self.vehicle.ad.specialDrivingModule:driveReverse(dt, 15, 1, self.vehicle.ad.trailerModule:canBeHandledInReverse())
end

function FollowCombineTask:followChasePoint(dt)
    if self:shouldWaitForChasePos(dt) then
        self.vehicle.ad.specialDrivingModule:stopVehicle()
        self.vehicle.ad.specialDrivingModule:update(dt)
    else
        self.startedChasing = true
        local combineSpeed = self.combine.lastSpeedReal * 3600
        local acc = 1
        local totalSpeedLimit = 40
        -- Let's start driving a little slower when we are switching sides
        if not self.chaseTimer:done() or not self:isCaughtCurrentChaseSide() then
            acc = 1
            totalSpeedLimit = math.max(combineSpeed + 20, 10)
        end
        self.vehicle.ad.specialDrivingModule:driveToPoint(dt, self.chasePos, combineSpeed, false, acc, totalSpeedLimit)
    end
end

function FollowCombineTask:shouldWaitForChasePos(dt)
    local angle = self:getAngleToChasePos(dt)
    self.angleWrongTimer:timer(angle > 50, 3000, dt)
    local _, _, diffZ = worldToLocal(self.vehicle.components[1].node, self.chasePos.x, self.chasePos.y, self.chasePos.z)
    return self.angleWrongTimer:done() or  diffZ <= -1 --or (not self.combine.ad.sensors.frontSensorFruit:pollInfo())
end

function FollowCombineTask:isCaughtCurrentChaseSide()
    local caught = false
    local angle = self:getAngleToChasePos()
    local vehicleX, vehicleY, vehicleZ = getWorldTranslation(self.vehicle.components[1].node)

    local diffX, _, _ = worldToLocal(self.combine.components[1].node, vehicleX, vehicleY, vehicleZ)
    if (angle < 15) and (self.angleToCombineHeading < 15) and (AutoDrive.sign(diffX) == self.chaseSide or self.chaseSide == AutoDrive.CHASEPOS_REAR) then
        caught = true
    end
    return caught
end

function FollowCombineTask:getAngleToChasePos()
    local worldX, _, worldZ = getWorldTranslation(self.vehicle.components[1].node)
    local rx, _, rz = localDirectionToWorld(self.vehicle.components[1].node, 0, 0, 1)
    local angle = math.abs(AutoDrive.angleBetween({x = rx, z = rz}, {x = self.chasePos.x - worldX, z = self.chasePos.z - worldZ}))
    return angle
end

function FollowCombineTask:abort()
end

function FollowCombineTask:finished()
    AutoDrive.debugPrint(self.vehicle, AutoDrive.DC_COMBINEINFO, "FollowCombineTask:finished()")
    self.vehicle.ad.taskModule:setCurrentTaskFinished()
end

function FollowCombineTask:getExcludedVehiclesForCollisionCheck()
    local excludedVehicles = {}
    if self.state == FollowCombineTask.STATE_CHASING then
        table.insert(excludedVehicles, self.combine)
    end
    return excludedVehicles
end

function FollowCombineTask:getInfoText()
    local text = ""
    if self.state == FollowCombineTask.STATE_CHASING then
        text = g_i18n:getText("AD_task_chasing_combine") .. " - "
        if not self:isCaughtCurrentChaseSide() then
            text = text .. g_i18n:getText("AD_task_catching_chase_side") .. ": "
        else
            text = text .. g_i18n:getText("AD_task_chase_side") .. ": "
        end
        if self.chaseSide == AutoDrive.CHASEPOS_LEFT then
            text = text .. g_i18n:getText("AD_task_chase_side_left")
        elseif self.chaseSide == AutoDrive.CHASEPOS_REAR then
            text = text .. g_i18n:getText("AD_task_chase_side_rear")
        elseif self.chaseSide == AutoDrive.CHASEPOS_RIGHT then
            text = text .. g_i18n:getText("AD_task_chase_side_right")
        end
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_TURN then
        text = g_i18n:getText("AD_task_wait_for_combine_turn")
    elseif self.state == FollowCombineTask.STATE_REVERSING then
        text = g_i18n:getText("AD_task_reversing_from_combine")
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_PASS_BY then
        text = g_i18n:getText("AD_task_wait_for_combine_pass_by")
    elseif self.state == FollowCombineTask.STATE_WAIT_BEFORE_FINISH then
        text = g_i18n:getText("AD_task_waiting_for_room")
    end
    return text
end

function FollowCombineTask:getI18nInfo()
    local text = ""
    if self.state == FollowCombineTask.STATE_CHASING then
        text = "$l10n_AD_task_chasing_combine;" .. " - "
        if not self:isCaughtCurrentChaseSide() then
            text = text .. "$l10n_AD_task_catching_chase_side;" .. ": "
        else
            text = text .. "$l10n_AD_task_chase_side;" .. ": "
        end
        if self.chaseSide == AutoDrive.CHASEPOS_LEFT then
            text = text .. "$l10n_AD_task_chase_side_left;"
        elseif self.chaseSide == AutoDrive.CHASEPOS_REAR then
            text = text .. "$l10n_AD_task_chase_side_rear;"
        elseif self.chaseSide == AutoDrive.CHASEPOS_RIGHT then
            text = text .. "$l10n_AD_task_chase_side_right;"
        end
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_TURN then
        text = "$l10n_AD_task_wait_for_combine_turn;"
    elseif self.state == FollowCombineTask.STATE_REVERSING then
        text = "$l10n_AD_task_reversing_from_combine;"
    elseif self.state == FollowCombineTask.STATE_WAIT_FOR_PASS_BY then
        text = "$l10n_AD_task_wait_for_combine_pass_by;"
    elseif self.state == FollowCombineTask.STATE_WAIT_BEFORE_FINISH then
        text = "$l10n_AD_task_waiting_for_room;"
    end
    return text
end
