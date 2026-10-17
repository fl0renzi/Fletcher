-- Fletcher - tests/spec.lua
-- Behaviour tests for the addon, run on top of tests/wow_stub.lua. Every test
-- boots a fresh session with __boot, so no test depends on another.

local passed, failed = 0, 0

local function test(name, body)
    local ok, err = pcall(body)
    if ok then
        passed = passed + 1
        __print("ok   " .. name)
    else
        failed = failed + 1
        __print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error((label and (label .. ": ") or "") .. "expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(value, label)
    if not value then error(label or "expected a true value", 2) end
end

local function assert_false(value, label)
    if value then error(label or "expected a false value", 2) end
end

local function has_line(lines, wanted)
    for _, line in ipairs(lines) do
        if line == wanted then return true end
    end
    return false
end

local function lines_text(lines)
    return table.concat(lines, " // ")
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local SILVER, GOLD = 100, 10000

local BOW, GUN, CROSSBOW, KNIFE = 2504, 2508, 15808, 2947
local QUIVER, POUCH, BAG = 2101, 2102, 4496
local ROUGH, SHARP, RAZOR, JAGGED, THORIUM_ARROW = 2512, 2515, 3030, 11285, 18042
local LIGHT, HEAVY, SOLID, SLUGS = 2516, 2519, 3033, 11284
local WATER = 159

local function quiver(slots, contents, itemID)
    return { item = itemID or QUIVER, slots = slots or 4, contents = contents or {} }
end

local function pouch(slots, contents)
    return quiver(slots, contents, POUCH)
end

local function backpack()
    return { slots = 16, contents = {} }
end

-- The 1.x arrow vendor, with water among the ammo: 200 arrows a batch.
local function arrowVendor()
    return {
        { id = WATER, price = 25, batch = 1 },
        { id = ROUGH, price = 10 },
        { id = SHARP, price = 50 },
        { id = RAZOR, price = 100 },
        { id = JAGGED, price = 400 },
    }
end

local function bulletVendor()
    return {
        { id = LIGHT, price = 10 },
        { id = HEAVY, price = 50 },
        { id = SOLID, price = 100 },
        { id = SLUGS, price = 400 },
    }
end

-- A level 30 hunter with a bow, ten gold and an empty 4 slot quiver, unless
-- told otherwise.
local function hunter(options)
    local boot = {
        level = 30, money = 10 * GOLD, ranged = BOW,
        bags = { [0] = backpack(), [1] = quiver(4) },
    }
    for key, value in pairs(options or {}) do boot[key] = value end
    return __boot(boot)
end

local function button() return FletcherVendorButton end

local function hover_button()
    __script(button(), "OnEnter")
    return GameTooltip.__lines
end

local function click_button(mouseButton)
    __script(button(), "OnClick", mouseButton or "LeftButton")
end

local function slash(text)
    SlashCmdList.FLETCHER(text)
end

--------------------------------------------------------------------------------
-- The gate and login
--------------------------------------------------------------------------------

test("the gate leaves the addon inert on another client", function()
    local saved = { autoBuy = false, keepCopper = 99 }
    local ns = __boot({ interface = 11507, db = saved, level = 30, ranged = BOW,
        bags = { [0] = backpack(), [1] = quiver(4) } })
    assert_eq(ns.Allowed, false)
    assert_eq(FletcherDB, saved, "saved table replaced")
    assert_eq(saved.keepCopper, 99, "saved settings rewritten")
    assert_eq(SlashCmdList.FLETCHER, nil, "slash command registered")
    assert_eq(__frame_count(), __base_frames, "frames created on another client")
    assert_true(__printed("disabled on this client"), "no message")
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought on another client")
end)

test("the gate fails open when the interface cannot be read", function()
    local ns = hunter({ interface = "unknown" })
    assert_eq(ns.Allowed, true)
    __open_vendor(arrowVendor())
    assert_true(#__buy_log > 0, "nothing bought")
end)

test("a character that is not a hunter listens to no vendor and still gets the page", function()
    hunter({ class = "WARRIOR" })
    assert_false(__registered("MERCHANT_SHOW"), "MERCHANT_SHOW registered")
    assert_false(__registered("MERCHANT_CLOSED"), "MERCHANT_CLOSED registered")
    assert_true(__settings_page(), "no settings page")
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "a warrior bought arrows")
    assert_eq(button(), nil, "vendor button built for a warrior")
    slash("refill")
    assert_true(__printed("only hunters use ammo"), "no explanation")
end)

test("a hunter listens to MERCHANT_SHOW and MERCHANT_CLOSED, the rest only at a vendor", function()
    hunter()
    assert_true(__registered("MERCHANT_SHOW"), "MERCHANT_SHOW not registered")
    assert_true(__registered("MERCHANT_CLOSED"), "MERCHANT_CLOSED not registered")
    for _, event in ipairs({ "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE", "PLAYER_MONEY",
        "GET_ITEM_INFO_RECEIVED", "MERCHANT_FILTER_ITEM_UPDATE" }) do
        assert_false(__registered(event), event .. " registered before a vendor opened")
    end
    assert_eq(button(), nil, "vendor button built at load")

    __open_vendor(arrowVendor())
    for _, event in ipairs({ "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE", "PLAYER_MONEY",
        "MERCHANT_FILTER_ITEM_UPDATE" }) do
        assert_true(__registered(event), event .. " not registered at the vendor")
    end
    assert_false(__registered("GET_ITEM_INFO_RECEIVED"), "item event registered with nothing to wait for")

    __close_vendor()
    for _, event in ipairs({ "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE", "PLAYER_MONEY",
        "MERCHANT_FILTER_ITEM_UPDATE" }) do
        assert_false(__registered(event), event .. " still registered after the vendor closed")
    end
end)

test("a vendor event the client does not have does not stop the others", function()
    hunter({ missingEvents = { "MERCHANT_FILTER_ITEM_UPDATE" } })
    __open_vendor(arrowVendor())
    assert_true(__registered("BAG_UPDATE_DELAYED"), "BAG_UPDATE_DELAYED not registered")
    __deliver_all()
    assert_eq(__bought(), 800)
    __close_vendor()
end)

test("a client without a C_ call Fletcher needs says so once and stays off", function()
    local ok, err = pcall(hunter, { remove = { "C_MerchantFrame.GetItemInfo" } })
    assert_true(ok, tostring(err))
    assert_true(__printed("this client has no C_MerchantFrame.GetItemInfo, so Fletcher stays off."),
        "no explanation")
    assert_false(__registered("MERCHANT_SHOW"), "listening without the API")
    assert_true(__settings_page(), "no settings page")
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0)

    hunter({ remove = { "GetMerchantItemMaxStack" } })
    assert_true(__printed("this client has no GetMerchantItemMaxStack"), "no explanation for a global")

    hunter({ remove = { "Enum" } })
    assert_true(__printed("this client has no Enum.ItemClass"), "no explanation for the enums")
end)

