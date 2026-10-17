-- Fletcher - tests/wow_stub.lua
-- A minimal headless mock of the WoW client API surface the addon touches. It
-- runs under fengari (Lua 5.3), not the game: the point is to exercise the
-- addon's own logic, not Blizzard's. Anything game-side a test needs to
-- control lives behind a __ helper below. A widget method the addon calls that
-- is not defined here fails the test, the way a misspelled one fails in game.
-- The widget, menu, template and settings parts are BeastXP's.

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
    __mul = function() error("attempt to perform arithmetic on a secret value") end,
    __div = function() error("attempt to perform arithmetic on a secret value") end,
    __concat = function() error("attempt to concatenate a secret value") end,
    __len = function() error("attempt to get length of a secret value") end,
    __index = function() error("attempt to index a secret value") end,
}

function __secret()
    local secret = setmetatable({}, secretMeta)
    secretRegistry[secret] = true
    return secret
end

function issecretvalue(value)
    return secretRegistry[value] == true
end

-- A value the stub itself can do sums with: a secret counts as nothing.
local function plain(value, default)
    if issecretvalue(value) then return default end
    if value == nil then return default end
    return value
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local real_print = print
__print = real_print
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

-- How many printed lines contain the fragment.
function __printed_count(fragment)
    local count = 0
    for _, line in ipairs(__output) do
        if line:find(fragment, 1, true) then count = count + 1 end
    end
    return count
end

function strtrim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------

-- C_Timer on a clock the tests move with __advance.
__now = 0
local timers = {}

