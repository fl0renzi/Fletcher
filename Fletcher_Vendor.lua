-- Fletcher - Fletcher_Vendor.lua
-- The parts of Fletcher that live in the vendor window:
--   the gold border on the item icon of the best ammo, an optional dim green
--   border on the other usable ammo, with an optional gentle pulse;
--   a small button with the chosen ammo's icon at the vendor window's top
--   right, whose click refills the quiver, whose right-click opens the
--   settings menu, and whose tooltip says what a refill would do;
--   the right-click menu, whose entries go through the same setters in
--   ns.API as the settings page and the slash commands.
--
-- Everything here is built lazily on the first callable visit of a hunter,
-- never at load, so a hunter that never opens a vendor pays for nothing but
-- its event registrations. The game's own functions are only ever hooked
-- with hooksecurefunc, drawn after Blizzard drew, and nothing writes into a
-- Blizzard frame, so none of Fletcher's paths can taint the vendor window.

local addonName, ns = ...
if not ns.Allowed then return end

local API = ns.API

-- The game's tooltip colours, for a label line and for a hint line, as
-- BeastXP takes them.
local LABEL_COLOR = { 1.0, 0.82, 0.0 }
local HINT_COLOR  = { 0.5, 0.5, 0.5 }

-- The highlight's own look: the client's action button border, drawn over
-- the item's icon at this multiple of its size, tinted gold for the best
-- ammo and dim green for the others.
local BORDER_TEXTURE  = "Interface\\Buttons\\UI-ActionButton-Border"
local BORDER_SCALE    = 1.8
local BEST_COLOR      = { 1.0, 0.78, 0.0 }
local OTHER_COLOR     = { 0.4, 0.8, 0.3 }
local OTHER_ALPHA     = 0.7

-- The pulse, an alpha bounce on the best border. VERIFY(phase0): which
-- animation calls Forever has; every step is guarded, so a missing one
-- leaves the border static, not broken.
local PULSE_FROM    = 1.0
local PULSE_TO      = 0.45
local PULSE_SECONDS = 0.9

-- The icon on the vendor button while nothing of the chosen kind is for
-- sale. The same texture the toc names.
local QUIVER_ICON = "Interface\\Icons\\INV_Ammo_Arrow_02"

local BUTTON_SIZE = 34

local overlays          -- the highlight frames, by item slot
local overlaysBuilt = false
local button            -- the vendor button, after the first show of a page

--------------------------------------------------------------------------------
-- The highlight
--------------------------------------------------------------------------------

-- The frame that holds the highlight over one item button, made once. The
-- overlay lives on the item's icon button (VERIFY(phase0): Blizzard's naming
-- for the icon inside a vendor slot, read defensively), sized around it, and
-- carries one border texture with a pulse group beside it.
local function BuildOverlay(n, holder)
    local icon = holder.ItemButton or holder
    local overlay = CreateFrame("Frame", "FletcherOverlay" .. n, icon)
    overlay:SetFrameLevel(icon:GetFrameLevel() + 5)
    overlay:SetPoint("CENTER", icon, "CENTER", 0, 0)
    local side = (icon:GetWidth() > 0 and icon:GetWidth() or 36) * BORDER_SCALE
    overlay:SetSize(side, side)
    overlay.border = overlay:CreateTexture(nil, "OVERLAY")
    overlay.border:SetTexture(BORDER_TEXTURE)
    overlay.border:SetBlendMode("ADD")
    overlay.border:SetAllPoints(overlay)
    overlay.border:SetVertexColor(BEST_COLOR[1], BEST_COLOR[2], BEST_COLOR[3], 1)
    overlay:Hide()
    return overlay
end

local function EnsureOverlays()
    if overlaysBuilt or type(MERCHANT_ITEMS_PER_PAGE) ~= "number" then return end
    overlaysBuilt = true
    overlays = {}
    for n = 1, MERCHANT_ITEMS_PER_PAGE do
        local holder = _G["MerchantItem" .. n]
        if holder then
            overlays[n] = BuildOverlay(n, holder)
        end
    end
end

-- Whether the highlight is wanted at all: no closed window, no buyback tab,
-- no setting off, no best.
local function HighlightsWanted()
    if not (API.VendorOpen() and overlaysBuilt) then return false end
    if type(MerchantFrame) ~= "table" then return false end
    if MerchantFrame.selectedTab ~= 1 and MerchantFrame.selectedTab ~= nil then
        return false -- the buyback tab: the vendor does not sell there
    end
    return API.GetDB().highlight
