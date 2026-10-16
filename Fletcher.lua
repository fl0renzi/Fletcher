-- Fletcher - Fletcher.lua
-- A quiver refill for the hunter. When a hunter opens a vendor that sells
-- ammo, Fletcher finds the equipped quiver or ammo pouch, picks the best
-- arrows or bullets the vendor sells that the hunter can use, marks that
-- item's icon in the vendor window, and buys exactly as many rounds as fill
-- every slot of the bag. Nothing is bought for normal bags, and an older
-- kind of ammo sitting in a slot is never moved, sold or replaced.
--
-- The vendor window's own parts (the highlight, the button, the right-click
-- menu) are in Fletcher_Vendor.lua, the settings page in
-- Fletcher_Options.lua; all three change a setting only through the same
-- setter in ns.API.
--
-- Cost: the vendor window's parts are built on the first MERCHANT_SHOW of a
-- hunter, never at load. Buying is event-driven and one purchase at a time,
-- advanced by the event the game sends after a purchase; the only timer is a
-- one-shot safety net per purchase step. A character that is not a hunter
-- unregisters everything at login and pays nothing after that.

local addonName, ns = ...

--------------------------------------------------------------------------------
-- Client gate
--------------------------------------------------------------------------------
-- Fletcher targets World of Warcraft: Forever, whose toc is 16001. On any
-- other client it stays inert and never reads or writes FletcherDB, so the
-- saved settings round-trip untouched. It fails open when the interface
-- number cannot be read, so a healthy client is never blocked.

local FOREVER_INTERFACE = 16001

local iface = select(4, GetBuildInfo())
if type(iface) == "number" and iface ~= FOREVER_INTERFACE then
    ns.Allowed = false
    print(("Fletcher targets WoW Forever (interface %d) and is disabled on this client (interface %d).")
        :format(FOREVER_INTERFACE, iface))
    return
end
ns.Allowed = true

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Inventory slots and the equipped bags. The ammo slot is slot 0 and the
-- ranged weapon slot is 18; the equipped bags are 1 to 4, and a bag is
-- itself an item sitting in the inventory slot ContainerIDToInventoryID
-- names. Values as names, so the logic never carries a bare number.
local INVSLOT_AMMO   = 0
local INVSLOT_RANGED = 18
local FIRST_BAG, LAST_BAG = 1, 4

-- Item classes and subclasses, as GetItemInfoInstant answers them. A bag of
-- class 11 (Container) with subclass 2 is a quiver (holds arrows) and
-- subclass 3 an ammo pouch (holds bullets); an item of class 6 (Projectile)
-- with subclass 2 is an arrow, subclass 3 a bullet; a weapon of class 2
-- (Weapon) with subclass 2 is a bow, 3 a gun and 18 a crossbow: bows and
-- crossbows shoot arrows, guns shoot bullets. Thrown weapons and wands
-- shoot nothing, and there is no ammo for them to mark.
local ITEM_CLASS_CONTAINER  = 11
local SUBCLASS_QUIVER, SUBCLASS_POUCH = 2, 3
local ITEM_CLASS_PROJECTILE = 6
local SUBCLASS_ARROW, SUBCLASS_BULLET = 2, 3
local ITEM_CLASS_WEAPON     = 2
local SUBCLASS_BOW, SUBCLASS_GUN, SUBCLASS_CROSSBOW = 2, 3, 18

-- What each ranged weapon subclass shoots (nil when it shoots nothing): the
-- kind the highlight falls back to when no ammo bag is equipped.
local RANGED_PROJECTILE = {
    [SUBCLASS_BOW]      = SUBCLASS_ARROW,
    [SUBCLASS_GUN]      = SUBCLASS_BULLET,
    [SUBCLASS_CROSSBOW] = SUBCLASS_ARROW,
}

-- Bag family bits, the same thing the bag's item class says in another way:
-- bit 0x1 marks a family that holds arrows, 0x2 one that holds bullets.
-- Read when the bag's own item cannot be read.
local FAMILY_ARROWS, FAMILY_BULLETS = 0x1, 0x2

-- The kinds, named as the addon speaks of them.
local KIND_PLURAL   = { [SUBCLASS_ARROW] = "arrows", [SUBCLASS_BULLET] = "bullets" }
local KIND_SINGULAR = { [SUBCLASS_ARROW] = "arrow",  [SUBCLASS_BULLET] = "bullet" }

-- Money, in copper. The Keep gold and Spending cap settings are set in gold
-- ("1" and "0.5" on the slash command) and held in copper.
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD   = 10000
local MAX_GOLD          = 1000

-- The version the toc names, which the packager writes from the release tag,
-- "1.0.0" from a "v1.0.0" tag. Run straight from the repository, the toc
-- still holds the packager's placeholder, and there is no version to show.
local VERSION
do
    local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local version = type(GetMetadata) == "function" and GetMetadata(addonName, "Version")
    if type(version) == "string" and version ~= "" and not version:find("@", 1, true) then
        VERSION = version
    end
end

local DEFAULTS = {
    autoBuy        = true,
    highlight      = true,
    highlightOther = false,
    pulse          = true,
    report         = true,
    showButton     = true,
    keepCopper     = 0,  -- money never goes below this
    capCopper      = 0,  -- 0 means no cap per refill
}

-- The colours the game's own tooltips use, for a label line and for a hint
-- line.
local LABEL_COLOR = { 1.0, 0.82, 0.0 }
local HINT_COLOR  = { 0.5, 0.5, 0.5 }

-- A purchase that no bag update follows within this many seconds stops the
-- refill. A safety net, not logic: the refill walks on the game's own
-- events, never on a timer.
local STEP_TIMEOUT = 3

-- An item whose details are not cached yet is waited for at most this many
-- GET_ITEM_INFO_RECEIVED events; after that the visit goes on with what is
-- cached, silently without it.
local MAX_INFO_TRIES = 3

-- The money amounts the right-click menu offers, as copper, with their
-- names. None first: a reserve of 0 means "spend it all", a cap of 0 means
-- no cap.
local KEEP_CHOICES = {
    { copper = 0,      name = "None" },
    { copper = 1000,   name = "10s" },
    { copper = 10000,  name = "1g" },
    { copper = 50000,  name = "5g" },
    { copper = 100000, name = "10g" },
    { copper = 500000, name = "50g" },
}
local CAP_CHOICES = {
    { copper = 0,      name = "None" },
    { copper = 5000,   name = "50s" },
    { copper = 10000,  name = "1g" },
    { copper = 50000,  name = "5g" },
    { copper = 100000, name = "10g" },
}

