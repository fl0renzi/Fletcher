-- Fletcher - Fletcher_Vendor.lua
-- Fletcher's parts of the vendor window: a gold mark on the best ammo's
-- icon, a dimmer green one on the other ammo the hunter can use (when asked
-- for), and a small button that refills on a left click and opens the
-- right-click menu on a right click. Its tooltip says what the quiver holds,
-- what the vendor has, and what a refill would buy.
--
-- Built on a hunter's first MERCHANT_SHOW, never at load. Nothing here
-- touches a Blizzard frame beyond reading it: the marks follow the vendor
-- window through hooksecurefunc on the functions that draw its page, and
-- every frame here is Fletcher's own, so nothing taints. Fletcher.lua reads
-- the game into ns.scan; this file only shows it.

local addonName, ns = ...
if not ns.Allowed then return end

local API = ns.API
local scan = ns.scan

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- The marks are Forever's own art. The best ammo gets the action bar's proc
-- glow, the gold border that runs around an ability when it procs, the way
-- Forever's trade window puts it on an item: a burst when it appears, then
-- the loop (ActionButtonSpellAlerts.xml and TradeFrame.xml on the forever
-- branch). Each is a flipbook of 6 rows of 5 frames.
local PROC_START_ATLAS = "UI-HUD-ActionBar-Proc-Start-Flipbook"
local PROC_LOOP_ATLAS = "UI-HUD-ActionBar-Proc-Loop-Flipbook"
local FLIPBOOK_ROWS, FLIPBOOK_COLUMNS, FLIPBOOK_FRAMES = 6, 5, 30
local PROC_START_SECONDS, PROC_LOOP_SECONDS = 0.7, 1.0
-- The loop is 1.4 times the button it rings; the burst is 150 on the
-- action bar's 45 wide button.
local PROC_LOOP_SCALE = 1.4
local PROC_START_SCALE = 150 / 45

-- Under the proc glow, and alone with Pulse off, the soft glow the bags put
-- on a new item (ContainerFrame.xml), at its own size, which is made for an
-- item button: white tinted gold for the best ammo, the bags' own green for
-- the other usable ammo.
local BEST_GLOW_ATLAS = "bags-glow-white"
local OTHER_GLOW_ATLAS = "bags-glow-green"
local BEST_GLOW_COLOR = { 1.0, 0.82, 0.0 }
local OTHER_GLOW_ALPHA = 0.75

-- The vendor window's item button, when the client does not report its size
-- (MerchantItemTemplate in the Mainline MerchantFrame.xml).
local ITEM_BUTTON_SIZE = 37

-- The vendor button sits in the strip above the item grid, left of the
-- vendor window's filter dropdown, which is 152 wide at 11 in from the right
-- and 30 down (Mainline MerchantFrame.xml).
local BUTTON_SIZE = 26
local BUTTON_X, BUTTON_Y = -171, -30
local BUTTON_HIGHLIGHT = "Interface\\Buttons\\ButtonHilight-Square"

-- MERCHANT_ITEMS_PER_PAGE, when the client does not define it.
local ITEMS_PER_PAGE = 10

local LABEL_COLOR = API.LABEL_COLOR
local HINT_COLOR = API.HINT_COLOR

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local built = false
local button       -- the vendor button
local overlays = {} -- the mark on each item button, by its place on the page
local perPage = ITEMS_PER_PAGE

local ShowMenu -- defined with the menu, below

local function OnVendorTab()
    return MerchantFrame.selectedTab == 1
end

-- The page of the vendor's list the best ammo is on.
local function BestPage()
    local best = scan.best
    return best and math.ceil(best.index / perPage) or nil
end

--------------------------------------------------------------------------------
-- The marks
--------------------------------------------------------------------------------

-- A flipbook texture, centred on the item button, at a scale of its size. It
-- stays at alpha 0 until its animation runs: a flipbook shown still is its
-- whole sheet of frames.
local function FlipbookTexture(overlay, itemButton, atlas, size, subLevel)
    local texture = overlay:CreateTexture(nil, "OVERLAY", nil, subLevel)
    texture:SetAtlas(atlas)
    texture:SetSize(size, size)
    texture:SetPoint("CENTER", itemButton, "CENTER", 0, 0)
    texture:SetAlpha(0)
    return texture
