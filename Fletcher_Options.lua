-- Fletcher - Fletcher_Options.lua
-- The settings page, under Options > AddOns > Fletcher, laid out the way
-- BeastXP's is and the game's own settings list is: the title in a header
-- strip with a Defaults button and the divider under it, section headings,
-- then rows with the label on the left and the control from the middle.
-- Every control goes through the same setters as the right-click menu and the
-- slash commands (ns.API, in Fletcher.lua), so the three can never disagree.
--
-- A canvas page (Settings.RegisterCanvasLayoutCategory), not a vertical list:
-- the game's settings search reads the rows of every vertical list, and
-- ItemTree found that carries an addon's taint into Blizzard's own rows. And
-- every frame is made at login while the page is hidden, never while the
-- settings window is open. The controls are the client's own templates, the
-- ones BeastXP's page already uses on Forever.

local addonName, ns = ...
if not ns.Allowed then return end

local API = ns.API

local PAGE_TITLE = "Fletcher"

-- The settings list's own measurements, as BeastXP takes them: the title at
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
-- settings window leaves room for.
local SCROLL_TOP = HEADER_HEIGHT + 2
local SCROLL_RIGHT = -24
local SCROLL_BOTTOM = 4

local DROPDOWN_WIDTH = 220
local SLIDER_WIDTH = 250
local GOLD_BOX_WIDTH = 64
local GOLD_BOX_LETTERS = 8

-- How far the gold sliders reach. A typed amount may go past them, up to
-- what the setters take.
local KEEP_SLIDER_MAX = 100
local CAP_SLIDER_MAX = 50

-- The status rows, in order, by the labels API.StatusLines gives. Only what
-- reads away from a vendor: the game closes the vendor window when the
-- settings window opens, so the vendor's own lines would never show here.
local STATUS_ROWS = { "Quiver", "Ammo slot" }
local VENDOR_HINT = "At a vendor, hover the Fletcher button for the best ammo there and what a refill buys, or type /ammo status."

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

-- The client's stepper slider, whole gold only; the box beside it shows the
-- exact amount. Its change callback is the one BeastXP reads on Forever.
local function Slider(row, minimum, maximum, onChange)
    local slider = CreateFrame("Slider", nil, row, "MinimalSliderWithSteppersTemplate")
    slider:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(20)
    slider:Init(minimum, minimum, maximum, maximum - minimum, nil)
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        if refreshing then return end
        onChange(math.floor(value + 0.5))
    end)
    return slider
end

-- A box on a slider's right for typing an exact amount of gold, for example
-- 0.5. Enter or clicking away applies it, and the setter keeps it in range;
-- Escape, or a box left empty or not holding an amount, puts the current
-- value back.
local function GoldBox(row, slider, current, apply)
    local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    box:SetSize(GOLD_BOX_WIDTH, 20)
    box:SetPoint("LEFT", slider, "RIGHT", 14, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(GOLD_BOX_LETTERS)
    box:SetJustifyH("CENTER")
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        self.cancelled = true
        self:ClearFocus()
    end)
    -- Hooked, so the template still clears its highlight.
    box:HookScript("OnEditFocusLost", function(self)
        local copper = API.ParseGold(strtrim(self:GetText() or ""))
        if copper and not self.cancelled then apply(copper) end
        self.cancelled = false
        self:SetText(API.GoldText(current()))
    end)
    return box
end

-- Shows an amount in a GoldBox, unless one is being typed into it.
local function SetBoxValue(box, copper)
    if not box:HasFocus() then box:SetText(API.GoldText(copper)) end
end

-- A gold slider and its box, both setting copper through apply.
local function GoldRow(text, maximum, key, apply)
    local row = Row(text)
    local slider = Slider(row, 0, maximum, function(gold) apply(gold * API.COPPER_PER_GOLD) end)
    local box = GoldBox(row, slider, function() return API.GetDB()[key] end, apply)
    return slider, box
end

