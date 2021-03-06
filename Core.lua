local AngryAssign = LibStub("AceAddon-3.0"):NewAddon("AngryAssignments", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceTimer-3.0")
local AceGUI = LibStub("AceGUI-3.0")
local libS = LibStub("AceSerializer-3.0")
local libC = LibStub("LibCompress")
local lwin = LibStub("LibWindow-1.1")
local libCE = libC:GetAddonEncodeTable()

BINDING_HEADER_AngryAssign = "Angry Assignments"
BINDING_NAME_AngryAssign_WINDOW = "Toggle Window"
BINDING_NAME_AngryAssign_LOCK = "Toggle Lock"
BINDING_NAME_AngryAssign_DISPLAY = "Toggle Display"

local AngryAssign_Version = GetAddOnMetadata("AngryAssignmentsTBC","version") or "unknown"
local AngryAssign_Timestamp = '20190101010000'

local default_channel = "GUILD"
local protocolVersion = 1
local comPrefix = "AnAss"..protocolVersion
local updateFrequency = 2
local pageLastUpdate = {}
local pageTimerId = {}
local displayLastUpdate = nil
local displayTimerId = nil

local guildName = nil
local officerGuildRank = nil -- The lowest officer guild rank

-- Used for version tracking
local warnedOOD = false
local versionList = {}

local currentGroup = nil

-- Pages Saved Variable Format 
--   AngryAssign_Pages = {
--     [Id] = { Id = "1231", Updated = time(), Name = "Name", Contents = "...", Backup = "..." },
--    ...
--   }
--
-- Format for our addon communication
--
-- { "PAGE", [Id], [Last Update Timestamp], [Name], [Contents] }
-- Sent when a page is updated. Id is a random unique value. Checks that sender is Officer or Promoted. Uses GUILD.
--
-- { "REQUEST_PAGE", [Id] }
-- Asks to be sent PAGE with given Id. Response is a throttled PAGE. Uses WHISPER to raid leader.
--
-- { "DISPLAY", [Id], [Last Update Timestamp] }
-- Raid leader / promoted sends out when new page is to be displayed. Checks that sender is Officer or Promoted. Uses RAID.
--
-- { "REQUEST_DISPLAY" }
-- Asks to be sent DISPLAY. Response is a throttled DISPLAY. Uses WHISPER to raid leader.
--
-- { "VER_QUERY" }
-- { "VERSION", [Version], [Project Timestamp] }

-- Constants for dealing with our addon communication
local COMMAND = 1

local PAGE_Id = 2
local PAGE_Updated = 3
local PAGE_Name = 4
local PAGE_Contents = 5

local REQUEST_PAGE_Id = 2

local DISPLAY_Id = 2
local DISPLAY_Updated = 3

local VERSION_Version = 2
local VERSION_Timestamp = 3

local ANGRYASSIGN_TEXTUREPATH = "Interface\\AddOns\\AngryAssignmentsTBC\\Textures\\"

local function IsInRaid()
  if GetNumRaidMembers() > 0 then
    return 1
  end
end

local function GetNumGroupMembers()
  return math.max(GetNumRaidMembers(),GetNumPartyMembers())
end

-------------------------
-- Addon Communication --
-------------------------

function AngryAssign:ReceiveMessage(prefix, data, channel, sender)
  if prefix ~= comPrefix then return end
  
  local one = libCE:Decode(data) -- Decode the compressed data
  
  local two, message = libC:Decompress(one) -- Decompress the decoded data
  
  if not two then error("Error decompressing: " .. message); return end
  
  local success, final = libS:Deserialize(two) -- Deserialize the decompressed data
  if not success then error("Error deserializing " .. final); return end

  self:ProcessMessage( sender, final )
end

function AngryAssign:SendMessage(data, channel, target)
  local one = libS:Serialize( data )
  local two = libC:CompressHuffman(one)
  local final = libCE:Encode(two)
  local destChannel = channel or default_channel

  if destChannel == "RAID" and not IsInRaid() then return end
  if destChannel == "GUILD" and not guildName then return end

  -- self:Print("Sending "..data[COMMAND].." over "..destChannel.." to "..tostring(target))
  self:SendCommMessage(comPrefix, final, destChannel, target, "NORMAL")
end

function AngryAssign:ProcessMessage(sender, data)
  local cmd = data[COMMAND]
  -- self:Print("Received "..data[COMMAND].." from "..sender)
  if cmd == "PAGE" then
    if not self:PermissionCheck(sender) or sender == UnitName('player') then return end

    local contents_updated = true
    local id = data[PAGE_Id]
    local page = AngryAssign_Pages[id]
    if page then
      if page.Updated >= data[PAGE_Updated] then return end -- The version received is not newer then the one we already have

      page.Updated = data[PAGE_Updated]
      page.Name = data[PAGE_Name]
      contents_updated = page.Contents ~= data[PAGE_Contents]
      page.Contents = data[PAGE_Contents]

      if self:SelectedId() == id then
        self:SelectedUpdated(sender)
        self:UpdateSelected()
      end
    else
      AngryAssign_Pages[id] = { Id = id, Updated = data[PAGE_Updated], Name = data[PAGE_Name], Contents = data[PAGE_Contents] }
    end
    if AngryAssign_State.displayed == id then
      self:UpdateDisplayed()
      self:ShowDisplay()
      if contents_updated then self:DisplayUpdateNotification() end
    end
    self:UpdateTree()

  elseif cmd == "DISPLAY" then
    if not self:PermissionCheck(sender) then return end

    local id = data[DISPLAY_Id]
    local updated = data[DISPLAY_Updated]
    local page = AngryAssign_Pages[id]
    if id and (not page or updated > page.Updated) then
      self:SendRequestPage(id, sender)
    end
    
    if AngryAssign_State.displayed ~= id then
      AngryAssign_State.displayed = id
      self:UpdateTree()
      self:UpdateDisplayed()
      self:ShowDisplay()
      if id then self:DisplayUpdateNotification() end
    end

  elseif cmd == "REQUEST_DISPLAY" then

    self:SendDisplay( AngryAssign_State.displayed )

  elseif cmd == "REQUEST_PAGE" then
    
    self:SendPage( data[REQUEST_PAGE_Id] )


  elseif cmd == "VER_QUERY" then
    local revToSend
    local timestampToSend
    local verToSend
    if AngryAssign_Version:sub(1,1) == "@" then verToSend = "dev" else verToSend = AngryAssign_Version end
    if AngryAssign_Timestamp:sub(1,1) == "@" then timestampToSend = "dev" else timestampToSend = tonumber(AngryAssign_Timestamp) end
    self:SendMessage({ "VERSION", [VERSION_Version] = verToSend, [VERSION_Timestamp] = timestampToSend })

  elseif cmd == "VERSION" then
    local localTimestamp, ver, timestamp
    
    if AngryAssign_Timestamp:sub(1,1) == "@" then localTimestamp = nil else localTimestamp = tonumber(AngryAssign_Timestamp) end
    ver = data[VERSION_Version]
    timestamp = data[VERSION_Timestamp]
      
    if localTimestamp ~= nil and timestamp ~= "dev" and timestamp > localTimestamp and not warnedOOD then 
      self:Print("Your version of Angry Assignments is out of date! Download the latest version from www.wowace.com.")
      warnedOOD = true
    end

    local found = false
    for i,v in pairs(versionList) do
      if (v["name"] == sender) then
        v["version"] = ver
        found = true
      end
    end
    if not found then tinsert(versionList, {name = sender, version = ver}) end

  end
end

function AngryAssign:SendPage(id, force)
  local lastUpdate = pageLastUpdate[id]
  local timerId = pageTimerId[id]
  local curTime = time()

  if lastUpdate and (curTime - lastUpdate <= updateFrequency) then
    if not timerId then
      if force then
        self:SendPageMessage(id)
      else
        pageTimerId[id] = self:ScheduleTimer("SendPageMessage", updateFrequency - (curTime - lastUpdate), id)
      end
    elseif force then
      self:CancelTimer( timerId )
      self:SendPageMessage(id)
    end
  else
    self:SendPageMessage(id)
  end
end

function AngryAssign:SendPageMessage(id)
  pageLastUpdate[id] = time()
  pageTimerId[id] = nil
  
  local page = AngryAssign_Pages[ id ]
  if not page then error("Can't send page, does not exist"); return end
  self:SendMessage({ "PAGE", [PAGE_Id] = page.Id, [PAGE_Updated] = page.Updated, [PAGE_Name] = page.Name, [PAGE_Contents] = page.Contents })
end

function AngryAssign:SendDisplay(id, force)
  local curTime = time()

  if displayLastUpdate and (curTime - displayLastUpdate <= updateFrequency) then
    if not displayTimerId then
      if force then
        self:SendDisplayMessage(id)
      else
        displayTimerId = self:ScheduleTimer("SendDisplayMessage", updateFrequency - (curTime - displayLastUpdate), id)
      end
    elseif force then
      self:CancelTimer( displayTimerId )
      self:SendDisplayMessage(id)
    end
  else
    self:SendDisplayMessage(id)
  end
end

function AngryAssign:SendDisplayMessage(id)
  displayLastUpdate = time()
  displayTimerId = nil
  
  local page = AngryAssign_Pages[ id ]
  if not page then
    self:SendMessage({ "DISPLAY", [DISPLAY_Id] = nil, [DISPLAY_Updated] = nil }, "RAID") 
  else
    self:SendMessage({ "DISPLAY", [DISPLAY_Id] = page.Id, [DISPLAY_Updated] = page.Updated }, "RAID") 
  end
end

function AngryAssign:SendRequestDisplay()
  if IsInRaid() then
    local to = self:GetRaidLeader()
    if to then self:SendMessage({ "REQUEST_DISPLAY" }, "WHISPER", to) end
  end
end

function AngryAssign:SendRequestPage(id, to)
  if IsInRaid() or to then
    if not to then to = self:GetRaidLeader() end
    if to then self:SendMessage({ "REQUEST_PAGE", [REQUEST_PAGE_Id] = id }, "WHISPER", to) end
  end
end

function AngryAssign:GetRaidLeader()
  if IsInRaid() then
    for i = 1, 40 do
      local name, rank = GetRaidRosterInfo(i)
      if rank == 2 then
        return name
      end
    end
  end
  return nil
end

function AngryAssign:GetCurrentGroup()
  local player = UnitName('player')
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local name, _, subgroup = GetRaidRosterInfo(i)
      if name == player then
        return subgroup
      end
    end
  end
  return nil
end

function AngryAssign:VersionCheckOutput()
  local versionliststr = ""
  for i,v in pairs(versionList) do
    versionliststr = versionliststr..v["name"].."-|cFFFF0000"..v["version"].."|r "
  end
  self:Print(versionliststr)
  versionliststr = ""
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local name, _, _, _, _, _, _, _, online = GetRaidRosterInfo(i)  
      if online then
        local found = false
        for i,v in pairs(versionList) do
          if v["name"] == name then
            found = true
            break
          end
        end
        if not found then versionliststr = versionliststr .. " " .. name end
      end
    end
  end
  if versionliststr ~= "" then self:Print("Not running:"..versionliststr) end
end

--------------------------
-- Editing Pages Window --
--------------------------

function AngryAssign_ToggleWindow()
  if not AngryAssign.window then AngryAssign:CreateWindow() end
  if AngryAssign.window:IsShown() then 
    AngryAssign.window:Hide() 
  else
    AngryAssign.window:Show() 
  end
end

function AngryAssign_ToggleLock()
  AngryAssign:ToggleLock()
end

local function AngryAssign_AddPage(widget, event, value)
  local popup_name = "AngryAssign_AddPage"
  if StaticPopupDialogs[popup_name] == nil then
    StaticPopupDialogs[popup_name] = {
      button1 = OKAY,
      button2 = CANCEL,
      timeout = -1,
      OnAccept = function()
        local text = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if text ~= "" then AngryAssign:CreatePage(text) end
      end,
      EditBoxOnEnterPressed = function()
        local text =  getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if text ~= "" then AngryAssign:CreatePage(text) end
        this:GetParent():Hide()
      end,
      text = "New page name:",
      hasEditBox = true,
      whileDead = true,
      EditBoxOnEscapePressed = function() this:GetParent():Hide() end,
      hideOnEscape = true,
      preferredIndex = 3
    }
  end
  StaticPopup_Show(popup_name)
end

local function AngryAssign_RenamePage(widget, event, value)
  local page = AngryAssign:Get()
  if not page then return end

  local popup_name = "AngryAssign_RenamePage_"..page.Id
  if StaticPopupDialogs[popup_name] == nil then
    StaticPopupDialogs[popup_name] = {
      button1 = OKAY,
      button2 = CANCEL,
      timeout = -1,
      OnAccept = function()
        local text = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        AngryAssign:RenamePage(page.Id, text)
      end,
      EditBoxOnEnterPressed = function()
        local text = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        AngryAssign:RenamePage(page.Id, text)
        this:GetParent():Hide()
      end,
      OnShow = function()
        getglobal(this:GetName().."EditBox"):SetText(page.Name)
      end,
      whileDead = true,
      hasEditBox = true,
      EditBoxOnEscapePressed = function() this:GetParent():Hide() end,
      hideOnEscape = true,
      preferredIndex = 3
    }
  end
  StaticPopupDialogs[popup_name].text = 'Rename page "'.. page.Name ..'" to:'

  StaticPopup_Show(popup_name)
end

local function AngryAssign_DeletePage(widget, event, value)
  local page = AngryAssign:Get()
  if not page then return end

  local popup_name = "AngryAssign_DeletePage_"..page.Id
  if StaticPopupDialogs[popup_name] == nil then
    StaticPopupDialogs[popup_name] = {
      button1 = OKAY,
      button2 = CANCEL,
      timeout = -1,
      OnAccept = function()
        AngryAssign:DeletePage(page.Id)
      end,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3
    }
  end
  StaticPopupDialogs[popup_name].text = 'Are you sure you want to delete page "'.. page.Name ..'"?'

  StaticPopup_Show(popup_name)
end

local function AngryAssign_RevertPage(widget, event, value)
  if not AngryAssign.window then return end
  AngryAssign:UpdateSelected(true)
end

local function AngryAssign_DisplayPage(widget, event, value)
  if not AngryAssign:PermissionCheck() then return end
  local id = AngryAssign:SelectedId()

  AngryAssign:TouchPage( id )
  AngryAssign:SendPage( id, true )
  AngryAssign:SendDisplay( id, true )
  
  if true and AngryAssign_State.displayed ~= id then
    AngryAssign_State.displayed = AngryAssign:SelectedId()
    AngryAssign:UpdateDisplayed()
    AngryAssign:ShowDisplay()
    AngryAssign:UpdateTree()
    AngryAssign:DisplayUpdateNotification()
  end
end

local function AngryAssign_ClearPage(widget, event, value)
  if not AngryAssign:PermissionCheck() then return end

  AngryAssign:ClearDisplayed()
  AngryAssign:SendDisplay( nil, true )
end

local function AngryAssign_TextChanged(widget, event, value)
  AngryAssign.window.button_revert:SetDisabled(false)
  AngryAssign.window.button_restore:SetDisabled(false)
  AngryAssign.window.button_display:SetDisabled(true)
end

local function AngryAssign_TextEntered(widget, event, value)
  AngryAssign:UpdateContents(AngryAssign:SelectedId(), value)
end

local function AngryAssign_RestorePage(widget, event, value)
  if not AngryAssign.window then return end
  local page = AngryAssign_Pages[AngryAssign:SelectedId()]
  if not page or not page.Backup then return end
  
  AngryAssign.window.text:SetText( page.Backup )
  AngryAssign.window.text.button:Enable()
  AngryAssign_TextChanged(widget, event, value)
end

function AngryAssign:CreateWindow()
  local window = AceGUI:Create("Frame")
  window:SetTitle("Angry Assignments")
  window:SetStatusText("")
  window:SetLayout("Flow")
  if AngryAssign:GetConfig('scale') then window.frame:SetScale( AngryAssign:GetConfig('scale') ) end
  window:SetStatusTable(AngryAssign_State.window)
  window:Hide()
  AngryAssign.window = window

  AngryAssign_Window = window.frame
  window.frame:SetFrameStrata("HIGH")
  window.frame:SetFrameLevel(1)
  tinsert(UISpecialFrames, "AngryAssign_Window")

  local tree = AceGUI:Create("TreeGroup")
  tree:SetTree( self:GetTree() )
  tree:SelectByValue(1)
  tree:SetStatusTable(AngryAssign_State.tree)
  tree:SetFullWidth(true)
  tree:SetFullHeight(true)
  tree:SetLayout("Flow")
  tree:SetCallback("OnGroupSelected", function(widget, event, value) AngryAssign:UpdateSelected(true) end)
  window:AddChild(tree)
  window.tree = tree

  local text = AceGUI:Create("MultiLineEditBox")
  text:SetLabel(nil)
  text:SetFullWidth(true)
  text:SetFullHeight(true)
  text:SetCallback("OnTextChanged", AngryAssign_TextChanged)
  text:SetCallback("OnEnterPressed", AngryAssign_TextEntered)
  tree:AddChild(text)
  window.text = text
  text.button:SetWidth(75)
  local buttontext = text.button:GetFontString()
  buttontext:ClearAllPoints()
  buttontext:SetPoint("TOPLEFT", text.button, "TOPLEFT", 15, -1)
  buttontext:SetPoint("BOTTOMRIGHT", text.button, "BOTTOMRIGHT", -15, 1)

  tree:PauseLayout()
  local button_display = AceGUI:Create("Button")
  button_display:SetText("Send and Display")
  button_display:SetWidth(140)
  button_display:SetHeight(22)
  button_display:ClearAllPoints()
  button_display:SetPoint("BOTTOMRIGHT", text.frame, "BOTTOMRIGHT", 0, 4)
  button_display:SetCallback("OnClick", AngryAssign_DisplayPage)
  tree:AddChild(button_display)
  window.button_display = button_display

  local button_revert = AceGUI:Create("Button")
  button_revert:SetText("Revert")
  button_revert:SetWidth(80)
  button_revert:SetHeight(22)
  button_revert:ClearAllPoints()
  button_revert:SetDisabled(true)
  button_revert:SetPoint("BOTTOMLEFT", text.button, "BOTTOMRIGHT", 6, 0)
  button_revert:SetCallback("OnClick", AngryAssign_RevertPage)
  tree:AddChild(button_revert)
  window.button_revert = button_revert
  
  local button_restore = AceGUI:Create("Button")
  button_restore:SetText("Restore")
  button_restore:SetWidth(80)
  button_restore:SetHeight(22)
  button_restore:ClearAllPoints()
  button_restore:SetPoint("LEFT", button_revert.frame, "RIGHT", 6, 0)
  button_restore:SetCallback("OnClick", AngryAssign_RestorePage)
  tree:AddChild(button_restore)
  window.button_restore = button_restore

  window:PauseLayout()
  local button_add = AceGUI:Create("Button")
  button_add:SetText("Add")
  button_add:SetWidth(80)
  button_add:SetHeight(19)
  button_add:ClearAllPoints()
  button_add:SetPoint("BOTTOMLEFT", window.frame, "BOTTOMLEFT", 17, 18)
  button_add:SetCallback("OnClick", AngryAssign_AddPage)
  window:AddChild(button_add)
  window.button_add = button_add

  local button_rename = AceGUI:Create("Button")
  button_rename:SetText("Rename")
  button_rename:SetWidth(80)
  button_rename:SetHeight(19)
  button_rename:ClearAllPoints()
  button_rename:SetPoint("BOTTOMLEFT", button_add.frame, "BOTTOMRIGHT", 5, 0)
  button_rename:SetCallback("OnClick", AngryAssign_RenamePage)
  window:AddChild(button_rename)
  window.button_rename = button_rename

  local button_delete = AceGUI:Create("Button")
  button_delete:SetText("Delete")
  button_delete:SetWidth(80)
  button_delete:SetHeight(19)
  button_delete:ClearAllPoints()
  button_delete:SetPoint("BOTTOMLEFT", button_rename.frame, "BOTTOMRIGHT", 5, 0)
  button_delete:SetCallback("OnClick", AngryAssign_DeletePage)
  window:AddChild(button_delete)
  window.button_delete = button_delete

  local button_clear = AceGUI:Create("Button")
  button_clear:SetText("Clear Displayed")
  button_clear:SetWidth(128)
  button_clear:SetHeight(19)
  button_clear:ClearAllPoints()
  button_clear:SetPoint("BOTTOMRIGHT", window.frame, "BOTTOMRIGHT", -135, 18)
  button_clear:SetCallback("OnClick", AngryAssign_ClearPage)
  window:AddChild(button_clear)
  window.button_clear = button_clear

  self:UpdateSelected(true)
  
  self:CreateIconPicker()
end

local function AngryAssign_IconPicker_Clicked(widget, event)
  local texture
  if widget:GetUserData('name') then
    icon = widget:GetUserData('name')
  else
    icon = '{icon '..strmatch(widget.image:GetTexture():lower(), "^interface\\icons\\([-_%w]+)$")..'}'
  end

  local position = AngryAssign.window.text.editbox:GetCursorPosition()
  if position > 0 then
    local text = AngryAssign.window.text:GetText()
    AngryAssign.window.text:SetText( strsub(text, 1, position)..icon..strsub(text, position+1, AngryAssign.window.text.editbox:GetNumLetters()) )
    AngryAssign.window.text.editbox:SetCursorPosition( position + string.len(icon) )
  else
    AngryAssign.window.text:SetText( AngryAssign.window.text:GetText()..icon)
  end

  AngryAssign.window.text.button:Enable()
  AngryAssign_TextChanged()
end

function AngryAssign:CreateIconButton(name, texture)
  local icon = AceGUI:Create("Icon")
  icon:SetImage(texture)
  icon.image:SetWidth(20)
  icon.image:SetHeight(20)
  icon:SetWidth(24)
  icon:SetHeight(24)
  icon:SetUserData('name', name)
  icon:SetCallback('OnClick', AngryAssign_IconPicker_Clicked)
  return icon
end

function AngryAssign:CreateIconPicker()
  local window = AceGUI:Create("Frame")
  window:SetTitle("Insert an Icon")
  window:SetLayout("List")
  window:SetWidth(240)
  window:SetHeight(140)
  window.frame:SetParent(self.window.frame)
  window.frame:ClearAllPoints()
  window.frame:SetPoint("TOPLEFT", self.window.frame, "TOPRIGHT", 4, -4)
  window.frame:SetMovable(false)
  window.frame:SetResizable(false)
  window.title:SetScript("OnMouseDown", nil)
  window.title:SetScript("OnMouseUp", nil)
  window.closebutton:Hide()
  window.statusbg:Hide()
  window.sizer_se:Hide()
  
  --window:EnableResize(false)
  self.iconpicker = window

  local group = AceGUI:Create("SimpleGroup")
  group:SetLayout("Flow")
  group:SetFullWidth(true)
  for i = 8, 1, -1 do 
    group:AddChild( self:CreateIconButton("{rt"..i.."}", "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"..i) )
  end
  group:AddChild( self:CreateIconButton("{bl}", "Interface\\Icons\\SPELL_Nature_Bloodlust") )
  group:AddChild( self:CreateIconButton("{hs}", "Interface\\Icons\\INV_Stone_04") )
  group:AddChild( self:CreateIconButton("{tank}", "Interface\\Icons\\Ability_Warrior_DefensiveStance") )
  group:AddChild( self:CreateIconButton("{healer}", "Interface\\Icons\\Spell_Holy_Renew") )
  group:AddChild( self:CreateIconButton("{dps}", "Interface\\Icons\\Ability_DualWield") )
  group:AddChild( self:CreateIconButton("{md}", "Interface\\Icons\\Ability_Hunter_Misdirection") )
  group:AddChild( self:CreateIconButton("{bok}", "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings") )
  group:AddChild( self:CreateIconButton("{bow}", "Interface\\Icons\\Spell_Holy_GreaterBlessingofWisdom") )
  group:AddChild( self:CreateIconButton("{bofs}", "Interface\\Icons\\Spell_Holy_GreaterBlessingofSalvation") )
  group:AddChild( self:CreateIconButton("{bol}", "Interface\\Icons\\Spell_Holy_GreaterBlessingofLight") )
  
  window:AddChild(group)
--[[
  local heading = AceGUI:Create("Heading")
  heading:SetFullWidth(true)
  window:AddChild(heading)

  local text = AceGUI:Create("EditBox")
  text:SetFullWidth(true)
  text:SetCallback("OnTextChanged", AngryAssign_IconPicker_TextChanged)
  window:AddChild(text)

  local scroll = AceGUI:Create("ScrollFrame")
  scroll:SetLayout("Flow")
  scroll:SetFullWidth(true)
  scroll:SetFullHeight(true)
  window:AddChild(scroll)
  self.iconpicker_scroll = scroll
  ]]
end

function AngryAssign:SelectedUpdated(sender)
  if self.window and self.window.text.button:IsEnabled() then
    local popup_name = "AngryAssign_PageUpdated"
    if StaticPopupDialogs[popup_name] == nil then
      StaticPopupDialogs[popup_name] = {
        button1 = OKAY,
        whileDead = true,
        text = "",
        hideOnEscape = true,
        timeout = -1,
        preferredIndex = 3
      }
    end
    StaticPopupDialogs[popup_name].text = "The page you are editing has been updated by "..sender..".\n\nYou can view this update by reverting your changes."
    StaticPopup_Show(popup_name)
    return true
  else
    return false
  end
end

function AngryAssign:GetTree()

  local sortTable = {}
  for _, page in pairs(AngryAssign_Pages) do
    tinsert(sortTable, { Id = page.Id, Name = page.Name })
  end

  table.sort( sortTable, function(a,b) return a.Name < b.Name end)


  local ret = {}
  for _, page in ipairs(sortTable) do
    if page.Id == AngryAssign_State.displayed then
      tinsert(ret, { value = page.Id, text = page.Name, icon = "Interface\\BUTTONS\\UI-GuildButton-MOTD-Up" })
    else
      tinsert(ret, { value = page.Id, text = page.Name })
    end
  end

  return ret
end

function AngryAssign:UpdateTree(id)
  if not self.window then 
    DEFAULT_CHAT_FRAME:AddMessage(self.window) return end
  self.window.tree:SetTree( self:GetTree() )
  if id then
    self.window.tree:SelectByValue( id )
    DEFAULT_CHAT_FRAME:AddMessage(id)
  end
end

function AngryAssign:UpdateSelected(destructive)
  if not self.window then return end
  local page = AngryAssign_Pages[ self:SelectedId() ]
  local permission = self:PermissionCheck()
  if destructive or not self.window.text.button:IsEnabled() then
    if page then
      self.window.text:SetText( page.Contents )
    else
      self.window.text:SetText("")
    end
    self.window.text.button:Disable()
  end
  if page and permission then
    self.window.button_rename:SetDisabled(false)
    self.window.button_revert:SetDisabled(not self.window.text.button:IsEnabled())
    self.window.button_display:SetDisabled(false)
    self.window.button_restore:SetDisabled(not self.window.text.button:IsEnabled() and page.Backup == page.Contents)
    self.window.text:SetDisabled(false)
  else
    self.window.button_rename:SetDisabled(true)
    self.window.button_revert:SetDisabled(true)
    self.window.button_display:SetDisabled(true)
    self.window.button_restore:SetDisabled(true)
    self.window.text:SetDisabled(true)
  end
  if page then
    self.window.button_delete:SetDisabled(false)
  else
    self.window.button_delete:SetDisabled(true)
  end
  if permission then
    self.window.button_add:SetDisabled(false)
    self.window.button_clear:SetDisabled(false)
  else
    self.window.button_add:SetDisabled(true)
    self.window.button_clear:SetDisabled(true)
  end
end

----------------------------------
-- Performing changes functions --
----------------------------------

function AngryAssign:SelectedId()
  return AngryAssign_State.tree.selected
end

function AngryAssign:Get(id)
  if id == nil then id = self:SelectedId() end
  return AngryAssign_Pages[id]
end

function AngryAssign:CreatePage(name)
  if not self:PermissionCheck() then return end
  local id = math.random(2000000000)

  AngryAssign_Pages[id] = { Id = id, Updated = time(), Name = name, Contents = "" }
  self:UpdateTree(id)
  self:SendPage(id, true)
end

function AngryAssign:RenamePage(id, name)
  local page = self:Get(id)
  if not page or not self:PermissionCheck() then return end

  page.Name = name
  page.Updated = time()

  self:SendPage(id, true)
  self:UpdateTree()
  if AngryAssign_State.displayed == id then
    self:UpdateDisplayed()
    self:ShowDisplay()
  end
end

function AngryAssign:DeletePage(id)
  AngryAssign_Pages[id] = nil
  if self.window and self:SelectedId() == id then
    self.window.tree:SetSelected(nil)
    self:UpdateSelected(true)
  end
  if AngryAssign_State.displayed == id then
    self:ClearDisplayed()
  end
  self:UpdateTree()
end

function AngryAssign:TouchPage(id)
  if not self:PermissionCheck() then return end
  local page = self:Get(id)
  if not page then return end

  page.Updated = time()
end

function AngryAssign:UpdateContents(id, value)
  if not self:PermissionCheck() then return end
  local page = self:Get(id)
  if not page then return end

  local new_content = value:gsub('^%s+', ''):gsub('%s+$', '')
  local contents_updated = new_content ~= page.Contents
  page.Contents = new_content
  page.Backup = new_content
  page.Updated = time()

  self:SendPage(id, true)
  self:UpdateSelected(true)
  if AngryAssign_State.displayed == id then
    self:UpdateDisplayed()
    self:ShowDisplay()
    if contents_updated then self:DisplayUpdateNotification() end
  end
end

function AngryAssign:CreateBackup()
  for _, page in pairs(AngryAssign_Pages) do
    page.Backup = page.Contents
  end
  self:UpdateSelected()
end

function AngryAssign:GetGuildRank(player)
  if not guildName then return 100 end
  
  for i = 1, GetNumGuildMembers() do
    local name, _, rankIndex = GetGuildRosterInfo(i)
    if name and (name == player) then
      return rankIndex 
    end
  end
  return 100
end

function AngryAssign:ClearDisplayed()
  AngryAssign_State.displayed = nil
  self:UpdateDisplayed()
  self:UpdateTree()
end

function AngryAssign:UpdateOfficerRank()
  local currentGuildName = GetGuildInfo('player')
  local newOfficerGuildRank = 0
  if currentGuildName then
    for i = 1, GuildControlGetNumRanks() do
      GuildControlSetRank(i)
      if select(4, GuildControlGetRankFlags(i)) ~= nil then
        newOfficerGuildRank = i - 1
      else
        break
      end
    end
  end
  if newOfficerGuildRank ~= officerGuildRank or currentGuildName ~= guildName then
    officerGuildRank = newOfficerGuildRank
    guildName = currentGuildName
    self:UpdateSelected()
  end
end

function AngryAssign:PermissionCheck(sender)
  if not sender then sender = UnitName('player') end
  if IsInRaid() then
    for i = 1, 40 do
      local name, rank = GetRaidRosterInfo(i)
      if rank > 0 and name == sender then
        return true
      end
    end
    return false
  else
    return true
  end
end

---------------------
-- Displaying Page --
---------------------

local function DragHandle_MouseDown(frame) frame:GetParent():GetParent():StartSizing("RIGHT") end
local function DragHandle_MouseUp(frame)
  local display = frame:GetParent():GetParent()
  display:StopMovingOrSizing()
  AngryAssign_State.display.width = display:GetWidth()
  lwin.SavePosition(display)
end
local function Mover_MouseDown(frame) frame:GetParent():StartMoving() end
local function Mover_MouseUp(frame)
  local display = frame:GetParent()
  display:StopMovingOrSizing()
  lwin.SavePosition(display)
end

function AngryAssign_ToggleDisplay()
  AngryAssign:ToggleDisplay()
end

function AngryAssign:ShowDisplay()
  if AngryAssign_State.directionUp then
    AngryAssign.display_text_up:Show()
  else
    AngryAssign.display_text_down:Show()
  end
  AngryAssign_State.display.hidden = false
end

function AngryAssign:HideDisplay()
  AngryAssign.display_text_up:Hide()
  AngryAssign.display_text_down:Hide()
  AngryAssign_State.display.hidden = true
end

function AngryAssign:ToggleDisplay()
  if AngryAssign.display_text_up:IsShown() or AngryAssign.display_text_down:IsShown() then
    AngryAssign:HideDisplay()
  else
    AngryAssign:ShowDisplay()
  end
end

function AngryAssign:CreateDisplay()
  local frame = CreateFrame("Frame", nil, UIParent)
  frame:SetPoint("CENTER",0,0)
  frame:SetWidth(AngryAssign_State.display.width or 300)
  frame:SetHeight(1)
  frame:SetMovable(true)
  frame:SetResizable(true)
  frame:SetMinResize(180,1)
  frame:SetMaxResize(830,1)
  frame:SetFrameStrata("MEDIUM")  

  lwin.RegisterConfig(frame, AngryAssign_State.display)
  lwin.RestorePosition(frame)

  local text_up = CreateFrame("ScrollingMessageFrame", nil, frame)
  text_up:SetIndentedWordWrap(true)
  text_up:SetJustifyH("LEFT")
  text_up:SetFading(false)
  text_up:SetMaxLines(70)
  text_up:SetHeight(700)
  text_up:SetPoint("BOTTOMLEFT", 0, 8)
  text_up:SetPoint("RIGHT", 0, 0)
  text_up:SetInsertMode("BOTTOM")
  self.display_text_up = text_up

  local text_down = CreateFrame("ScrollingMessageFrame", nil, frame)
  text_down:SetIndentedWordWrap(true)
  text_down:SetJustifyH("LEFT")
  text_down:SetFading(false)
  text_down:SetMaxLines(70)
  text_down:SetHeight(700)
  text_down:SetPoint("TOPLEFT", 0, -8)
  text_down:SetPoint("RIGHT", 0, 0)
  text_down:SetInsertMode("TOP")
  self.display_text_down = text_down
  
  local mover = CreateFrame("Frame", nil, frame)
  mover:SetPoint("LEFT",0,0)
  mover:SetPoint("RIGHT",0,0)
  mover:SetHeight(16)
  mover:EnableMouse(true)
  mover:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
  mover:SetBackdropColor( 0.2, 0.2, 0.2, 0.9)
  mover:SetScript("OnMouseDown", Mover_MouseDown)
  mover:SetScript("OnMouseUp", Mover_MouseUp)
  self.mover = mover
  if AngryAssign_State.locked then mover:Hide() end

  local label = mover:CreateFontString()
  label:SetFont("FONTS\\ARIALN.ttf",12)
  label:SetJustifyH("CENTER")
  label:SetPoint("LEFT", 38, 0)
  label:SetPoint("RIGHT", -38, 0)
  label:SetText("Angry Assignments")
  label:SetTextColor(1,1,1,0.75)

  local direction = CreateFrame("Button", nil, mover)
  direction:SetNormalTexture( ANGRYASSIGN_TEXTUREPATH .. "direction")
  direction:SetPoint("LEFT", 2, 0)
  direction:SetWidth(10)
  direction:SetHeight(10)
  direction:GetNormalTexture():SetBlendMode("ADD")
  direction:GetNormalTexture():SetAlpha(0.5)
  direction:SetScript("OnClick", function() AngryAssign:ToggleDirection() end)
  self.direction_button = direction

  local lock = CreateFrame("Button", nil, mover)
  lock:SetNormalTexture( ANGRYASSIGN_TEXTUREPATH .. "lock")
  lock:SetPoint("LEFT", direction, "RIGHT", 4, 0)
  lock:SetWidth(10)
  lock:SetHeight(10)
  lock:GetNormalTexture():SetBlendMode("ADD")
  lock:GetNormalTexture():SetAlpha(0.5)
  lock:SetScript("OnClick", function() AngryAssign:ToggleLock() end)

  local drag = CreateFrame("Frame", nil, mover)
  drag:SetFrameLevel(mover:GetFrameLevel() + 10)
  drag:SetWidth(10)
  drag:SetHeight(10)
  drag:SetPoint("BOTTOMRIGHT", -1, 1)
  drag:EnableMouse(true)
  drag:SetScript("OnMouseDown", DragHandle_MouseDown)
  drag:SetScript("OnMouseUp", DragHandle_MouseUp)
  drag:SetAlpha(0.5)
  local dragtex = drag:CreateTexture(nil, "OVERLAY")
  dragtex:SetTexture( ANGRYASSIGN_TEXTUREPATH .. "draghandle")
  dragtex:SetWidth(10)
  dragtex:SetHeight(10)
  dragtex:SetBlendMode("ADD")
  dragtex:SetPoint("BOTTOMRIGHT", drag)

  if ( not AngryAssign_State.directionUp ) or AngryAssign_State.display.hidden then
    text_up:Hide()
  end
  if AngryAssign_State.directionUp or AngryAssign_State.display.hidden then
    text_down:Hide()
  end
  self:UpdateMedia()
  self:UpdateDirection()
end

function AngryAssign:ToggleLock()
  AngryAssign_State.locked = not AngryAssign_State.locked
  if AngryAssign_State.locked then
    self.mover:Hide()
  else
    self.mover:Show()
  end
end

function AngryAssign:ToggleDirection()
  AngryAssign_State.directionUp = not AngryAssign_State.directionUp
  self:UpdateDirection()
end

function AngryAssign:UpdateDirection()
  if AngryAssign_State.directionUp then
    self.direction_button:GetNormalTexture():SetTexCoord(0,1,0,0.5)
    --self.direction_button:SetPushedTexture("Interface\\BUTTONS\\UI-ScrollBar-ScrollUpButton-Down")
    if not AngryAssign_State.hidden then
      self.display_text_up:Show()
    end
    self.display_text_down:Hide()
  else
    self.direction_button:GetNormalTexture():SetTexCoord(0,1,0.5,1)
    --self.direction_button:SetNormalTexture("Interface\\BUTTONS\\UI-ScrollBar-ScrollDownButton-Up")
    --self.direction_button:SetPushedTexture("Interface\\BUTTONS\\UI-ScrollBar-ScrollDownButton-Down")
    if not AngryAssign_State.hidden then
      self.display_text_down:Show()
    end
    self.display_text_up:Hide()
  end
  self:UpdateDisplayed()
end

function AngryAssign:UpdateMedia()
  local fontName = "Fonts\\ARIALN.TTF"
  local fontHeight = AngryAssign:GetConfig('fontHeight')
  local fontFlags = AngryAssign:GetConfig('fontFlags')

  local hex = self:GetConfig('color')
  self.display_text_up:SetTextColor(tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255)
  self.display_text_up:SetFont(fontName, fontHeight, fontFlags)
  self.display_text_down:SetTextColor(tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255)
  self.display_text_down:SetFont(fontName, fontHeight, fontFlags)
end


function AngryAssign:DisplayUpdateNotification()
  -- TODO
end

local function ci_pattern(pattern)
  local p = pattern:gsub("(%%?)(.)", function(percent, letter)
    if percent ~= "" or not letter:match("%a") then
      return percent .. letter
    else
      return string.format("[%s%s]", letter:lower(), letter:upper())
    end
  end)
  return p
end

function AngryAssign:UpdateDisplayedIfNewGroup()
  local newGroup = self:GetCurrentGroup()
  if newGroup ~= currentGroup then
    currentGroup = newGroup
    self:UpdateDisplayed()
  end
end

function AngryAssign:UpdateDisplayed()
  local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
  if page then
    local text = page.Contents

    local highlights = { }
    for token in string.gmatch( AngryAssign:GetConfig('highlight') , "%w+") do
      token = token:lower()
      if token == 'group'then
        tinsert(highlights, 'g'..(currentGroup or 0))
      else
        tinsert(highlights, token)
      end
    end
    local highlightHex = self:GetConfig('highlightColor')
    
    text = text:gsub("||", "|")
      :gsub(ci_pattern('|cblue'), "|cff049cdb")
      :gsub(ci_pattern('|cgreen'), "|cff46a546")
      :gsub(ci_pattern('|cred'), "|cff9d261d")
      :gsub(ci_pattern('|cyellow'), "|cffffc40d")
      :gsub(ci_pattern('|corange'), "|cfff89406")
      :gsub(ci_pattern('|cpink'), "|cffc3325f")
      :gsub(ci_pattern('|cpurple'), "|cff7a43b6")
      :gsub("(%w+)", function(word)
        local word_lower = word:lower()
        for _, token in ipairs(highlights) do
          if token == word_lower then
            return string.format("|cff%s%s|r", highlightHex, word)
          end
        end
        return word
      end)
      :gsub(ci_pattern('{star}'), "{rt1}")
      :gsub(ci_pattern('{circle}'), "{rt2}")
      :gsub(ci_pattern('{diamond}'), "{rt3}")
      :gsub(ci_pattern('{triangle}'), "{rt4}")
      :gsub(ci_pattern('{moon}'), "{rt5}")
      :gsub(ci_pattern('{square}'), "{rt6}")
      :gsub(ci_pattern('{cross}'), "{rt7}")
      :gsub(ci_pattern('{x}'), "{rt7}")
      :gsub(ci_pattern('{skull}'), "{rt8}")
      :gsub(ci_pattern('{rt([1-8])}'), "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%1:0|t" )
      :gsub(ci_pattern('{healthstone}'), "{hs}")
      :gsub(ci_pattern('{hs}'), "|TInterface\\Icons\\INV_Stone_04:0|t")
      :gsub(ci_pattern('{bloodlust}'), "{bl}")
      :gsub(ci_pattern('{bl}'), "|TInterface\\Icons\\SPELL_Nature_Bloodlust:0|t")
      :gsub(ci_pattern('{icon%s+([%w_]+)}'), "|TInterface\\Icons\\%1:0|t")
      :gsub(ci_pattern('{damage}'), "{dps}")
      :gsub(ci_pattern('{tank}'), "|TInterface\\Icons\\Ability_Warrior_DefensiveStance:0|t")
      :gsub(ci_pattern('{healer}'), "|TInterface\\Icons\\Spell_Holy_Renew:0|t")
      :gsub(ci_pattern('{dps}'), "|TInterface\\Icons\\Ability_DualWield:0|t")
      :gsub(ci_pattern('{bok}'), "|TInterface\\Icons\\Spell_Holy_GreaterBlessingofKings:0|t")
      :gsub(ci_pattern('{bow}'), "|TInterface\\Icons\\Spell_Holy_GreaterBlessingofWisdom:0|t")
      :gsub(ci_pattern('{bofs}'), "|TInterface\\Icons\\Spell_Holy_GreaterBlessingofSalvation:0|t")
      :gsub(ci_pattern('{bol}'), "|TInterface\\Icons\\Spell_Holy_GreaterBlessingofLight:0|t")
      :gsub(ci_pattern('{hero}'), "{heroism}")
      :gsub(ci_pattern('{heroism}'), "|TInterface\\Icons\\ABILITY_Shaman_Heroism:0|t")
      :gsub(ci_pattern('{md}'), "|TInterface\\Icons\\Ability_Hunter_Misdirection:0|t")
    self.display_text_up:Clear()
    self.display_text_down:Clear()
    local lines = { strsplit("\n", text) }
    local lines_count = #lines
    for i = 1, lines_count do
      local line
      if AngryAssign_State.directionUp then
        line = lines[i]
      else 
        line = lines[lines_count - i + 1]
      end
      if line == "" then line = " " end
      self.display_text_up:AddMessage(line)
      self.display_text_down:AddMessage(line)
    end
  else
    self.display_text_up:Clear()
    self.display_text_down:Clear()
  end
end


-----------------
-- Addon Setup --
-----------------

local function RGBToHex(r, g, b)
  r = math.ceil(255 * r)
  g = math.ceil(255 * g)
  b = math.ceil(255 * b)
  return string.format("%02x%02x%02x", r, g, b)
end

local configDefaults = {
  scale = 1,
  hideoncombat = false,
  fontName = "Friz Quadrata TT",
  fontHeight = 12,
  fontFlags = "NONE",
  highlight = "",
  highlightColor = "ffd200",
  color = "ffffff"
}
function AngryAssign:GetConfig(key)
  if AngryAssign_Config[key] == nil then
    return configDefaults[key]
  else
    return AngryAssign_Config[key]
  end
end

function AngryAssign:SetConfig(key, value)
  if configDefaults[key] == value then
    AngryAssign_Config[key] = nil
  else
    AngryAssign_Config[key] = value
  end
end

function AngryAssign:RestoreDefaults()
  AngryAssign_Config = {}
  self:UpdateMedia()
  self:UpdateDisplayed()
  LibStub("AceConfigRegistry-3.0"):NotifyChange("AngryAssign")
end

local blizOptionsPanel
function AngryAssign:OnInitialize()
  if AngryAssign_State == nil then
    AngryAssign_State = { tree = {}, window = {}, display = {}, displayed = nil, locked = false, directionUp = false }
  end
  if AngryAssign_Pages == nil then AngryAssign_Pages = { } end
  if AngryAssign_Config == nil then AngryAssign_Config = { } end
  if not AngryAssign_Config.highlightColor and AngryAssign_Config.highlightColorR and AngryAssign_Config.highlightColorG and AngryAssign_Config.highlightColorB then
    AngryAssign_Config.highlightColor = RGBToHex( AngryAssign_Config.highlightColorR, AngryAssign_Config.highlightColorG, AngryAssign_Config.highlightColorB )
    AngryAssign_Config.highlightColorR = nil
    AngryAssign_Config.highlightColorG = nil
    AngryAssign_Config.highlightColorB = nil
  end

  local ver = AngryAssign_Version
  if ver:sub(1,1) == "@" then ver = "dev" end
  
  local options = {
    name = "Angry Assignments "..ver,
    handler = AngryAssign,
    type = "group",
    args = {
      window = {
        type = "execute",
        order = 3,
        name = "Toggle Window",
        desc = "Shows/hides the edit window (also available in game keybindings)",
        func = function() AngryAssign_ToggleWindow() end
      },
      help = {
        type = "execute",
        order = 99,
        name = "Help",
        hidden = true,
        func = function()
          LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryAssign", "")
        end
      },
      toggle = {
        type = "execute",
        order = 1,
        name = "Toggle Display",
        desc = "Shows/hides the display frame (also available in game keybindings)",
        func = function() AngryAssign_ToggleDisplay() end
      },
      deleteall = {
        type = "execute",
        name = "Delete All Pages",
        desc = "Deletes all pages",
        order = 4,
        hidden = true,
        cmdHidden = false,
        confirm = true,
        func = function()
          AngryAssign_State.displayed = nil
          AngryAssign_Pages = {}
          self:UpdateTree()
          self:UpdateSelected()
          self:UpdateDisplayed()
          if self.window then self.window.tree:SetSelected(nil) end
          self:Print("All pages have been deleted.")
        end
      },
      defaults = {
        type = "execute",
        name = "Restore Defaults",
        desc = "Restore configuration values to their default settings",
        order = 9,
        hidden = true,
        cmdHidden = false,
        confirm = true,
        func = function()
          self:RestoreDefaults()
        end
      },
      backup = {
        type = "execute",
        order = 7,
        name = "Backup Pages",
        desc = "Creates a backup of all pages with their current contents",
        func = function() 
          self:CreateBackup()
          self:Print("Created a backup of all pages.")
        end
      },
      version = {
        type = "execute",
        order = 8,
        name = "Version Check",
        desc = "Displays a list of all users (in the guild) running the addon and the version they're running",
        func = function()
          versionList = {} -- start with a fresh version list, when displaying it
          self:SendMessage({ "VER_QUERY" }) 
          self:ScheduleTimer("VersionCheckOutput", 2)
          self:Print("Version check running...")
        end
      },
      lock = {
        type = "execute",
        order = 2,
        name = "Toggle Lock",
        desc = "Shows/hides the display mover (also available in game keybindings)",
        func = function() self:ToggleLock() end
      },
      config = { 
        type = "group",
        order = 5,
        name = "General",
        inline = true,
        args = {
          highlight = {
            type = "input",
            order = 1,
            name = "Highlight",
            desc = "A list of words to highlight on displayed pages (separated by spaces or punctuation)\n\nUse 'Group' to highlight the current group you are in, ex. G2",
            get = function(info) return self:GetConfig('highlight') end,
            set = function(info, val)
              self:SetConfig('highlight', val)
              self:UpdateDisplayed()
            end
          },
          hideoncombat = {
            type = "toggle",
            order = 3,
            name = "Hide on Combat",
            desc = "Enable to hide display frame upon entering combat",
            get = function(info) return self:GetConfig('hideoncombat') end,
            set = function(info, val)
              self:SetConfig('hideoncombat', val)

            end
          },
          scale = {
            type = "range",
            order = 4,
            name = "Scale",
            desc = function() 
              return "Sets the scale of the edit window"
            end,
            min = 0.3,
            max = 3,
            get = function(info) return self:GetConfig('scale') end,
            set = function(info, val)
              self:SetConfig('scale', val)
              if AngryAssign.window then AngryAssign.window.frame:SetScale(val) end
            end
          }
        }
      },
      font = { 
        type = "group",
        order = 6,
        name = "Font",
        inline = true,
        args = {
          --[[
          fontname = {
            type = 'select',
            order = 1,
            dialogControl = 'LSM30_Font',
            name = 'Face',
            desc = 'Sets the font face used to display a page',
            values = LSM:HashTable("font"),
            get = function(info) return self:GetConfig('fontName') end,
            set = function(info, val)
              self:SetConfig('fontName', val)
              self:UpdateMedia()
            end
          },
          ]]
          fontheight = {
            type = "range",
            order = 2,
            name = "Size",
            desc = function() 
              return "Sets the font height used to display a page"
            end,
            min = 6,
            max = 24,
            step = 1,
            get = function(info) return self:GetConfig('fontHeight') end,
            set = function(info, val)
              self:SetConfig('fontHeight', val)
              self:UpdateMedia()
            end
          },
          fontflags = {
            type = "select",
            order = 3,
            name = "Outline",
            desc = function() 
              return "Sets the font outline used to display a page"
            end,
            values = { ["NONE"] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline", ["MONOCHROMEOUTLINE"] = "Monochrome" },
            get = function(info) return self:GetConfig('fontFlags') end,
            set = function(info, val)
              self:SetConfig('fontFlags', val)
              self:UpdateMedia()
            end
          },
          color = {
            type = "color",
            order = 4,
            name = "Normal Color",
            desc = "The normal color used to display assignments",
            get = function(info)
              local hex = self:GetConfig('color')
              return tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255
            end,
            set = function(info, r, g, b)
              self:SetConfig('color', RGBToHex(r, g, b))
              self:UpdateMedia()
              self:UpdateDisplayed()
            end
          },
          highlightcolor = {
            type = "color",
            order = 5,
            name = "Highlight Color",
            desc = "The color used to emphasize highlighted words",
            get = function(info)
              local hex = self:GetConfig('highlightColor')
              return tonumber("0x"..hex:sub(1,2)) / 255, tonumber("0x"..hex:sub(3,4)) / 255, tonumber("0x"..hex:sub(5,6)) / 255
            end,
            set = function(info, r, g, b)
              self:SetConfig('highlightColor', RGBToHex(r, g, b))
              self:UpdateDisplayed()
            end
          }
        }
      }
    }
  }

  self:RegisterChatCommand("aa", "ChatCommand")
  LibStub("AceConfig-3.0"):RegisterOptionsTable("AngryAssign", options)

  blizOptionsPanel = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("AngryAssign", "Angry Assignments")
  blizOptionsPanel.default = function() self:RestoreDefaults() end
end

function AngryAssign:ChatCommand(input)
  if not input or input:trim() == "" then
  --InterfaceOptionsFrame_OpenToCategory(blizOptionsPanel)
  InterfaceOptionsFrame_OpenToFrame(blizOptionsPanel)
  else
    LibStub("AceConfigCmd-3.0").HandleCommand(self, "aa", "AngryAssign", input)
  end
end

function AngryAssign:OnEnable()
  self:UpdateOfficerRank()
  self:CreateDisplay()

  self:RegisterComm(comPrefix, "ReceiveMessage")
  
  self:ScheduleTimer("AfterEnable", 4)

  self:RegisterEvent("PARTY_CONVERTED_TO_RAID")
  self:RegisterEvent("GROUP_JOINED")
  self:RegisterEvent("PLAYER_REGEN_DISABLED")
  self:RegisterEvent("GROUP_ROSTER_UPDATE")
  self:RegisterEvent("PLAYER_GUILD_UPDATE")

end

function AngryAssign:PARTY_CONVERTED_TO_RAID()
  self:SendRequestDisplay()
  self:UpdateDisplayedIfNewGroup()
end

function AngryAssign:GROUP_JOINED()
  self:SendRequestDisplay()
  self:UpdateDisplayedIfNewGroup()
end

function AngryAssign:PLAYER_REGEN_DISABLED()
  if AngryAssign:GetConfig('hideoncombat') then
    self:HideDisplay()
  end
end

function AngryAssign:GROUP_ROSTER_UPDATE()
  self:UpdateSelected()
  if not IsInRaid() then
    if AngryAssign_State.displayed then self:ClearDisplayed() end
    currentGroup = nil
  else
    self:UpdateDisplayedIfNewGroup()
  end
end

function AngryAssign:PLAYER_GUILD_UPDATE()
  self:UpdateOfficerRank()
end

function AngryAssign:AfterEnable()
  if not IsInRaid() then
    self:ClearDisplayed()
  end  
  self:SendMessage({ "VER_QUERY" })
  self:SendRequestDisplay()
  self:UpdateDisplayedIfNewGroup()
end