end

-- Plays a flipbook texture through once, or for as long as it loops, the
-- way Blizzard's template does: an instant alpha shows it, then the
-- flipbook runs, and when the group stops the texture is at alpha 0 again.
-- Run by the client: no OnUpdate.
local function FlipbookAnimation(overlay, texture, seconds, looping)
    local group = overlay:CreateAnimationGroup()
    if looping then group:SetLooping("REPEAT") end

    local show = group:CreateAnimation("Alpha")
    show:SetTarget(texture)
    show:SetFromAlpha(1)
    show:SetToAlpha(1)
    show:SetDuration(0.001)
    show:SetOrder(1)

    local flip = group:CreateAnimation("FlipBook")
    flip:SetTarget(texture)
    flip:SetFlipBookRows(FLIPBOOK_ROWS)
    flip:SetFlipBookColumns(FLIPBOOK_COLUMNS)
    flip:SetFlipBookFrames(FLIPBOOK_FRAMES)
    flip:SetFlipBookFrameWidth(0)
    flip:SetFlipBookFrameHeight(0)
    flip:SetDuration(seconds)
    flip:SetOrder(2)
    return group
end

-- A mark for one item button, made the first time that button needs one:
-- Fletcher's own frame, a child of the button so it pages and hides with it,
-- holding the soft glow and the proc glow's burst and loop. It takes no
-- mouse, so the button under it clicks as usual.
local function MakeOverlay(place, itemButton)
    local overlay = CreateFrame("Frame", nil, itemButton)
    overlay:SetAllPoints(itemButton)
    overlay:SetFrameLevel(itemButton:GetFrameLevel() + 5)

    local size = itemButton:GetWidth()
    if not size or size <= 0 then size = ITEM_BUTTON_SIZE end

    local glow = overlay:CreateTexture(nil, "OVERLAY", nil, 0)
    glow:SetPoint("CENTER", itemButton, "CENTER", 0, 0)
    glow:SetBlendMode("ADD")
    overlay.glow = glow

    overlay.loop = FlipbookTexture(overlay, itemButton, PROC_LOOP_ATLAS, size * PROC_LOOP_SCALE, 1)
    overlay.burst = FlipbookTexture(overlay, itemButton, PROC_START_ATLAS, size * PROC_START_SCALE, 2)
    overlay.loopAnim = FlipbookAnimation(overlay, overlay.loop, PROC_LOOP_SECONDS, true)
    overlay.burstAnim = FlipbookAnimation(overlay, overlay.burst, PROC_START_SECONDS, false)
    -- The burst hands over to the loop, as on the action bars.
    overlay.burstAnim:SetScript("OnFinished", function() overlay.loopAnim:Play() end)

    overlays[place] = overlay
    return overlay
end

local function StopProc(overlay)
    overlay.burstAnim:Stop()
    overlay.loopAnim:Stop()
end

local function HideOverlay(overlay)
    StopProc(overlay)
    overlay.mode = nil
    overlay:Hide()
end

-- Shows a mark as the best ammo's or another usable ammo's. The best one's
-- proc glow runs while Pulse is on: a burst when the mark first shows, then
-- the loop, which a redraw of the page does not restart.
local function ShowOverlay(overlay, mode, pulse)
    local wasBest = overlay:IsShown() and overlay.mode == "best"
    overlay.mode = mode

    if mode == "best" then
        overlay.glow:SetAtlas(BEST_GLOW_ATLAS, true)
        overlay.glow:SetVertexColor(BEST_GLOW_COLOR[1], BEST_GLOW_COLOR[2], BEST_GLOW_COLOR[3])
        overlay.glow:SetAlpha(1)
    else
        overlay.glow:SetAtlas(OTHER_GLOW_ATLAS, true)
        overlay.glow:SetVertexColor(1, 1, 1)
        overlay.glow:SetAlpha(OTHER_GLOW_ALPHA)
    end
    overlay:Show()

    if mode ~= "best" or not pulse then
        StopProc(overlay)
    elseif not (overlay.burstAnim:IsPlaying() or overlay.loopAnim:IsPlaying()) then
        if wasBest then overlay.loopAnim:Play() else overlay.burstAnim:Play() end
    end