-- The quiver icon when nothing fits to show on the vendor button. VERIFY:
-- the texture the client draws for a quiver's icon is confirmed on the
-- client; the fallback below is the plan's other candidate if it does not
-- load.
local QUIVER_ICON = "Interface\\Icons\\INV_Ammo_Arrow_02"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local db          -- FletcherDB, set at PLAYER_LOGIN
local active      -- a hunter
local isHunter = false

-- The quiver, as last read. One table, refilled in place, so a refresh
-- allocates nothing. bags holds the indexes of the containers the refill
-- fills: bags.n is the count, bags[1..n] the indexes.
local quiver = {
    present = false, -- a quiver or ammo pouch is equipped
    kind = nil,      -- what the bag holds: SUBCLASS_ARROW or SUBCLASS_BULLET
    name = nil,      -- the bag's name, when the item is cached
    bags = { n = 0 },
    stackSize = nil, -- the chosen ammo's stack
    capacity = 0,    -- rounds the bag holds when every slot is full
    rounds = 0,      -- rounds of the chosen ammo it holds now
    need = 0,        -- rounds the refill wants (0 when the bag is full)
}

-- The ranged weapon, as last read: whether one is equipped and the
-- projectile it shoots (nil when it shoots nothing, or when the weapon
-- cannot be read).
local ranged = { present = false, shoots = nil }

-- The vendor visit. A vendor is "open" from MERCHANT_SHOW to
-- MERCHANT_CLOSED; that is when the refills live. All of it refilled in
-- place.
local shopping = {
    open = false,    -- a vendor is on screen
    active = false,  -- a refill is walking its purchases
    reason = nil,    -- "auto" or "manual", for what a stop says

    -- The chosen ammo, fixed when the refill started.
    index = nil,     -- the vendor index to buy from
    itemID = nil,    -- the ammo's item id
    name = nil,      -- its name, for the report line
    kind = nil,      -- SUBCLASS_ARROW or SUBCLASS_BULLET, for the report line
    unitPrice = nil, -- the price of one round

    -- The need is fixed at the start, and the queue never buys more than
    -- what is left of it.
    left = 0,        -- rounds still to buy
    pending = 0,     -- rounds of the purchase that is in flight
    bought = 0,      -- rounds bought so far
    spent = 0,       -- copper spent so far

    -- The wait states: a purchase goes out and its bag update comes in; an
    -- item's details may still arrive from the client's cache.
    waiting = false,     -- a purchase is out, its bag update not in yet
    watchingInfo = false -- GET_ITEM_INFO_RECEIVED is registered for the visit
    -- and its retries:
}
local infoTries = 0 -- GET_ITEM_INFO_RECEIVED events waited through this visit