-- The client's dropdown. The generator runs every time the menu opens and on
-- every refresh, so the button shows the selection.
local function Dropdown(row, width, generator)
    local dropdown = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    dropdown:SetWidth(width)
    dropdown:SetupMenu(generator)
    controls.dropdowns[#controls.dropdowns + 1] = dropdown
    return dropdown
end

-- A read-only value on a row, in white.
local function Value(row)
    local value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("LEFT", row, "CENTER", CONTROL_X, 0)
    value:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)
    value:SetText("")
    return value
end

--------------------------------------------------------------------------------
-- Keeping the page in step
--------------------------------------------------------------------------------

local function GoldValue(copper)
    return math.floor(copper / API.COPPER_PER_GOLD + 0.5)
end

-- The status rows, read fresh.
local function UpdateStatus()
    local values = {}
    for _, line in ipairs(API.StatusLines()) do values[line[1]] = line[2] end
    controls.status["Quiver"]:SetText(values["Quiver"] or values["Status"] or "")
    controls.status["Ammo slot"]:SetText(values["Ammo slot"] or "")
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
    controls.keep:SetValue(GoldValue(db.keepCopper))
    controls.cap:SetValue(GoldValue(db.capCopper))
    SetBoxValue(controls.keepBox, db.keepCopper)
    SetBoxValue(controls.capBox, db.capCopper)
    for _, dropdown in ipairs(controls.dropdowns) do
        dropdown:GenerateMenu()
    end
    UpdateStatus()
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

    -- Defaults takes a second click: the first only asks. Leaving the page
    -- puts the question away again.
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
    Tooltip(controls.autoBuy, "Talking to a vendor that sells your ammo fills your quiver or ammo pouch. Hold Shift while you talk to the vendor to skip it once. The Fletcher button in the vendor window refills either way.")

    controls.keep, controls.keepBox = GoldRow("Keep gold", KEEP_SLIDER_MAX, "keepCopper", API.SetKeepCopper)
    Tooltip(controls.keepBox, "Money a refill never touches, in gold. Type an amount such as 0.5, then press Enter.")

    controls.cap, controls.capBox = GoldRow("Spending cap", CAP_SLIDER_MAX, "capCopper", API.SetCapCopper)
    Tooltip(controls.capBox, "The most one refill spends, in gold; 0 means no cap. Type an amount such as 0.5, then press Enter.")

    Dropdown(Row("When my ammo is better"), DROPDOWN_WIDTH, function(_, root)
        local db = API.GetDB()
        for _, choice in ipairs(API.BETTER_CHOICES) do
            local key = choice.key
            root:CreateRadio(choice.name,
                function() return db.betterAmmo == key end,
                function() API.SetBetterAmmo(key) end)
        end
    end)

    controls.report = Checkbox(Row("Report purchases in chat"), API.SetReport)
    Tooltip(controls.report, "One line in chat after each refill: what was bought, what it cost and how many of the quiver's slots are in use.")
end

local function BuildVendorSection()
    Section("Vendor window")

    controls.showButton = Checkbox(Row("Show vendor button"), API.SetShowButton)
    Tooltip(controls.showButton, "A small button at the top of the vendor window: left click to refill, right click for these options.")

    controls.highlight = Checkbox(Row("Highlight best ammo"), API.SetHighlight)
    Tooltip(controls.highlight, "A gold border around the best ammo the vendor sells that you can use.")

    controls.highlightOther = Checkbox(Row("Highlight other usable ammo"), API.SetHighlightOther)
    Tooltip(controls.highlightOther, "A dimmer green border around the other ammo of the same kind you can use.")

    controls.pulse = Checkbox(Row("Pulse"), API.SetPulse)
    Tooltip(controls.pulse, "The best ammo gets the gold glow that runs around an ability when it procs. Off, it keeps a still gold glow.")
end

local function BuildStatusSection()
    Section("Status")
    controls.status = {}
    for _, label in ipairs(STATUS_ROWS) do
        controls.status[label] = Value(Row(label))
    end

    -- Where the vendor's side is shown, in the settings list's grey.
    local row = NextRow(ROW_HEIGHT)
    local hint = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", LABEL_X, 0)
    hint:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(0.5, 0.5, 0.5)
    hint:SetText(VENDOR_HINT)
end

local function BuildPage()
    page = CreateFrame("Frame")
    page:Hide()
    controls.dropdowns = {}

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
