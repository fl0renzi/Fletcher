-- Fletcher - tests/spec.lua
-- Behaviour tests for the addon, run on top of tests/wow_stub.lua. Every test
-- boots a fresh session with __boot, so no test depends on another. The
-- fixtures below are the plan's: Rough/Sharp/Razor/Jagged arrows and their
-- bullet sisters, a 4 slot quiver (family 0x1), a pouch (0x2), a bow, a gun,
-- and a crossbow that shoots arrows too.

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

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local ITEMS = {
    [2512]  = { name = "Rough Arrow",   class = 6, subclass = 2, iLevel = 1,  reqLevel = 1,  stack = 200 },
    [2515]  = { name = "Sharp Arrow",   class = 6, subclass = 2, iLevel = 4,  reqLevel = 10, stack = 200 },
    [3030]  = { name = "Razor Arrow",   class = 6, subclass = 2, iLevel = 7,  reqLevel = 25, stack = 200 },
    [11285] = { name = "Jagged Arrow",  class = 6, subclass = 2, iLevel = 11, reqLevel = 40, stack = 200 },
    [2516]  = { name = "Light Shot",    class = 6, subclass = 3, iLevel = 1,  reqLevel = 1,  stack = 200 },
    [2519]  = { name = "Heavy Shot",    class = 6, subclass = 3, iLevel = 4,  reqLevel = 10, stack = 200 },
    [3033]  = { name = "Solid Shot",    class = 6, subclass = 3, iLevel = 7,  reqLevel = 25, stack = 200 },
    [5571]  = { name = "Small Quiver",  class = 11, subclass = 2, stack = 6 },
    [5572]  = { name = "Medium Ammo Pouch", class = 11, subclass = 3, stack = 6 },
    [2503]  = { name = "Laminated Recurve Bow", class = 2, subclass = 2 },
    [2903]  = { name = "Dwarven Hand Cannon",   class = 2, subclass = 3 },
    [11288] = { name = "Heavy Crossbow", class = 2, subclass = 18 },
}

local RAZOR_VENDOR = {
    { id = 2512, price = 1 },
    { id = 2515, price = 2 },
    { id = 3030, price = 4 },
    { id = 11285, price = 8 },
}

-- A hunter at 30 with a bow, a 2 slot quiver in bag 1 and 100g. overrides
-- fills into the boot options, so each test names only what it changes.
local function hunterBoot(overrides)
    local options = {
        items = ITEMS,
        level = 30,
        money = 1000000, -- 100g
        inv = { [1] = 5571 },
        bags = { [1] = { slots = 2, family = 0x1 } },
        ranged = { id = 2503 },
    }
    for key, value in pairs(overrides or {}) do options[key] = value end
    return __boot(options)
end

local function emptyQuiver()
    return { [1] = { slots = 2, family = 0x1 } }
end

local function buyTotal()
    local total = 0
    for _, entry in ipairs(__buy_log) do total = total + entry.count end
    return total
end

local function bagSlot(bag, slot)
    return __bags[bag][slot]
end

--------------------------------------------------------------------------------
-- The client gate
--------------------------------------------------------------------------------

test("a client that is not Forever stays inert", function()
    local ns = __boot({ interface = 120000 })
    assert_false(ns.Allowed, "the addon did not stop itself")
    assert_true(__printed("is disabled on this client"), "no disabled note")
    assert_eq(_G.FletcherDB, nil, "the saved settings were touched")
    assert_false(__registered("MERCHANT_SHOW"), "a vendor event was registered")
end)

test("an interface the client refuses to answer fails open", function()
    local ns = __boot({ interface = __secret() })
    assert_true(ns.Allowed, "a healthy client was blocked")
    assert_true(__registered("MERCHANT_SHOW"), "no vendor event was registered")
end)

--------------------------------------------------------------------------------
-- Characters that are not hunters
--------------------------------------------------------------------------------