end

-- Draws the highlight: gold on the best item's icon, dim green on the other
-- usable ammo when that setting is on, nothing anywhere else. Runs after
-- Blizzard drew the page, and on a setting change while the window is open.
local function RefreshHighlight()
    EnsureOverlays()
    if not overlaysBuilt then return end

    local page = 1
    if type(MerchantFrame) == "table" and MerchantFrame.page then
        page = MerchantFrame.page
    end
    local best = API.Best()
    local wanted = HighlightsWanted()
    local otherWanted = wanted and API.GetDB().highlightOther or false
    local itemsPerPage = MERCHANT_ITEMS_PER_PAGE

    for n = 1, itemsPerPage do
        local overlay = overlays[n]
        if not overlay then break end
        local index = (page - 1) * itemsPerPage + n

        local mode -- "best", "other", or nothing
        if wanted and best.found and index == best.index then
            mode = "best"
        elseif otherWanted and best.found then
            for i = 1, best.others.n do
                if best.others[i].index == index then
                    mode = "other"
                    -- The first one is enough; there is one slot per index.
                    break
                end
            end
        end

        if mode == nil then
            overlay:Hide()
        else
            local color = mode == "best" and BEST_COLOR or OTHER_COLOR
            overlay.border:SetVertexColor(color[1], color[2], color[3],
                mode == "best" and 1 or OTHER_ALPHA)
            overlay:Show()

            if mode == "best" and API.GetDB().pulse then
                if not overlay.pulse and overlay.border.CreateAnimationGroup then
                    local group = overlay.border:CreateAnimationGroup()
                    group:SetLooping("BOUNCE")
                    local alpha = group:CreateAlpha()
                    if alpha.SetFromAlpha then
                        alpha:SetFromAlpha(PULSE_FROM)
                        alpha:SetToAlpha(PULSE_TO)
                        alpha:SetDuration(PULSE_SECONDS)
                    end
                    overlay.pulse = group
                end
                if overlay.pulse and not overlay.pulse:IsPlaying() then
                    overlay.pulse:Play()
                end
            elseif overlay.pulse and overlay.pulse:IsPlaying() then
                overlay.pulse:Stop()
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The vendor button
--------------------------------------------------------------------------------

-- What the tooltip says, freshly read, in the game's own tooltip colours.
local function ShowTooltip(tooltipOwner)
    local quiver, best = API.Quiver(), API.Best()

    -- One line at a time, in the colour its kind names.
    local function AddLine(text, kind)
        local color = kind == "hint" and HINT_COLOR or LABEL_COLOR
        GameTooltip:AddLine(text, color[1], color[2], color[3])
    end

    GameTooltip:SetOwner(tooltipOwner, "ANCHOR_RIGHT")
    AddLine("Fletcher")

    if quiver.present then
        if quiver.capacity > 0 and best.found then
            AddLine(("Quiver: %s, %d / %d %s"):format(
                quiver.name or "your quiver", quiver.rounds, quiver.capacity,
                API.KindPlural(quiver.kind)))
        else
            AddLine(quiver.name or "Quiver equipped", "hint")
        end
    else
        AddLine("Equip a quiver or ammo pouch to refill", "hint")
    end

    if best.found then
        AddLine(("Best here: %s%s"):format(
            best.name or "?",
            best.reqLevel and (" (level " .. best.reqLevel .. ")") or ""))
        if quiver.need <= 0 then
            AddLine("Quiver is full", "hint")
        else
            local rounds, cost = API.Preview()
            if rounds and rounds > 0 then
                AddLine(("Refill: %d for %s"):format(rounds, API.MoneyText(cost)))
            else
                AddLine("Not enough money to refill", "hint")
            end
        end
        -- The best item may sit on another page of the vendor's goods.
        if type(MerchantFrame) == "table" and MerchantFrame.page
            and type(MERCHANT_ITEMS_PER_PAGE) == "number" then
            local bestPage = math.ceil(best.index / MERCHANT_ITEMS_PER_PAGE)
            if bestPage and bestPage ~= MerchantFrame.page then
                AddLine("Best ammo is on page " .. bestPage .. ".", "hint")
            end
        end
    elseif quiver.present then
        AddLine("This vendor sells nothing you can load.", "hint")
    end

    AddLine("Left click to refill", "hint")
    AddLine("Right click for options", "hint")
    AddLine("Hold Shift when talking to a vendor to skip auto buy", "hint")
    GameTooltip:Show()