-- Whether the visit has yet said the warning about an ammo bag that holds
-- another kind than the weapon shoots. Said once per visit, so it resets at
-- open.
local warnedMismatch = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Secret values (the patch 12.0 security model) raise a Lua error on any
-- comparison, boolean test, length or arithmetic. Everything read from the
-- game passes through here first; a secret becomes nil, read as "unknown".
local issecretvalue = issecretvalue
local function SafeValue(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

-- A number from the game, or nil: SafeValue for anything the logic does
-- arithmetic on.
local function SafeNumber(value)
    value = SafeValue(value)
    return type(value) == "number" and value or nil
end

local function Print(text)
    print("|cffffd200Fletcher:|r " .. text)
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function Round(value)
    return math.floor(value + 0.5)
end

-- The bit library's band does this on the client; without it, and in the
-- Lua of the test harness, the same test by hand.
local band
do
    local ok, library = pcall(function() return bit end)
    if ok and type(library) == "table" and type(library.band) == "function" then
        band = library.band
    end
end
local function HasBit(family, bitValue)
    if band then return band(family, bitValue) ~= 0 end
    return math.floor(family / bitValue) % 2 == 1
end

-- 350 copper as "3s 50c", 10000 as "1g", 0 as "0c". Plain text, no coin
-- icons, so the settings and the reports read the same everywhere.
local function MoneyText(copper)
    copper = math.max(0, math.floor(copper or 0))
    local gold = math.floor(copper / COPPER_PER_GOLD)
    copper = copper - gold * COPPER_PER_GOLD
    local silver = math.floor(copper / COPPER_PER_SILVER)
    local penny = copper - silver * COPPER_PER_SILVER
    if gold > 0 then
        if penny > 0 then
            return ("%dg %ds %dc"):format(gold, silver, penny)
        elseif silver > 0 then
            return ("%dg %ds"):format(gold, silver)
        end
        return ("%dg"):format(gold)
    elseif silver > 0 then
        if penny > 0 then return ("%ds %dc"):format(silver, penny) end
        return ("%ds"):format(silver)
    end
    return ("%dc"):format(penny)
end

--------------------------------------------------------------------------------
-- Game calls
--------------------------------------------------------------------------------
-- Forever runs the 1.x game on a modern client, where several of the calls
-- the logic needs exist as both a C_ table method and an old global function
-- with the same name. Each of these wrappers prefers the C_ form and falls
-- back to the global, the way BeastXP picks C_AddOns.GetAddOnMetadata or
-- GetAddOnMetadata.
--
-- The Phase 0 probe answers what Forever really is; until its answers are
-- in, whatever a wrapper assumes is marked VERIFY(phase0) next to it, and
-- the stub exercises the assumption as it stands. The owner's answers pin
-- each mark.

-- VERIFY(phase0): what Forever's C_MerchantFrame.GetItemInfo(index) answers
-- - an info table, as retail 12.0 does (the probe dumps it), or nothing and
-- the old GetMerchantItemInfo answer stands. Both spellings of every field
-- are read until the answer is in.
local function MerchantItemInfo(index)
    local reader = C_MerchantFrame and C_MerchantFrame.GetItemInfo
    if type(reader) ~= "function" then reader = GetMerchantItemInfo end
    if type(reader) ~= "function" then return nil end
    local first, texture, price, rounds, stock, usable, extra = reader(index)
    if type(first) == "table" then
        -- The info table: every field in whichever spelling it names, a
        -- nil taken for an unknown, and a false never swapped for one.
        local info = first
        local kind = info.name
        if kind == nil then kind = info.itemName end
        local roundsRead = info.quantity
        if roundsRead == nil then roundsRead = info.stackCount end
        if roundsRead == nil then roundsRead = info.batch end
        local stockRead = info.numAvailable
        if stockRead == nil then stockRead = info.count end
        local usableRead = info.isUsable
        if usableRead == nil then usableRead = info.usable end
        return kind, info.texture or info.icon,
            info.price, roundsRead, stockRead, usableRead
    end
    -- The old value list: name, texture, price, quantity, numAvailable,
    -- isUsable, ...
    return first, texture, price, rounds, stock, usable, extra
end

-- VERIFY(phase0): the shape of the modern GetItemInfoInstant (the probe
-- dumps it) - the class and subclass expected as the sixth and seventh
-- returns of either form.
local function ItemClassOf(itemID)
    if itemID == nil then return nil end
    local reader = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    if type(reader) ~= "function" then
        -- No instant call on this client: the plain GetItemInfo answers
        -- class and subclass, when the item is cached.
        local data = ItemInfo(itemID)
        if data == nil then return nil end
        return data.class, data.subclass
    end
    return SafeNumber(select(6, reader(itemID))), SafeNumber(select(7, reader(itemID)))
end

-- VERIFY(phase0): that the item level is the fourth return, the required
-- level the fifth and the stack size the eighth of GetItemInfo, and that
-- C_Item's copy answers the same returns as the global. An item the client
-- has not cached yet answers nothing.
local function ItemInfo(itemID)
    if itemID == nil then return nil end
    local reader = C_Item and C_Item.GetItemInfo or GetItemInfo
    if type(reader) ~= "function" then return nil end
    local name, _, _, iLevel, reqLevel, class, subclass, stackSize = reader(itemID)
    if name == nil then return nil end
    return {
        name = SafeValue(name),
        iLevel = SafeNumber(iLevel),
        reqLevel = SafeNumber(reqLevel),
        class = SafeNumber(class),
        subclass = SafeNumber(subclass),
        stackSize = SafeNumber(stackSize),
    }
end

local function NumMerchantItems()
    local reader = C_MerchantFrame and C_MerchantFrame.GetNumItems
    if type(reader) ~= "function" then reader = GetMerchantNumItems end
    return SafeNumber(type(reader) == "function" and reader() or nil)
end

-- VERIFY(phase0): the id the vendor's index names. GetMerchantItemID has no
-- C_ form in the retail reference; the probe says what Forever has.
local function VendorID(index)
    return SafeNumber(GetMerchantItemID and GetMerchantItemID(index) or nil)
end

-- VERIFY(phase0): what GetMerchantItemMaxStack returns for ammo - the most
-- rounds one BuyMerchantItem may ask, is what the split math takes it for.
local function MaxPurchase(index)
    return SafeNumber(GetMerchantItemMaxStack and GetMerchantItemMaxStack(index) or nil)
end

local function MerchantBuy(index, count)
    local ok = pcall(BuyMerchantItem, index, count)
    return ok and true or false
end

-- VERIFY(phase0): what C_Container.GetContainerItemInfo answers on Forever -
-- an info table (whose fields the probe names: iconFileID, stackCount,
-- itemID, isLocked, on retail) or the old value list of
-- GetContainerItemInfo. ReadBagSlot reads both spellings.
local function BagItem(bag, slot)
    local reader = C_Container and C_Container.GetContainerItemInfo
    if type(reader) == "function" then
        local info = reader(bag, slot)
        if type(info) == "table" then
            local itemID = SafeValue(info.itemID)
            if itemID == nil then return nil end
            return SafeNumber(info.stackCount or info.count),
                SafeNumber(itemID),
                SafeValue(info.isLocked)
        end
        -- The C_ form answered like the old list after all.
    end
    if type(GetContainerItemInfo) ~= "function" then return nil end
    local _, count, locked = GetContainerItemInfo(bag, slot)
    if count == nil then return nil end
    return SafeNumber(count),
        SafeNumber(GetContainerItemID and GetContainerItemID(bag, slot) or nil),
        SafeValue(locked)
end

-- VERIFY(phase0): whether C_Container.GetContainerNumFreeSlots' second
-- return names the bag family, as the old global does.
local function BagFamily(bag)
    local reader = C_Container and C_Container.GetContainerNumFreeSlots
    if type(reader) ~= "function" then reader = GetContainerNumFreeSlots end
    if type(reader) ~= "function" then return nil end
    return SafeValue(select(2, reader(bag)))
end

-- VERIFY(phase0): whether C_Container.GetContainerNumSlots is there (retail
-- names it so) or the old global GetContainerNumSlots.
local function BagSlots(bag)
    local reader = C_Container and C_Container.GetContainerNumSlots
    if type(reader) ~= "function" then reader = GetContainerNumSlots end
    return SafeNumber(type(reader) == "function" and reader(bag) or nil)
end

-- VERIFY(phase0): whether C_Container.ContainerIDToInventoryID is there
-- (retail has it); the old global of the same name answers the same slot.
local function BagInventorySlot(bag)
    local reader = C_Container and C_Container.ContainerIDToInventoryID
    if type(reader) ~= "function" then reader = ContainerIDToInventoryID end
    return SafeNumber(type(reader) == "function" and reader(bag) or nil)
end

local function PlayerLevel()
    return SafeNumber(UnitLevel("player"))
end

local function PlayerMoney()
    return SafeNumber(GetMoney())
end

-- The item in a player's inventory slot (the equipped bags sit in them too).
local function InventoryItemID(slot)
    return SafeNumber(GetInventoryItemID and GetInventoryItemID("player", slot) or nil)
end

-- The stack in an inventory slot, in the game's own count.
local function InventoryCount(slot)
    return SafeNumber(GetInventoryItemCount and GetInventoryItemCount("player", slot) or nil)
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
-- Account-wide: the Forever client writes a per-character SavedVariables file
-- but never loads it back. Everything applies live, since the beta client
-- does not reliably keep a write across a reload either.

-- Whole copper in the settings' range, or nil for anything else (including a
-- NaN, which the type check lets through and no comparison understands).
local function FixCopper(value)
    if type(value) ~= "number" or value ~= value then return nil end
    return Clamp(Round(value), 0, MAX_GOLD * COPPER_PER_GOLD)
end

local function InitDB()
    if type(FletcherDB) ~= "table" then FletcherDB = {} end
    db = FletcherDB

    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= type(value) then db[key] = value end
    end

    db.keepCopper = FixCopper(db.keepCopper) or DEFAULTS.keepCopper
    db.capCopper  = FixCopper(db.capCopper) or DEFAULTS.capCopper
end

--------------------------------------------------------------------------------
-- Reading the quiver
--------------------------------------------------------------------------------