end

-- Marks the item buttons on the page as it is drawn. Each button's id is its
-- index in the vendor's list (the vendor window sets it), so no page
-- arithmetic is needed. Hidden buttons hold no item. On the buyback tab
-- there is nothing to mark.
local function UpdateOverlays()
    if not built then return end
    local db = API.GetDB()
    local best = scan.best
    local vendorTab = OnVendorTab()

    for place = 1, perPage do
        local itemButton = _G["MerchantItem" .. place .. "ItemButton"]
        local mode
        if itemButton and vendorTab and itemButton:IsShown() then
            local index = itemButton:GetID()
            if db.highlight and best and index == best.index then
                mode = "best"
            elseif db.highlightOther and scan.others[index] then
                mode = "other"
            end
        end

        local overlay = overlays[place]
        if mode then
            ShowOverlay(overlay or MakeOverlay(place, itemButton), mode, db.pulse)
        elseif overlay then
            HideOverlay(overlay)
        end
    end
end

--------------------------------------------------------------------------------
-- The button and its tooltip
--------------------------------------------------------------------------------

local function AddValueLine(label, value)
    GameTooltip:AddDoubleLine(label, value,
        LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3], 1, 1, 1)
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(addonName, 1, 1, 1)

    local quiver = API.QuiverLine()
    if quiver then AddValueLine("Quiver", quiver) end
    local best = API.BestLine()
    if best then AddValueLine("Best here", best) end

    local refill = API.RefillLine()
    if API.IsBuying() then
        GameTooltip:AddLine("Buying...", 1, 1, 1)
    elseif refill then
        AddValueLine("Refill", refill)
        if scan.leftOut > 0 then
            GameTooltip:AddLine(API.LeftOutText(scan.leftOut, scan.limit), 1, 1, 1, true)
        end
    elseif scan.message then
        GameTooltip:AddLine(scan.message, 1, 1, 1, true)
    end

    local mismatch = API.MismatchLine()
    if mismatch then GameTooltip:AddLine(mismatch, LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3], true) end

    local page = BestPage()
    if page and OnVendorTab() and page ~= MerchantFrame.page then
        GameTooltip:AddLine(("Best ammo is on page %d."):format(page), LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3])
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left click to refill", HINT_COLOR[1], HINT_COLOR[2], HINT_COLOR[3])
    GameTooltip:AddLine("Right click for options", HINT_COLOR[1], HINT_COLOR[2], HINT_COLOR[3])
    GameTooltip:AddLine("Hold Shift when talking to a vendor to skip auto buy",
        HINT_COLOR[1], HINT_COLOR[2], HINT_COLOR[3], true)
    GameTooltip:Show()
end

-- An open tooltip follows what it shows: a purchase, a page turn, a setting.
local function RefreshTooltip()
    if button and GameTooltip:IsShown() and GameTooltip:GetOwner() == button then
        ShowTooltip(button)
    end
end

-- The button shows while the vendor sells ammo the quiver takes. Without a
-- quiver it shows at any ammo vendor, to say why nothing is bought.
local function ButtonWanted()
    if not (API.GetDB().showButton and scan.open) then return false end
    if scan.best or (scan.loading and scan.sellsAmmo) then return true end
    return not scan.kind and scan.sellsAmmo
end

local function UpdateButton()
    if not ButtonWanted() then
        button:Hide()
        return
    end
    local best = scan.best
    button.icon:SetTexture(best and best.texture or scan.quiverIcon or API.DEFAULT_ICON)
    -- Grey while a click would buy nothing.
    button.icon:SetDesaturated(scan.status ~= "ready" and not API.IsBuying())
    button:Show()
end

