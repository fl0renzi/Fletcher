-- Fletcher - Fletcher.lua
-- A quiver refill for the hunter. When a hunter opens a vendor that sells
-- ammo, Fletcher finds the equipped quiver or ammo pouch, picks the best
-- arrows or bullets the vendor sells that the hunter can use, and buys a full
-- stack for every empty slot of the bag, less what the normal bags already
-- hold of that ammo. Nothing is bought for normal bags, and ammo already in a
-- slot is never moved, sold or replaced. /fletcher, or /ammo for short,
-- offers every option as a slash command.
--
-- The vendor window's own parts (the highlight, the button, the right-click
-- menu) are in Fletcher_Vendor.lua and the settings page in
-- Fletcher_Options.lua. All three change a setting through the same setter
-- in ns.API, at the end of this file.
--
-- Cost: the vendor window's parts are built on a hunter's first MERCHANT_SHOW,
-- never at load. While no vendor is open a hunter listens to MERCHANT_SHOW and
-- MERCHANT_CLOSED only. Buying is one purchase at a time, each sent when the
-- game reports the bags changed after the one before; the only timer is a
-- one-shot safety net per purchase. A character that is not a hunter stops
-- listening at login and pays nothing after that.

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
-- From Forever's own UI code (Gethe/wow-ui-source, branch forever, build
-- 1.60.1.70450), unless marked "Seen in game" (the owner's in-game probe) or
-- VERIFY: those still wait for it.

local AMMO_SLOT   = 0  -- INVSLOT_AMMO, Blizzard_FrameXMLBase/Constants.lua
local RANGED_SLOT = 18 -- INVSLOT_RANGED, the same file

-- Bags 1 to NUM_BAG_SLOTS are the equipped bags; the reagent bag after them
-- is left out. NUM_BAG_SLOTS is read at login.
local BACKPACK = 0 -- Enum.BagIndex.Backpack
local DEFAULT_BAG_SLOTS = 4

-- The projectile subclasses. The forever branch has no enum for them.
-- Seen in game on 2026-10-17: C_Item.GetItemInfoInstant gives subclass 2 for
-- Rough Arrow (2512) and 3 for Light Shot (2516).
local PROJECTILE_ARROW, PROJECTILE_BULLET = 2, 3

-- The bag family bits C_Container.GetContainerNumFreeSlots reports for a
-- quiver and an ammo pouch. Only read when the bag's own item class cannot
-- be. Seen in game on 2026-10-17: a Medium Quiver reports 1. VERIFY the ammo
-- pouch's 2 at a bullet vendor.
local FAMILY_ARROWS, FAMILY_BULLETS = 0x1, 0x2

-- The safety net: a purchase the game has not delivered after this many
-- seconds stops the refill.
local BUY_TIMEOUT = 3

-- How many times an item the vendor scan needs may come back still missing
-- before Fletcher stops waiting for it.
local MAX_ITEM_TRIES = 3

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD   = 10000
-- The most Keep gold and Spending cap take: ten thousand gold.
local MAX_COPPER = 10000 * COPPER_PER_GOLD

-- The vendor button's icon when there is no ammo to show. VERIFY in game that
-- it loads (the toc's icon is the same file).
local DEFAULT_ICON = "Interface\\Icons\\INV_Ammo_Arrow_02"

-- The colours the game's own tooltips use for a label and a hint line.
local LABEL_COLOR = { 1.0, 0.82, 0.0 }
local HINT_COLOR  = { 0.5, 0.5, 0.5 }

-- The version the toc names, which the packager writes from the release tag,
-- for example "v1.0.0". Run straight from the repository, the toc still holds
-- the packager's placeholder, and there is no version to show.
local VERSION
do
    local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata
    local version = type(GetMetadata) == "function" and GetMetadata(addonName, "Version")
    if type(version) == "string" and version ~= "" and not version:find("@", 1, true) then
        VERSION = version
    end
end

-- The two kinds of ammo. The bag decides which one is bought: a quiver holds
-- arrows, an ammo pouch holds bullets. bagSubclass is filled in at login from
-- the client's Enum.ItemQuiverSubclass.
local KINDS = {
    arrow  = { projectile = PROJECTILE_ARROW,  family = FAMILY_ARROWS,
               noun = "arrows",  holder = "quiver",     title = "Quiver" },
    bullet = { projectile = PROJECTILE_BULLET, family = FAMILY_BULLETS,
               noun = "bullets", holder = "ammo pouch", title = "Ammo pouch" },
}
local KIND_ORDER = { "arrow", "bullet" }

-- Ready-made amounts for the right-click menu, in copper.
local KEEP_PRESETS = { 0, 10 * COPPER_PER_SILVER, COPPER_PER_GOLD, 5 * COPPER_PER_GOLD,
    10 * COPPER_PER_GOLD, 50 * COPPER_PER_GOLD }
local CAP_PRESETS = { 0, 50 * COPPER_PER_SILVER, COPPER_PER_GOLD, 5 * COPPER_PER_GOLD,
    10 * COPPER_PER_GOLD }

-- What to do when the ammo slot holds better ammo than the vendor sells. The
-- key is what is saved and the slash command word.
local BETTER_CHOICES = {
    { key = "skip", name = "Buy nothing" },
    { key = "fill", name = "Fill empty slots" },
}

local DEFAULTS = {
    autoBuy        = true,
    highlight      = true,
    highlightOther = false,
    pulse          = true,
    report         = true,
    showButton     = true,
    keepCopper     = 0, -- money never goes below this
    capCopper      = 0, -- the most one refill spends; 0 means no cap
    betterAmmo     = "skip",
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local db             -- FletcherDB, set at PLAYER_LOGIN
local active = false -- a hunter, on a client with everything Fletcher reads
local isHunter = false
local lastBag = DEFAULT_BAG_SLOTS

-- The item classes Fletcher reads, from the client's enums at login.
local CLASS_WEAPON, CLASS_PROJECTILE, CLASS_QUIVER
local WEAPONS = {} -- ranged weapon subclass -> { kind, noun }

-- Everything read about the quiver, the ranged weapon, the ammo slot and the
-- open vendor, refilled in place by Evaluate. Fletcher_Vendor.lua reads it
-- and never writes it.
local scan = {
    open = false,       -- a vendor window is open
    kind = nil,         -- "arrow" or "bullet": what the equipped quiver holds
    weaponKind = nil,   -- what the ranged weapon fires, when it uses ammo
    weaponNoun = nil,   -- "bow", "crossbow" or "gun"
    bags = nil,         -- the bag numbers of the quiver(s) of `kind`
    quiverName = nil,
    quiverIcon = nil,
    sellsAmmo = false,  -- the vendor sells ammo of either kind
    best = nil,         -- the best ammo of `kind` (or the weapon's) the vendor sells
    others = {},        -- vendor index -> true, for the other usable ammo of that kind
    loading = false,    -- an item the scan needs is not cached yet
    loadedID = nil,     -- the ammo in the ammo slot
    loadedName = nil,
    loadedBetter = false, -- it beats the vendor's best
    slots = 0,          -- the quiver's slots
    emptySlots = 0,     -- the ones a refill fills
    rounds = 0,         -- rounds in the quiver, of any ammo
    need = 0,           -- a full stack of the chosen ammo per empty slot
    spare = 0,          -- rounds of the chosen ammo in the normal bags
    buyRounds = 0,      -- what a refill would buy now, within the money limits
    buyCost = 0,
    leftOut = 0,        -- rounds the money limits leave out
    limit = nil,        -- which limit: "keep", "cap" or "money"
    status = "none",    -- why a refill would or would not buy, see PlanPurchase
    message = nil,      -- the same, in words
}
ns.scan = scan

local bagsByKind = { arrow = {}, bullet = {} }
local quiverByKind = {}
local NO_BAGS = {}

-- The vendor's usable ammo, one record per item, reused from visit to visit.
local candidates = {}
local numCandidates = 0

local waiting = {}          -- item id -> true, for items the scan is missing
local itemTries = 0         -- times one came back still missing
local gaveUp = false        -- stopped waiting this visit
local autoPending = false   -- this visit's auto buy has not run yet
local manualPending = false -- a Refill click is waiting for item data
local warned = false        -- the weapon mismatch was mentioned this visit

-- The refill in progress. Its plan is fixed when it starts.
local order = {
    active = false,
    itemID = nil, name = nil, index = nil,
    price = 0, batch = 1, step = 1,
    remaining = 0,     -- rounds still to ask for; it only ever goes down
    asked = 0,         -- the purchase in flight, in rounds
    countBefore = nil, -- the item's count in the bags before it
    bought = 0, spent = 0,
    leftOut = 0, limit = nil,
    token = 0,         -- which purchase the running safety net belongs to
}

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

-- A number from the game, or nil for anything else, a secret or not a number
-- included.
local function Number(value)
    value = SafeValue(value)
    if type(value) == "number" and value == value then return value end
    return nil
end

local function Bool(value)
    return SafeValue(value) == true
end

local function Print(text)
    print("|cffffd200Fletcher:|r " .. text)
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function Wipe(list)
    for key in pairs(list) do list[key] = nil end
end

-- Whether a flag is set in a bit field, without the bit library.
local function HasBit(value, flag)
    return math.floor(value / flag) % 2 == 1
end

-- A sentence for the tooltip, as a chat line after "Fletcher:".
local function ChatLine(text)
    return text:sub(1, 1):lower() .. text:sub(2)
end

-- Copper as the game writes it in chat: "1g 2s 3c", leaving out what is zero.
local function MoneyText(copper)
    copper = math.max(0, math.floor(copper + 0.5))
    local gold = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor(copper / COPPER_PER_SILVER) % 100
    local rest = copper % COPPER_PER_SILVER
    local text = ""
    if gold > 0 then text = ("%dg"):format(gold) end
    if silver > 0 then text = text .. (text ~= "" and " " or "") .. ("%ds"):format(silver) end
    if rest > 0 or text == "" then text = text .. (text ~= "" and " " or "") .. ("%dc"):format(rest) end
    return text
end

-- Copper as a number of gold for typing: 5000 becomes "0.5".
local function GoldText(copper)
    local text = ("%.4f"):format(copper / COPPER_PER_GOLD)
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
    return text
end

-- A typed amount of gold, "1", "0.5", ".25", "2g" or, with a decimal comma,
-- "1,5", as copper; nil for anything else.
local function ParseGold(word)
    local number = tonumber(word:gsub(",", "."):match("^(%d*%.?%d+)g?$") or "")
    if not number then return nil end
    return math.floor(number * COPPER_PER_GOLD + 0.5)
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------
-- Account-wide: the Forever client writes a per-character SavedVariables file
-- but never loads it back. Everything applies live, since the beta client does
-- not reliably keep a write across a reload either.

local function ValidCopper(value)
    if type(value) ~= "number" or value ~= value then return 0 end
    return Clamp(math.floor(value + 0.5), 0, MAX_COPPER)
end

local function KnownBetter(key)
    for _, choice in ipairs(BETTER_CHOICES) do
        if choice.key == key then return true end
    end
    return false
end

local function InitDB()
    if type(FletcherDB) ~= "table" then FletcherDB = {} end
    db = FletcherDB

    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= type(value) then db[key] = value end
    end

    db.keepCopper = ValidCopper(db.keepCopper)
    db.capCopper = ValidCopper(db.capCopper)
    if not KnownBetter(db.betterAmmo) then db.betterAmmo = DEFAULTS.betterAmmo end
end

--------------------------------------------------------------------------------
-- What the client must have
--------------------------------------------------------------------------------
-- Forever is a 1.x game on the modern client: the old globals
-- (GetMerchantItemInfo, GetItemInfo, GetContainerNumFreeSlots, ...) are gone,
-- and only the C_ forms are used. Each is checked once at login; a client
-- without one gets one line and no Fletcher, never an error at a vendor.

local REQUIRED_API = {
    "C_MerchantFrame.GetItemInfo",
    "C_Item.GetItemInfo",
    "C_Item.GetItemInfoInstant",
    "C_Item.GetItemCount",
    "C_Container.GetContainerNumSlots",
    "C_Container.GetContainerItemInfo",
    "C_Container.GetContainerNumFreeSlots",
    "C_Container.ContainerIDToInventoryID",
    "GetMerchantNumItems",
    "GetMerchantItemID",
    "GetMerchantItemMaxStack",
    "BuyMerchantItem",
    "GetInventoryItemID",
    "GetInventoryItemCount",
    "UnitUsesAmmo",
    "GetMoney",
}

-- The first call the client does not have, or nil.
local function MissingAPI()
    for _, name in ipairs(REQUIRED_API) do
        local space, member = name:match("^(.-)%.(.+)$")
        local found
        if space then
            local namespace = _G[space]
            found = type(namespace) == "table" and namespace[member]
        else
            found = _G[name]
        end
        if type(found) ~= "function" then return name end
    end
    return nil
end

-- The item classes and subclasses, from the client's own enums. False when
-- one is missing.
local function ReadEnums()
    local itemClass = type(Enum) == "table" and Enum.ItemClass
    local quiverClass = type(Enum) == "table" and Enum.ItemQuiverSubclass
    local weaponClass = type(Enum) == "table" and Enum.ItemWeaponSubclass
    if type(itemClass) ~= "table" or type(quiverClass) ~= "table" or type(weaponClass) ~= "table" then
        return false
    end
    local numbers = {
        itemClass.Weapon, itemClass.Projectile, itemClass.Quiver,
        quiverClass.Quiver, quiverClass.Ammopouch,
        weaponClass.Bows, weaponClass.Crossbow, weaponClass.Guns,
    }
    for i = 1, 8 do
        if type(numbers[i]) ~= "number" then return false end
    end

    CLASS_WEAPON, CLASS_PROJECTILE, CLASS_QUIVER = itemClass.Weapon, itemClass.Projectile, itemClass.Quiver
    KINDS.arrow.bagSubclass = quiverClass.Quiver
    KINDS.bullet.bagSubclass = quiverClass.Ammopouch
    -- Thrown weapons and wands use no ammo, so they are not listed.
    WEAPONS[weaponClass.Bows] = { kind = "arrow", noun = "bow" }
    WEAPONS[weaponClass.Crossbow] = { kind = "arrow", noun = "crossbow" }
    WEAPONS[weaponClass.Guns] = { kind = "bullet", noun = "gun" }
    return true
end

--------------------------------------------------------------------------------
-- Reading items
--------------------------------------------------------------------------------
-- The only places that call the item, container and merchant APIs. Each
-- result passes through SafeValue, and anything unknown comes back as nil.

-- Class, subclass and icon, which the client answers at once, cached or not.
local function ItemClass(itemID)
    if not itemID then return nil end
    local _, _, _, _, icon, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    return Number(classID), Number(subclassID), SafeValue(icon)
end

-- Name, item level, required level and stack size. Nil until the client has
-- the item cached; asking is what makes it fetch the item, and
-- GET_ITEM_INFO_RECEIVED says when it is in.
local function ItemDetails(itemID)
    local name, _, _, itemLevel, minLevel, _, _, stackSize = C_Item.GetItemInfo(itemID)
    name = SafeValue(name)
    if type(name) ~= "string" then return nil end
    return name, Number(itemLevel) or 0, Number(minLevel) or 0, Number(stackSize)
end

-- How many of an item the bags hold, or nil when the client will not say.
local function ItemCount(itemID)
    return Number(C_Item.GetItemCount(itemID))
end

-- "arrow" or "bullet" for ammo, nil for anything else.
local function ProjectileKind(itemID)
    local classID, subclassID = ItemClass(itemID)
    if classID ~= CLASS_PROJECTILE then return nil end
    for _, kind in ipairs(KIND_ORDER) do
        if KINDS[kind].projectile == subclassID then return kind end
    end
    return nil
end

-- The item an equipped bag is, or nil for an empty bag slot.
local function BagItem(bag)
    local slot = Number(C_Container.ContainerIDToInventoryID(bag))
    if not slot then return nil end
    return Number(GetInventoryItemID("player", slot))
end

-- What a bag holds when it is a quiver or an ammo pouch, by its item class.
-- When the class cannot be read, the bag's family says it instead.
local function BagKind(bag, itemID)
    local classID, subclassID = ItemClass(itemID)
    if classID then
        if classID ~= CLASS_QUIVER then return nil end
        for _, kind in ipairs(KIND_ORDER) do
            if KINDS[kind].bagSubclass == subclassID then return kind end
        end
        return nil
    end
    local _, family = C_Container.GetContainerNumFreeSlots(bag)
    family = Number(family)
    if not family then return nil end
    for _, kind in ipairs(KIND_ORDER) do
        if HasBit(family, KINDS[kind].family) then return kind end
    end
    return nil
end

-- The vendor index of an item, which moves when the vendor's filter changes.
local function FindVendorIndex(itemID)
    local count = Number(GetMerchantNumItems()) or 0
    for index = 1, count do
        if Number(GetMerchantItemID(index)) == itemID then return index end
    end
    return nil
end

--------------------------------------------------------------------------------
-- The quiver, the weapon and the ammo slot
--------------------------------------------------------------------------------

-- What the ranged weapon fires. UnitUsesAmmo is the test the character sheet
-- makes before it shows the ammo slot.
local function ReadWeapon()
    scan.weaponKind, scan.weaponNoun = nil, nil
    if not Bool(UnitUsesAmmo("player")) then return end
    local classID, subclassID = ItemClass(Number(GetInventoryItemID("player", RANGED_SLOT)))
    if classID ~= CLASS_WEAPON then return end
    local weapon = WEAPONS[subclassID]
    if weapon then scan.weaponKind, scan.weaponNoun = weapon.kind, weapon.noun end
end

-- Finds the quiver or ammo pouch. The bag decides the kind; with one of each
-- equipped, the one the ranged weapon fills wins.
local function ReadQuivers()
    Wipe(bagsByKind.arrow)
    Wipe(bagsByKind.bullet)
    Wipe(quiverByKind)
    local first
    for bag = 1, lastBag do
        local itemID = BagItem(bag)
        local kind = itemID and BagKind(bag, itemID)
        if kind then
            local bags = bagsByKind[kind]
            bags[#bags + 1] = bag
            quiverByKind[kind] = quiverByKind[kind] or itemID
            first = first or kind
        end
    end

    local kind = first
    if scan.weaponKind and quiverByKind[scan.weaponKind] then kind = scan.weaponKind end
    scan.kind = kind
    scan.bags = kind and bagsByKind[kind] or NO_BAGS
    scan.quiverName, scan.quiverIcon = nil, nil
    if kind then
        local quiverID = quiverByKind[kind]
        scan.quiverName = ItemDetails(quiverID) or KINDS[kind].title
        scan.quiverIcon = select(3, ItemClass(quiverID))
    end
end

-- One vendor item is better ammo than another: the higher required level,
-- then the higher item level, then the cheaper single round, then the one
-- higher in the list.
local function Better(a, b)
    if a.minLevel ~= b.minLevel then return a.minLevel > b.minLevel end
    if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
    -- Price per round is price over batch, compared without fractions.
    local aRound, bRound = a.price * b.batch, b.price * a.batch
    if aRound ~= bRound then return aRound < bRound end
    return a.index < b.index
end

-- For sale for gold alone, in stock, and usable by this character.
local function ForSale(info)
    local price, batch, stock = Number(info.price), Number(info.stackCount), Number(info.numAvailable)
    return Bool(info.isUsable) and Bool(info.isPurchasable) and SafeValue(info.hasExtendedCost) == false
        and price ~= nil and price >= 0 and batch ~= nil and batch >= 1
        and stock ~= nil and stock ~= 0 -- -1 is an unlimited stock
end

-- Ranks the vendor's ammo of one kind. The list is the one the player sees,
-- after the vendor window's filter; Fletcher never changes the filter.
local function ScanVendor(kind)
    numCandidates = 0
    scan.best, scan.sellsAmmo = nil, false
    Wipe(scan.others)
    if not scan.open then return end

    local level = Number(UnitLevel("player"))
    local count = Number(GetMerchantNumItems()) or 0
    for index = 1, count do
        local itemID = Number(GetMerchantItemID(index))
        local itemKind = ProjectileKind(itemID)
        if itemKind then scan.sellsAmmo = true end

        local info = itemKind and itemKind == kind and SafeValue(C_MerchantFrame.GetItemInfo(index))
        if type(info) == "table" and ForSale(info) then
            local name, itemLevel, minLevel, stackSize = ItemDetails(itemID)
            if not name then
                waiting[itemID] = true
            elseif stackSize and stackSize >= 1 and (not level or minLevel <= level) then
                numCandidates = numCandidates + 1
                local record = candidates[numCandidates]
                if not record then
                    record = {}
                    candidates[numCandidates] = record
                end
                record.index, record.itemID, record.name = index, itemID, name
                record.texture = SafeValue(info.texture)
                record.price = Number(info.price)
                record.batch = math.floor(Number(info.stackCount))
                record.itemLevel, record.minLevel, record.stackSize = itemLevel, minLevel, stackSize
                -- The most rounds one BuyMerchantItem call buys. The game's
                -- own stack split caps its total at this, in rounds. Seen in
                -- game on 2026-10-17: 200 for every arrow, one vendor batch.
                record.maxStack = Number(GetMerchantItemMaxStack(index))
                if not scan.best or Better(record, scan.best) then scan.best = record end
            end
        end
    end

    for i = 1, numCandidates do
        local record = candidates[i]
        if record ~= scan.best then scan.others[record.index] = true end
    end
end

-- The ammo in the ammo slot, and whether it beats the vendor's best: then it
-- is crafted, reputation or raid ammo the hunter chose on purpose.
local function ReadLoadedAmmo()
    local loadedID = Number(GetInventoryItemID("player", AMMO_SLOT))
    scan.loadedID, scan.loadedName, scan.loadedBetter = loadedID, nil, false
    if not loadedID then return end

    local name, itemLevel, minLevel = ItemDetails(loadedID)
    if not name then
        waiting[loadedID] = true
        return
    end
    scan.loadedName = name

    local best = scan.best
    if best and scan.kind and loadedID ~= best.itemID and ProjectileKind(loadedID) == scan.kind then
        scan.loadedBetter = minLevel > best.minLevel
            or (minLevel == best.minLevel and itemLevel > best.itemLevel)
    end
end

-- Walks every slot of the quiver. A refill goes by the slots, not by how
-- many rounds the quiver could hold: each empty slot gets one full stack.
-- Seen in game on 2026-10-17: a bought batch of 200 Razor Arrows did not go
-- on top of a stack of 90 in the quiver; it took an empty slot, and with none
-- free it went into a normal bag, so the stack stayed at 90 and every visit
-- bought another 200. So a part stack, like other ammo or a locked slot,
-- needs nothing and is left alone. Returns the slots, the empty ones and the
-- rounds in the quiver.
local function ReadQuiver()
    local slots, empty, rounds = 0, 0, 0
    for _, bag in ipairs(scan.bags) do
        local numSlots = Number(C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, numSlots do
            slots = slots + 1
            local info = SafeValue(C_Container.GetContainerItemInfo(bag, slot))
            if type(info) ~= "table" then
                empty = empty + 1
            else
                rounds = rounds + (Number(info.stackCount) or 0)
            end
        end
    end
    return slots, empty, rounds
end

local function IsQuiverBag(bag)
    for _, quiverBag in ipairs(scan.bags) do
        if quiverBag == bag then return true end
    end
    return false
end

-- Rounds of an item in the backpack and the equipped bags that are not the
-- quiver. They count toward the need: Fletcher does not buy what the hunter
-- already carries, and a purchase the game put in a normal bag is never
-- bought again on the next visit.
local function SpareRounds(itemID)
    if not itemID then return 0 end
    local spare = 0
    for bag = BACKPACK, lastBag do
        if not IsQuiverBag(bag) then
            local numSlots = Number(C_Container.GetContainerNumSlots(bag)) or 0
            for slot = 1, numSlots do
                local info = SafeValue(C_Container.GetContainerItemInfo(bag, slot))
                if type(info) == "table" and Number(info.itemID) == itemID then
                    spare = spare + (Number(info.stackCount) or 0)
                end
            end
        end
    end
    return spare
end

--------------------------------------------------------------------------------
-- What a refill buys
--------------------------------------------------------------------------------
-- From the source: BuyMerchantItem(index, quantity) takes a number of rounds,
-- and the game's own vendor window only ever passes whole vendor batches (its
-- stack split steps by the batch, stackCount). The server takes part of a
-- batch too. Seen in game on 2026-10-17: BuyMerchantItem(i, 50) for Rough
-- Arrow, sold 200 for 9c, delivered 50 arrows and took 3c.
local PARTIAL_BATCHES = true

-- The only place that turns the rounds a quiver needs into what is bought.
-- With part batches, that is the need itself. In whole batches, the need is
-- rounded up, so the empty slots always end full and the few rounds over
-- land in a normal bag; but less than half a batch buys nothing, so a need
-- the bags almost cover is not sold a batch.
local function BuyCount(rounds, batch)
    if PARTIAL_BATCHES then return rounds end
    if rounds * 2 < batch then return 0 end
    return math.ceil(rounds / batch) * batch
end

-- What rounds of an item cost. The vendor's price is for one whole batch,
-- and part of a batch costs its share rounded up to the copper (seen in game
-- on 2026-10-17: 50 of 200 for 9c, 2.25c, took 3c).
local function Cost(rounds, item)
    if PARTIAL_BATCHES then return math.ceil(rounds * item.price / item.batch) end
    return math.ceil(rounds / item.batch) * item.price
end

-- The most rounds a sum of copper buys.
local function AffordableRounds(budget, item)
    if item.price <= 0 then return math.huge end
    if budget <= 0 then return 0 end
    if PARTIAL_BATCHES then return math.floor(budget * item.batch / item.price) end
    return math.floor(budget / item.price) * item.batch
end

-- The most rounds one purchase asks for.
local function StepRounds(item)
    local step = item.maxStack
    if not step or step < 1 then step = item.batch end
    if not PARTIAL_BATCHES then
        step = math.max(item.batch, math.floor(step / item.batch) * item.batch)
    end
    return step
end

local function SetStatus(status, message)
    scan.status, scan.message = status, message
end

-- Why a money limit left rounds out, as a sentence.
local function LeftOutText(rounds, limit)
    if limit == "keep" then
        return ("Left out %d to keep %s."):format(rounds, MoneyText(db.keepCopper))
    elseif limit == "cap" then
        return ("Left out %d to stay under the %s spending cap."):format(rounds, MoneyText(db.capCopper))
    end
    return ("Left out %d you cannot afford."):format(rounds)
end

-- What a refill would buy now, and why when it is nothing. The status is one
-- of: noquiver, loading, noammo, better, full, inbags, nearlyfull, money or
-- ready.
local function PlanPurchase()
    scan.buyRounds, scan.buyCost, scan.leftOut, scan.limit = 0, 0, 0, nil
    local best = scan.best

    if not scan.kind then
        return SetStatus("noquiver", "Equip a quiver or ammo pouch to refill.")
    end
    local kind = KINDS[scan.kind]
    if scan.loading then
        return SetStatus("loading", "Waiting for the game to load the vendor's ammo.")
    end
    if not best then
        return SetStatus("noammo", ("This vendor sells no %s you can use."):format(kind.noun))
    end
    if scan.loadedBetter and db.betterAmmo == "skip" then
        return SetStatus("better", ("Your %s beat anything sold here."):format(scan.loadedName))
    end
    if scan.need <= 0 then
        return SetStatus("full", ("Your %s has no empty slot."):format(kind.holder))
    end

    local need = scan.need - scan.spare
    local rounds = need > 0 and BuyCount(need, best.batch) or 0
    if rounds <= 0 then
        if scan.spare > 0 then
            return SetStatus("inbags", ("Your bags already hold %d %s. Move them into your %s.")
                :format(scan.spare, best.name, kind.holder))
        end
        return SetStatus("nearlyfull", ("Your %s is nearly full."):format(kind.holder))
    end

    -- Keep gold is never spent; the spending cap is the most one refill spends.
    local budget = (Number(GetMoney()) or 0) - db.keepCopper
    local limit = db.keepCopper > 0 and "keep" or "money"
    if db.capCopper > 0 and db.capCopper < budget then
        budget, limit = db.capCopper, "cap"
    end
    local affordable = AffordableRounds(budget, best)
    if affordable < rounds then
        scan.leftOut, scan.limit = rounds - affordable, limit
        rounds = affordable
    end

    if rounds <= 0 then
        if limit == "keep" then
            return SetStatus("money", ("Not enough money for %d %s while keeping %s.")
                :format(best.batch, best.name, MoneyText(db.keepCopper)))
        elseif limit == "cap" then
            return SetStatus("money", ("The %s spending cap does not cover %d %s.")
                :format(MoneyText(db.capCopper), best.batch, best.name))
        end
        return SetStatus("money", ("Not enough money for %d %s."):format(best.batch, best.name))
    end

    scan.buyRounds, scan.buyCost = rounds, Cost(rounds, best)
    return SetStatus("ready", nil)
end

-- Watches for the items the scan is missing while a vendor is open, and only
-- then.
local function WatchItems(frame)
    if scan.loading then
        pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")
    else
        pcall(frame.UnregisterEvent, frame, "GET_ITEM_INFO_RECEIVED")
    end
end

local events -- the events frame, made at the end of this file

-- The one place everything is read: the weapon, the quiver, the vendor, the
-- ammo slot, the need and what a refill would buy, into `scan`.
local function Evaluate()
    if not active then return end
    Wipe(waiting)
    ReadWeapon()
    ReadQuivers()
    -- Without a quiver, the highlight still marks the best ammo for the weapon.
    ScanVendor(scan.kind or scan.weaponKind)
    ReadLoadedAmmo()
    scan.loading = scan.open and not gaveUp and next(waiting) ~= nil

    local best = scan.best
    scan.slots, scan.emptySlots, scan.rounds = ReadQuiver()
    scan.need = best and scan.emptySlots * best.stackSize or 0
    scan.spare = SpareRounds(best and best.itemID)

    PlanPurchase()
    if scan.open then WatchItems(events) end
end

--------------------------------------------------------------------------------
-- Lines for the tooltip and /ammo status
--------------------------------------------------------------------------------

-- "Medium Quiver, 8 / 10 slots, 1490 arrows": the slots in use, then the
-- rounds in them. Nil without a quiver.
local function QuiverLine()
    if not scan.kind then return nil end
    return ("%s, %d / %d slots, %d %s"):format(scan.quiverName, scan.slots - scan.emptySlots,
        scan.slots, scan.rounds, KINDS[scan.kind].noun)
end

-- "Razor Arrow (level 25)", or nil when the vendor sells nothing that fits.
local function BestLine()
    local best = scan.best
    if not best then return nil end
    if best.minLevel > 0 then return ("%s (level %d)"):format(best.name, best.minLevel) end
    return best.name
end

-- "600 for 1s 50c", or nil when a refill would buy nothing.
local function RefillLine()
    if scan.status ~= "ready" then return nil end
    return ("%d for %s"):format(scan.buyRounds, MoneyText(scan.buyCost))
end

-- "Your quiver holds arrows but your gun fires bullets.", or nil.
local function MismatchLine()
    if not (scan.kind and scan.weaponKind and scan.kind ~= scan.weaponKind) then return nil end
    local kind = KINDS[scan.kind]
    return ("Your %s holds %s but your %s fires %s."):format(kind.holder, kind.noun,
        scan.weaponNoun, KINDS[scan.weaponKind].noun)
end

-- The ammo slot: "Razor Arrow, 1650", "Empty", or nil when the name is not in.
local function LoadedLine()
    if not scan.loadedID then return "Empty" end
    if not scan.loadedName then return nil end
    -- The character sheet's ammo count. Seen in game on 2026-10-17: it counts
    -- the rounds in every bag, as in the 1.x game (1800 with one of nine
    -- stacks moved out of the quiver, the same as C_Item.GetItemCount).
    local count = Number(GetInventoryItemCount("player", AMMO_SLOT))
    if count then return ("%s, %d"):format(scan.loadedName, count) end
    return scan.loadedName
end

-- Label and value pairs for /ammo status and the settings page, read fresh.
local function StatusLines()
    local lines = {}
    if not active then
        lines[1] = { "Status", isHunter and "This client lacks what Fletcher reads." or "Only hunters use ammo." }
        return lines
    end
    Evaluate()
    lines[#lines + 1] = { "Quiver", QuiverLine() or "No quiver or ammo pouch equipped" }
    lines[#lines + 1] = { "Ammo slot", LoadedLine() or "Loading" }
    if scan.open then
        lines[#lines + 1] = { "Best here", BestLine() or "Nothing that fits" }
        lines[#lines + 1] = { "Refill", RefillLine() or scan.message or "" }
    end
    return lines
end

--------------------------------------------------------------------------------
-- The refill, one purchase at a time
--------------------------------------------------------------------------------
-- Never more than the plan made at the start of the refill, whatever the bag
-- updates say: order.remaining only ever goes down. That is the guard
-- against a buying loop.

local function NotifyVendor()
    if ns.OnScanChanged then ns.OnScanChanged() end
end

-- "bought 1400 Razor Arrow for 3s 50c."
local function BoughtText()
    return ("bought %d %s for %s."):format(order.bought, order.name, MoneyText(order.spent))
end

-- "Quiver full (10 / 10 slots)." or "Quiver 8 / 10 slots."
local function QuiverStateText()
    local kind = scan.kind and KINDS[scan.kind]
    if not kind or scan.slots <= 0 then return nil end
    local used = scan.slots - scan.emptySlots
    if scan.emptySlots == 0 then
        return ("%s full (%d / %d slots)."):format(kind.title, used, scan.slots)
    end
    return ("%s %d / %d slots."):format(kind.title, used, scan.slots)
end

-- One line in chat when a refill ends. A refill that ran to its end reports
-- only with Report purchases on; one that was stopped always says why.
local function ReportRefill(why, detail)
    local bought = order.bought > 0 and (" " .. (BoughtText():gsub("^b", "B"))) or ""
    if why == "done" or why == "closed" then
        if not db.report or order.bought == 0 then return end
        local text = BoughtText()
        local state = why == "done" and QuiverStateText()
        if state then text = text .. " " .. state end
        if order.leftOut > 0 then text = text .. " " .. LeftOutText(order.leftOut, order.limit) end
        Print(text)
    elseif why == "money" then
        Print(("stopped buying to keep %s.%s"):format(MoneyText(db.keepCopper), bought))
    elseif why == "error" then
        local message = type(detail) == "string" and (detail:gsub("%.$", "")) or "the game refused a purchase"
        Print(("stopped buying: %s.%s"):format(message, bought))
    elseif why == "timeout" then
        Print("the vendor did not answer, so buying stopped." .. bought)
    elseif why == "gone" then
        Print(("%s is no longer in the vendor's list, so buying stopped.%s"):format(order.name, bought))
    end
end

local function FinishRefill(why, detail)
    if not order.active then return end
    order.active = false
    order.asked = 0
    order.token = order.token + 1 -- the last safety net no longer applies
    if scan.open then Evaluate() end
    ReportRefill(why, detail)
    NotifyVendor()
end

local function BuyNext()
    if order.remaining <= 0 then return FinishRefill("done") end

    -- The money as it is now, with Keep gold still kept.
    local amount = math.min(order.remaining, order.step)
    local affordable = AffordableRounds((Number(GetMoney()) or 0) - db.keepCopper, order)
    if affordable < amount then
        amount = affordable
        if amount <= 0 then return FinishRefill("money") end
    end

    -- The list follows the vendor window's filter, so the item may have moved.
    local index = order.index
    if Number(GetMerchantItemID(index)) ~= order.itemID then
        index = FindVendorIndex(order.itemID)
        if not index then return FinishRefill("gone") end
        order.index = index
    end

    order.countBefore = ItemCount(order.itemID)
    order.asked = amount
    order.remaining = order.remaining - amount
    order.token = order.token + 1
    local token = order.token
    BuyMerchantItem(index, amount)

    -- The safety net, not logic: a purchase that never lands stops the refill.
    C_Timer.After(BUY_TIMEOUT, function()
        if order.active and order.token == token then FinishRefill("timeout") end
    end)
end

-- BAG_UPDATE_DELAYED during a refill: the purchase in flight has landed when
-- the item's count went up. A bag update from anything else is waited out.
local function OnPurchaseLanded()
    if not (order.active and order.asked > 0) then return end
    local now = ItemCount(order.itemID)
    if order.countBefore and now and now <= order.countBefore then return end
    order.bought = order.bought + order.asked
    order.spent = order.spent + Cost(order.asked, order)
    order.asked = 0
    BuyNext()
end

-- Starts a refill from what Evaluate reads right now. Manual is a click on the
-- vendor button, /ammo refill or the menu; anything else is the auto buy,
-- which keeps quiet about why it bought nothing, money aside.
local function Refill(manual)
    if not active then
        if manual then
            Print(isHunter and "this client lacks what Fletcher reads, so it cannot buy."
                or "only hunters use ammo.")
        end
        return false
    end
    if not scan.open then
        if manual then Print("talk to a vendor that sells ammo first.") end
        return false
    end
    if order.active then return false end
    if manual then autoPending = false end

    Evaluate()
    if scan.status == "loading" then
        if manual then
            manualPending = true
            Print("waiting for the game to load the vendor's ammo; Fletcher buys as soon as it has.")
        end
        return false
    end
    if scan.status ~= "ready" then
        if manual or (scan.status == "money" and db.report) then Print(ChatLine(scan.message)) end
        NotifyVendor()
        return false
    end

    local best = scan.best
    order.active = true
    order.itemID, order.name, order.index = best.itemID, best.name, best.index
    order.price, order.batch, order.step = best.price, best.batch, StepRounds(best)
    order.remaining = scan.buyRounds
    order.asked, order.countBefore = 0, nil
    order.bought, order.spent = 0, 0
    order.leftOut, order.limit = scan.leftOut, scan.limit
    BuyNext()
    NotifyVendor()
    return true
end

-- The auto buy runs once per vendor visit, as soon as the vendor's list and
-- the items in it are in.
local function TryAuto()
    if not autoPending or order.active then return end
    local count = Number(GetMerchantNumItems())
    if not count or count == 0 then return end -- MERCHANT_UPDATE brings the list
    if scan.loading then return end            -- GET_ITEM_INFO_RECEIVED brings the items
    autoPending = false
    Refill(false)
end

-- Says once per visit, at a vendor that sells ammo, that the quiver and the
-- weapon disagree. The bag still decides what is bought.
local function WarnMismatch()
    if warned or not scan.sellsAmmo then return end
    local line = MismatchLine()
    if not line then return end
    warned = true
    Print(ChatLine(line))
end

-- After anything at an open vendor that may change what is read.
local function Update()
    Evaluate()
    WarnMismatch()
    TryAuto()
    NotifyVendor()
end

-- An item the scan was missing came in, or came back still missing. After
-- MAX_ITEM_TRIES of those, Fletcher stops waiting for this visit, and a
-- refill that was waiting is dropped.
local function OnItemInfo(itemID)
    itemID = Number(itemID)
    if not (itemID and waiting[itemID]) then return end
    Evaluate()
    if waiting[itemID] then
        itemTries = itemTries + 1
        if itemTries >= MAX_ITEM_TRIES then
            gaveUp = true
            if autoPending or manualPending then
                Print("the game did not load the vendor's ammo, so nothing was bought.")
            end
            autoPending, manualPending = false, false
            Evaluate()
        end
    end
    if manualPending and not scan.loading then
        manualPending = false
        Refill(true)
    end
    Update()
end

--------------------------------------------------------------------------------
-- Changing settings
--------------------------------------------------------------------------------
-- Every setter changes the saved value and tells the settings page and the
-- vendor window, which redraw only while they are showing.

local function NotifyChanged()
    if ns.OnSettingsChanged then ns.OnSettingsChanged() end
    -- Keep gold, the cap and the better ammo choice change what a refill buys.
    if scan.open then Evaluate() end
    NotifyVendor()
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

local function SetKeepCopper(copper)
    db.keepCopper = ValidCopper(copper)
    NotifyChanged()
end

local function SetCapCopper(copper)
    db.capCopper = ValidCopper(copper)
    NotifyChanged()
end

local function SetBetterAmmo(key)
    if not KnownBetter(key) then return end
    db.betterAmmo = key
    NotifyChanged()
end

-- The settings page's Defaults and /ammo reset: every setting back to how a
-- fresh install has it.
local function ResetDefaults()
    for key, value in pairs(DEFAULTS) do db[key] = value end
    NotifyChanged()
end

-- The settings page lives in Fletcher_Options.lua, which sets ns.OpenSettings.
local function OpenSettings()
    if not (ns.OpenSettings and ns.OpenSettings()) then
        Print("the settings page is not available on this client; /ammo help lists the commands.")
    end
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local HELP = {
    "/ammo - open the settings page (also under Options, AddOns)",
    "/ammo help - list these commands",
    "/ammo status - your quiver, its rounds, and the best ammo at the open vendor",
    "/ammo refill - fill the quiver now (talk to a vendor first)",
    "/ammo auto on | off - buy when you talk to a vendor that sells your ammo",
    "/ammo highlight on | off - mark the best ammo in the vendor window",
    "/ammo others on | off - mark the other ammo you can use, in green",
    "/ammo pulse on | off - the proc glow on the best ammo, or a still glow",
    "/ammo report on | off - say in chat what was bought",
    "/ammo button on | off - the Fletcher button in the vendor window",
    "/ammo keep <gold> - money a refill never touches, for example 1, 0.5 or 0",
    "/ammo cap <gold> - the most one refill spends, 0 for no cap",
    "/ammo better skip | fill - when your loaded ammo beats the vendor's",
    "/ammo reset - every setting back to its default",
    "Right-click the Fletcher button in the vendor window for the same options.",
}

-- The on and off commands: the setting, its setter and what to say.
local SWITCHES = {
    auto = { key = "autoBuy", set = SetAutoBuy,
        on = "auto buy on: talking to a vendor that sells your ammo fills the quiver.",
        off = "auto buy off: click the Fletcher button in the vendor window to refill." },
    highlight = { key = "highlight", set = SetHighlight,
        on = "the best ammo is marked in the vendor window.",
        off = "the best ammo is no longer marked." },
    others = { key = "highlightOther", set = SetHighlightOther,
        on = "the other ammo you can use is marked in green.",
        off = "only the best ammo is marked." },
    pulse = { key = "pulse", set = SetPulse,
        on = "the best ammo gets the proc glow.",
        off = "the best ammo keeps a still gold glow." },
    report = { key = "report", set = SetReport,
        on = "purchases are reported in chat.",
        off = "purchases are no longer reported in chat." },
    button = { key = "showButton", set = SetShowButton,
        on = "the Fletcher button shows in the vendor window.",
        off = "the Fletcher button is hidden; /ammo refill still refills." },
}

local function PrintStatus()
    local lines = StatusLines()
    Print("your ammo:")
    for _, line in ipairs(lines) do
        print(("  %s: %s"):format(line[1], line[2]))
    end
end

SLASH_FLETCHER1 = "/fletcher"
SLASH_FLETCHER2 = "/ammo"
SlashCmdList["FLETCHER"] = function(msg)
    if not db then return end -- before PLAYER_LOGIN

    local command, word = strtrim(msg or ""):lower():match("^(%S*)%s*(.-)$")
    local switch = SWITCHES[command]

    if command == "" or command == "options" or command == "config" or command == "settings" then
        OpenSettings()
    elseif command == "status" then
        PrintStatus()
    elseif command == "refill" then
        Refill(true)
    elseif switch then
        if word == "on" or word == "off" then
            switch.set(word == "on")
            Print(db[switch.key] and switch.on or switch.off)
        else
            Print(("use /ammo %s on or /ammo %s off."):format(command, command))
        end
    elseif command == "keep" or command == "cap" then
        local copper = ParseGold(word)
        if command == "keep" and copper then
            SetKeepCopper(copper)
            Print(db.keepCopper > 0 and ("a refill always leaves you %s."):format(MoneyText(db.keepCopper))
                or "a refill may spend all your money.")
        elseif copper then
            SetCapCopper(copper)
            Print(db.capCopper > 0 and ("one refill spends at most %s."):format(MoneyText(db.capCopper))
                or "a refill spends what filling the quiver costs, with no cap.")
        else
            Print(("give an amount of gold, for example /ammo %s 1 or /ammo %s 0.5."):format(command, command))
        end
    elseif command == "better" then
        if KnownBetter(word) then
            SetBetterAmmo(word)
            Print(word == "skip" and "when your loaded ammo beats the vendor's, nothing is bought."
                or "when your loaded ammo beats the vendor's, only the empty slots are filled.")
        else
            Print("use /ammo better skip or /ammo better fill.")
        end
    elseif command == "reset" then
        ResetDefaults()
        Print("every setting is back to its default.")
    else
        Print("fills your quiver or ammo pouch at the vendor.")
        for _, line in ipairs(HELP) do print("  " .. line) end
    end
end

--------------------------------------------------------------------------------
-- For the vendor window and the settings page
--------------------------------------------------------------------------------
-- Fletcher_Vendor.lua and Fletcher_Options.lua build on these, so the menu,
-- the page and the slash commands all change a setting through the same
-- setter.

ns.API = {
    Version = VERSION, -- nil when the toc names none
    GetDB = function() return db end,
    Print = Print,
    IsActive = function() return active end,
    IsBuying = function() return order.active end,

    Refill = function() return Refill(true) end,
    QuiverLine = QuiverLine,
    BestLine = BestLine,
    RefillLine = RefillLine,
    MismatchLine = MismatchLine,
    LeftOutText = LeftOutText,
    StatusLines = StatusLines,
    MoneyText = MoneyText,
    GoldText = GoldText,
    ParseGold = ParseGold,
    OpenSettings = OpenSettings,

    SetAutoBuy = SetAutoBuy,
    SetHighlight = SetHighlight,
    SetHighlightOther = SetHighlightOther,
    SetPulse = SetPulse,
    SetReport = SetReport,
    SetShowButton = SetShowButton,
    SetKeepCopper = SetKeepCopper,
    SetCapCopper = SetCapCopper,
    SetBetterAmmo = SetBetterAmmo,
    ResetDefaults = ResetDefaults,

    KEEP_PRESETS = KEEP_PRESETS,
    CAP_PRESETS = CAP_PRESETS,
    BETTER_CHOICES = BETTER_CHOICES,
    COPPER_PER_GOLD = COPPER_PER_GOLD,
    MAX_COPPER = MAX_COPPER,
    DEFAULT_ICON = DEFAULT_ICON,
    LABEL_COLOR = LABEL_COLOR,
    HINT_COLOR = HINT_COLOR,
}

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- What a hunter listens to while a vendor is open, and only then. Each is
-- registered through pcall: registering an event the client does not have
-- raises an error, and one missing event must not stop the rest.
local VENDOR_EVENTS = {
    "MERCHANT_UPDATE",
    "MERCHANT_FILTER_ITEM_UPDATE",
    "BAG_UPDATE_DELAYED",
    "UI_ERROR_MESSAGE",
    "PLAYER_MONEY",
}

local function OnVendorShow()
    scan.open = true
    warned, itemTries, gaveUp, manualPending = false, 0, false, false
    for _, name in ipairs(VENDOR_EVENTS) do
        pcall(events.RegisterEvent, events, name)
    end
    if ns.BuildVendorUI then ns.BuildVendorUI() end
    -- Holding Shift while talking to the vendor skips the auto buy.
    autoPending = db.autoBuy and not Bool(IsShiftKeyDown())
    Update()
end

local function OnVendorClosed()
    if not scan.open then return end
    scan.open = false
    FinishRefill("closed")
    autoPending, manualPending = false, false
    for _, name in ipairs(VENDOR_EVENTS) do
        pcall(events.UnregisterEvent, events, name)
    end
    pcall(events.UnregisterEvent, events, "GET_ITEM_INFO_RECEIVED")
    Wipe(waiting)
    scan.best, scan.loading = nil, false
    Wipe(scan.others)
    NotifyVendor()
end

events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        InitDB()

        -- The settings page, for every character: the settings are account
        -- wide, so they can be set up from any of them.
        if ns.InstallSettings then ns.InstallSettings() end

        local _, classFile = UnitClass("player")
        isHunter = SafeValue(classFile) == "HUNTER"
        if not isHunter then return end

        local missing = MissingAPI() or (not ReadEnums() and "Enum.ItemClass")
        if missing then
            Print(("this client has no %s, so Fletcher stays off."):format(missing))
            return
        end
        lastBag = Number(NUM_BAG_SLOTS) or DEFAULT_BAG_SLOTS

        active = true
        pcall(self.RegisterEvent, self, "MERCHANT_SHOW")
        pcall(self.RegisterEvent, self, "MERCHANT_CLOSED")
        return
    end

    if event == "MERCHANT_SHOW" then
        OnVendorShow()
    elseif event == "MERCHANT_CLOSED" then
        OnVendorClosed()
    elseif not scan.open then
        return
    elseif event == "BAG_UPDATE_DELAYED" then
        OnPurchaseLanded()
        Update()
    elseif event == "UI_ERROR_MESSAGE" then
        local _, message = ...
        FinishRefill("error", SafeValue(message))
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        OnItemInfo((...))
    else
        -- MERCHANT_UPDATE, MERCHANT_FILTER_ITEM_UPDATE and PLAYER_MONEY.
        Update()
    end
end)
