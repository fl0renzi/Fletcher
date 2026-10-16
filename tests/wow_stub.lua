-- Fletcher - tests/wow_stub.lua
-- A minimal headless mock of the WoW client API surface the addon touches. It
-- runs under fengari (Lua 5.3), not the game: the point is to exercise the
-- addon's own logic, not Blizzard's. Anything game-side a test needs to
-- control lives behind a __ helper below. A widget method the addon calls that
-- is not defined here fails the test, the way a misspelled one fails in game.

-- Lua 5.1 compatibility the addon relies on.
unpack = unpack or table.unpack

--------------------------------------------------------------------------------
-- Secret values
--------------------------------------------------------------------------------

local secretRegistry = setmetatable({}, { __mode = "k" })

-- A stand-in for a secret value: any comparison or arithmetic on it errors.
local secretMeta = {
    __eq = function() error("attempt to compare a secret value") end,
    __lt = function() error("attempt to compare a secret value") end,
    __le = function() error("attempt to compare a secret value") end,
    __add = function() error("attempt to perform arithmetic on a secret value") end,
    __sub = function() error("attempt to perform arithmetic on a secret value") end,
    __div = function() error("attempt to perform arithmetic on a secret value") end,
    __mul = function() error("attempt to perform arithmetic on a secret value") end,
    __concat = function() error("attempt to concatenate a secret value") end,
    __len = function() error("attempt to get length of a secret value") end,
}

function __secret()
    local secret = setmetatable({}, secretMeta)
    secretRegistry[secret] = true
    return secret
end

function issecretvalue(value)
    return secretRegistry[value] == true
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

