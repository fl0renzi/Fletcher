-- Fletcher - Fletcher_Options.lua
-- The settings page, under Options > AddOns > Fletcher, drawn the way the
-- game's own settings list is: the title in a header strip with a Defaults
-- button and the divider under it, section headings, then rows with the label
-- on the left and the control from the middle. Every control goes through the
-- same setters in ns.API as the right-click menu and the slash commands, so
-- the three can never disagree.
--
-- A canvas page (Settings.RegisterCanvasLayoutCategory), not a vertical list,
-- and every frame made at login while the page is hidden, as BeastXP's is:
-- the game's settings search reads the rows of every vertical list, and a
-- page built while the settings window is open carries an addon's taint into
-- Blizzard's own rows. The controls are the client's own templates.

local addonName, ns = ...
if not ns.Allowed then return end

local API = ns.API

local PAGE_TITLE = "Fletcher"

-- The settings list's own measurements, the same numbers BeastXP's page is
-- drawn with, as ItemTree takes them from Blizzard_SettingsList: the title at
-- 7, -22 in a 50 tall header strip, the Defaults button 96 by 22 at -36, -16
-- from the top right, rows 26 tall with 9 between them, the label 37 in, the
-- control from 80 left of the middle.
local HEADER_HEIGHT = 50
local TITLE_X, TITLE_Y = 7, -22
local DEFAULTS_WIDTH, DEFAULTS_HEIGHT = 96, 22
local DEFAULTS_X, DEFAULTS_Y = -36, -16
local ROW_HEIGHT = 26
local ROW_SPACING = 9
local SECTION_HEIGHT = 40
local LABEL_X = 37
local CONTROL_X = -80

-- Under the header the page scrolls, since its rows can be taller than the
-- settings window leaves room for. The client's scroll bar sits 6 to the
-- right of the scrolling area and is 8 wide.
local SCROLL_TOP = HEADER_HEIGHT + 2
local SCROLL_RIGHT = -24
local SCROLL_BOTTOM = 4

local SLIDER_WIDTH = 250
local NUMBER_BOX_WIDTH = 52

local page            -- the canvas frame, built at login
local content         -- the scrolling part of the page, under the header
local categoryID      -- what Settings.OpenToCategory takes
local combatWaiter    -- opens the page once combat ends
local controls = {}   -- what RefreshPage keeps in step with the settings
local refreshing = false -- true while RefreshPage sets controls, so they do not call back

--------------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------------

local nextY -- where the next row goes, walking down the scrolling part

local function NextRow(height)
    local row = CreateFrame("Frame", nil, content)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, nextY)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, nextY)
    row:SetHeight(height)
    nextY = nextY - height - ROW_SPACING
    return row
end

local function Section(text)
    local row = NextRow(SECTION_HEIGHT)
    local title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("BOTTOMLEFT", TITLE_X, 4)
    title:SetText(text)
end