test("a non hunter registers nothing and says so", function()
    local ns = __boot({ class = "WARRIOR" })
    assert_false(__registered("MERCHANT_SHOW"), "a vendor event was registered")
    assert_false(ns.API.VendorOpen(), "a vendor is open before one is")
    SlashCmdList["FLETCHER"]("refill")
    assert_true(__printed("only a hunter carries a quiver"), "no explanation")
end)

--------------------------------------------------------------------------------
-- Reading the quiver
--------------------------------------------------------------------------------

test("a quiver decides arrows and a pouch decides bullets", function()
    local ns = hunterBoot()
    local status = ns.API.Status()
    assert_eq(status.quiver, "Small Quiver (bag 1)", "quiver line")
    assert_eq(status.kind, "holds arrows", "kind")

    local pouch = hunterBoot({
        inv = { [1] = 5572 },
        bags = { [1] = { slots = 2, family = 0x2 } },
        ranged = { id = 2903 },
    })
    assert_eq(pouch.API.Status().kind, "holds bullets", "pouch kind")

    -- Two bags: the first in bag order decides; the other kind is left out.
    local mixed = hunterBoot({
        inv = { [1] = 5571, [2] = 5572 },
        bags = { [1] = { slots = 2, family = 0x1 }, [2] = { slots = 2, family = 0x2 } },
    })
    assert_eq(mixed.API.Status().kind, "holds arrows", "bag order decides")
end)

test("the ranged weapon fills in when no bag is equipped", function()
    local ns = hunterBoot{ inv = {}, bags = {} }
    SlashCmdList["FLETCHER"]("refill")
    assert_true(__printed("open a vendor that sells ammo"), "no instruction")
    assert_false(__printed("only a hunter"), "the not-active note leaked in")

    -- A crossbow shoots arrows too, so the visit picks arrows for it.
    local crossbow = hunterBoot{ inv = {}, bags = {}, ranged = { id = 11288 } }
    __open_vendor(RAZOR_VENDOR)
    assert_eq(crossbow.API.Best().itemID, 3030, "the crossbow was not read as arrows")

    -- With no quiver at all the vendor button shows anyway, to explain.
    assert_true(_G.FletcherVendorButton:IsShown(), "the button does not explain")
end)

--------------------------------------------------------------------------------
-- The vendor visit
--------------------------------------------------------------------------------

test("the best ammo is highlighted and the button is drawn", function()
    local full = hunterBoot{ bags = { [1] = { slots = 2, family = 0x1,
        [1] = { id = 3030, count = 200 }, [2] = { id = 3030, count = 200 } } } }
    __open_vendor(RAZOR_VENDOR)
    full.API.Refill("manual")
    assert_false(__printed("bought"), "a full quiver bought something")
    assert_true(full.API.Quiver().need <= 0, "a full quiver asked for rounds")

    -- The empty quiver picks the razor arrow, third on the page.
    hunterBoot()
    __open_vendor(RAZOR_VENDOR)
    assert_eq(FletcherVendorButton ~= nil, true, "no vendor button")
    local overlays = __overlays()
    assert_eq(overlays[3].__shown, true, "the best's overlay hidden")
    assert_eq(overlays[3].border.__vertexColor[1], 1.0, "red channel")
    assert_eq(overlays[3].border.__vertexColor[2], 0.78, "green channel")
    for n = 1, 4 do
        if n ~= 3 then assert_eq(overlays[n].__shown, false, "overlay " .. n .. " lit") end
    end
    assert_eq(FletcherVendorButton.__normal, "Interface\\Icons\\INV_Misc_QuestionMark",
        "the button does not show the best ammo's icon")

    -- The pulse breathes in the gold border.
    local pulse = overlays[3].pulse
    assert_true(pulse, "no pulse group")
    assert_true(pulse:IsPlaying(), "the pulse is not playing")
end)