local function schedule(delay, callback, iterations)
    local timer = { due = __now + delay, interval = delay, callback = callback, left = iterations }
    function timer:Cancel() self.cancelled = true end
    function timer:IsCancelled() return self.cancelled == true end
    timers[#timers + 1] = timer
    return timer
end

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

function __pending_timers()
    local count = 0
    for _, timer in ipairs(timers) do
        if not timer.cancelled then count = count + 1 end
    end
    return count
end

local function resetTimers()
    timers = {}
    __now = 0
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------
-- The 1.x vendor ammo and a few items around it. A test changes __items[id]
-- for one session: cached = false leaves it out of the client's cache, and
-- any field may be a secret.

local ITEMS = {
    -- Arrows: class 6 (Projectile), subclass 2.
    [2512]  = { name = "Rough Arrow", class = 6, subclass = 2, itemLevel = 5, minLevel = 1, stack = 200 },
    [2515]  = { name = "Sharp Arrow", class = 6, subclass = 2, itemLevel = 15, minLevel = 10, stack = 200 },
    [3030]  = { name = "Razor Arrow", class = 6, subclass = 2, itemLevel = 30, minLevel = 25, stack = 200 },
    [11285] = { name = "Jagged Arrow", class = 6, subclass = 2, itemLevel = 45, minLevel = 40, stack = 200 },
    [18042] = { name = "Thorium Headed Arrow", class = 6, subclass = 2, itemLevel = 57, minLevel = 52, stack = 200 },
    -- Bullets: subclass 3.
    [2516]  = { name = "Light Shot", class = 6, subclass = 3, itemLevel = 5, minLevel = 1, stack = 200 },
    [2519]  = { name = "Heavy Shot", class = 6, subclass = 3, itemLevel = 15, minLevel = 10, stack = 200 },
    [3033]  = { name = "Solid Shot", class = 6, subclass = 3, itemLevel = 30, minLevel = 25, stack = 200 },
    [11284] = { name = "Accurate Slugs", class = 6, subclass = 3, itemLevel = 45, minLevel = 40, stack = 200 },
    [15997] = { name = "Thorium Shells", class = 6, subclass = 3, itemLevel = 57, minLevel = 52, stack = 200 },
    -- Bags: class 11 (Quiver), subclass 2 quiver or 3 ammo pouch; class 1 a bag.
    [2101]  = { name = "Light Quiver", class = 11, subclass = 2, family = 1, stack = 1 },
    [2102]  = { name = "Small Ammo Pouch", class = 11, subclass = 3, family = 2, stack = 1 },
    [4496]  = { name = "Small Brown Pouch", class = 1, subclass = 0, family = 0, stack = 1 },
    -- Ranged weapons: class 2, subclass 2 bow, 3 gun, 18 crossbow, 16 thrown.
    [2504]  = { name = "Worn Shortbow", class = 2, subclass = 2, stack = 1 },
    [2508]  = { name = "Old Blunderbuss", class = 2, subclass = 3, stack = 1 },
    [15808] = { name = "Fine Light Crossbow", class = 2, subclass = 18, stack = 1 },
    [2947]  = { name = "Small Throwing Knife", class = 2, subclass = 16, stack = 200 },
    -- What else a vendor sells.
    [159]   = { name = "Refreshing Spring Water", class = 0, subclass = 0, itemLevel = 5, minLevel = 1, stack = 20 },
}

local function copyItems()
    local items = {}
    for id, item in pairs(ITEMS) do
        local copy = { cached = true, icon = 130000 + id }
        for key, value in pairs(item) do copy[key] = value end
        items[id] = copy
    end
    return items
end

__items = copyItems()

local function item(id)
    if issecretvalue(id) then return nil end
    return __items[id]
end

C_Item = {
    GetItemInfo = function(id)
        local entry = item(id)
        if not entry or not entry.cached then return end
        return entry.name, "|Hitem:" .. tostring(id) .. "|h", 1, entry.itemLevel or 1, entry.minLevel or 0,
            "Type", "Subtype", entry.stack or 1, "", entry.icon, 0, entry.class, entry.subclass
    end,
    GetItemInfoInstant = function(id)
        local entry = item(id)
        if not entry then return end
        return id, "Type", "Subtype", "", entry.icon, entry.class, entry.subclass
    end,
    GetItemCount = function(id)
        if __itemCountSecret then return __secret() end
        return __count(id)
    end,
}

--------------------------------------------------------------------------------
-- The character
--------------------------------------------------------------------------------

__interface = 16001
function GetBuildInfo() return "1.60.1", "70450", "Oct 16 2026", __interface end

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
    return 0
end

__money = 0
function GetMoney() return __money end

-- The ranged weapon and the ammo in the ammo slot, by item id.
__ranged = nil
__ammo = nil

-- The bags, by bag number: 0 is the backpack, 1 to 4 the equipped bags. A bag
-- is { item = id, slots = n, contents = { [slot] = { id, count, locked } } }.
__bags = {}

local function bagFamily(bag)
    local entry = bag.item and item(bag.item)
    return entry and plain(entry.family, 0) or 0
end

-- What family of special bag an item goes into: 1 arrows, 2 bullets, 0 none.
local function itemFamily(id)
    local entry = item(id)
    if entry and entry.class == 6 then return entry.subclass == 2 and 1 or 2 end
    return 0
end

-- How many of an item the bags hold.
function __count(id)
    local total = 0
    for bag = 0, 4 do
        local container = __bags[bag]
        for _, slot in pairs(container and container.contents or {}) do
            if plain(slot.id) == id then total = total + plain(slot.count, 0) end
        end
    end
    return total
end

-- The rounds in one bag, by item id.
function __bag_count(bag, id)
    local total = 0
    for _, slot in pairs(__bags[bag] and __bags[bag].contents or {}) do
        if id == nil or plain(slot.id) == id then total = total + plain(slot.count, 0) end
    end
    return total
end

-- Puts rounds in the bags the way Forever was seen to on 2026-10-17: in
-- stacks, each going onto a stack of the same item only when it fits there
-- whole, and otherwise into an empty slot, special bags that take the item
-- ahead of plain ones. A bought 200 did not go onto a stack of 90 in the
-- quiver; it went to a normal bag. What does not fit at all is lost.
-- Returns what fitted.
function __add_item(id, count)
    local entry = item(id)
    local stack = entry and entry.stack or 1
    local family = itemFamily(id)
    local order = {}
    for bag = 1, 4 do
        if __bags[bag] and family ~= 0 and bagFamily(__bags[bag]) == family then order[#order + 1] = bag end
    end
    for bag = 0, 4 do
        if __bags[bag] and bagFamily(__bags[bag]) == 0 then order[#order + 1] = bag end
    end

    local function place(piece)
        for _, bag in ipairs(order) do
            for slot = 1, __bags[bag].slots do
                local content = __bags[bag].contents[slot]
                if content and content.id == id and content.count + piece <= stack then
                    content.count = content.count + piece
                    return true
                end
            end
        end
        for _, bag in ipairs(order) do
            for slot = 1, __bags[bag].slots do
                if not __bags[bag].contents[slot] then
                    __bags[bag].contents[slot] = { id = id, count = piece }
                    return true
                end
            end
        end
        return false
    end

    local left, fitted = count, 0
    while left > 0 do
        local piece = math.min(left, stack)
        if place(piece) then fitted = fitted + piece end
        left = left - piece
    end
    return fitted
end

NUM_BAG_SLOTS = 4

C_Container = {
    ContainerIDToInventoryID = function(bag)
        if bag >= 1 and bag <= 4 then return 19 + bag end
    end,
    GetContainerNumSlots = function(bag)
        local container = __bags[bag]
        return container and container.slots or 0
    end,
    GetContainerItemInfo = function(bag, slot)
        local container = __bags[bag]
        local content = container and container.contents[slot]
        if not content then return nil end
        local entry = item(content.id)
        return {
            itemID = content.id,
            stackCount = content.count,
            isLocked = content.locked or false,
            iconFileID = entry and entry.icon or 0,
            itemName = entry and entry.name or "",
            hyperlink = "",
        }
    end,
    GetContainerNumFreeSlots = function(bag)
        local container = __bags[bag]
        if not container then return 0, nil end
        local free = 0
        for slot = 1, container.slots do
            if not container.contents[slot] then free = free + 1 end
        end
        if container.secretFamily then return free, __secret() end
        return free, bagFamily(container)
    end,
}

function GetInventoryItemID(unit, slot)
    if unit ~= "player" then return nil end
    if slot == 0 then return __ammo end
    if slot == 18 then return __ranged end
    if slot >= 20 and slot <= 23 then
        local container = __bags[slot - 19]
        return container and container.item
    end
end

function GetInventoryItemCount(unit, slot)
    if unit == "player" and slot == 0 and __ammo then return __count(__ammo) end
    return 0
end

function UnitUsesAmmo(unit)
    local entry = unit == "player" and __ranged and item(__ranged)
    if not entry then return false end
    return entry.class == 2 and (entry.subclass == 2 or entry.subclass == 3 or entry.subclass == 18)
end

--------------------------------------------------------------------------------
-- The vendor
--------------------------------------------------------------------------------
-- __merchant is the vendor's list as the window shows it (after its filter):
-- { id, price, batch, stock, usable, purchasable, extended, maxStack }, the
-- batch defaulting to the item's stack, the stock to -1 (unlimited). A
-- purchase is logged in __buy_log and lands when a test calls __deliver,
-- which charges the money, fills the bags and fires BAG_UPDATE_DELAYED.

__merchant = {}
__buy_log = {}
__buyback = 2
local deliveries = {}

local function merchantEntry(index)
    return __merchant[index]
end

local function batchOf(entry)
    if entry.batch then return entry.batch end
    local info = item(entry.id)
    return info and info.stack or 1
end

C_MerchantFrame = {
    GetItemInfo = function(index)
        local entry = merchantEntry(index)
        if not entry then return nil end
        if entry.secretInfo then
            return { name = __secret(), texture = __secret(), price = __secret(), stackCount = __secret(),
                numAvailable = __secret(), isPurchasable = __secret(), isUsable = __secret(),
                hasExtendedCost = __secret() }
        end
        local info = item(entry.id)
        return {
            name = info and info.name,
            texture = info and info.icon or 0,
            price = entry.price or 0,
            stackCount = batchOf(entry),
            numAvailable = entry.stock or -1,
            isPurchasable = entry.purchasable ~= false,
            isUsable = entry.usable ~= false,
            hasExtendedCost = entry.extended == true,
            isQuestStartItem = false,
        }
    end,
}

function GetMerchantNumItems()
    if __merchantCountSecret then return __secret() end
    return #__merchant
end

function GetMerchantItemID(index)
    local entry = merchantEntry(index)
    return entry and entry.id
end

function GetMerchantItemMaxStack(index)
    local entry = merchantEntry(index)
    if not entry then return 0 end
    if entry.maxStack then return entry.maxStack end
    local info = item(entry.id)
    return info and info.stack or 1
end

function BuyMerchantItem(index, quantity)
    local entry = merchantEntry(index)
    __buy_log[#__buy_log + 1] = { index = index, id = entry and entry.id, quantity = quantity }
    if not entry or __refuse then return end
    deliveries[#deliveries + 1] = { id = entry.id, quantity = quantity or batchOf(entry),
        price = entry.price or 0, batch = batchOf(entry) }
end

-- The rounds asked for so far, in all.
function __bought()
    local total = 0
    for _, purchase in ipairs(__buy_log) do total = total + purchase.quantity end
    return total
end

-- Lands every purchase made so far, then fires BAG_UPDATE_DELAYED, which may
-- make the addon buy again. Returns how many landed.
function __deliver()
    local list = deliveries
    deliveries = {}
    for _, purchase in ipairs(list) do
        -- Seen in game on 2026-10-17: 50 of a 200 batch for 9c took 3c.
        __money = __money - math.ceil(purchase.quantity * purchase.price / purchase.batch)
        __add_item(purchase.id, purchase.quantity)
    end
    __fire("PLAYER_MONEY")
    __fire("BAG_UPDATE_DELAYED")
    return #list
end

-- Lands purchases until the addon stops buying.
function __deliver_all()
    for _ = 1, 50 do
        if #deliveries == 0 then return end
        __deliver()
    end
    error("the addon never stopped buying")
end

function __pending_purchases() return #deliveries end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

__badTextures = {}

local methods = {}
local frames = {}

local function fontOf(object)
    return object and object.__font
end

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
function methods:EnableMouse(enabled) self.__mouse = enabled end
function methods:SetAlpha(alpha) self.__alpha = alpha end
function methods:GetAlpha() return self.__alpha or 1 end
function methods:SetID(id) self.__id = id end
function methods:GetID() return self.__id or 0 end
function methods:CreateTexture() return __new_widget("Texture", self) end
function methods:CreateFontString(_, _, template)
    local fontString = __new_widget("FontString", self)
    if template then
        if not _G[template] then error("CreateFontString: unknown font object " .. tostring(template)) end
        fontString:SetFontObject(_G[template])
    end
    return fontString
end
function methods:RegisterEvent(event)
    if not __knownEvents[event] then
        error("Attempt to register unknown event \"" .. tostring(event) .. "\"")
    end
    self.__events[event] = true
end
function methods:UnregisterEvent(event)
    if not __knownEvents[event] then
        error("Attempt to unregister unknown event \"" .. tostring(event) .. "\"")
    end
    self.__events[event] = nil
end
function methods:UnregisterAllEvents() self.__events = {} end

-- Button
function methods:RegisterForClicks(...) self.__clicks = { ... } end
function methods:SetNormalTexture(texture) self.__normal = texture end
function methods:SetHighlightTexture(texture, blend) self.__highlight, self.__highlightBlend = texture, blend end
function methods:SetPushedTexture(texture) self.__pushed = texture end

-- Texture. A file id is a number, a path a string.
function methods:SetTexture(texture)
    if type(texture) == "string" and __badTextures[texture:lower()] then return false end
    if texture ~= nil and type(texture) ~= "string" and type(texture) ~= "number" then
        error("SetTexture: not a path or a file id")
    end
    self.__texture = texture
    return true
end
function methods:SetColorTexture(...) self.__color = { ... } end
function methods:SetAtlas(atlas, useAtlasSize)
    self.__atlas, self.__useAtlasSize = atlas, useAtlasSize == true
    return true
end
function methods:SetBlendMode(mode) self.__blend = mode end
function methods:SetDesaturated(desaturated) self.__desaturated = desaturated and true or false end
function methods:SetVertexColor(...) self.__vertexColor = { ... } end

-- CheckButton
function methods:SetChecked(checked) self.__checked = checked and true or false end
function methods:GetChecked() return self.__checked or false end

-- FontString
function methods:SetFontObject(object) self.__font = fontOf(object) and { unpack(fontOf(object)) } end
function methods:SetFont(path, size, flags) self.__font = { path, size, flags }; return true end
function methods:GetFont() if self.__font then return unpack(self.__font) end end
function methods:SetText(text)
    if self.__kind == "FontString" and not self.__font then error("FontString:SetText(): Font not set") end
    self.__text = text
end
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

-- Animation groups: alpha and flipbook animations, each on a target. A
-- group plays until it is stopped or a test finishes it with __finish.
local animationGroup = {}
local animationGroupMeta = { __index = animationGroup }
local animation = {}
local animationMeta = { __index = animation }
local ANIMATION_KINDS = { Alpha = true, FlipBook = true }

function animationGroup:SetLooping(mode) self.__looping = mode end
function animationGroup:CreateAnimation(kind)
    if not ANIMATION_KINDS[kind] then error("CreateAnimation: unknown animation type " .. tostring(kind)) end
    local anim = setmetatable({ __kind = kind }, animationMeta)
    self.__animations[#self.__animations + 1] = anim
    return anim
end
function animationGroup:SetScript(name, handler) self.__scripts[name] = handler end
function animationGroup:Play() self.__playing = true end
function animationGroup:Stop() self.__playing = false end
function animationGroup:IsPlaying() return self.__playing == true end

-- A group that does not loop comes to its end, as the client's does.
function __finish(group)
    if not group:IsPlaying() then return end
    group.__playing = false
    if group.__scripts.OnFinished then group.__scripts.OnFinished(group) end
end

-- The group's animation of a kind, to read how it was set up.
function __animation(group, kind)
    for _, anim in ipairs(group.__animations) do
        if anim.__kind == kind then return anim end
    end
end

function animation:SetTarget(target) self.__target = target end
function animation:SetOrder(order) self.__order = order end
function animation:SetDuration(seconds) self.__duration = seconds end
function animation:SetFromAlpha(alpha) self.__from = alpha end
function animation:SetToAlpha(alpha) self.__to = alpha end
function animation:SetFlipBookRows(rows) self.__rows = rows end
function animation:SetFlipBookColumns(columns) self.__columns = columns end
function animation:SetFlipBookFrames(count) self.__frames = count end
function animation:SetFlipBookFrameWidth(width) self.__frameWidth = width end
function animation:SetFlipBookFrameHeight(height) self.__frameHeight = height end

function methods:CreateAnimationGroup()
    return setmetatable({ __animations = {}, __scripts = {}, __parent = self }, animationGroupMeta)
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

-- The widgets made with this parent, of this kind when one is given.
function __children(parent, kind)
    local found = {}
    for _, widget in ipairs(frames) do
        if widget.__parent == parent and (not kind or widget.__kind == kind) then
            found[#found + 1] = widget
        end
    end
    return found
end

--------------------------------------------------------------------------------
-- Secure hooks
--------------------------------------------------------------------------------

-- Replaces the function with one that calls it, then the hook, with the same
-- arguments, as the client's does.
function hooksecurefunc(target, name, hook)
    if type(target) == "string" then target, name, hook = _G, target, name end
    local original = target[name]
    if type(original) ~= "function" then error("hooksecurefunc: no function " .. tostring(name)) end
    target[name] = function(...)
        local results = { original(...) }
        hook(...)
        return unpack(results)
    end
end

--------------------------------------------------------------------------------
-- Menus
--------------------------------------------------------------------------------
-- The client's menu descriptions, for the right-click menu and the settings
-- page's dropdowns alike. A generator runs against a tree the tests can read
-- and click through.

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

-- Finds a menu entry by its path of texts, for example ("Keep gold", "1g").
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

templates.UICheckButtonTemplate = function() end
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

-- The settings dropdown: SetupMenu keeps the generator and generates at once,
-- GenerateMenu runs it again and shows the radio that is selected.
templates.WowStyle1DropdownTemplate = function(frame)
    function frame:SetupMenu(generator)
        self.__generator = generator
        self:GenerateMenu()
    end
    function frame:GenerateMenu()
        local root = node("root")
        self.__generator(self, root)
        self.__menuRoot = root
        self.__selectedText = nil
        for _, child in ipairs(root.children) do
            if child.kind == "radio" and child.a() then self.__selectedText = child.text end
        end
    end
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

-- The value font string on a settings row: the row's text that is not its
-- label.
function __row_value(label)
    for _, widget in ipairs(frames) do
        if widget.__kind == "FontString" and widget.__text == label and widget.__parent ~= nil then
            for _, other in ipairs(frames) do
                if other.__parent == widget.__parent and other.__kind == "FontString" and other ~= widget then
                    return other:GetText()
                end
            end
        end
    end
    error("no settings row labelled " .. tostring(label))
end

-- Picks an entry in a settings dropdown the way the player would.
function __dropdown_pick(dropdown, text)
    dropdown:GenerateMenu()
    for _, child in ipairs(dropdown.__menuRoot.children) do
        if child.text == text then
            child.b()
            return
        end
    end
    error("no entry " .. tostring(text) .. " in the dropdown")
end

function __dropdown_text(dropdown)
    dropdown:GenerateMenu()
    return dropdown.__selectedText
end

-- The settings page, once registered.
function __settings_page()
    return __settingsCategory and __settingsCategory.frame
end

-- The button on the settings page with this text.
function __page_button(text)
    for _, widget in ipairs(frames) do
        if widget.__template == "UIPanelButtonTemplate" and widget.__text == text then return widget end
    end
    error("no button " .. tostring(text))
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
-- The vendor window
--------------------------------------------------------------------------------
-- The Mainline MerchantFrame as far as Fletcher sees it: ten item buttons,
-- each with its id set to its vendor index when the page is drawn, the page
-- number, the tab, and the functions that draw it, which the addon hooks.

local function buildMerchantFrame()
    MERCHANT_ITEMS_PER_PAGE = 10
    MerchantFrame = CreateFrame("Frame", "MerchantFrame", UIParent)
    MerchantFrame.__shown = false
    MerchantFrame.page = 1
    MerchantFrame.selectedTab = 1
    for i = 1, MERCHANT_ITEMS_PER_PAGE do
        local merchantItem = CreateFrame("Frame", "MerchantItem" .. i, MerchantFrame)
        local itemButton = CreateFrame("Button", "MerchantItem" .. i .. "ItemButton", merchantItem)
        itemButton:SetSize(37, 37)
    end

    function MerchantFrame_UpdateMerchantInfo()
        local count = #__merchant
        for i = 1, MERCHANT_ITEMS_PER_PAGE do
            local index = (MerchantFrame.page - 1) * MERCHANT_ITEMS_PER_PAGE + i
            local itemButton = _G["MerchantItem" .. i .. "ItemButton"]
            if index <= count then
                itemButton:SetID(index)
                itemButton:Show()
            else
                itemButton:Hide()
            end
        end
    end

    function MerchantFrame_UpdateBuybackInfo()
        for i = 1, MERCHANT_ITEMS_PER_PAGE do
            local itemButton = _G["MerchantItem" .. i .. "ItemButton"]
            if i <= __buyback then
                itemButton:SetID(i)
                itemButton:Show()
            else
                itemButton:Hide()
            end
        end
    end

    -- Global lookups, so a hooked function runs its hook.
    function MerchantFrame_Update()
        if MerchantFrame.selectedTab == 1 then
            MerchantFrame_UpdateMerchantInfo()
        else
            MerchantFrame_UpdateBuybackInfo()
        end
    end
end

-- Talks to a vendor with this list: the window shows and draws its first
-- page, then MERCHANT_SHOW reaches the addons, the way the game orders it.
function __open_vendor(list)
    __merchant = list or {}
    MerchantFrame.page = 1
    MerchantFrame.selectedTab = 1
    MerchantFrame:Show()
    MerchantFrame_Update()
    __fire("MERCHANT_SHOW")
end

function __close_vendor()
    MerchantFrame:Hide()
    __fire("MERCHANT_CLOSED")
end

function __merchant_page(page)
    MerchantFrame.page = page
    MerchantFrame_Update()
end

function __merchant_tab(tab)
    MerchantFrame.selectedTab = tab
    MerchantFrame_Update()
end

-- The vendor's list changed (its filter, or its stock), and the game says so.
function __merchant_update(list)
    if list then __merchant = list end
    MerchantFrame_Update()
    __fire("MERCHANT_UPDATE")
end

-- The mark Fletcher put on an item button on the page, when it is showing.
function __overlay(place)
    local itemButton = _G["MerchantItem" .. place .. "ItemButton"]
    for _, child in ipairs(__children(itemButton, "Frame")) do
        if child.glow then return child:IsShown() and child or nil end
    end
    return nil
end

-- Whether any font string says exactly this.
function __text_shown(text)
    for _, widget in ipairs(frames) do
        if widget.__kind == "FontString" and widget.__text == text then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Client globals
--------------------------------------------------------------------------------

local function resetGlobals()
    frames = {}
    UIParent = __new_widget("Frame")
    UIParent:SetSize(1920, 1080)

    GameFontHighlightSmall = { __font = { "Fonts\\FRIZQT__.TTF", 10, "" } }
    GameFontHighlight = { __font = { "Fonts\\FRIZQT__.TTF", 12, "" } }
    GameFontNormal = { __font = { "Fonts\\FRIZQT__.TTF", 12, "" } }
    GameFontHighlightLarge = { __font = { "Fonts\\FRIZQT__.TTF", 16, "" } }
    GameFontHighlightHuge = { __font = { "Fonts\\FRIZQT__.TTF", 20, "" } }

    Enum = {
        ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Projectile = 6, Quiver = 11 },
        ItemQuiverSubclass = { ObsoleteQuiver = 0, ObsoleteBolts = 1, Quiver = 2, Ammopouch = 3 },
        ItemWeaponSubclass = { Bows = 2, Guns = 3, Thrown = 16, Crossbow = 18, Wand = 19 },
    }

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

    __inCombat = false
    function InCombatLockdown() return __inCombat end
    __shift = false
    function IsShiftKeyDown() return __shift end

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
            local root = node("root")
            generator(owner, root)
            __menu = root
        end,
    }

    C_Timer = {
        After = function(delay, callback) schedule(delay, callback, 1) end,
        NewTicker = function(interval, callback, iterations) return schedule(interval, callback, iterations) end,
    }

    SlashCmdList = {}
    SLASH_FLETCHER1, SLASH_FLETCHER2 = nil, nil
    FletcherVendorButton = nil

    buildMerchantFrame()
end

--------------------------------------------------------------------------------
-- Loading the addon
--------------------------------------------------------------------------------

-- The events this client knows. A test removes one to check that a missing
-- event does not stop the addon.
local DEFAULT_EVENTS = {
    "PLAYER_LOGIN", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE",
    "MERCHANT_FILTER_ITEM_UPDATE", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE",
    "PLAYER_MONEY", "GET_ITEM_INFO_RECEIVED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
}

-- Removes a global or a namespace member, "GetMoney" or "C_Item.GetItemCount".
local function removeGlobal(name)
    local space, member = name:match("^(.-)%.(.+)$")
    if space then
        local copy = {}
        for key, value in pairs(_G[space] or {}) do copy[key] = value end
        copy[member] = nil
        _G[space] = copy
    else
        _G[name] = nil
    end
end

-- The real functions, put back at every boot after a test removed one.
local REAL = {
    C_Item = C_Item, C_Container = C_Container, C_MerchantFrame = C_MerchantFrame,
    GetMerchantNumItems = GetMerchantNumItems, GetMerchantItemID = GetMerchantItemID,
    GetMerchantItemMaxStack = GetMerchantItemMaxStack, BuyMerchantItem = BuyMerchantItem,
    GetInventoryItemID = GetInventoryItemID, GetInventoryItemCount = GetInventoryItemCount,
    UnitUsesAmmo = UnitUsesAmmo, GetMoney = GetMoney,
}

-- Starts a fresh session: a clean world, the given character, bags and saved
-- settings, every file the .toc lists loaded in order as the game loads
-- them, and (unless told not to) PLAYER_LOGIN fired. Returns the addon's
-- namespace. Options: interface, version, class, level, money, ranged, ammo,
-- bags, db, missingEvents, remove (globals the client lacks), noSettings,
-- noMenu, login.
function __boot(options)
    options = options or {}
    for name, value in pairs(REAL) do _G[name] = value end
    resetGlobals()
    resetTimers()

    __output = {}
    __interface = options.interface or 16001
    __version = options.version or "@project-version@"
    __class = options.class or "HUNTER"
    __level = options.level or 30
    __money = options.money or 0
    __ranged = options.ranged
    __ammo = options.ammo
    __bags = options.bags or { [0] = { slots = 16, contents = {} } }
    __items = copyItems()
    __merchant = {}
    __buy_log = {}
    __buyback = 2
    __refuse = false
    __itemCountSecret = false
    __merchantCountSecret = false
    deliveries = {}
    __badTextures = {}
    __knownEvents = {}
    for _, event in ipairs(DEFAULT_EVENTS) do __knownEvents[event] = true end
    for _, event in ipairs(options.missingEvents or {}) do __knownEvents[event] = nil end
    for _, name in ipairs(options.remove or {}) do removeGlobal(name) end
    FletcherDB = options.db
    if options.noSettings then Settings = nil end
    if options.noMenu then MenuUtil = nil end

    __base_frames = #frames

    local ns = {}
    for _, entry in ipairs(__toc_files) do
        local chunk, err = load(entry.source, "=" .. entry.file)
        if not chunk then error(err) end
        chunk("Fletcher", ns)
    end

    if options.login ~= false then __fire("PLAYER_LOGIN") end
    return ns
end