-- A row with its label; the control is anchored to the row's middle.
local function Row(text, height)
    local row = NextRow(height or ROW_HEIGHT)
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", LABEL_X, 0)
    label:SetPoint("RIGHT", row, "CENTER", CONTROL_X - 8, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(text)
    return row
end

-- A status row: one line, all of it text, refreshed from API.Status() on
-- every show of the page and at every setting change. Nothing here goes
-- through a control, so there is nothing to refresh a control with.
local function TextRow()
    local row = NextRow(ROW_HEIGHT)
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", LABEL_X, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    return text
end

local function Tooltip(widget, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Checkbox(row, onClick)
    local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    check:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    check:SetScript("OnClick", function(self)
        if refreshing then return end
        onClick(self:GetChecked() and true or false)
    end)
    return check
end

local function WholeNumber(value)
    return ("%d"):format(math.floor(value + 0.5))
end

-- Gold, shown the way the slash command takes it: 0.5 for half a gold.
local function GoldText(value)
    return ("%g"):format(value)
end

-- The client's stepper slider, whole numbers only, with the value on its
-- right unless a NumberBox shows it there instead. Its change callback is the
-- one Baganator reads on Forever.
local function Slider(row, minimum, maximum, onChange, withBox)
    local slider = CreateFrame("Slider", nil, row, "MinimalSliderWithSteppersTemplate")
    slider:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(20)
    slider:Init(minimum, minimum, maximum, maximum - minimum, not withBox and {
        [MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(
            MinimalSliderWithSteppersMixin.Label.Right, WholeNumber),
    } or nil)
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if refreshing then return end
        onChange(math.floor(value + 0.5))
    end)
    return slider
end

-- A box on a slider's right for typing an exact amount. Enter or clicking
-- away applies it, and the setter keeps it in range; Escape, or a box left
-- empty or not holding a number, puts the current value back. A gold box
-- takes decimals (0.5), so it is not numeric; the whole ones refuse them.
local function NumberBox(row, slider, current, apply, decimal)
    local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    box:SetSize(NUMBER_BOX_WIDTH, 20)
    box:SetPoint("LEFT", slider, "RIGHT", 14, 0)
    box:SetAutoFocus(false)
    if not decimal then box:SetNumeric(true) end
    box:SetMaxLetters(decimal and 7 or 4)
    box:SetJustifyH("CENTER")
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        self.cancelled = true
        self:ClearFocus()
    end)
    -- Hooked, so the template still clears its highlight.
    box:HookScript("OnEditFocusLost", function(self)
        local value = tonumber(self:GetText())
        if value and not self.cancelled then apply(value) end
        self.cancelled = false
        self:SetText((decimal and GoldText or WholeNumber)(current()))
    end)
    return box
end

-- Shows a value in a NumberBox, unless a number is being typed into it.
local function SetBoxValue(box, value, decimal)
    if not box:HasFocus() then
        box:SetText((decimal and GoldText or WholeNumber)(value))
    end
end

--------------------------------------------------------------------------------
-- Keeping the page in step
--------------------------------------------------------------------------------

-- The Status section's lines, straight from ns.API.Status(), which rereads
-- the bags each time it is asked for.
local function RefreshStatus()
    local status = API.Status()
    controls.statusQuiver:SetText("Quiver: " .. status.quiver)
    controls.statusKind:SetText("Kind: " .. status.kind)
    controls.statusRounds:SetText("Rounds: " .. status.rounds)
    controls.statusAmmoSlot:SetText("Ammo slot: " .. status.ammoSlot)
end

local function RefreshPage()
    local db = API.GetDB()
    refreshing = true
    controls.autoBuy:SetChecked(db.autoBuy)
    controls.report:SetChecked(db.report)
    controls.showButton:SetChecked(db.showButton)
    controls.highlight:SetChecked(db.highlight)
    controls.highlightOther:SetChecked(db.highlightOther)
    controls.pulse:SetChecked(db.pulse)
    controls.keep:SetValue(db.keepCopper / 10000)
    controls.cap:SetValue(db.capCopper / 10000)
    SetBoxValue(controls.keepBox, db.keepCopper / 10000, true)
    SetBoxValue(controls.capBox, db.capCopper / 10000, true)
    RefreshStatus()
    refreshing = false
end

-- Called by every setter in Fletcher.lua. Only an open page is redrawn; a
-- closed one catches up in OnShow.
function ns.OnSettingsChanged()
    if page and page:IsVisible() then RefreshPage() end
end

--------------------------------------------------------------------------------
-- The page
--------------------------------------------------------------------------------

local function BuildHeader()
    local title = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", TITLE_X, TITLE_Y)
    title:SetJustifyH("LEFT")
    title:SetText(PAGE_TITLE)

    -- The version beside the title, small and grey, when the toc names one.
    if API.Version then
        local version = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 2)
        version:SetTextColor(0.5, 0.5, 0.5)
        version:SetText(API.Version)
    end

    local divider = page:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("Options_HorizontalDivider", true)
    divider:SetPoint("TOP", 0, -HEADER_HEIGHT)

    -- Defaults takes a second click, as ItemTree's does: the first only asks.
    -- Leaving the page puts the question away again.
    local defaults = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    defaults:SetSize(DEFAULTS_WIDTH, DEFAULTS_HEIGHT)
    defaults:SetPoint("TOPRIGHT", DEFAULTS_X, DEFAULTS_Y)
    defaults:SetText("Defaults")
    defaults:SetScript("OnClick", function(self)
        if self.armed then
            self.armed = false
            self:SetText("Defaults")
            API.ResetDefaults()
        else
            self.armed = true
            self:SetText("Click again")
        end
    end)
    Tooltip(defaults, "Puts every setting back to how a fresh install has it.")
    controls.defaults = defaults
end