test("the pick follows required level, usability and stock", function()
    local vendor = {
        { id = 2512, price = 1 },
        { id = 11285, price = 8 },                 -- needs level 40
        { id = 3030, price = 4, usable = false },  -- the game says unusable
        { id = 2515, price = 222, stock = 0 },     -- gone, whatever it costs
    }
    local ns = hunterBoot()
    __open_vendor(vendor)
    assert_eq(ns.API.Best().itemID, 2512, "a guarded item was picked")

    -- A secret level reads as unknown, and every level is allowed.
    local secret = hunterBoot{ level = __secret() }
    __open_vendor(vendor)
    assert_eq(secret.API.Best().itemID, 11285, "an unknown level did not open the gate")
end)

test("the best on a later page keeps its highlight, the page's own does not", function()
    -- Seven items a page at a time of 6: the jagged arrow sits on page 2.
    local vendor = {
        { id = 2512, price = 1 },
        { id = 2515, price = 2 },
        { id = 3030, price = 4 },
        { id = 2516, price = 1 },
        { id = 2519, price = 2 },
        { id = 3033, price = 3 },
        { id = 11285, price = 8 },
    }
    local ns = hunterBoot{ level = 40 }
    __open_vendor(vendor)
    __goto_page(2)
    assert_eq(ns.API.Best().itemID, 11285, "the best was not the jagged arrow")
    local overlays = __overlays()
    assert_eq(overlays[1].__shown, true, "the second page's best is not lit")
    __goto_page(1)
    for n = 1, 6 do
        assert_eq(overlays[n].__shown, false, "page 1's overlay " .. n .. " lit")
    end
end)

test("other usable ammo dims green only when the setting asks", function()
    hunterBoot()
    __open_vendor(RAZOR_VENDOR)
    local overlays = __overlays()
    assert_eq(overlays[1].__shown, false, "others lit with the setting off")
    SlashCmdList["FLETCHER"]("others on")
    local after = __overlays()
    assert_eq(after[1].__shown, true, "rough not dimmed green")
    assert_eq(after[2].__shown, true, "sharp not dimmed green")
    assert_eq(after[1].border.__vertexColor[1], 0.4, "red channel")
    assert_eq(after[1].border.__vertexColor[2], 0.8, "green channel")
    SlashCmdList["FLETCHER"]("others off")
    assert_eq(__overlays()[1].__shown, false, "green stayed on after off")
end)

--------------------------------------------------------------------------------
-- The refill
--------------------------------------------------------------------------------

test("opening a vendor buys exactly what fills the quiver", function()
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(#__buy_log, 2, "the wrong number of purchases")
    assert_eq(__buy_log[1].count, 200, "first purchase")
    assert_eq(__buy_log[2].count, 200, "second purchase")
    assert_eq(__buy_log[1].cost, 800, "first cost")
    assert_eq(__money, 998400, "the money was not taken right")
    assert_eq(bagSlot(1, 1).id, 3030, "slot 1")
    assert_eq(bagSlot(1, 1).count, 200, "slot 1 count")
    assert_eq(bagSlot(1, 2).count, 200, "slot 2 count")
    assert_true(__printed("bought 400 arrows for 16s"), "no report line")
    assert_true(__printed("The quiver now holds 400 / 400 rounds"), "no quiver state")
end)

test("the need is fixed at the start and other ammo is never moved", function()
    hunterBoot{ bags = { [1] = { slots = 3, family = 0x1,
        [1] = { id = 2512, count = 200 }, -- another ammo, full
        [2] = { id = 3030, count = 100 } } } }
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 300, "the need was not 300")
    assert_eq(bagSlot(1, 1).id, 2512, "the other ammo was moved")
    assert_eq(bagSlot(1, 1).count, 200, "the other ammo was changed")
    assert_eq(bagSlot(1, 2).count, 200, "the razor slot was not topped up")
    assert_eq(bagSlot(1, 3).count, 200, "the empty slot was not filled")
    assert_true(__printed("bought 300 arrows for 12s"), "no report line")
end)

test("a locked slot is left alone", function()
    hunterBoot{ bags = { [1] = { slots = 2, family = 0x1,
        [1] = { id = 3030, count = 100, locked = true } } } }
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 200, "the locked slot asked for rounds")
    assert_eq(bagSlot(1, 1).count, 100, "the locked slot was touched")
    assert_eq(bagSlot(1, 2).count, 200, "the empty slot was not filled")