local function BuildButton()
    button = CreateFrame("Button", "FletcherVendorButton", MerchantFrame)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", BUTTON_X, BUTTON_Y)
    button:SetFrameLevel(MerchantFrame:GetFrameLevel() + 10)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(button)
    button.icon = icon
    button:SetHighlightTexture(BUTTON_HIGHLIGHT, "ADD")

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            ShowMenu(self)
        else
            API.Refill()
        end
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:Hide()
end

-- After the vendor window draws a page, of the vendor's list or the
-- buyback: the marks follow, and the tooltip's page note with them.
local function OnPageDrawn()
    UpdateOverlays()
    RefreshTooltip()
end

-- Called by Fletcher.lua on a hunter's every MERCHANT_SHOW; builds once.
-- MerchantFrame_UpdateMerchantInfo draws the vendor's page and
-- MerchantFrame_UpdateBuybackInfo the buyback page. Paging, the mouse wheel,
-- the filter, the tabs and MERCHANT_UPDATE all go through
-- MerchantFrame_Update, which calls one of the two.
function ns.BuildVendorUI()
    if built or not MerchantFrame then return end
    built = true
    if type(MERCHANT_ITEMS_PER_PAGE) == "number" then perPage = MERCHANT_ITEMS_PER_PAGE end
    BuildButton()
    if type(MerchantFrame_UpdateMerchantInfo) == "function" then
        hooksecurefunc("MerchantFrame_UpdateMerchantInfo", OnPageDrawn)
    end
    if type(MerchantFrame_UpdateBuybackInfo) == "function" then
        hooksecurefunc("MerchantFrame_UpdateBuybackInfo", OnPageDrawn)
    end
end

-- Called by Fletcher.lua whenever ns.scan or a setting changed.
function ns.OnScanChanged()
    if not built then return end
    UpdateButton()
    UpdateOverlays()
    RefreshTooltip()
end

--------------------------------------------------------------------------------
-- Right-click menu
--------------------------------------------------------------------------------

local function MoneyName(copper)
    return copper == 0 and "None" or API.MoneyText(copper)
end

-- A submenu of ready-made amounts, checked against the saved one.
local function AddMoneyMenu(root, title, presets, key, apply)
    local submenu = root:CreateButton(title)
    local db = API.GetDB()
    for _, copper in ipairs(presets) do
        submenu:CreateRadio(MoneyName(copper),
            function() return db[key] == copper end,
            function() apply(copper) end)
    end
end

-- The client's own context menu, so it looks like every other menu in the
-- game. Every entry calls the setter the settings page and the slash
-- commands call.
function ShowMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        API.Print("the right-click menu is not available on this client; type /ammo help for the commands.")
        return
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        local db = API.GetDB()
        root:CreateTitle(API.Version and (addonName .. " " .. API.Version) or addonName)
        root:CreateCheckbox("Auto buy",
            function() return db.autoBuy end,
            function() API.SetAutoBuy(not db.autoBuy) end)
        root:CreateCheckbox("Highlight best ammo",
            function() return db.highlight end,
            function() API.SetHighlight(not db.highlight) end)
        root:CreateCheckbox("Highlight other usable ammo",
            function() return db.highlightOther end,
            function() API.SetHighlightOther(not db.highlightOther) end)
        root:CreateCheckbox("Pulse",
            function() return db.pulse end,
            function() API.SetPulse(not db.pulse) end)
        root:CreateCheckbox("Report purchases in chat",
            function() return db.report end,
            function() API.SetReport(not db.report) end)

        AddMoneyMenu(root, "Keep gold", API.KEEP_PRESETS, "keepCopper", API.SetKeepCopper)
        AddMoneyMenu(root, "Spending cap", API.CAP_PRESETS, "capCopper", API.SetCapCopper)

        local betterMenu = root:CreateButton("When my ammo is better")
        for _, choice in ipairs(API.BETTER_CHOICES) do
            local key = choice.key
            betterMenu:CreateRadio(choice.name,
                function() return db.betterAmmo == key end,
                function() API.SetBetterAmmo(key) end)
        end

        root:CreateDivider()
        root:CreateButton("Refill now", function() API.Refill() end)
        root:CreateButton("Settings...", function() API.OpenSettings() end)
    end)
end