local function BuildBuyingSection()
    Section("Buying")

    controls.autoBuy = Checkbox(Row("Auto buy"), API.SetAutoBuy)
    Tooltip(controls.autoBuy, "Opens a vendor that sells ammo for your bag's kind, and buys exactly what fills the bag. Hold Shift while opening the vendor to skip it once.")

    controls.report = Checkbox(Row("Report purchases in chat"), API.SetReport)
    Tooltip(controls.report, "One chat line when an automatic refill is done, with what was bought and what it cost. A manual refill reports anyway.")

    -- The reserve, in whole gold on the slider, with decimals in the box.
    local keepRow = Row("Keep gold")
    controls.keep = Slider(keepRow, 0, API.MAX_GOLD, function(value)
        API.SetKeepGold(value)
    end, true)
    controls.keepBox = NumberBox(keepRow, controls.keep,
        function() return API.GetDB().keepCopper / 10000 end, API.SetKeepGold, true)
    Tooltip(controls.keepBox, "Never spend below this much gold, for example 0.5 for half. Type a number, then press Enter.")
    SetBoxValue(controls.keepBox, API.GetDB().keepCopper / 10000, true)

    local capRow = Row("Spending cap")
    controls.cap = Slider(capRow, 0, API.MAX_GOLD, function(value)
        API.SetCapGold(value)
    end, true)
    controls.capBox = NumberBox(capRow, controls.cap,
        function() return API.GetDB().capCopper / 10000 end, API.SetCapGold, true)
    Tooltip(controls.capBox, "The most one refill may spend, for example 1 for a gold. 0 means no cap. Type a number, then press Enter.")
    SetBoxValue(controls.capBox, API.GetDB().capCopper / 10000, true)
end

local function BuildVendorSection()
    Section("Vendor window")

    controls.showButton = Checkbox(Row("Show vendor button"), API.SetShowButton)
    Tooltip(controls.showButton, "The small button at the vendor window's top right, whose click refills the quiver and whose tooltip says what a refill would do.")

    controls.highlight = Checkbox(Row("Highlight best ammo"), API.SetHighlight)
    Tooltip(controls.highlight, "A gold border around the best ammo the vendor sells that you can use.")

    controls.highlightOther = Checkbox(Row("Highlight other usable ammo"), API.SetHighlightOther)
    Tooltip(controls.highlightOther, "A dim green border around the other ammo of your bag's kind that the vendor sells.")

    controls.pulse = Checkbox(Row("Pulse"), API.SetPulse)
    Tooltip(controls.pulse, "The gold border gently breathes.")
end

local function BuildStatusSection()
    Section("Status")

    controls.statusQuiver = TextRow()
    controls.statusKind = TextRow()
    controls.statusRounds = TextRow()
    controls.statusAmmoSlot = TextRow()
end

local function BuildPage()
    page = CreateFrame("Frame")
    page:Hide()

    BuildHeader()

    -- The rows scroll under the header in the client's own scroll frame,
    -- whose scroll bar shows only when the rows do not fit.
    local scroll = CreateFrame("ScrollFrame", nil, page, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -SCROLL_TOP)
    scroll:SetPoint("BOTTOMRIGHT", SCROLL_RIGHT, SCROLL_BOTTOM)
    if scroll.ScrollBar and scroll.ScrollBar.SetHideIfUnscrollable then
        scroll.ScrollBar:SetHideIfUnscrollable(true)
    end
    content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)
    -- A scroll child takes no width from its scroll frame, so it is given it.
    scroll:HookScript("OnSizeChanged", function(_, width) content:SetWidth(width) end)
    nextY = -10

    BuildBuyingSection()
    BuildVendorSection()
    BuildStatusSection()
    content:SetSize(scroll:GetWidth(), -nextY)

    page:SetScript("OnShow", function()
        content:SetWidth(scroll:GetWidth())
        RefreshPage()
    end)
    page:SetScript("OnHide", function()
        controls.defaults.armed = false
        controls.defaults:SetText("Defaults")
    end)
end

--------------------------------------------------------------------------------
-- Registering and opening
--------------------------------------------------------------------------------

-- Called once from Fletcher.lua's PLAYER_LOGIN, after the settings are
-- loaded, for every character: the settings are account-wide, so they can be
-- set up from any of them.
function ns.InstallSettings()
    if page or not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return
    end

    BuildPage()
    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, page, PAGE_TITLE)
    if not ok or not category then return end
    pcall(Settings.RegisterAddOnCategory, category)
    categoryID = category.GetID and category:GetID() or category.ID

    -- The client will not open the settings window in combat, so a request
    -- made then waits for combat to end.
    combatWaiter = CreateFrame("Frame")
    combatWaiter:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        Settings.OpenToCategory(categoryID)
    end)
end

-- Returns false when there is no page to open, so the caller can say so.
function ns.OpenSettings()
    if not categoryID then return false end
    if InCombatLockdown() then
        API.Print("the settings page opens when combat ends.")
        combatWaiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        return true
    end
    Settings.OpenToCategory(categoryID)
    return true
end