-- What bag `bag` holds, by its item class first (a bag is an item sitting in
-- the inventory slot ContainerIDToInventoryID names), then by its bag family
-- bits. SUBCLASS_ARROW, SUBCLASS_BULLET, or nil.
local function BagKind(bag)
    local inventorySlot = BagInventorySlot(bag)
    local bagItemID = inventorySlot and InventoryItemID(inventorySlot)
    if type(bagItemID) == "number" then
        local class, subclass = ItemClassOf(bagItemID)
        if class == ITEM_CLASS_CONTAINER then
            if subclass == SUBCLASS_QUIVER then return SUBCLASS_ARROW end
            if subclass == SUBCLASS_POUCH then return SUBCLASS_BULLET end
        end
    end
    local family = BagFamily(bag)
    if type(family) == "number" then
        if HasBit(family, FAMILY_ARROWS) then return SUBCLASS_ARROW end
        if HasBit(family, FAMILY_BULLETS) then return SUBCLASS_BULLET end
    end
    return nil
end

-- The quiver, as last read: whether an ammo bag is equipped, what it holds,
-- and which bags the refill fills. The first ammo bag in the scan decides
-- the kind (the bag decides, as the owner asked); every other bag of the
-- same kind joins the list.
local function ReadQuiver()
    quiver.present = false
    quiver.kind = nil
    quiver.name = nil
    quiver.bags.n = 0
    for bag = FIRST_BAG, LAST_BAG do
        local kind = BagKind(bag)
        if kind then
            if not quiver.kind then
                quiver.present = true
                quiver.kind = kind
                -- The bag's own name, for the tooltip's quiver line, when
                -- the item is cached.
                local inventorySlot = BagInventorySlot(bag)
                if inventorySlot then
                    local data = ItemInfo(InventoryItemID(inventorySlot))
                    quiver.name = data and data.name or nil
                end
            end
            if kind == quiver.kind then
                quiver.bags.n = quiver.bags.n + 1
                quiver.bags[quiver.bags.n] = bag
            end
        end
    end
end

-- The ranged weapon, as last read: whether one is equipped and the
-- projectile it shoots.
local function ReadRanged()
    ranged.present = false
    ranged.shoots = nil
    local weaponID = InventoryItemID(INVSLOT_RANGED)
    if type(weaponID) ~= "number" then return end
    local class, subclass = ItemClassOf(weaponID)
    if class == ITEM_CLASS_WEAPON and RANGED_PROJECTILE[subclass] then
        ranged.present = true
        ranged.shoots = RANGED_PROJECTILE[subclass]
    end
end

-- The ammo slot (INVSLOT_AMMO), as (itemID, count) or nil, nil.
local function ReadAmmoSlot()
    local itemID = InventoryItemID(INVSLOT_AMMO)
    if type(itemID) ~= "number" then return nil, nil end
    return itemID, InventoryCount(INVSLOT_AMMO)
end

--------------------------------------------------------------------------------
-- What the quiver needs
--------------------------------------------------------------------------------

-- The rounds of `itemID` the quiver's slots still ask for, and what they
-- hold at all. Per slot:
--   an empty slot              needs a full stack;
--   a slot of the chosen ammo  needs the top of its stack up;
--   a slot of another ammo     counts as it is: never moved, sold or
--                              replaced;
--   a locked slot              counts as it is.
-- quiver.capacity, quiver.rounds and quiver.need are filled in place.
local function ScanQuiver(itemID, stackSize)
    if type(stackSize) ~= "number" or stackSize < 1 then
        quiver.stackSize, quiver.capacity, quiver.rounds, quiver.need = nil, 0, 0, 0
        return
    end
    quiver.stackSize = stackSize
    quiver.capacity, quiver.rounds, quiver.need = 0, 0, 0
    for i = 1, quiver.bags.n do
        local bag = quiver.bags[i]
        local bagSlots = BagSlots(bag) or 0
        quiver.capacity = quiver.capacity + bagSlots * stackSize
        for slot = 1, bagSlots do
            local count, slotID, locked = BagItem(bag, slot)
            if slotID == itemID and not locked and type(count) == "number" then
                local inSlot = math.min(count, stackSize)
                quiver.rounds = quiver.rounds + inSlot
                quiver.need = quiver.need + (stackSize - inSlot)
            elseif slotID == nil and not locked then
                quiver.need = quiver.need + stackSize
            end
        end
    end
end

--------------------------------------------------------------------------------
-- The best ammo the vendor sells
--------------------------------------------------------------------------------

-- The best candidate, as last searched. found says whether the vendor sells
-- one the hunter can use; waiting says whether the search is waiting for an
-- item's details to arrive from the client's cache, and will be run again
-- when they do. others holds the usable candidates that did not come out on
-- top ({ index, itemID, name } values), for the dim green highlight, in the
-- order they were seen.
local best = {
    found = false,
    waiting = false,
    index = nil,
    itemID = nil,
    name = nil,
    texture = nil,   -- the icon, for the vendor button
    reqLevel = nil,  -- the required level, for "Best here: ... (level n)"
    stackSize = nil,
    unitPrice = nil, -- the price of one round
    others = { n = 0 },
}

-- Whether a limited stock is gone. A nil or an unlimited marker is not
-- limited. VERIFY(phase0): what the vendor's stock return reads for
-- unlimited goods (the stub answers -1); any limited 0 means gone.
local function StockGone(stock)
    if type(stock) ~= "number" then return false end
    return stock >= 0 and stock < 1
end

-- Whether `newest` rates better than `kept`: the highest required level
-- first, then the higher item level, then the lower price for one round. A
-- tie: the earlier candidate keeps it.
local function RatesBetter(newest, kept)
    if newest.reqLevel ~= kept.reqLevel then
        return newest.reqLevel > kept.reqLevel
    elseif newest.iLevel ~= kept.iLevel then
        return newest.iLevel > kept.iLevel
    elseif newest.unitPrice ~= kept.unitPrice then
        return newest.unitPrice < kept.unitPrice
    end
    return false
end

-- One candidate's own rating, reused, so the search allocates nothing.
local candidate = { reqLevel = 0, iLevel = 0, unitPrice = 0 }