end)

test("the keep gold reserve buys nothing when it has to", function()
    local ns = hunterBoot{ money = 2000, bags = emptyQuiver() }
    SlashCmdList["FLETCHER"]("keep 0.5")
    assert_eq(ns.API.GetDB().keepCopper, 5000, "the reserve was not 50s")
    __open_vendor(RAZOR_VENDOR)
    assert_true(__printed("bought nothing: 400 arrows would cost 16s and you have 20s."),
        "no refused line")
    assert_eq(#__buy_log, 0, "something was bought")
end)

test("the spending cap limits one refill", function()
    local ns = hunterBoot{ bags = emptyQuiver() }
    SlashCmdList["FLETCHER"]("cap 0.1")
    assert_eq(ns.API.GetDB().capCopper, 1000, "the cap was not 10s")
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 250, "the cap was not respected")
    assert_eq(__buy_log[1].count, 200, "first purchase size")
    assert_eq(__buy_log[2].count, 50, "second purchase size")
    assert_eq(__money, 999000, "the cap did not keep the money")
    assert_true(__printed("bought 250 arrows for 10s. Not enough money under the reserve and the cap for more."),
        "no cap stop line")
end)

test("the money running short mid refill stops it", function()
    hunterBoot{ money = 800, bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED") -- nothing more happens; the queue stopped
    assert_eq(buyTotal(), 200, "more than the money bought")
    assert_true(__printed("bought 200 arrows for 8s. Not enough money under the reserve and the cap for more."),
        "no money stop line")
end)

test("Shift skips the auto buy; the button still works", function()
    local ns = hunterBoot{ shift = true, bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 0, "something was bought with Shift held")
    __script(_G.FletcherVendorButton, "OnClick", "LeftButton")
    assert_eq(#__buy_log, 1, "the manual click bought nothing")
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 400, "the manual refill did not finish")
end)

test("a second refill while one is out is ignored", function()
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 1, "no purchase started")
    SlashCmdList["FLETCHER"]("refill")
    assert_eq(#__buy_log, 1, "a second refill doubled the purchase")
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 400, "the refill did not finish")
end)