test("saved settings are checked, and broken ones fall back to the defaults", function()
    hunter({ db = { autoBuy = "yes", highlight = false, keepCopper = -5, capCopper = 1e12,
        betterAmmo = "sell", pulse = 0 / 0 } })
    assert_eq(FletcherDB.autoBuy, true, "a string kept as a flag")
    assert_eq(FletcherDB.highlight, false, "a saved choice lost")
    assert_eq(FletcherDB.keepCopper, 0, "negative reserve kept")
    assert_eq(FletcherDB.capCopper, 10000 * GOLD, "a cap past the limit kept")
    assert_eq(FletcherDB.betterAmmo, "skip", "an unknown choice kept")
    assert_eq(FletcherDB.pulse, true, "not a flag kept")
    assert_eq(FletcherDB.showButton, true, "a missing setting not filled in")

    hunter({ db = { keepCopper = 0 / 0, capCopper = 1234.4 } })
    assert_eq(FletcherDB.keepCopper, 0, "not a number kept")
    assert_eq(FletcherDB.capCopper, 1234, "copper not whole")
end)

--------------------------------------------------------------------------------
-- Which kind
--------------------------------------------------------------------------------

test("a quiver means arrows", function()
    hunter()
    __open_vendor(arrowVendor())
    assert_eq(__buy_log[1].id, RAZOR, "not the level 30 arrow")
end)