-- The best ammo of `kind` the vendor sells. Every candidate must be of the
-- right projectile subclass, usable by the vendor's own flag, not above the
-- player's level, and in stock where a stock is counted. best is filled in
-- place. An item whose details the client has not cached yet is left out of
-- this pass and the search says waiting, so the caller can run it again
-- when GET_ITEM_INFO_RECEIVED comes.
local function SearchBest(kind)
    best.found = false
    best.waiting = false
    best.others.n = 0
    best.index, best.itemID, best.name, best.texture = nil, nil, nil, nil
    best.reqLevel, best.stackSize, best.unitPrice = nil, nil, nil

    local playerLevel = PlayerLevel()
    local count = NumMerchantItems() or 0

    for index = 1, count do
        local itemID = VendorID(index)
        if type(itemID) == "number" then
            local class, subclass = ItemClassOf(itemID)
            if class == ITEM_CLASS_PROJECTILE and subclass == kind then
                local name, texture, price, rounds, stock, usable =
                    MerchantItemInfo(index)
                -- VERIFY(phase0): the rounds one purchase delivers, and
                -- what the price is for. The reading here: `rounds` rounds
                -- at `price` copper the lot; a 1-round vendor line prices
                -- one round. With no rounds readable, 1.
                rounds = type(rounds) == "number" and math.max(1, math.floor(rounds)) or 1
                price = type(price) == "number" and math.max(0, price) or nil

                local data = ItemInfo(itemID)

                if data == nil then
                    -- Not in the client's cache yet: leave it out and wait.
                    best.waiting = true
                    reqLevel, iLevel, stackSize = nil, nil, nil
                else
                    reqLevel, iLevel, stackSize = data.reqLevel, data.iLevel, data.stackSize
                end

                if data ~= nil and price ~= nil and usable ~= false
                    and not StockGone(stock)
                    and (playerLevel == nil or reqLevel == nil or reqLevel <= playerLevel) then
                    candidate.reqLevel = reqLevel or 0
                    candidate.iLevel = iLevel or 0
                    candidate.unitPrice = price / rounds
                    if not best.found or RatesBetter(candidate, best) then
                        if best.found then
                            -- The last best joins the other usable ones.
                            best.others.n = best.others.n + 1
                            best.others[best.others.n] = {
                                index = best.index, itemID = best.itemID, name = best.name }
                        end
                        best.found = true
                        best.index, best.itemID, best.name = index, itemID, name
                        best.texture = texture
                        best.reqLevel, best.stackSize = reqLevel, stackSize
                        best.unitPrice = candidate.unitPrice
                    else
                        best.others.n = best.others.n + 1
                        best.others[best.others.n] = {
                            index = index, itemID = itemID, name = name }
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- What the money allows
--------------------------------------------------------------------------------

-- How many of the wanted rounds the money, the reserve and the cap allow.
-- The cap is per refill, so the copper already spent in this one counts
-- against it. 0 when not even one round fits.
local function AffordRounds(wanted, unitPrice)
    local money = PlayerMoney()
    if type(money) ~= "number" or type(unitPrice) ~= "number" or unitPrice <= 0 then
        return 0
    end

    local room = money - db.keepCopper
    if room < 0 then room = 0 end
    -- A cap of 0 means no cap. Otherwise it is the refill's whole budget.
    if db.capCopper > 0 then
        local capped = db.capCopper - shopping.spent
        if capped < 0 then capped = 0 end
        if capped < room then room = capped end
    end

    local affordable = math.floor(room / unitPrice)
    if affordable > wanted then affordable = wanted end
    return affordable < 0 and 0 or affordable
end

--------------------------------------------------------------------------------
-- The count argument
--------------------------------------------------------------------------------
-- VERIFY(phase0), answered when the owner pastes the purchase test's output,
-- which the plan's build order asks for. Until then the assumption this
-- block and the stub share:
--
--   (2026-10-17, unverified) BuyMerchantItem's count argument counts single
--   rounds; the vendor prices per round; an amount down to one round can be
--   bought in one purchase. So one purchase buys min(what the need still
--   asks, what the money allows, GetMerchantItemMaxStack) rounds, and
--   BuyCount is given them and returns them. If the game counts vendor
--   bundles instead (a whole stack per purchase, say), this one function
--   changes - the head comment above then records what the game did and on
--   which date.

local function BuyCount(rounds)
    return rounds
end

--------------------------------------------------------------------------------
-- The refill, one purchase at a time
--------------------------------------------------------------------------------
-- The need is fixed when the refill starts; the queue never buys more than
-- what is left of it, whatever bag updates arrive. That is the guard against
-- a buying loop. The next purchase goes when the game says something
-- changed: BAG_UPDATE_DELAYED or MERCHANT_UPDATE (the probe will say which
-- follows a purchase; until then both do). A purchase whose bag update does
-- not come within STEP_TIMEOUT seconds stops the refill. A safety net, not
-- logic.

-- What the menu and the button tooltip read: rounds and cost a refill would
-- buy and spend now, from the current quiver, best and money, buying
-- nothing. (rounds, cost) with rounds > 0, or nil when nothing to buy.
local function Preview()
    if not active then return nil end
    if quiver.need <= 0 then return nil end
    local rounds = AffordRounds(quiver.need, best.unitPrice)
    if rounds <= 0 then return nil end
    return rounds, math.ceil(rounds * best.unitPrice)
end

-- Done. One line for the chat when it has something to say: how much was
-- bought, what it cost, and where the quiver stands. A refill that was told
-- to stop mid-way says why.
-- Done. The bags are read once more first, so the line says where the
-- quiver stands now, not where it stood when the refill started.
local function QueueDone(stop, detail)
    shopping.active = false
    shopping.waiting = false
    shopping.pending = 0

    if shopping.kind then
        ReadQuiver()
        ScanQuiver(shopping.itemID, quiver.stackSize)
    end

    if shopping.bought <= 0 then
        if stop == "error" then
            Print(("bought nothing: the game refused the purchase (%s).")
                :format(SafeValue(detail) or "unknown reason"))
        elseif stop == "timeout" and (shopping.reason == "manual" or db.report) then
            Print(("bought nothing: no bag update followed the purchase within %d seconds.")
                :format(STEP_TIMEOUT))
        end
        return
    end

    local line = ("bought %d %s for %s."):format(
        shopping.bought, KIND_PLURAL[shopping.kind] or "ammo", MoneyText(shopping.spent))
    if stop == nil then
        line = line .. (" The quiver now holds %d / %d rounds.")
            :format(quiver.rounds, quiver.capacity)
    elseif stop == "money" then
        line = line .. " Not enough money under the reserve and the cap for more."
    elseif stop == "reserve" then
        line = line .. " The keep-gold reserve stopped it."
    elseif stop == "error" then
        line = line .. (" The game refused a purchase (%s).")
            :format(SafeValue(detail) or "unknown reason")
    elseif stop == "timeout" then
        line = line .. " No bag update came after a buy, so it stopped."
    elseif stop == "closed" then
        line = line .. " The vendor closed."
    else
        line = line .. (" The quiver now holds %d / %d rounds.")
            :format(quiver.rounds, quiver.capacity)
    end
    Print(line)
end

-- Stops the refill. Called from the events, from the timer's safety net,
-- from the reserve and from the vendor's closing.
local function QueueStop(reason, detail)
    if not shopping.active then return end
    QueueDone(reason, detail)
end

