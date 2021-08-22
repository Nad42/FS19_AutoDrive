ADColorSettingsGui = {}
ADColorSettingsGui.CONTROLS = {"listItemTemplate", "autoDriveColorList"}
ADColorSettingsGui.debug = false

local ADColorSettingsGui_mt = Class(ADColorSettingsGui, ScreenElement)

function ADColorSettingsGui:new(target)
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:new") -- 1
    local o = ScreenElement:new(target, ADColorSettingsGui_mt)
    o.returnScreenName = ""
    o.listItems = {}
    o.rowIndex = 0
    o:registerControls(ADColorSettingsGui.CONTROLS)
    return o
end

function ADColorSettingsGui:onCreate()
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onCreate") -- 2
    self.listItemTemplate:unlinkElement()
    self.listItemTemplate:setVisible(false)
end

function ADColorSettingsGui:onOpen()
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onOpen") -- 4
    self:refreshItems()
    ADColorSettingsGui:superClass().onOpen(self)
end

function ADColorSettingsGui:refreshItems()
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:refreshItems")   -- 5
    self.listItems = {}
    self.rowIndex = 1
    local colorKeys = AutoDrive:getColorKeyNames()
    self.autoDriveColorList:deleteListItems()
    for _ , v in pairs(colorKeys) do
        table.insert(self.listItems, {key = v, listItemText = g_i18n:getText(v)})
    end
    table.sort(
        self.listItems,
        function(a, b)
            return a.listItemText < b.listItemText
        end
    )
    for _, listItem in ipairs(self.listItems) do
        local new = self.listItemTemplate:clone(self.autoDriveColorList)
        new:setVisible(true)
        new.elements[1]:setText(listItem.listItemText)
        new:updateAbsolutePosition()
    end
end

function ADColorSettingsGui:onListSelectionChanged(rowIndex)
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onListSelectionChanged rowIndex %s", tostring(rowIndex)) -- 3 -> rowIndex==0 !!!
    if rowIndex > 0 then
        self.rowIndex = rowIndex
    end
end

function ADColorSettingsGui:onClickOk()   -- OK
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onClickOk self.rowIndex %s", tostring(self.rowIndex))
    local controlledVehicle = g_currentMission.controlledVehicle
    if controlledVehicle ~= nil and controlledVehicle.ad ~= nil and controlledVehicle.ad.selectedColorNodeId ~= nil then
        local colorPoint = ADGraphManager:getWayPointById(controlledVehicle.ad.selectedColorNodeId)
        if colorPoint ~= nil and colorPoint.colors ~= nil then
            if self.rowIndex > 0 and self.listItems ~= nil and #self.listItems > 0 then
                local colorKeyName = self.listItems[self.rowIndex].key
                ADColorSettingsGui.debugMsg("ADColorSettingsGui:onClickOk colorKeyName %s ", tostring(colorKeyName))
                AutoDrive:setColorAssignment(colorKeyName, colorPoint.colors[1], colorPoint.colors[2], colorPoint.colors[3])
                AutoDrive.writeLocalSettingsToXML()
            end
        end
    end
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onClickOk end")
    ADColorSettingsGui:superClass().onClickBack(self)
end

function ADColorSettingsGui:onClickBack()   -- ESC
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onClickBack")
    ADColorSettingsGui:superClass().onClickBack(self)
end

function ADColorSettingsGui:onClickReset()
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onClickReset")
    if self.rowIndex > 0 and self.listItems ~= nil and #self.listItems > 0 then
        local colorKeyName = self.listItems[self.rowIndex].key
        AutoDrive:resetColorAssignment(colorKeyName)
        AutoDrive.writeLocalSettingsToXML()
    end
    ADColorSettingsGui:superClass().onClickBack(self)
end

function ADColorSettingsGui:onEnterPressed(_, isClick)
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onEnterPressed isClick %s", tostring(isClick))
    if not isClick then
        -- self:onDoubleClick(self.autoDriveColorList:getSelectedElementIndex())
    end
end

function ADColorSettingsGui:onEscPressed()
    ADColorSettingsGui.debugMsg("ADColorSettingsGui:onEscPressed")
    self:onClickBack()
end

function ADColorSettingsGui.debugMsg(...)
    if ADColorSettingsGui.debug == true then
        AutoDrive.debugMsg(nil, ...)
    end
end