test("a purchase with no bag update stops on the timer", function()
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    __advance(3)
    assert_true(__printed("no bag update followed the purchase"), "no timeout note")
    local purchases = #__buy_log
    __fire("BAG_UPDATE_DELAYED")
    __fire("MERCHANT_UPDATE")
    __advance(3)
    assert_eq(#__buy_log, purchases, "the stopped queue bought on")
end)

test("the vendor closing stops the refill and empties the window", function()
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED") -- the first purchase lands; the second goes out
    __close_vendor()
    assert_true(__printed("bought 200 arrows for 8s. The vendor closed."), "no closed line")
    assert_false(__registered("BAG_UPDATE_DELAYED"), "the visit's events stayed")
    local purchases = #__buy_log
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(#__buy_log, purchases, "the closed refill bought on")
    local overlays = __overlays()
    for n = 1, 6 do
        assert_eq(overlays[n].__shown, false, "overlay " .. n .. " still lit")
    end
    assert_eq(_G.FletcherVendorButton.__shown, false, "the button stayed")
end)

test("an uncached item is waited for, and arrives", function()
    ITEMS[3030].uncached = true
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    assert_true(__registered("GET_ITEM_INFO_RECEIVED"), "not waiting for the cache")
    assert_eq(#__buy_log, 0, "the wait bought something")

    -- The details arrive; the deferred auto buy runs.
    ITEMS[3030].uncached = nil
    __fire("GET_ITEM_INFO_RECEIVED")
    assert_eq(#__buy_log, 1, "the arrival did not buy")
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 400, "the refill did not finish")
end)

test("three tries, and the visit goes on with what is cached", function()
    ITEMS[3030].uncached = true
    hunterBoot{ bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    __fire("GET_ITEM_INFO_RECEIVED")
    __fire("GET_ITEM_INFO_RECEIVED")
    __fire("GET_ITEM_INFO_RECEIVED")
    assert_false(__registered("GET_ITEM_INFO_RECEIVED"), "the wait never stopped")
    -- The sharp arrow was cached all along: the visit buys it.
    assert_eq(#__buy_log, 1, "the cached best did not come back")
    assert_eq(__buy_log[1].count, 200, "the wrong item was bought")
    ITEMS[3030].uncached = nil
end)

--------------------------------------------------------------------------------
-- Secret values
--------------------------------------------------------------------------------

test("secret game data reads as unknown, and nothing breaks", function()
    -- A secret money amount is treated as no money: nothing is bought.
    hunterBoot{ money = __secret(), bags = emptyQuiver() }
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 0, "a secret money bought something")
    assert_true(__printed("bought nothing"), "no refused line")

    -- A secret slot count: the bag cannot be counted, so nothing is asked.
    hunterBoot{ bags = { [1] = { slots = __secret(), family = 0x1 } } }
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 0, "an uncountable bag bought something")
end)

--------------------------------------------------------------------------------
-- The settings page
--------------------------------------------------------------------------------

test("the settings page reflects and changes the settings", function()
    local ns = hunterBoot()
    SlashCmdList["FLETCHER"]("cap 1")
    SlashCmdList["FLETCHER"]("")  -- opens the page
    assert_eq(__settingsOpened, "Fletcher", "the page did not open")

    local auto = __control("Auto buy", "UICheckButtonTemplate")
    assert_eq(auto:GetChecked(), true, "auto buy off on a fresh install")

    -- The status rows say what the character carries.
    local found
    for _, line in ipairs(__page_texts()) do
        if line:find("Quiver: Small Quiver", 1, true) then found = line break end
    end
    if not found then error("no quiver status line", 2) end

    -- Defaults asks twice before it resets.
    local defaults = __page_button("Defaults")
    __script(defaults, "OnClick")
    assert_eq(defaults:GetText(), "Click again", "the first click reset at once")
    __script(defaults, "OnClick")
    assert_eq(ns.API.GetDB().capCopper, 0, "the reset did not run")
    assert_eq(defaults:GetText(), "Defaults", "the button did not cool down")
end)

test("the keep gold box applies a typed amount", function()
    local ns = hunterBoot()
    SlashCmdList["FLETCHER"]("")
    local box = __control("Keep gold", "InputBoxTemplate")
    box:SetFocus()
    box:SetText("2")
    box:ClearFocus()
    assert_eq(ns.API.GetDB().keepCopper, 20000, "the typed 2g was not applied")

    box:SetFocus()
    box:SetText("99999")
    box:ClearFocus()
    assert_eq(ns.API.GetDB().keepCopper, 10000000, "an out of range amount applied")
end)

--------------------------------------------------------------------------------
-- The right-click menu
--------------------------------------------------------------------------------

test("the menu reflects and changes the settings", function()
    local ns = hunterBoot{ bags = emptyQuiver() }
    SlashCmdList["FLETCHER"]("auto off")
    __open_vendor(RAZOR_VENDOR)
    __script(_G.FletcherVendorButton, "OnClick", "RightButton")
    assert_true(__menu ~= nil, "no menu opened")

    -- The settings' current values are checked.
    local auto = __menu_item("Auto buy")
    assert_eq(__menu_selected(auto), false, "auto buy checked while off")
    assert_eq(__menu_selected(__menu_item("Keep gold", "None")), true, "None checked with no reserve")
    assert_eq(__menu_selected(__menu_item("Keep gold", "1g")), false, "1g checked")

    -- A click goes through the same setter.
    __menu_click(__menu_item("Keep gold", "10s"))
    assert_eq(ns.API.GetDB().keepCopper, 1000, "the menu click was not applied")
    assert_eq(__menu_selected(__menu_item("Keep gold", "10s")), true, "the menu did not follow")

    __menu_click(auto)
    assert_eq(ns.API.GetDB().autoBuy, false, "the menu's auto buy did not turn off")

    -- Refill now is the manual refill.
    __menu_click(__menu_item("Refill now"))
    assert_eq(#__buy_log, 1, "refill now bought nothing")
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")
    assert_eq(buyTotal(), 400, "the manual refill did not run")
end)

--------------------------------------------------------------------------------
-- The slash commands
--------------------------------------------------------------------------------

test("the slash commands go through the same setters", function()
    local ns = hunterBoot()

    SlashCmdList["FLETCHER"]("auto off")
    assert_eq(ns.API.GetDB().autoBuy, false, "auto did not turn off")
    assert_true(__printed("auto off."), "no line about it")

    SlashCmdList["FLETCHER"]("auto turnip")
    assert_true(__printed("/fletcher auto on or /fletcher auto off."), "no usage line")
    assert_eq(ns.API.GetDB().autoBuy, false, "a bad word changed the setting")

    SlashCmdList["FLETCHER"]("keep bananas")
    assert_true(__printed("give a gold amount"), "no usage line")
    assert_eq(ns.API.GetDB().keepCopper, 0, "a bad word changed the reserve")
end)

test("auto off, no vendor buy; auto on buys", function()
    hunterBoot{ bags = emptyQuiver() }
    SlashCmdList["FLETCHER"]("auto off")
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 0, "the auto refill ran while off")

    SlashCmdList["FLETCHER"]("auto on")
    __close_vendor()
    __open_vendor(RAZOR_VENDOR)
    assert_eq(#__buy_log, 1, "auto on did not buy")
end)

test("reset puts every setting back", function()
    local ns = hunterBoot()
    SlashCmdList["FLETCHER"]("keep 5")
    SlashCmdList["FLETCHER"]("cap 1")
    SlashCmdList["FLETCHER"]("auto off")
    SlashCmdList["FLETCHER"]("others on")
    SlashCmdList["FLETCHER"]("reset")
    local db = ns.API.GetDB()
    assert_eq(db.keepCopper, 0, "the reserve")
    assert_eq(db.capCopper, 0, "the cap")
    assert_eq(db.autoBuy, true, "auto buy")
    assert_eq(db.highlight and db.pulse and db.report and db.showButton, true, "the toggles")
    assert_eq(db.highlightOther, false, "others")
end)

--------------------------------------------------------------------------------
-- The vendor window follows its settings
--------------------------------------------------------------------------------

test("the button and the highlight follow their settings", function()
    hunterBoot{ bags = emptyQuiver() }

    -- Auto buy runs the refill; let it finish before the next open.
    __open_vendor(RAZOR_VENDOR)
    __fire("BAG_UPDATE_DELAYED")
    __fire("BAG_UPDATE_DELAYED")

    SlashCmdList["FLETCHER"]("button off")
    __open_vendor(RAZOR_VENDOR) -- the quiver is full now; nothing to buy
    assert_eq(_G.FletcherVendorButton.__shown, false, "the button drew while off")

    SlashCmdList["FLETCHER"]("button on")
    SlashCmdList["FLETCHER"]("highlight off")
    __fire("MERCHANT_SHOW")
    MerchantFrame_Update()
    assert_eq(_G.FletcherVendorButton.__shown, true, "the highlight off took the button out")
    local overlays = __overlays()
    for n = 1, 6 do
        assert_eq(overlays[n].__shown, false, "overlay " .. n .. " lit while off")
    end

    -- The pulse off leaves the border still.
    SlashCmdList["FLETCHER"]("highlight on")
    SlashCmdList["FLETCHER"]("pulse off")
    __fire("MERCHANT_SHOW")
    MerchantFrame_Update()
    assert_eq(overlays[3].__shown, true, "the best not lit")
    if overlays[3].pulse then
        assert_eq(overlays[3].pulse:IsPlaying(), false, "the pulse played while off")
    end
end)

--------------------------------------------------------------------------------
-- The end
--------------------------------------------------------------------------------

__print(("passed %d, failed %d"):format(passed, failed))
__exit_code = failed > 0 and 1 or 0