-- One purchase of the chosen ammo: at most what the need still asks for, at
-- most what one purchase holds, at most what the money under the reserve
-- and the cap allows. Then it waits for the game's own word.
local function BuyNext()
    if not (shopping.active and shopping.open) then return end
    if shopping.left <= 0 then QueueDone(nil) return end

    local affordable = AffordRounds(shopping.left, shopping.unitPrice)
    if affordable <= 0 then
        -- The money ran out (or fell short of the reserve, or used up the
        -- cap) mid-refill.
        QueueDone("money")
        return
    end

    local step = affordable
    local maxPurchase = MaxPurchase(shopping.index)
    if type(maxPurchase) == "number" and maxPurchase >= 1 and maxPurchase < step then
        step = maxPurchase
    end

    shopping.pending = step
    shopping.waiting = true
    MerchantBuy(shopping.index, BuyCount(step))
    -- The safety net this one step only: its callback reads the same state,
    -- and a step that the bag update advanced earlier is already clear.
    C_Timer.After(STEP_TIMEOUT, function()
        if shopping.waiting then QueueStop("timeout") end
    end)
end

-- A purchase's bag update came in, or the vendor's own stock changed under
-- it: the purchase is retired, and the next one goes. Nothing else advances
-- the refill.
local function StepDone()
    if not shopping.waiting then return end
    shopping.waiting = false
    shopping.bought = shopping.bought + shopping.pending
    shopping.spent = shopping.spent + Round(shopping.pending * (shopping.unitPrice or 0))
    shopping.left = shopping.left - shopping.pending
    shopping.pending = 0
    if shopping.left <= 0 then
        QueueDone(nil)
    else
        BuyNext()
    end
end

--------------------------------------------------------------------------------
-- The vendor visit
--------------------------------------------------------------------------------

-- The refill and the visit's refresh, and the events frame, all
-- forward-declared: they call each other in both directions.
local Refill
local events