end

local function EnsureButton()
    if button or type(MerchantFrame) ~= "table" then return end
    button = CreateFrame("Button", "FletcherVendorButton", MerchantFrame)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -8, -8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, click)
        if click == "LeftButton" then
            API.Refill("manual")
        elseif click == "RightButton" then
            if ns.ShowMenu then ns.ShowMenu(self) end
        end
    end)
    button:SetScript("OnEnter", function(self) ShowTooltip(self) end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    button:Hide()
end

-- Whether the button is on the vendor window at all: while the best ammo is
-- there (whatever the settings' highlight says), or, when no ammo bag is
-- equipped, anyway, with the tooltip explaining why no refill can run.
local function RefreshButton()
    EnsureButton()
    if not button then return end
    if not API.VendorOpen() or not API.GetDB().showButton then
        button:Hide()
        return
    end
    local show = API.Best().found or not API.Quiver().present
    button:SetNormalTexture(
        (API.Best().found and API.Best().texture) and API.Best().texture or QUIVER_ICON)
    button:SetShown(show)
end

--------------------------------------------------------------------------------
-- The right-click menu
--------------------------------------------------------------------------------

-- The menu's own shape, per the plan:
--   Auto buy, Highlight best ammo, Highlight other usable ammo, Pulse,
--   Report purchases in chat; Keep gold and Spending cap as radio submenus;
--   Refill now; Settings...
function ns.ShowMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        API.Print("the right-click menu is not available on this client; /ammo help lists the commands.")
        return
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        local GetDB = API.GetDB

        root:CreateTitle(API.Version and (addonName .. " " .. API.Version) or addonName)
        root:CreateDivider()

        root:CreateCheckbox("Auto buy",
            function() return GetDB().autoBuy end,
            function(on) API.SetAutoBuy(on) end)
        root:CreateCheckbox("Highlight best ammo",
            function() return GetDB().highlight end,
            function(on) API.SetHighlight(on) end)
        root:CreateCheckbox("Highlight other usable ammo",
            function() return GetDB().highlightOther end,
            function(on) API.SetHighlightOther(on) end)
        root:CreateCheckbox("Pulse",
            function() return GetDB().pulse end,
            function(on) API.SetPulse(on) end)
        root:CreateCheckbox("Report purchases in chat",
            function() return GetDB().report end,
            function(on) API.SetReport(on) end)

        local keepMenu = root:CreateButton("Keep gold")
        for _, choice in ipairs(API.KeepChoices()) do
            keepMenu:CreateRadio(choice.name,
                function() return GetDB().keepCopper == choice.copper end,
                function() API.SetKeepCopper(choice.copper) end)
        end

        local capMenu = root:CreateButton("Spending cap")
        for _, choice in ipairs(API.CapChoices()) do
            capMenu:CreateRadio(choice.name,
                function() return GetDB().capCopper == choice.copper end,
                function() API.SetCapCopper(choice.copper) end)
        end

        root:CreateDivider()
        root:CreateButton("Refill now", function() API.Refill("manual") end)
        root:CreateButton("Settings...", function()
            if not (ns.OpenSettings and ns.OpenSettings()) then
                API.Print("the settings page is not available on this client; /ammo help lists the commands.")
            end
        end)
    end)
end

--------------------------------------------------------------------------------
-- The pieces' turns
--------------------------------------------------------------------------------

-- From Fletcher.lua's setters and from its MERCHANT_SHOW and friends: build
-- the parts the first time a vendor is on screen, then draw what is there.
function ns.VendorRefresh()
    if not API.VendorOpen() then return end
    RefreshHighlight()
    RefreshButton()
end

function ns.VendorShow()
    if type(MerchantFrame) ~= "table" then return end
    RefreshHighlight()
    RefreshButton()
end

function ns.VendorHide()
    if overlays then
        for _, overlay in pairs(overlays) do
            overlay:Hide()
        end
    end
    if button then button:Hide() end
    GameTooltip:Hide()
end