test("an ammo pouch means bullets", function()
    hunter({ ranged = GUN, bags = { [0] = backpack(), [2] = pouch(4) } })
    local vendor = bulletVendor()
    for _, entry in ipairs(arrowVendor()) do vendor[#vendor + 1] = entry end
    __open_vendor(vendor)
    assert_eq(__buy_log[1].id, SOLID, "not the level 30 bullet")
    __deliver_all()
    assert_eq(__bag_count(2, SOLID), 800, "the pouch is not full")
    assert_eq(__count(RAZOR), 0, "arrows bought for a pouch")
end)

test("without a quiver or pouch nothing is bought, but the best ammo is still marked", function()
    hunter({ bags = { [0] = backpack(), [1] = quiver(4, nil, BAG) } })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought without a quiver")
    assert_true(__overlay(4), "the bow's best arrow is not marked")
    assert_true(button():IsShown(), "the button does not show to explain")
    local lines = hover_button()
    assert_true(has_line(lines, "Equip a quiver or ammo pouch to refill."), lines_text(lines))
    click_button()
    assert_eq(#__buy_log, 0, "a click bought without a quiver")
    assert_true(__printed("equip a quiver or ammo pouch to refill."), "the click said nothing")
end)

test("the bag decides against the weapon, and the mismatch is said once a visit", function()
    hunter({ bags = { [0] = backpack(), [1] = pouch(2) } })
    local vendor = arrowVendor()
    for _, entry in ipairs(bulletVendor()) do vendor[#vendor + 1] = entry end
    __open_vendor(vendor)
    assert_eq(__buy_log[1].id, SOLID, "did not follow the pouch")
    assert_true(__printed("your ammo pouch holds bullets but your bow fires arrows."), "no warning")
    __deliver_all()
    __merchant_update()
    assert_eq(__printed_count("holds bullets but your bow"), 1, "warned more than once in a visit")
    local lines = hover_button()
    assert_true(has_line(lines, "Your ammo pouch holds bullets but your bow fires arrows."), lines_text(lines))

    __close_vendor()
    __open_vendor(vendor)
    assert_eq(__printed_count("holds bullets but your bow"), 2, "not warned on the next visit")
end)

test("the mismatch is not mentioned at a vendor without ammo", function()
    hunter({ bags = { [0] = backpack(), [1] = pouch(2) } })
    __open_vendor({ { id = WATER, price = 25, batch = 1 } })
    assert_false(__printed("holds bullets"), "warned at a water vendor")
end)

test("with a quiver and a pouch, the one the weapon fills wins", function()
    hunter({ ranged = GUN, bags = { [0] = backpack(), [1] = quiver(2), [2] = pouch(2) } })
    local vendor = arrowVendor()
    for _, entry in ipairs(bulletVendor()) do vendor[#vendor + 1] = entry end
    __open_vendor(vendor)
    assert_eq(__buy_log[1].id, SOLID)
    __deliver_all()
    assert_eq(__bought(), 400, "bought for both bags")
end)

test("a bag whose class cannot be read is known by its family", function()
    local bags = { [0] = backpack(), [1] = quiver(2) }
    bags[1].secretFamily = false
    hunter({ bags = bags })
    __items[QUIVER].class = __secret()
    __open_vendor(arrowVendor())
    assert_eq(__buy_log[1] and __buy_log[1].id, RAZOR, "the family did not stand in")
end)

test("a crossbow fires arrows, and a thrown weapon needs no ammo", function()
    hunter({ ranged = CROSSBOW, bags = { [0] = backpack() } })
    __open_vendor(arrowVendor())
    assert_true(__overlay(4), "no arrow marked for a crossbow")

    hunter({ ranged = KNIFE, bags = { [0] = backpack() } })
    __open_vendor(arrowVendor())
    assert_eq(__overlay(4), nil, "ammo marked for a thrown weapon")
end)

--------------------------------------------------------------------------------
-- The best vendor ammo
--------------------------------------------------------------------------------

test("the best arrow follows the required level", function()
    local picks = { [1] = ROUGH, [10] = SHARP, [24] = SHARP, [25] = RAZOR, [30] = RAZOR, [40] = JAGGED }
    for level, expected in pairs(picks) do
        hunter({ level = level })
        __open_vendor(arrowVendor())
        assert_eq(__buy_log[1] and __buy_log[1].id, expected, "level " .. level)
    end
end)

test("an unusable, unpurchasable, sold out or token item is skipped", function()
    local cases = {
        { usable = false }, { purchasable = false }, { stock = 0 }, { extended = true },
    }
    for _, case in ipairs(cases) do
        hunter()
        local vendor = arrowVendor()
        for key, value in pairs(case) do vendor[4][key] = value end
        __open_vendor(vendor)
        assert_eq(__buy_log[1] and __buy_log[1].id, SHARP, "Razor Arrow not skipped")
    end
end)

test("a limited stock still sells", function()
    hunter()
    local vendor = arrowVendor()
    vendor[4].stock = 3
    __open_vendor(vendor)
    assert_eq(__buy_log[1].id, RAZOR)
end)

test("at the same level, the higher item level wins, then the cheaper round", function()
    hunter()
    __items[90001] = { name = "Fine Arrow", class = 6, subclass = 2, itemLevel = 31, minLevel = 25,
        stack = 200, cached = true, icon = 1 }
    __items[90002] = { name = "Cheap Arrow", class = 6, subclass = 2, itemLevel = 30, minLevel = 25,
        stack = 200, cached = true, icon = 1 }
    __open_vendor({ { id = RAZOR, price = 100 }, { id = 90001, price = 500 } })
    assert_eq(__buy_log[1].id, 90001, "item level did not decide")

    hunter()
    __items[90002] = { name = "Cheap Arrow", class = 6, subclass = 2, itemLevel = 30, minLevel = 25,
        stack = 200, cached = true, icon = 1 }
    -- 100 rounds for 40 copper is cheaper per round than 200 for 100.
    __open_vendor({ { id = RAZOR, price = 100 }, { id = 90002, price = 40, batch = 100 } })
    assert_eq(__buy_log[1].id, 90002, "the cheaper round did not win")
end)

test("a vendor that sells only the other kind buys nothing and shows no button", function()
    hunter()
    __open_vendor(bulletVendor())
    assert_eq(#__buy_log, 0)
    assert_false(button():IsShown(), "button shown at a bullet vendor for a quiver")
    slash("refill")
    assert_true(__printed("this vendor sells no arrows you can use."), "no explanation")
end)

--------------------------------------------------------------------------------
-- How many
--------------------------------------------------------------------------------

test("an empty 4 slot quiver of 200 stacks needs 800, bought a stack at a time", function()
    hunter()
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 1, "more than one purchase before the bags changed")
    assert_eq(__buy_log[1].quantity, 200)
    __deliver_all()
    assert_eq(#__buy_log, 4)
    assert_eq(__bought(), 800)
    assert_eq(__bag_count(1, RAZOR), 800, "the quiver is not full")
    assert_eq(__money, 10 * GOLD - 400, "charged wrongly")
end)

test("a part stack is left as it is, and no visit buys for it", function()
    -- Seen in game: nine stacks of 200 and one of 90 in a 10 slot quiver.
    -- Every visit bought 200 more, which went into the backpack.
    local contents = {}
    for slot = 1, 9 do contents[slot] = { id = RAZOR, count = 200 } end
    contents[10] = { id = RAZOR, count = 90 }
    hunter({ bags = { [0] = backpack(), [1] = quiver(10, contents) } })
    for _ = 1, 3 do
        __open_vendor(arrowVendor())
        __deliver_all()
        __close_vendor()
    end
    assert_eq(#__buy_log, 0, "bought for a part stack")
    __open_vendor(arrowVendor())
    local lines = hover_button()
    assert_true(has_line(lines, "Your quiver has no empty slot."), lines_text(lines))
    assert_true(has_line(lines, "Quiver | Light Quiver, 10 / 10 slots, 1890 arrows"), lines_text(lines))

    -- With an empty slot beside the part stack, only the empty slot is bought for, once.
    contents = { [1] = { id = RAZOR, count = 200 }, [2] = { id = RAZOR, count = 200 },
        [3] = { id = RAZOR, count = 90 } }
    hunter({ bags = { [0] = backpack(), [1] = quiver(4, contents) } })
    for _ = 1, 3 do
        __open_vendor(arrowVendor())
        __deliver_all()
        __close_vendor()
    end
    assert_eq(__bought(), 200, "bought more than the empty slot")
    assert_eq(__bags[1].contents[3].count, 90, "the part stack changed")
    assert_eq(__bag_count(1, RAZOR), 690)
    assert_eq(__bag_count(0, RAZOR), 0, "bought into the backpack")
end)

test("the chosen ammo already in the normal bags is not bought again", function()
    local pack = backpack()
    pack.contents[1] = { id = RAZOR, count = 200 }
    pack.contents[2] = { id = RAZOR, count = 100 }
    hunter({ bags = { [0] = pack, [1] = quiver(4) } })
    __open_vendor(arrowVendor())
    __deliver_all()
    -- 800 for the empty slots, less the 300 the backpack holds: 500, bought exactly.
    assert_eq(__bought(), 500)
    assert_eq(__count(RAZOR), 800)
    __close_vendor()

    -- The backpack's ammo covers the slots still empty, wherever the last
    -- part batch landed.
    __open_vendor(arrowVendor())
    assert_eq(__bought(), 500, "bought what the backpack already holds")
    local spare = __bag_count(0, RAZOR)
    local lines = hover_button()
    assert_true(has_line(lines, ("Your bags already hold %d Razor Arrow. Move them into your quiver.")
        :format(spare)), lines_text(lines))
    click_button()
    assert_true(__printed(("your bags already hold %d Razor Arrow. Move them into your quiver.")
        :format(spare)), "the click said nothing")

    -- Other ammo in the backpack does not count.
    pack = backpack()
    pack.contents[1] = { id = SHARP, count = 200 }
    hunter({ bags = { [0] = pack, [1] = quiver(2) } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 400)
end)

test("other ammo in the quiver is left alone and counts as nothing to fill", function()
    local contents = { [1] = { id = SHARP, count = 120 }, [3] = { id = ROUGH, count = 200 } }
    hunter({ bags = { [0] = backpack(), [1] = quiver(4, contents) } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 400, "the other ammo's slots were counted")
    assert_eq(__bags[1].contents[1].id, SHARP, "old ammo moved")
    assert_eq(__bags[1].contents[1].count, 120, "old ammo changed")
    assert_eq(__bags[1].contents[3].count, 200, "old ammo changed")
end)

test("a locked slot is left alone", function()
    local contents = { [1] = { id = RAZOR, count = 0, locked = true } }
    contents[1].count = 10
    hunter({ bags = { [0] = backpack(), [1] = quiver(2, contents) } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 200, "the locked slot was filled")
end)

test("a full quiver buys nothing and says so", function()
    local contents = { [1] = { id = RAZOR, count = 200 }, [2] = { id = RAZOR, count = 200 } }
    hunter({ bags = { [0] = backpack(), [1] = quiver(2, contents) } })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0)
    assert_false(__printed("no empty slot"), "the auto buy talked about a full quiver")
    local lines = hover_button()
    assert_true(has_line(lines, "Your quiver has no empty slot."), lines_text(lines))
    assert_true(has_line(lines, "Quiver | Light Quiver, 2 / 2 slots, 400 arrows"), lines_text(lines))
    assert_true(button().icon.__desaturated, "the button is not greyed")
    click_button()
    assert_eq(#__buy_log, 0)
    assert_true(__printed("your quiver has no empty slot."), "the click said nothing")
end)

test("BuyCount: the exact need, part of a batch included", function()
    -- An arrow that stacks to 20, sold 100 at a time for 9c: the vendor takes
    -- part of a batch and rounds its share of the price up (seen in game).
    hunter({ bags = { [0] = backpack(), [1] = quiver(2) } })
    __items[90003] = { name = "Short Arrow", class = 6, subclass = 2, itemLevel = 30, minLevel = 25,
        stack = 20, cached = true, icon = 1 }
    local money = __money
    __open_vendor({ { id = 90003, price = 9, batch = 100 } })
    __deliver_all()
    -- 40 missing buys 40: not a batch of 100, and not nothing.
    assert_eq(__bought(), 40)
    assert_eq(__bag_count(1, 90003), 40, "the quiver is not full")
    assert_eq(__bag_count(0, 90003), 0, "rounds over the need went to a normal bag")
    -- Two purchases of 20, 1.8c each, so 2c each.
    assert_eq(money - __money, 4, "not the vendor's share of the price")
    assert_true(__printed("bought 40 Short Arrow for 4c."), "the report's cost is not what was paid")
end)

test("a purchase never asks for more than the vendor's most per purchase", function()
    hunter()
    local vendor = arrowVendor()
    vendor[4].batch, vendor[4].maxStack = 100, 300
    __open_vendor(vendor)
    __deliver_all()
    assert_eq(__bought(), 800)
    for _, purchase in ipairs(__buy_log) do
        assert_true(purchase.quantity <= 300 and purchase.quantity % 100 == 0,
            "purchase of " .. purchase.quantity)
    end
end)

--------------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------------

test("Keep gold limits the refill and says what was left out", function()
    hunter({ money = 2 * SILVER + 50, db = { keepCopper = SILVER } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 300, "spent the reserve")
    assert_eq(__money, SILVER, "money fell under the reserve")
    assert_true(__printed("bought 300 Razor Arrow for 1s 50c. Quiver 2 / 4 slots. Left out 500 to keep 1s."),
        "no clear message")
end)

test("the spending cap limits one refill", function()
    hunter({ db = { capCopper = 2 * SILVER } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 400)
    assert_true(__printed("Left out 400 to stay under the 2s spending cap."), "no cap message")
end)

test("money for part of a batch buys that part; none at all buys nothing and says so", function()
    hunter({ money = 99 })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 198, "not what 99c buys")
    assert_eq(__money, 0)
    assert_true(__printed("Left out 602 you cannot afford."), "no left out message")

    hunter({ money = 0 })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0)
    assert_true(__printed("not enough money for 200 Razor Arrow."), "no message")

    hunter({ money = 150, db = { keepCopper = 150 } })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0)
    assert_true(__printed("not enough money for 200 Razor Arrow while keeping 1s 50c."), "no reserve message")

    -- A round costs 1.5c here, so a 1c cap buys none.
    hunter({ db = { capCopper = 1 } })
    local vendor = arrowVendor()
    vendor[4].price = 300
    __open_vendor(vendor)
    assert_eq(#__buy_log, 0)
    assert_true(__printed("the 1c spending cap does not cover 200 Razor Arrow."), "no cap message")
end)

test("money falling under the reserve during a refill stops it", function()
    hunter({ money = 10 * SILVER, db = { keepCopper = 5 * SILVER } })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 1)
    __money = 5 * SILVER + 50 -- a repair, say, while the first purchase lands
    __deliver()
    assert_eq(#__buy_log, 1, "bought into the reserve")
    assert_true(__printed("stopped buying to keep 5s. Bought 200 Razor Arrow for 1s."), "no stop message")
end)

test("the tooltip shows what a refill costs", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    local lines = hover_button()
    assert_true(has_line(lines, "Fletcher"), "no title")
    assert_true(has_line(lines, "Quiver | Light Quiver, 0 / 4 slots, 0 arrows"), lines_text(lines))
    assert_true(has_line(lines, "Best here | Razor Arrow (level 25)"), lines_text(lines))
    assert_true(has_line(lines, "Refill | 800 for 4s"), lines_text(lines))
    assert_true(has_line(lines, "Left click to refill"), "no hint")
    assert_true(has_line(lines, "Right click for options"), "no hint")
    assert_true(has_line(lines, "Hold Shift when talking to a vendor to skip auto buy"), "no hint")
    assert_false(button().icon.__desaturated, "greyed with something to buy")
    assert_eq(button().icon.__texture, __items[RAZOR].icon, "not the best ammo's icon")
end)

--------------------------------------------------------------------------------
-- The buying queue
--------------------------------------------------------------------------------

test("one purchase per bag update, and a line in chat at the end", function()
    hunter()
    __open_vendor(arrowVendor())
    for step = 1, 4 do
        assert_eq(#__buy_log, step, "purchases before bag update " .. step)
        __deliver()
    end
    assert_eq(#__buy_log, 4)
    assert_eq(__pending_purchases(), 0)
    assert_true(__printed("bought 800 Razor Arrow for 4s. Quiver full (4 / 4 slots)."), "no report")
    assert_eq(__printed_count("bought"), 1, "more than one report")
end)

test("Report off keeps the chat quiet", function()
    hunter({ db = { report = false } })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 800)
    assert_false(__printed("bought"), "reported with Report off")
end)

test("a bag update that is not the purchase waits for it", function()
    hunter()
    __open_vendor(arrowVendor())
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(#__buy_log, 1, "an unrelated bag update sent the next purchase")
    __deliver()
    assert_eq(#__buy_log, 2)
end)

test("closing the vendor stops the refill", function()
    hunter()
    __open_vendor(arrowVendor())
    __deliver()
    __close_vendor()
    __deliver_all()
    assert_eq(#__buy_log, 2, "bought after the vendor closed")
    -- The report counts what landed before the window closed.
    assert_true(__printed("bought 200 Razor Arrow for 1s."), "no report of what was bought")
end)

test("an error from the game stops the refill", function()
    hunter()
    __open_vendor(arrowVendor())
    __deliver()
    __fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
    __deliver_all()
    assert_eq(#__buy_log, 2, "bought after an error")
    assert_true(__printed("stopped buying: Inventory is full. Bought 200 Razor Arrow for 1s."),
        "no stop message")
end)

test("a purchase that never lands stops on the safety net", function()
    hunter()
    __refuse = true
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 1)
    __advance(2.9)
    assert_false(__printed("did not answer"), "stopped too soon")
    __advance(0.2)
    assert_true(__printed("the vendor did not answer, so buying stopped."), "no stop message")
    __refuse = false
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(#__buy_log, 1, "kept buying after the safety net")
    assert_eq(__pending_timers(), 0, "a timer left running")
end)

test("the safety net of a purchase that landed does nothing", function()
    hunter()
    __open_vendor(arrowVendor())
    __deliver_all()
    __advance(10)
    assert_false(__printed("did not answer"), "an old safety net fired")
end)

test("the total never goes past the need counted at the start", function()
    hunter()
    __open_vendor(arrowVendor())
    for _ = 1, 10 do
        -- The player keeps moving the arrows out of the quiver into the
        -- backpack while it is being filled, so the quiver always looks empty.
        for slot, content in pairs(__bags[1].contents) do
            __bags[0].contents[slot + 4 * _] = content
        end
        __bags[1].contents = {}
        if __pending_purchases() == 0 then break end
        __deliver()
    end
    assert_eq(__bought(), 800, "bought past the starting need")
end)

test("a second refill while one is running is ignored", function()
    hunter()
    __open_vendor(arrowVendor())
    click_button()
    slash("refill")
    assert_eq(#__buy_log, 1, "a second refill started")
    __deliver_all()
    assert_eq(__bought(), 800)
end)

test("the refill follows its item when the vendor's list moves, and stops when it goes", function()
    hunter()
    __open_vendor(arrowVendor())
    local moved = arrowVendor()
    table.insert(moved, 1, { id = LIGHT, price = 10 })
    __merchant = moved
    __deliver()
    assert_eq(__buy_log[2].index, 5, "bought from the old index")
    assert_eq(__buy_log[2].id, RAZOR)

    __merchant = bulletVendor()
    __deliver()
    assert_eq(#__buy_log, 2, "bought something else")
    assert_true(__printed("Razor Arrow is no longer in the vendor's list, so buying stopped."), "no message")
end)

--------------------------------------------------------------------------------
-- Auto buy
--------------------------------------------------------------------------------

test("with auto buy off, opening the vendor buys nothing; the button still refills", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0)
    click_button()
    __deliver_all()
    assert_eq(__bought(), 800)
end)

test("holding Shift skips the auto buy; the button and /ammo refill still work", function()
    hunter()
    __shift = true
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought with Shift held")
    __shift = false
    slash("refill")
    __deliver_all()
    assert_eq(__bought(), 800)
end)

test("the auto buy runs once a visit", function()
    hunter({ money = 3 * SILVER })
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 600, "not what the money allowed")
    __money = 10 * GOLD
    __fire("PLAYER_MONEY")
    __merchant_update()
    assert_eq(__bought(), 600, "bought twice in one visit")

    __close_vendor()
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__bought(), 800, "the next visit did not fill the rest")
end)

test("a vendor list that arrives after MERCHANT_SHOW is bought from then", function()
    hunter()
    __open_vendor({})
    assert_eq(#__buy_log, 0)
    __merchant_update(arrowVendor())
    assert_eq(__buy_log[1] and __buy_log[1].id, RAZOR, "the late list was not bought from")
end)

--------------------------------------------------------------------------------
-- Items not cached yet
--------------------------------------------------------------------------------

test("an item not cached yet is waited for, then bought", function()
    hunter()
    __items[RAZOR].cached = false
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought before the best arrow was known")
    assert_true(__registered("GET_ITEM_INFO_RECEIVED"), "not waiting for the item")
    assert_true(has_line(hover_button(), "Waiting for the game to load the vendor's ammo."), "no waiting line")

    __fire("GET_ITEM_INFO_RECEIVED", SHARP, true) -- not one it waits for
    assert_eq(#__buy_log, 0)

    __items[RAZOR].cached = true
    __fire("GET_ITEM_INFO_RECEIVED", RAZOR, true)
    assert_eq(__buy_log[1] and __buy_log[1].id, RAZOR, "not bought once the item came in")
    assert_false(__registered("GET_ITEM_INFO_RECEIVED"), "still waiting")
end)

test("after three tries Fletcher stops waiting, without an error", function()
    hunter()
    __items[RAZOR].cached = false
    __open_vendor(arrowVendor())
    for _ = 1, 3 do __fire("GET_ITEM_INFO_RECEIVED", RAZOR, false) end
    assert_eq(#__buy_log, 0, "bought what was not known")
    assert_false(__registered("GET_ITEM_INFO_RECEIVED"), "still waiting after three tries")
    assert_true(__printed("the game did not load the vendor's ammo, so nothing was bought."), "no message")
    __fire("GET_ITEM_INFO_RECEIVED", RAZOR, false)
    assert_eq(__printed_count("did not load"), 1, "said twice")
    -- A click now buys the best of what is known.
    click_button()
    assert_eq(__buy_log[1] and __buy_log[1].id, SHARP)
end)

test("a click while the items load buys once they are in", function()
    hunter({ db = { autoBuy = false } })
    __items[RAZOR].cached = false
    __open_vendor(arrowVendor())
    click_button()
    assert_eq(#__buy_log, 0)
    assert_true(__printed("waiting for the game to load the vendor's ammo"), "no waiting message")
    __items[RAZOR].cached = true
    __fire("GET_ITEM_INFO_RECEIVED", RAZOR, true)
    assert_eq(__buy_log[1] and __buy_log[1].id, RAZOR)
end)

--------------------------------------------------------------------------------
-- The highlight
--------------------------------------------------------------------------------

local function proc_running(overlay)
    return overlay.burstAnim:IsPlaying() or overlay.loopAnim:IsPlaying()
end

test("the best ammo is marked with a gold glow and the proc glow, burst then loop", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    local overlay = __overlay(4)
    assert_true(overlay, "Razor Arrow not marked")
    for _, place in ipairs({ 1, 2, 3, 5 }) do
        assert_eq(__overlay(place), nil, "button " .. place .. " marked")
    end

    -- The bags' new item glow, at its own size, in gold.
    assert_eq(overlay.glow.__atlas, "bags-glow-white")
    assert_true(overlay.glow.__useAtlasSize, "the glow not at its own size")
    assert_eq(overlay.glow.__blend, "ADD")
    assert_eq(overlay.glow.__vertexColor[1], 1.0, "not gold")
    assert_eq(overlay.glow.__vertexColor[2], 0.82, "not gold")

    -- The action bar's proc glow: the burst first, then the loop.
    assert_eq(overlay.burst.__atlas, "UI-HUD-ActionBar-Proc-Start-Flipbook")
    assert_eq(overlay.loop.__atlas, "UI-HUD-ActionBar-Proc-Loop-Flipbook")
    assert_eq(overlay.loop.__width, 37 * 1.4, "the loop not 1.4 times the button")
    assert_eq(overlay.burst.__alpha, 0, "a flipbook sheet shown still")
    assert_eq(overlay.loop.__alpha, 0, "a flipbook sheet shown still")
    assert_true(overlay.burstAnim:IsPlaying(), "no burst")
    assert_false(overlay.loopAnim:IsPlaying(), "the loop ran before the burst ended")
    local flip = __animation(overlay.loopAnim, "FlipBook")
    assert_eq(flip.__target, overlay.loop)
    assert_eq(flip.__rows, 6)
    assert_eq(flip.__columns, 5)
    assert_eq(flip.__frames, 30)
    assert_eq(flip.__duration, 1.0)
    assert_eq(overlay.loopAnim.__looping, "REPEAT")
    assert_eq(__animation(overlay.burstAnim, "FlipBook").__duration, 0.7)

    __finish(overlay.burstAnim)
    assert_true(overlay.loopAnim:IsPlaying(), "the loop did not follow the burst")

    -- A redraw of the page, from a purchase say, leaves the loop running.
    __merchant_update()
    assert_true(overlay.loopAnim:IsPlaying(), "a redraw stopped the loop")
    assert_false(overlay.burstAnim:IsPlaying(), "a redraw played the burst again")

    -- The next visit bursts again.
    __close_vendor()
    assert_false(proc_running(overlay), "the glow ran on with the vendor closed")
    __open_vendor(arrowVendor())
    assert_true(overlay.burstAnim:IsPlaying(), "no burst on the next visit")
end)

test("the best ammo on page 2 is marked once the page turns", function()
    hunter({ db = { autoBuy = false } })
    local vendor = {}
    for i = 1, 12 do vendor[i] = { id = WATER, price = 25, batch = 1 } end
    vendor[13] = { id = RAZOR, price = 100 }
    __open_vendor(vendor)
    for place = 1, 10 do assert_eq(__overlay(place), nil, "page 1 button " .. place .. " marked") end
    assert_true(has_line(hover_button(), "Best ammo is on page 2."), "no page note")

    __merchant_page(2)
    assert_true(__overlay(3), "Razor Arrow not marked on page 2")
    assert_false(has_line(GameTooltip.__lines, "Best ammo is on page 2."), "page note stayed after paging")

    __merchant_page(1)
    assert_eq(__overlay(3), nil, "the mark stayed on the old place")
end)

test("the buyback tab hides every mark", function()
    hunter({ db = { autoBuy = false, highlightOther = true } })
    __open_vendor(arrowVendor())
    __merchant_tab(2)
    for place = 1, 10 do assert_eq(__overlay(place), nil, "buyback button " .. place .. " marked") end
    __merchant_tab(1)
    assert_true(__overlay(4), "the mark did not come back")
end)

test("turning the highlight off hides the mark at once", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    slash("highlight off")
    assert_eq(__overlay(4), nil, "the mark stayed")
    slash("highlight on")
    assert_true(__overlay(4), "the mark did not come back")
end)

test("other usable ammo is marked in green only when asked for", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    assert_eq(__overlay(2), nil, "Rough Arrow marked by default")

    slash("others on")
    local rough, sharp = __overlay(2), __overlay(3)
    assert_true(rough and sharp, "the other arrows are not marked")
    assert_eq(rough.glow.__atlas, "bags-glow-green", "not green")
    assert_true(rough.glow.__alpha < 1, "the other mark is as bright as the best")
    assert_false(proc_running(rough), "the other mark runs the proc glow")
    assert_eq(__overlay(1), nil, "water marked")
    assert_eq(__overlay(5), nil, "an arrow above the level marked")
    assert_true(proc_running(__overlay(4)), "the best lost its proc glow")
    assert_eq(__overlay(4).glow.__atlas, "bags-glow-white", "the best is not gold")

    -- The best ammo moving to a mark that was green turns it gold.
    __level = 40
    __merchant_update()
    local jagged = __overlay(5)
    assert_true(jagged and jagged.glow.__atlas == "bags-glow-white", "the new best is not gold")
    assert_eq(__overlay(4).glow.__atlas, "bags-glow-green", "the old best stayed gold")
    assert_false(proc_running(__overlay(4)), "the old best kept its proc glow")
end)

test("Pulse off keeps the gold glow still, without the proc glow", function()
    hunter({ db = { autoBuy = false, pulse = false } })
    __open_vendor(arrowVendor())
    local overlay = __overlay(4)
    assert_true(overlay, "no mark with Pulse off")
    assert_eq(overlay.glow.__atlas, "bags-glow-white")
    assert_false(proc_running(overlay), "the proc glow runs with Pulse off")
    slash("pulse on")
    assert_true(overlay.loopAnim:IsPlaying(), "turning Pulse on did not start the loop")
    assert_false(overlay.burstAnim:IsPlaying(), "turning Pulse on burst an old mark")
    slash("pulse off")
    assert_false(proc_running(overlay), "turning Pulse off left the proc glow running")
end)

test("the button hides at a vendor without ammo and with Show vendor button off", function()
    hunter()
    __open_vendor({ { id = WATER, price = 25, batch = 1 } })
    assert_false(button():IsShown(), "button at a water vendor")
    __close_vendor()

    hunter({ db = { showButton = false } })
    __open_vendor(arrowVendor())
    assert_false(button():IsShown(), "button shown while turned off")
    slash("button on")
    assert_true(button():IsShown(), "button did not come back")
end)

test("the button sits in the vendor window, and only Fletcher's own frames are made", function()
    hunter({ db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    assert_eq(button().__parent, MerchantFrame)
    local point = button().__points[1]
    assert_eq(point[1], "TOPRIGHT")
    assert_eq(point[2], MerchantFrame)
    assert_eq(MerchantFrame.__scripts.OnShow, nil, "a script set on the vendor window")
    local itemButton = MerchantItem4ItemButton
    assert_eq(next(itemButton.__scripts), nil, "a script set on an item button")
end)

--------------------------------------------------------------------------------
-- The menu, the slash commands and the settings page
--------------------------------------------------------------------------------

test("right-click opens the client's menu, and its entries change the settings", function()
    hunter({ db = { autoBuy = false }, version = "v1.0.0" })
    __open_vendor(arrowVendor())
    click_button("RightButton")
    assert_eq(#__buy_log, 0, "a right click bought")
    assert_true(__menu_item("Fletcher v1.0.0"), "no title with the version")

    __menu_click(__menu_item("Auto buy"))
    assert_eq(FletcherDB.autoBuy, true)
    __menu_click(__menu_item("Highlight other usable ammo"))
    assert_eq(FletcherDB.highlightOther, true)
    __menu_click(__menu_item("Pulse"))
    assert_eq(FletcherDB.pulse, false)
    __menu_click(__menu_item("Report purchases in chat"))
    assert_eq(FletcherDB.report, false)
    __menu_click(__menu_item("Highlight best ammo"))
    assert_eq(FletcherDB.highlight, false)
    assert_eq(__overlay(4), nil, "the menu's highlight entry did not hide the mark")

    __menu_click(__menu_item("Keep gold", "5g"))
    assert_eq(FletcherDB.keepCopper, 5 * GOLD)
    assert_true(__menu_selected(__menu_item("Keep gold", "5g")), "the preset is not checked")
    __menu_click(__menu_item("Spending cap", "50s"))
    assert_eq(FletcherDB.capCopper, 50 * SILVER)
    __menu_click(__menu_item("Spending cap", "None"))
    assert_eq(FletcherDB.capCopper, 0)
    __menu_click(__menu_item("When my ammo is better", "Fill empty slots"))
    assert_eq(FletcherDB.betterAmmo, "fill")

    __menu_click(__menu_item("Refill now"))
    assert_eq(#__buy_log, 1, "Refill now did not buy")
    __menu_click(__menu_item("Settings..."))
    assert_eq(__settingsOpened, "Fletcher", "Settings... did not open the page")
end)

test("without the client's menu, a right click says to use the commands", function()
    hunter({ noMenu = true, db = { autoBuy = false } })
    __open_vendor(arrowVendor())
    click_button("RightButton")
    assert_true(__printed("type /ammo help for the commands"), "no message")
end)

test("the slash commands change the same settings", function()
    hunter()
    local switches = {
        { "auto", "autoBuy" }, { "highlight", "highlight" }, { "others", "highlightOther" },
        { "pulse", "pulse" }, { "report", "report" }, { "button", "showButton" },
    }
    for _, switch in ipairs(switches) do
        slash(switch[1] .. " off")
        assert_eq(FletcherDB[switch[2]], false, switch[1] .. " off")
        slash(switch[1] .. " on")
        assert_eq(FletcherDB[switch[2]], true, switch[1] .. " on")
    end
    slash("pulse maybe")
    assert_true(__printed("use /ammo pulse on or /ammo pulse off."), "no usage line")

    slash("keep 0.5")
    assert_eq(FletcherDB.keepCopper, 5000)
    assert_true(__printed("a refill always leaves you 50s."), "no keep message")
    slash("keep 2g")
    assert_eq(FletcherDB.keepCopper, 2 * GOLD)
    slash("keep lots")
    assert_eq(FletcherDB.keepCopper, 2 * GOLD, "a bad amount changed the reserve")
    assert_true(__printed("give an amount of gold, for example /ammo keep 1"), "no usage line")
    slash("keep 1,5")
    assert_eq(FletcherDB.keepCopper, 15000, "a decimal comma not read")
    slash("keep 0")
    assert_eq(FletcherDB.keepCopper, 0)
    slash("cap 1.25")
    assert_eq(FletcherDB.capCopper, 12500)
    assert_true(__printed("one refill spends at most 1g 25s."), "no cap message")
    slash("cap 0")
    assert_true(__printed("with no cap"), "no message for no cap")

    slash("better fill")
    assert_eq(FletcherDB.betterAmmo, "fill")
    slash("better sell")
    assert_eq(FletcherDB.betterAmmo, "fill", "an unknown choice taken")
    slash("better skip")
    assert_eq(FletcherDB.betterAmmo, "skip")

    slash("auto off")
    slash("keep 3")
    slash("reset")
    assert_eq(FletcherDB.autoBuy, true, "reset left auto buy off")
    assert_eq(FletcherDB.keepCopper, 0, "reset left the reserve")
    assert_true(__printed("every setting is back to its default."), "no reset message")
end)

test("/ammo help lists the commands, and an unknown command does too", function()
    hunter()
    slash("help")
    assert_true(__printed("/ammo keep <gold>"), "no keep line")
    assert_true(__printed("/ammo better skip | fill"), "no better line")
    local count = #__output
    slash("dance")
    assert_true(#__output > count, "an unknown command printed nothing")
end)

test("/ammo and /fletcher open the settings page; /ammo status reads the quiver", function()
    hunter()
    assert_eq(SLASH_FLETCHER1, "/fletcher")
    assert_eq(SLASH_FLETCHER2, "/ammo")
    slash("")
    assert_eq(__settingsOpened, "Fletcher")
    assert_true(__settings_page():IsShown(), "page not shown")

    local contents = { [1] = { id = RAZOR, count = 150 } }
    hunter({ ammo = RAZOR, bags = { [0] = backpack(), [1] = quiver(4, contents) } })
    slash("status")
    assert_true(__printed("Quiver: Light Quiver, 1 / 4 slots, 150 arrows"), "no quiver line")
    assert_true(__printed("Ammo slot: Razor Arrow, 150"), "no ammo slot line")
    __open_vendor(arrowVendor())
    __deliver_all()
    slash("status")
    assert_true(__printed("Best here: Razor Arrow (level 25)"), "no vendor line")
    assert_true(__printed("Refill: Your quiver has no empty slot."), "no refill line")
end)

test("/ammo refill away from a vendor says to find one", function()
    hunter()
    slash("refill")
    assert_eq(#__buy_log, 0)
    assert_true(__printed("talk to a vendor that sells ammo first."), "no message")
end)

local function open_page()
    __settings_page():Hide()
    __settings_page():Show()
end

test("the settings page shows the settings and changes them through the same setters", function()
    hunter({ db = { autoBuy = false, keepCopper = 5000, capCopper = 2 * GOLD } })
    open_page()
    local autoBuy = __control("Auto buy", "UICheckButtonTemplate")
    assert_eq(autoBuy:GetChecked(), false)
    assert_eq(__control("Pulse", "UICheckButtonTemplate"):GetChecked(), true)
    local keepBox = __control("Keep gold", "InputBoxTemplate")
    assert_eq(keepBox:GetText(), "0.5")
    assert_eq(__control("Spending cap", "InputBoxTemplate"):GetText(), "2")
    assert_eq(__control("Spending cap", "MinimalSliderWithSteppersTemplate"):GetValue(), 2)
    local better = __control("When my ammo is better", "WowStyle1DropdownTemplate")
    assert_eq(__dropdown_text(better), "Buy nothing")

    autoBuy:SetChecked(true)
    __script(autoBuy, "OnClick")
    assert_eq(FletcherDB.autoBuy, true)
    for _, label in ipairs({ "Report purchases in chat", "Show vendor button", "Highlight best ammo",
        "Highlight other usable ammo", "Pulse" }) do
        local check = __control(label, "UICheckButtonTemplate")
        local before = check:GetChecked()
        check:SetChecked(not before)
        __script(check, "OnClick")
        assert_eq(check:GetChecked(), not before, label)
    end
    assert_eq(FletcherDB.report, false)
    assert_eq(FletcherDB.showButton, false)
    assert_eq(FletcherDB.highlight, false)
    assert_eq(FletcherDB.highlightOther, true)
    assert_eq(FletcherDB.pulse, false)

    __control("Keep gold", "MinimalSliderWithSteppersTemplate"):SetValue(7)
    assert_eq(FletcherDB.keepCopper, 7 * GOLD)
    assert_eq(keepBox:GetText(), "7", "the box did not follow the slider")

    keepBox:SetFocus()
    keepBox:SetText("1.5")
    __script(keepBox, "OnEnterPressed")
    assert_eq(FletcherDB.keepCopper, 15000)
    assert_eq(keepBox:GetText(), "1.5")
    keepBox:SetFocus()
    keepBox:SetText("lots")
    __script(keepBox, "OnEnterPressed")
    assert_eq(FletcherDB.keepCopper, 15000, "a bad amount changed the reserve")
    assert_eq(keepBox:GetText(), "1.5", "the box kept a bad amount")
    keepBox:SetFocus()
    keepBox:SetText("9")
    __script(keepBox, "OnEscapePressed")
    assert_eq(FletcherDB.keepCopper, 15000, "Escape applied the amount")

    __dropdown_pick(better, "Fill empty slots")
    assert_eq(FletcherDB.betterAmmo, "fill")
end)

test("a change made elsewhere shows on the open page", function()
    hunter()
    open_page()
    slash("auto off")
    assert_eq(__control("Auto buy", "UICheckButtonTemplate"):GetChecked(), false)
    slash("keep 3")
    assert_eq(__control("Keep gold", "InputBoxTemplate"):GetText(), "3")
end)

test("the page's status shows the quiver and the ammo slot, and where the vendor's side is", function()
    local contents = { [1] = { id = RAZOR, count = 150 } }
    hunter({ ammo = RAZOR, bags = { [0] = backpack(), [1] = quiver(4, contents) }, db = { autoBuy = false } })
    open_page()
    assert_eq(__row_value("Quiver"), "Light Quiver, 1 / 4 slots, 150 arrows")
    assert_eq(__row_value("Ammo slot"), "Razor Arrow, 150")
    -- The settings window and a vendor are never open together, so the page
    -- has no vendor rows; it says where to look instead.
    assert_false(pcall(__row_value, "Best here"), "a vendor row on the page")
    assert_false(pcall(__row_value, "Refill"), "a vendor row on the page")
    assert_true(__text_shown("At a vendor, hover the Fletcher button for the best ammo there and what a refill buys, or type /ammo status."),
        "no pointer to the vendor's side")

    -- The quiver row follows the bags each time the page opens.
    __bags[1].contents[2] = { id = RAZOR, count = 200 }
    open_page()
    assert_eq(__row_value("Quiver"), "Light Quiver, 2 / 4 slots, 350 arrows")

    hunter({ class = "MAGE" })
    open_page()
    assert_eq(__row_value("Quiver"), "Only hunters use ammo.")
end)

test("Defaults takes two clicks", function()
    hunter({ db = { autoBuy = false, keepCopper = 3 * GOLD } })
    open_page()
    local defaults = __page_button("Defaults")
    __script(defaults, "OnClick")
    assert_eq(FletcherDB.autoBuy, false, "one click reset")
    assert_eq(defaults:GetText(), "Click again")
    __script(defaults, "OnClick")
    assert_eq(FletcherDB.autoBuy, true)
    assert_eq(FletcherDB.keepCopper, 0)
    assert_eq(defaults:GetText(), "Defaults")

    __script(defaults, "OnClick")
    __settings_page():Hide()
    assert_eq(defaults:GetText(), "Defaults", "leaving the page did not put the question away")
end)

test("in combat the settings page waits for combat to end", function()
    hunter()
    __inCombat = true
    slash("")
    assert_eq(__settingsOpened, nil, "opened in combat")
    assert_true(__printed("opens when combat ends"), "no message")
    __inCombat = false
    __fire("PLAYER_REGEN_ENABLED")
    assert_eq(__settingsOpened, "Fletcher")
end)

test("without the client's settings window, /ammo says to use the commands", function()
    hunter({ noSettings = true })
    slash("")
    assert_true(__printed("the settings page is not available on this client"), "no message")
end)

--------------------------------------------------------------------------------
-- Better ammo already loaded
--------------------------------------------------------------------------------

local function thoriumHunter(choice, contents)
    return hunter({ level = 60, ammo = THORIUM_ARROW, db = { betterAmmo = choice },
        bags = { [0] = backpack(), [1] = quiver(4, contents) } })
end

test("better ammo loaded and skip: nothing bought, and the tooltip says why", function()
    thoriumHunter("skip")
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought worse ammo")
    assert_true(__overlay(5), "the vendor's best is not marked")
    local lines = hover_button()
    assert_true(has_line(lines, "Your Thorium Headed Arrow beat anything sold here."), lines_text(lines))
    click_button()
    assert_eq(#__buy_log, 0, "a click bought worse ammo")
end)

test("better ammo loaded and fill: only the empty slots are filled", function()
    local contents = { [1] = { id = THORIUM_ARROW, count = 200 }, [2] = { id = JAGGED, count = 50 } }
    thoriumHunter("fill", contents)
    __open_vendor(arrowVendor())
    __deliver_all()
    assert_eq(__buy_log[1].id, JAGGED)
    assert_eq(__bought(), 400, "filled more than the two empty slots")
    assert_true(__overlay(5), "the vendor's best is not marked")
end)

test("the vendor's own best in the ammo slot is not better ammo", function()
    hunter({ ammo = RAZOR })
    __open_vendor(arrowVendor())
    assert_eq(__buy_log[1] and __buy_log[1].id, RAZOR)
end)

--------------------------------------------------------------------------------
-- Secret values
--------------------------------------------------------------------------------

test("secret values from any getter never raise an error", function()
    local secretContents = { [1] = { id = __secret(), count = __secret(), locked = __secret() } }
    local cases = {
        function() __level = __secret() end,
        function() __money = __secret() end,
        function() __ammo = __secret() end,
        function() __ranged = __secret() end,
        function() __items[RAZOR].minLevel = __secret(); __items[RAZOR].itemLevel = __secret() end,
        function() __items[RAZOR].name = __secret() end,
        function() __items[RAZOR].class = __secret(); __items[RAZOR].subclass = __secret() end,
        function() __items[RAZOR].stack = __secret() end,
        function() __items[QUIVER].subclass = __secret() end,
        function() __bags[1].contents = secretContents end,
        function() __itemCountSecret = true end,
        function() __merchantCountSecret = true end,
    }
    for number, setup in ipairs(cases) do
        hunter({ db = { autoBuy = true } })
        setup()
        local ok, err = pcall(function()
            local vendor = arrowVendor()
            vendor[2].secretInfo = true
            __open_vendor(vendor)
            __deliver_all()
            hover_button()
            slash("status")
            __fire("GET_ITEM_INFO_RECEIVED", __secret(), __secret())
            __fire("UI_ERROR_MESSAGE", __secret(), __secret())
            __close_vendor()
        end)
        assert_true(ok, "case " .. number .. ": " .. tostring(err))
    end

    local ok, err = pcall(hunter, { class = __secret() })
    assert_true(ok, tostring(err))
    assert_false(__registered("MERCHANT_SHOW"), "a secret class was read as a hunter")
end)

test("money that cannot be read buys nothing", function()
    hunter()
    __money = __secret()
    __open_vendor(arrowVendor())
    assert_eq(#__buy_log, 0, "bought without knowing the money")
end)

--------------------------------------------------------------------------------

__print(("\n%d passed, %d failed"):format(passed, failed))
__exit_code = failed == 0 and 0 or 1