__print = print
__output = {}

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    __output[#__output + 1] = table.concat(parts, " ")
end

function __printed(fragment)
    for _, line in ipairs(__output) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

function strtrim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--------------------------------------------------------------------------------
-- Game state the tests drive
--------------------------------------------------------------------------------

-- Forever reports 16001. A test changes it to exercise the gate.
__interface = 16001
function GetBuildInfo() return "1.60.1", "69893", "Sep 18 2026", __interface end

-- C_Timer on a clock the tests move with __advance. A ticker runs its
-- callback every interval until cancelled, or for its number of iterations.
__now = 0
local timers = {}

local function schedule(delay, callback, iterations)
    local timer = { due = __now + delay, interval = delay, callback = callback, left = iterations }
    function timer:Cancel() self.cancelled = true end
    function timer:IsCancelled() return self.cancelled == true end
    timers[#timers + 1] = timer
    return timer
end

C_Timer = {
    After = function(delay, callback) schedule(delay, callback, 1) end,
    NewTicker = function(interval, callback, iterations) return schedule(interval, callback, iterations) end,
}

function __advance(seconds)
    local target = __now + seconds
    while true do
        local nextTimer
        for _, timer in ipairs(timers) do
            if not timer.cancelled and timer.due <= target and (not nextTimer or timer.due < nextTimer.due) then
                nextTimer = timer
            end
        end
        if not nextTimer then break end
        __now = nextTimer.due
        nextTimer.callback(nextTimer)
        if nextTimer.left then
            nextTimer.left = nextTimer.left - 1
            if nextTimer.left <= 0 then nextTimer.cancelled = true end
        end
        nextTimer.due = nextTimer.due + nextTimer.interval
    end
    __now = target
end

-- The timers still waiting to run.
function __pending_timers()
    local count = 0
    for _, timer in ipairs(timers) do
        if not timer.cancelled then count = count + 1 end
    end
    return count
end

function __reset_timers()
    timers = {}
    __now = 0
end

-- The toc's Version line. The repository's toc holds the packager's
-- placeholder; a test names a release to see it shown.
__version = "@project-version@"
C_AddOns = {
    GetAddOnMetadata = function(name, field)
        if name == "Fletcher" and field == "Version" then return __version end
    end,
}

__class = "HUNTER"
function UnitClass(unit)
    if unit == "player" then return "Hunter", __class, 3 end
end

__level = 30
function UnitLevel(unit)
    if unit == "player" then return __level end
end

-- Copper on the player.
__money = 0
function GetMoney() return __money end

function IsShiftKeyDown() return __shift == true end

function InCombatLockdown() return __inCombat == true end

--------------------------------------------------------------------------------
-- Items, bags, the vendor
--------------------------------------------------------------------------------
-- __items      item id -> the item's own table: name, class, subclass,
--              iLevel, reqLevel, stack, icon, and true uncached while the
--              details have not arrived from the client's cache.
-- __bags       bag 1..4 -> { slots = n, family = bits or nil, and by slot
--              number { id, count, locked } }. family 0x1 holds arrows,
--              0x2 bullets.
-- __inv        bag 1..4 -> the item id of the bag in its inventory slot.
-- __ammo       the bowstring-side slot 0: { id, count } or nil when empty.
-- __ranged     the ranged weapon's slot 18: { id } or nil when empty.
-- __merchant   1..n vendor entries: { id, price (per round), usable (nil is
--              usable), stock (-1 on the stub means unlimited, nil means the
--              vendor does not count), quantity (rounds the line carries),
--              maxStack (rounds one purchase may ask for, falling back to
--              the item's stack) }.
-- __buy_log    one entry per BuyMerchantItem: { index, count, cost }.

-- A vendor window of six slots per page, the easy paging number. VERIFY
-- (phase0): the real MERCHANT_ITEMS_PER_PAGE the client has; the test names
-- pages through __goto_page and the stub draws __merchant onto the page.
MERCHANT_ITEMS_PER_PAGE = 6

-- The icon a fixture without one gets. The addon never reads what an icon
-- says, only that it is a string.
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function iconOf(item)
    return type(item) == "table" and item.icon or FALLBACK_ICON
end

function GetItemInfo(itemID)
    local item = __items[itemID]
    if not item or item.uncached then return nil end
    return item.name or ("item " .. tostring(itemID)), iconOf(item),
        item.quality or 1, item.iLevel or 0, item.reqLevel or 0,
        item.class, item.subclass, item.stack or 1
end

-- The instant form: id, type, subtype, equipLoc, icon, classID, subClassID,
-- as both the global and the C_Item copy answer. An id the client has never
-- heard of returns nothing, as the game does.
function GetItemInfoInstant(itemID)
    local item = __items[itemID]
    if not item then return nil end
    return itemID, "item", "Inventory", "", iconOf(item), item.class, item.subclass
end

C_Item = {
    GetItemInfo = GetItemInfo,
    GetItemInfoInstant = GetItemInfoInstant,
}

-- The equipped bags sit in inventory slots; the stub numbers slot 100 + bag
-- VERIFY(phase0): the stub's number is its own; the addon never reads it.
function GetInventoryItemID(unit, slot)
    if unit ~= "player" or type(slot) ~= "number" then return nil end
    if slot == 0 then return __ammo and __ammo.id or nil end
    if slot == 18 then return __ranged and __ranged.id or nil end
    for bag = 1, 4 do
        if 100 + bag == slot then return __inv[bag] or nil end
    end
    return nil
end

function GetInventoryItemCount(unit, slot)
    if unit ~= "player" or type(slot) ~= "number" then return 0 end
    if slot == 0 then return __ammo and __ammo.count or 0 end
    return 1
end

function ContainerIDToInventoryID(bag)
    if type(bag) ~= "number" then return nil end
    return 100 + bag
end

function GetContainerNumSlots(bag)
    local bagState = __bags[bag]
    return bagState and bagState.slots or 0
end

function GetContainerNumFreeSlots(bag)
    local bagState = __bags[bag]
    if not bagState then return 0, nil end
    local free = 0
    for slot = 1, bagState.slots do
        local held = bagState[slot]
        if not (held and held.id) then free = free + 1 end
    end
    return free, bagState.family
end

function GetContainerItemID(bag, slot)
    local held = __bags[bag] and __bags[bag][slot]
    return held and held.id or nil
end

-- The old list form: icon, count, locked, ...
function GetContainerItemInfo(bag, slot)
    local held = __bags[bag] and __bags[bag][slot]
    if not (held and held.id) then return nil end
    local item = __items[held.id]
    return iconOf(item), held.count, held.locked and true or false
end

-- The C form: an info table, as retail 12.0 answers, or nothing for an empty
-- slot.
C_Container = {
    GetContainerItemInfo = function(bag, slot)
        local held = __bags[bag] and __bags[bag][slot]
        if not (held and held.id) then return nil end
        local item = __items[held.id]
        return {
            itemID = held.id,
            iconFileID = iconOf(item),
            stackCount = held.count,
            isLocked = held.locked and true or false,
        }
    end,
    GetContainerItemID = GetContainerItemID,
    GetContainerNumSlots = GetContainerNumSlots,
    GetContainerNumFreeSlots = GetContainerNumFreeSlots,
    ContainerIDToInventoryID = ContainerIDToInventoryID,
}

function GetMerchantNumItems() return #__merchant end
function GetMerchantItemID(index)
    local entry = __merchant[index]
    return entry and entry.id or nil
end

-- The old list form: name, icon, price, quantity in the line, numAvailable,
-- isUsable.
function GetMerchantItemInfo(index)
    local entry = __merchant[index]
    if not entry then return nil end
    local item = __items[entry.id]
    return item.name, iconOf(item), entry.price,
        entry.quantity or 1,
        entry.stock == nil and -1 or entry.stock,
        entry.usable ~= false
end

-- The C form: an info table, as retail 12.0 answers, with the same numbers.
C_MerchantFrame = {
    GetItemInfo = function(index)
        local entry = __merchant[index]
        if not entry then return nil end
        local item = __items[entry.id]
        return {
            name = item.name,
            icon = iconOf(item),
            price = entry.price,
            quantity = entry.quantity or 1,
            numAvailable = entry.stock == nil and -1 or entry.stock,
            isUsable = entry.usable ~= false,
        }
    end,
    GetNumItems = GetMerchantNumItems,
}

-- The most rounds one purchase may ask.
function GetMerchantItemMaxStack(index)
    local entry = __merchant[index]
    if not entry then return nil end
    return entry.maxStack or (__items[entry.id] and __items[entry.id].stack) or 1
end

-- One purchase: the stub's model matches the plan's assumption until the
-- Phase 0 probe answers, so count is rounds, entry.price is per round, one
-- call delivers the rounds. The rounds land in the ammo bags whose family
-- takes the ammo's kind, topping stacks up first and then filling empty
-- slots, as a bag update would. It never fires the game's own events: the
-- test fires them, seeing each step of the queue.
__buy_log = {}

function BuyMerchantItem(index, count)
    local entry = __merchant[index]
    if not entry then
        error("BuyMerchantItem: no merchant item " .. tostring(index))
    end
    local item = __items[entry.id]
    local rounds = entry.quantity or 1
    local cost = math.floor((entry.price / rounds) * count + 0.5)
    __money = __money - cost
    __buy_log[#__buy_log + 1] = { index = index, count = count, cost = cost }

    local stock = entry.stock
    if type(stock) == "number" and stock >= 0 then
        entry.stock = math.max(0, stock - count)
    end

    local family
    if item.class == 6 then
        if item.subclass == 2 then family = 0x1
        elseif item.subclass == 3 then family = 0x2
        end
    end
    local left = count
    local stack = item.stack or 1
    for bag = 1, 4 do
        local bagState = __bags[bag]
        local takes
        if bagState and family then
            takes = math.floor(bagState.family / family) % 2 == 1
        end
        if takes and left > 0 then
            for slot = 1, bagState.slots do
                local held = bagState[slot]
                if held and held.id == entry.id and not held.locked and held.count < stack then
                    local add = math.min(stack - held.count, left)
                    held.count = held.count + add
                    left = left - add
                end
            end
            for slot = 1, bagState.slots do
                if left <= 0 then break end
                local held = bagState[slot]
                if not (held and held.id) and not (held and held.locked) then
                    local add = math.min(stack, left)
                    bagState[slot] = { id = entry.id, count = add }
                    left = left - add
                end
            end
        end
    end
    return true
end

function MerchantFrame_UpdateMerchantInfo()
    local page = __merchant_page
    MerchantFrame.page = page
    for n = 1, MERCHANT_ITEMS_PER_PAGE do
        local index = (page - 1) * MERCHANT_ITEMS_PER_PAGE + n
        local holder = _G["MerchantItem" .. n]
        if holder then
            if __merchant[index] then holder:Show() else holder:Hide() end
        end
    end
end

function MerchantFrame_Update() MerchantFrame_UpdateMerchantInfo() end

-- Opens a vendor the way the game does: MERCHANT_SHOW, then Blizzard draws
-- the first page.
function __open_vendor(merchant)
    __merchant = merchant or {}
    __merchant_page = 1
    __fire("MERCHANT_SHOW")
    MerchantFrame_Update()
end

function __close_vendor()
    __fire("MERCHANT_CLOSED")
    __merchant = {}
end

-- Flips a vendor page, as the game's arrows would: Blizzard redraws, then
-- the stock-changed event reaches anyone listening.
function __goto_page(page)
    __merchant_page = page
    MerchantFrame_Update()
    __fire("MERCHANT_UPDATE")
end

-- The highlight's overlays, by item slot, where the test expects them.
function __overlays()
    local list = {}
    for n = 1, MERCHANT_ITEMS_PER_PAGE do
        list[n] = _G["FletcherOverlay" .. n]
    end
    return list
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

-- Texture files the client cannot load: setting one returns false.
__badTextures = {}

local methods = {}
local frames = {}

function methods:SetPoint(...) self.__points[#self.__points + 1] = { ... } end
function methods:ClearAllPoints() self.__points = {} end
function methods:SetAllPoints() end
function methods:SetSize(width, height) self.__width, self.__height = width, height end
function methods:SetWidth(width) self.__width = width end
function methods:SetHeight(height) self.__height = height end
function methods:GetWidth() return self.__width or 0 end
function methods:GetHeight() return self.__height or 0 end
function methods:Show()
    local was = self.__shown
    self.__shown = true
    if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end
end
-- Visibility through the parents, as the game reports it.
function methods:IsVisible()
    local widget = self
    while widget do
        if not widget.__shown then return false end
        widget = widget.__parent
    end
    return true
end
function methods:Hide()
    local was = self.__shown
    self.__shown = false
    if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end
end
function methods:SetShown(shown) if shown then self:Show() else self:Hide() end end
function methods:IsShown() return self.__shown end
function methods:SetScript(name, handler) self.__scripts[name] = handler end
function methods:GetScript(name) return self.__scripts[name] end
function methods:SetFrameStrata(strata) self.__strata = strata end
function methods:SetFrameLevel(level) self.__frameLevel = level end
function methods:GetFrameLevel() return self.__frameLevel or 1 end

function methods:CreateTexture() return __new_widget("Texture", self) end
function methods:CreateFontString(_, _, template)
    local fontString = __new_widget("FontString", self)
    if template then fontString:SetFontObject(_G[template]) end
    return fontString
end
function methods:RegisterEvent(event)
    if not __knownEvents[event] then
        error("Attempt to register unknown event \"" .. tostring(event) .. "\"")
    end
    self.__events[event] = true
end
function methods:UnregisterEvent(event) self.__events[event] = nil end
function methods:UnregisterAllEvents() self.__events = {} end

function methods:SetStatusBarTexture(texture)
    if __badTextures[texture:lower()] then return false end
    self.__barTexture = texture
    return true
end
function methods:SetStatusBarColor(...) self.__barColor = { ... } end
function methods:SetMinMaxValues(minimum, maximum) self.__min, self.__max = minimum, maximum end
function methods:GetMinMaxValues() return self.__min, self.__max end
function methods:SetValue(value) self.__value = value end
function methods:GetValue() return self.__value end

-- Button
function methods:SetNormalTexture(texture) self.__normal = texture end
function methods:SetHighlightTexture(texture) self.__highlight = texture end
function methods:SetPushedTexture(texture) self.__pushed = texture end
function methods:RegisterForClicks(...) self.__clicks = { ... } end

-- Texture
function methods:SetTexture(texture)
    if __badTextures[texture:lower()] then return false end
    self.__texture = texture
    return true
end
function methods:SetColorTexture(...) self.__color = { ... } end
function methods:SetAtlas(atlas) self.__atlas = atlas; return true end
function methods:SetBlendMode(mode) self.__blend = mode end
function methods:SetVertexColor(...) self.__vertexColor = { ... } end

-- Texture animations, as far as the pulse uses them: an alpha bounce on the
-- border, looping BOUNCE.
function methods:CreateAnimationGroup()
    local group = __new_widget("AnimationGroup", self)
    function group:SetLooping(loop) self.__looping = loop end
    function group:Play() self.__playing = true end
    function group:Stop() self.__playing = false end
    function group:IsPlaying() return self.__playing == true end
    function group:CreateAlpha()
        local alpha = __new_widget("Alpha", group)
        function alpha:SetFromAlpha(from) self.__from = from end
        function alpha:SetToAlpha(to) self.__to = to end
        function alpha:SetDuration(seconds) self.__duration = seconds end
        return alpha
    end
    return group
end

-- CheckButton
function methods:SetChecked(checked) self.__checked = checked and true or false end
function methods:GetChecked() return self.__checked or false end

-- FontString
function methods:SetFontObject(object) self.__fontObject = object end
function methods:SetText(text) self.__text = text end
function methods:GetText() return self.__text end
function methods:SetTextColor(r, g, b, a) self.__textColor = { r, g, b, a } end
function methods:SetJustifyH(justify) self.__justify = justify end
function methods:SetWordWrap(wrap) self.__wrap = wrap end

-- Runs after the handler already set, the way the client's does.
function methods:HookScript(name, hook)
    local original = self.__scripts[name]
    self.__scripts[name] = function(...)
        if original then original(...) end
        hook(...)
    end
end

-- Edit boxes. Focus is tracked, and gaining or losing it fires its script at
-- once, as in the client.
function methods:SetAutoFocus(auto) self.__autoFocus = auto end
function methods:SetNumeric(numeric) self.__numeric = numeric end
function methods:SetMaxLetters(count) self.__maxLetters = count end
function methods:HasFocus() return self.__focus == true end
function methods:SetFocus()
    if self.__focus then return end
    self.__focus = true
    if self.__scripts.OnEditFocusGained then self.__scripts.OnEditFocusGained(self) end
end
function methods:ClearFocus()
    if not self.__focus then return end
    self.__focus = false
    if self.__scripts.OnEditFocusLost then self.__scripts.OnEditFocusLost(self) end
end

function methods:IsMouseOver() return self.__mouseOver == true end

-- A click on a check button toggles first, then fires, as the client's does.
function methods:Click()
    if self.__kind == "CheckButton" then self:SetChecked(not self:GetChecked()) end
    local handler = self.__scripts.OnClick
    if handler then handler(self) end
end

local widgetMeta = { __index = methods }

function __new_widget(kind, parent)
    local widget = setmetatable({
        __kind = kind,
        __parent = parent,
        __points = {},
        __scripts = {},
        __events = {},
        __shown = true,
    }, widgetMeta)
    frames[#frames + 1] = widget
    return widget
end

--------------------------------------------------------------------------------
-- Menus
--------------------------------------------------------------------------------
-- The client's menu descriptions for the right-click menu. A generator runs
-- against a tree the tests can read and click through.

local description = {}
local descriptionMeta = { __index = description }

local function node(kind, text, a, b)
    return setmetatable({ kind = kind, text = text, a = a, b = b, children = {} }, descriptionMeta)
end

local function add(parent, child)
    parent.children[#parent.children + 1] = child
    return child
end

function description:CreateTitle(text) return add(self, node("title", text)) end
function description:CreateDivider() return add(self, node("divider")) end
function description:CreateButton(text, callback) return add(self, node("button", text, callback)) end
function description:CreateCheckbox(text, isSelected, setSelected)
    return add(self, node("checkbox", text, isSelected, setSelected))
end
function description:CreateRadio(text, isSelected, setSelected)
    return add(self, node("radio", text, isSelected, setSelected))
end
function description:SetScrollMode(extent) self.scroll = extent end

function __new_menu_root() return node("root") end

--------------------------------------------------------------------------------
-- Templates
--------------------------------------------------------------------------------
-- The client templates the settings page builds on, as far as the page uses
-- them. A template name the stub does not know fails the test.

MinimalSliderWithSteppersMixin = {
    Event = { OnValueChanged = "OnValueChanged" },
    Label = { Left = 1, Right = 2, Top = 3 },
}
function CreateMinimalSliderFormatter(_, formatter) return formatter end

local templates = {}

templates.UICheckButtonTemplate = function(frame) frame.__kind = "CheckButton" end
templates.UIPanelButtonTemplate = function() end

-- The client's scroll frame, with the scroll bar its OnLoad makes.
templates.ScrollFrameTemplate = function(frame)
    frame.ScrollBar = __new_widget("EventFrame", frame)
    function frame.ScrollBar:SetHideIfUnscrollable(hide) self.__hideIfUnscrollable = hide end
    function frame:SetScrollChild(child) self.__scrollChild = child end
end

-- The client's input box: Escape clears the focus.
templates.InputBoxTemplate = function(frame)
    frame:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
end

-- The stepper slider: OnValueChanged fires when the value changes, whoever
-- changed it, the way the client's does.
templates.MinimalSliderWithSteppersTemplate = function(frame)
    frame.__callbacks = {}
    function frame:Init(value, minimum, maximum, steps, formatters)
        self.__sliderValue, self.__minValue, self.__maxValue = value, minimum, maximum
        self.__steps, self.__formatters = steps, formatters
    end
    function frame:RegisterCallback(event, func) self.__callbacks[event] = func end
    function frame:SetValue(value)
        value = math.max(self.__minValue, math.min(self.__maxValue, value))
        if value == self.__sliderValue then return end
        self.__sliderValue = value
        local callback = self.__callbacks[MinimalSliderWithSteppersMixin.Event.OnValueChanged]
        if callback then callback(nil, value) end
    end
    function frame:GetValue() return self.__sliderValue end
end

function CreateFrame(kind, name, parent, template)
    local frame = __new_widget(kind, parent)
    frame.__name = name
    frame.__template = template
    if template then
        local apply = templates[template]
        if not apply then error("CreateFrame: unknown template " .. tostring(template)) end
        apply(frame)
    end
    if name then _G[name] = frame end
    return frame
end

-- The widget a settings row holds: the row is found by its label, then the
-- child of that row made from the template (or of the kind, for no template).
function __control(label, template, kind)
    local row
    for _, widget in ipairs(frames) do
        if widget.__kind == "FontString" and widget.__text == label and widget.__parent ~= nil then
            row = widget.__parent
        end
    end
    if not row then error("no settings row labelled " .. tostring(label)) end
    for _, widget in ipairs(frames) do
        if widget.__parent == row and widget.__template == template and (not kind or widget.__kind == kind) then
            return widget
        end
    end
    error("no " .. tostring(template or kind) .. " in the row labelled " .. tostring(label))
end

-- The button on the settings page with this text.
function __page_button(text)
    for _, widget in ipairs(frames) do
        if widget.__template == "UIPanelButtonTemplate" and widget.__text == text then return widget end
    end
    error("no button " .. tostring(text))
end

-- Every text the settings page shows, for the read-only status rows.
function __page_texts()
    local texts = {}
    for _, widget in ipairs(frames) do
        if widget.__kind == "FontString" and widget.__text then
            texts[#texts + 1] = widget.__text
        end
    end
    return texts
end

-- Calls a widget's script handler the way the game would.
function __script(widget, name, ...)
    local handler = widget.__scripts[name]
    if handler then return handler(widget, ...) end
end

function __fire(event, ...)
    for _, frame in ipairs(frames) do
        if frame.__events[event] then
            local handler = frame.__scripts.OnEvent
            if handler then handler(frame, event, ...) end
        end
    end
end

function __registered(event)
    for _, frame in ipairs(frames) do
        if frame.__events[event] then return true end
    end
    return false
end

function __frame_count() return #frames end

--------------------------------------------------------------------------------
-- Client globals
--------------------------------------------------------------------------------

local function resetGlobals()
    frames = {}
    UIParent = __new_widget("Frame")
    UIParent:SetSize(1920, 1080)

    GameFontNormal = { __font = { "Fonts\\FRIZQT__.TTF", 12, "" } }
    GameFontHighlightLarge = { __font = { "Fonts\\FRIZQT__.TTF", 16, "" } }
    GameFontHighlightHuge = { __font = { "Fonts\\FRIZQT__.TTF", 20, "" } }
    GameFontHighlightSmall = { __font = { "Fonts\\FRIZQT__.TTF", 10, "" } }

    -- The client's settings window: a canvas category per addon, opened by
    -- its ID, which shows the canvas frame.
    __settingsCategory, __settingsAddOn, __settingsOpened = nil, nil, nil
    Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            __settingsCategory = { frame = frame, name = name, ID = name }
            function __settingsCategory:GetID() return self.ID end
            return __settingsCategory
        end,
        RegisterAddOnCategory = function(category) __settingsAddOn = category end,
        OpenToCategory = function(id)
            __settingsOpened = id
            if __settingsCategory and __settingsCategory.ID == id then __settingsCategory.frame:Show() end
        end,
    }

    __settingsOpened = nil
    __inCombat = false
    __shift = false

    GameTooltip = __new_widget("GameTooltip")
    GameTooltip.__shown = false
    GameTooltip.__lines = {}
    function GameTooltip:SetOwner(owner) self.__owner = owner; self.__lines = {} end
    function GameTooltip:GetOwner() return self.__owner end
    function GameTooltip:AddLine(text) self.__lines[#self.__lines + 1] = text end
    function GameTooltip:AddDoubleLine(left, right) self.__lines[#self.__lines + 1] = left .. " | " .. right end
    function GameTooltip:Show() self.__shown = true end
    function GameTooltip:Hide() self.__shown = false; self.__owner = nil end

    -- The client's context menu.
    __menu = nil
    MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local root = __new_menu_root()
            generator(owner, root)
            __menu = root
        end,
    }

    -- The vendor window: six item holders per page, each with its own item
    -- button the highlight lives on, the tab set to the goods, page 1.
    MerchantFrame = __new_widget("Frame")
    MerchantFrame.page = 1
    MerchantFrame.selectedTab = 1
    for n = 1, MERCHANT_ITEMS_PER_PAGE do
        local holder = __new_widget("Frame")
        _G["MerchantItem" .. n] = holder
        holder.ItemButton = __new_widget("Frame", holder)
        holder.ItemButton:SetSize(37, 37)
        holder:Hide()
    end

    LibStub = nil
    SlashCmdList = {}
    SLASH_FLETCHER1, SLASH_FLETCHER2 = nil, nil
    FletcherDB = nil
    FletcherVendorButton = nil
    __merchant = {}
    __merchant_page = 1
    __buy_log = {}
end

-- Finds a menu entry by its path of texts, for example ("Keep gold", "5g").
function __menu_item(...)
    local current = __menu
    for i = 1, select("#", ...) do
        local text = select(i, ...)
        local found
        for _, child in ipairs(current and current.children or {}) do
            if child.text == text then found = child end
        end
        current = found
    end
    return current
end

-- Clicks a menu entry the way the client would.
function __menu_click(item)
    if item.kind == "button" then
        if item.a then item.a() end
    else
        item.b()
    end
end

function __menu_selected(item)
    return item.a() and true or false
end

--------------------------------------------------------------------------------
-- Loading the addon
--------------------------------------------------------------------------------

-- The events this client knows. A test removes one to check that a missing
-- event does not stop the addon.
local DEFAULT_EVENTS = {
    "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE",
    "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "UI_ERROR_MESSAGE",
    "GET_ITEM_INFO_RECEIVED",
}

-- Starts a fresh session: a clean world, the given saved settings, every file
-- the .toc lists loaded in order as the game loads them, and (unless told not
-- to) PLAYER_LOGIN fired. Returns the addon's namespace.
function __boot(options)
    options = options or {}
    resetGlobals()

    __output = {}
    __interface = options.interface or 16001
    __version = options.version or "@project-version@"
    __class = options.class or "HUNTER"
    __level = options.level or 30
    __money = options.money or 0
    __shift = options.shift and true or false

    __items = {}
    for id, item in pairs(options.items or {}) do __items[id] = item end
    __bags = {}
    for bag, bagState in pairs(options.bags or {}) do __bags[bag] = bagState end
    __inv = {}
    for bag, id in pairs(options.inv or {}) do __inv[bag] = id end
    __ammo = options.ammo
    __ranged = options.ranged
    __badTextures = {}

    __reset_timers()
    __knownEvents = {}
    for _, event in ipairs(DEFAULT_EVENTS) do __knownEvents[event] = true end
    for _, event in ipairs(options.missingEvents or {}) do __knownEvents[event] = nil end
    FletcherDB = options.db
    if options.noSettings then Settings = nil end

    local ns = {}
    for _, entry in ipairs(__toc_files) do
        local chunk, err = load(entry.source, "=" .. entry.file)
        if not chunk then error(err) end
        chunk("Fletcher", ns)
    end

    if options.login ~= false then __fire("PLAYER_LOGIN") end
    return ns
end