-- Everything the visit draws on, read in the order the logic needs it: the
-- bag first (its kind decides, down to the weapon's kind without one), then
-- the weapon to warn against, then the best of the kind the vendor sells,
-- and then the quiver's numbers by the best item's own stack.
UpdateVisit = function()
    if not shopping.open then return end

    ReadQuiver()
    ReadRanged()
    if quiver.present and ranged.shoots and quiver.kind ~= ranged.shoots then
        if not warnedMismatch then
            warnedMismatch = true
            Print(("your quiver holds %s and your weapon does not shoot them; you may want a %s bag.")
                :format(KIND_PLURAL[quiver.kind] or "ammo",
                    quiver.kind == SUBCLASS_ARROW and "bullet" or "arrow"))
        end
    end

    local kind = quiver.kind or ranged.shoots
    SearchBest(kind)
    if best.found and best.stackSize then
        ScanQuiver(best.itemID, best.stackSize)
    else
        quiver.need = 0
    end

    -- The visit's own wait state: while the search waits for an item's
    -- details, GET_ITEM_INFO_RECEIVED is enrolled, and a deferred auto
    -- buy is remembered, because the event that clears the wait is what
    -- brings the purchase back. Three tries, and the visit goes on with
    -- what is cached.
    if infoTries >= MAX_INFO_TRIES then best.waiting = false end
    if best.waiting then
        if not shopping.watchingInfo then
            shopping.watchingInfo = true
            pcall(events.RegisterEvent, events, "GET_ITEM_INFO_RECEIVED")
        end
    elseif shopping.watchingInfo then
        shopping.watchingInfo = false
        pcall(events.UnregisterEvent, events, "GET_ITEM_INFO_RECEIVED")
    end
end

local function MaybeAutoBuy()
    if not db.autoBuy then return end
    if IsShiftKeyDown() then return end -- hold Shift to open a vendor without buying
    Refill("auto")
end

-- reason is "auto" or "manual"; a manual refill reports whatever it does,
-- since the hunter asked for it, while the auto one only speaks when the
-- Report setting is on. One refill at a time; a second call is ignored.
function Refill(reason)
    if not active then return end
    if not shopping.open then
        if reason == "manual" then
            Print("open a vendor that sells ammo to refill.")
        end
        return
    end
    if shopping.active then return end

    UpdateVisit()
    if not quiver.present then
        if reason == "manual" then
            Print("equip a quiver or ammo pouch to refill.")
        end
        return
    end
    if best.waiting then
        -- An item's details are still on their way: the visit waits, and
        -- the item info event brings the purchase back. Its handler only
        -- retries the auto buy, so a manual refill waits for another
        -- click or for the event itself.
        if reason == "auto" then shopping.autoWanted = true end
        return
    end
    if not best.found then
        if reason == "manual" or db.report then
            Print(("the vendor sells no %s you can use."):format(
                KIND_PLURAL[quiver.kind] or "ammo"))
        end
        return
    end
    if quiver.need <= 0 then
        -- Full already: the button's tooltip says so, and nothing bought.
        return
    end

    local affordable = AffordRounds(quiver.need, best.unitPrice)
    if affordable <= 0 then
        -- Not even one round under the reserve and the cap: say so and
        -- leave the queue out of it.
        if reason == "manual" or db.report then
            Print(("bought nothing: %d %s would cost %s and you have %s.")
                :format(quiver.need, KIND_PLURAL[quiver.kind] or "ammo",
                    MoneyText(math.ceil(quiver.need * best.unitPrice)),
                    MoneyText(PlayerMoney() or 0)))
        end
        return
    end

    shopping.reason = reason
    shopping.kind = quiver.kind
    shopping.index = best.index
    shopping.itemID = best.itemID
    shopping.name = best.name
    shopping.unitPrice = best.unitPrice
    -- The need is fixed now. The steps take what the money, the reserve and
    -- the cap allow of it, purchase by purchase.
    shopping.left = quiver.need
    shopping.bought = 0
    shopping.spent = 0
    shopping.pending = 0
    shopping.waiting = false
    shopping.active = true

    BuyNext()
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
-- Every setter applies at once and tells the settings page (if it is open)
-- and the vendor window (if one is), so the three places that set a setting
-- can never disagree.

local function NotifyChanged()
    if ns.OnSettingsChanged then ns.OnSettingsChanged() end
    if ns.OnVendorChanged then ns.OnVendorChanged() end
end

local function SetAutoBuy(on)
    db.autoBuy = on and true or false
    NotifyChanged()
end

local function SetHighlight(on)
    db.highlight = on and true or false
    NotifyChanged()
end

local function SetHighlightOther(on)
    db.highlightOther = on and true or false
    NotifyChanged()
end

local function SetPulse(on)
    db.pulse = on and true or false
    if not db.pulse and ns.OnVendorChanged then ns.OnVendorChanged() end
    NotifyChanged()
end

local function SetReport(on)
    db.report = on and true or false
    NotifyChanged()
end

local function SetShowButton(on)
    db.showButton = on and true or false
    NotifyChanged()
end

-- The money settings arrive in gold from the slash command and in copper
-- from the menu and the settings page; they are held in copper. Anything
-- else, and a negative number, is refused; the settings' top is MAX_GOLD.
local function SetKeepCopper(copper)
    copper = FixCopper(copper)
    if copper == nil then return end
    db.keepCopper = copper
    NotifyChanged()
end

local function SetCapCopper(copper)
    copper = FixCopper(copper)
    if copper == nil then return end
    db.capCopper = copper
    NotifyChanged()
end

local function SetKeepGold(gold)
    gold = SafeNumber(gold)
    if gold ~= nil then SetKeepCopper(Round(gold * COPPER_PER_GOLD)) end
end

local function SetCapGold(gold)
    gold = SafeNumber(gold)
    if gold ~= nil then SetCapCopper(Round(gold * COPPER_PER_GOLD)) end
end

local function ResetDefaults()
    for key, value in pairs(DEFAULTS) do
        db[key] = value
    end
    NotifyChanged()
end

--------------------------------------------------------------------------------
-- The status lines
--------------------------------------------------------------------------------

-- What the settings page's Status section says. One reused table of strings,
-- refreshed on every show of the page.
local status = {}

local function RefreshStatus()
    ReadQuiver()
    local itemID, ammoCount = ReadAmmoSlot()

    if quiver.present then
        status.quiver = quiver.name and (quiver.name .. " (bag " .. (quiver.bags[1] or "?") .. ")")
            or "a quiver or ammo pouch"
        status.kind = KIND_PLURAL[quiver.kind] and ("holds " .. KIND_PLURAL[quiver.kind]) or "unknown"
        if quiver.capacity > 0 and quiver.stackSize then
            status.rounds = ("%d / %d rounds"):format(quiver.rounds, quiver.capacity)
        else
            status.rounds = ("%d rounds"):format(quiver.rounds)
        end
    else
        status.quiver = "none equipped"
        status.kind = "-"
        status.rounds = "-"
    end

    if type(itemID) == "number" then
        local data = ItemInfo(itemID)
        local name = data and data.name or ("item " .. itemID)
        status.ammoSlot = ("%s x %s"):format(name,
            type(ammoCount) == "number" and ammoCount or "?")
    else
        status.ammoSlot = "empty"
    end
    return status
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local HELP = {
    "/ammo - open the settings page (also under Options, AddOns)",
    "/ammo status - the quiver, its rounds, and the best ammo at an open vendor",
    "/ammo refill - fill the quiver now (a vendor must be open)",
    "/ammo auto on | off - buy on opening a vendor that sells ammo",
    "/ammo highlight on | off - the gold border on the best ammo",
    "/ammo others on | off - the green border on the other usable ammo",
    "/ammo pulse on | off - the highlight's gentle pulse",
    "/ammo report on | off - one chat line when a refill is done",
    "/ammo button on | off - the vendor button in the vendor window",
    "/ammo keep <gold> - never spend below this, for example 1 or 0.5",
    "/ammo cap <gold> - the most one refill may spend; 0 for no cap",
    "/ammo reset - every setting back to how a fresh install has it",
    "Right-click the vendor button for the same options.",
}

-- Commands that only show something, so they need no hunter to make sense.
local SHOW_COMMANDS = { [""] = true, help = true, options = true, config = true, settings = true }

-- The settings page lives in Fletcher_Options.lua, which sets ns.OpenSettings.
local function OpenSettings()
    if not (ns.OpenSettings and ns.OpenSettings()) then
        Print("the settings page is not available on this client; /ammo help lists the commands.")
    end
end

-- /.ammo auto on | off, and the same shape for every boolean setting: they
-- all go through the setters in ns.API.
local TOGGLES = {
    { command = "auto",      setter = SetAutoBuy,        key = "autoBuy" },
    { command = "highlight", setter = SetHighlight,      key = "highlight" },
    { command = "others",    setter = SetHighlightOther, key = "highlightOther" },
    { command = "pulse",     setter = SetPulse,          key = "pulse" },
    { command = "report",    setter = SetReport,         key = "report" },
    { command = "button",    setter = SetShowButton,     key = "showButton" },
}

-- A gold number from a typed word: "1", "0.5", "10.25". nil for anything
-- else.
local function ParseGold(word)
    local number = word and tonumber(word:match("^(%d+%.?%d*)$") or "")
    if number == nil then return nil end
    return number
end

SLASH_FLETCHER1 = "/fletcher"
SLASH_FLETCHER2 = "/ammo"
SlashCmdList["FLETCHER"] = function(msg)
    if not db then return end -- before PLAYER_LOGIN

    local command, word = strtrim(msg or ""):lower():match("^(%S*)%s*(.-)$")

    if not SHOW_COMMANDS[command] and not active then
        Print(isHunter and "this client has no ammo to fetch, so there is nothing to refill."
            or "only a hunter carries a quiver, so there is nothing to refill on this character.")
    end

    if command == "" or command == "options" or command == "config" or command == "settings" then
        OpenSettings()
    elseif command == "help" then
        Print("a quiver refill, for hunting.")
        for _, line in ipairs(HELP) do print("  " .. line) end
    elseif command == "refill" then
        Refill("manual")
    elseif command == "keep" then
        local gold = ParseGold(word)
        if gold then
            SetKeepGold(gold)
            Print(("keeping %s on you."):format(MoneyText(db.keepCopper)))
        else
            Print("give a gold amount, for example /ammo keep 1 or /ammo keep 0.5, or 0 to spend it all.")
        end
    elseif command == "cap" then
        local gold = ParseGold(word)
        if gold then
            SetCapGold(gold)
            if db.capCopper == 0 then
                Print("the spending cap is off.")
            else
                Print(("one refill may spend at most %s."):format(MoneyText(db.capCopper)))
            end
        else
            Print("give a gold amount, for example /ammo cap 1, or 0 for no cap.")
        end
    elseif command == "reset" then
        ResetDefaults()
        Print("every setting is back to how a fresh install has it.")
    else
        local toggle
        for _, entry in ipairs(TOGGLES) do
            if entry.command == command then toggle = entry end
        end
        if toggle then
            if word == "on" or word == "off" then
                toggle.setter(word == "on")
                Print(("%s %s."):format(
                    toggle.command, db[toggle.key] and "on" or "off"))
            else
                Print(("/%s %s on or /%s %s off."):format(
                    "fletcher", toggle.command, "fletcher", toggle.command))
            end
        else
            Print("a quiver refill, for hunting.")
            for _, line in ipairs(HELP) do print("  " .. line) end
        end
    end
end

--------------------------------------------------------------------------------
-- For the settings page and the vendor window
--------------------------------------------------------------------------------
-- Fletcher_Options.lua builds its page from these, and Fletcher_Vendor.lua
-- draws from them, so the page, the right-click menu, the slash commands and
-- the vendor window can never disagree.

ns.API = {
    Version = VERSION, -- nil when the toc names none
    GetDB = function() return db end,
    Print = Print,
    MoneyText = MoneyText,
    SafeValue = SafeValue,

    -- Settings: every control goes through these.
    SetAutoBuy = SetAutoBuy,
    SetHighlight = SetHighlight,
    SetHighlightOther = SetHighlightOther,
    SetPulse = SetPulse,
    SetReport = SetReport,
    SetShowButton = SetShowButton,
    SetKeepGold = SetKeepGold,
    SetCapGold = SetCapGold,
    SetKeepCopper = SetKeepCopper,
    SetCapCopper = SetCapCopper,
    ResetDefaults = ResetDefaults,
    MAX_GOLD = MAX_GOLD,

    -- "arrows" or "bullets", or "ammo" past the two kinds.
    KindPlural = function(kind) return KIND_PLURAL[kind] or "ammo" end,
    KindSingular = function(kind) return KIND_SINGULAR[kind] or "ammo" end,

    -- The money amounts the menu offers.
    KeepChoices = function() return KEEP_CHOICES end,
    CapChoices = function() return CAP_CHOICES end,

    -- The reads the vendor window and the status section draw from. All of
    -- them are reused tables: read-only as far as the callers go.
    Quiver = function() return quiver end,
    Ranged = function() return ranged end,
    Best = function() return best end,
    VendorOpen = function() return shopping.open end,

    -- What a refill would do now, buying nothing: (rounds, cost) or nil.
    Preview = Preview,

    -- The status section's lines, refreshed when it is asked for.
    Status = RefreshStatus,

    -- Actions.
    Refill = Refill,
}

-- The vendor's highlight and button, in Fletcher_Vendor.lua. Called by the
-- setters too, so a setting shows up in an open vendor window at once.
function ns.OnVendorChanged()
    if ns.VendorRefresh then ns.VendorRefresh() end
end

function ns.VendorOpened()
    if ns.VendorShow then ns.VendorShow() end
end

function ns.VendorClosed()
    if ns.VendorHide then ns.VendorHide() end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
-- What is listened to, and at what cost:
--   at load:            PLAYER_LOGIN, and nothing else;
--   at login:           MERCHANT_SHOW and MERCHANT_CLOSED for a hunter;
--   while a vendor is:  MERCHANT_UPDATE, BAG_UPDATE_DELAYED,
--                       PLAYER_MONEY and UI_ERROR_MESSAGE, registered when
--                       it opens and dropped when it closes;
--   while waiting:      GET_ITEM_INFO_RECEIVED, registered when the search
--                       waits for the client's cache, dropped when it stops.
-- Every registration through pcall: an event the client does not have would
-- otherwise stop the rest.

local VENDOR_EVENTS = { "MERCHANT_SHOW", "MERCHANT_CLOSED" }

local IN_VENDOR_EVENTS = {
    "MERCHANT_UPDATE",
    "BAG_UPDATE_DELAYED",
    "PLAYER_MONEY",
    "UI_ERROR_MESSAGE",
}

events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        InitDB()

        -- The settings page, for every character: the settings are
        -- account-wide, so they can be set up from any of them.
        if ns.InstallSettings then ns.InstallSettings() end

        local _, classFile = UnitClass("player")
        isHunter = SafeValue(classFile) == "HUNTER"
        if not isHunter then return end

        active = true
        for _, name in ipairs(VENDOR_EVENTS) do
            pcall(self.RegisterEvent, self, name)
        end
        return
    end

    if event == "MERCHANT_SHOW" then
        for _, name in ipairs(IN_VENDOR_EVENTS) do
            pcall(self.RegisterEvent, self, name)
        end
        infoTries = 0
        warnedMismatch = false
        shopping.open = true
        shopping.autoWanted = false

        -- The visit reads first, then the vendor window's parts draw from
        -- what it read, and then the auto buy has its own go.
        UpdateVisit()
        if ns.OnVendorChanged then ns.OnVendorChanged() end
        MaybeAutoBuy()
    elseif event == "MERCHANT_UPDATE" then
        -- The vendor's own stock changed. A purchase that was out is
        -- retired, if the probe says MERCHANT_UPDATE is the event a
        -- purchase is followed by; until then both this and
        -- BAG_UPDATE_DELAYED do, and the queue's own counter keeps the
        -- total inside the need it started with.
        if shopping.waiting then StepDone() end
        UpdateVisit()
        if ns.OnVendorChanged then ns.OnVendorChanged() end
    elseif event == "BAG_UPDATE_DELAYED" then
        if shopping.waiting then StepDone() end
        UpdateVisit()
        if ns.OnVendorChanged then ns.OnVendorChanged() end
    elseif event == "MERCHANT_CLOSED" then
        -- The vendor's events go, a refill stops with the window, and the
        -- vendor window's own parts are hidden until the next one opens.
        for _, name in ipairs(IN_VENDOR_EVENTS) do
            pcall(self.UnregisterEvent, self, name)
        end
        if shopping.open and shopping.waiting then
            -- The purchase never finished: say so honestly, as bought
            -- nothing, unless something was bought already.
            shopping.waiting = false
        end
        shopping.open = false
        shopping.autoWanted = false
        if shopping.active then QueueStop("closed") end
        if ns.VendorClosed then ns.VendorClosed() end
    elseif event == "PLAYER_MONEY" then
        if shopping.active and shopping.left > 0 then
            local money = PlayerMoney()
            if money ~= nil and money < db.keepCopper then
                QueueStop("reserve")
            end
        end
    elseif event == "UI_ERROR_MESSAGE" then
        -- The game refused something. While a purchase is out, that is
        -- about the purchase (the bags are full, the money is not enough),
        -- and the refill stops with what the game said.
        if shopping.waiting then
            local detail = SafeValue(select(1, ...))
            if type(detail) ~= "string" then detail = SafeValue(select(2, ...)) end
            QueueStop("error", detail)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if not (shopping.open and shopping.watchingInfo) then return end
        infoTries = infoTries + 1
        if infoTries >= MAX_INFO_TRIES then
            -- Three goes: the visit goes on with what was cached.
            shopping.watchingInfo = false
            pcall(self.UnregisterEvent, self, "GET_ITEM_INFO_RECEIVED")
        end
        UpdateVisit()
        if shopping.autoWanted and not IsShiftKeyDown() then
            Refill("auto")
        end
    end
end)
