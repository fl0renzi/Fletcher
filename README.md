# Fletcher

Refills your quiver or ammo pouch at the vendor, for World of Warcraft: Forever.

Talk to a vendor that sells ammo and Fletcher looks at the quiver or ammo pouch you have equipped,
picks the best arrows or bullets the vendor sells that you can use, marks them in the vendor window,
and buys a full stack for every empty slot of the bag. One line in chat says what it bought:

```
Fletcher: bought 1400 Razor Arrow for 7s. Quiver full (10 / 10 slots).
```

## What it buys

- **Which kind**: the bag decides. A quiver gets arrows, an ammo pouch gets bullets. If your ranged
  weapon fires the other kind, Fletcher still follows the bag and says so once per vendor visit.
  With no quiver or ammo pouch equipped nothing is bought, though the best ammo for your weapon is
  still marked.
- **Which ammo**: the best of what the vendor sells that you can use right now: the highest required
  level at or below yours, then the highest item level, then the cheapest single round. Only ammo
  sold for gold counts, and nothing sold out. Fletcher ranks whatever the vendor has, so special or
  regional vendor ammo works too. It reads the vendor's list as the window shows it, so the vendor
  window's filter applies.
- **How much**: it goes by the quiver's slots, not by how many rounds it could hold. Each empty slot
  gets one full stack. A slot that already holds ammo, a part stack included, is left exactly as it
  is: the game puts a bought stack in an empty slot, not on top of a part stack, so buying for a part
  stack would only fill your backpack. Fletcher never moves, sells or replaces your things, and
  nothing is bought for your normal bags.
- **Ammo you already carry**: stacks of the chosen ammo in your normal bags count toward the empty
  slots, so Fletcher does not buy what you already have. It tells you to move them into the quiver
  instead.
- **Exact amounts**: vendors price ammo by the batch (200 arrows, for example), but they sell any
  number of rounds, at their share of the batch's price rounded up to the copper. Fletcher buys
  exactly what the empty slots need, so nothing extra lands in your bags.
- **Better ammo already loaded**: when your ammo slot holds ammo that beats anything the vendor sells
  (crafted, reputation or raid ammo), Fletcher buys nothing, so it never spends money on worse ammo.
  Set *When my ammo is better* to *Fill empty slots* to have it fill the empty slots with the
  vendor's best anyway, as a backup.
- **Money**: *Keep gold* is money a refill never touches, and *Spending cap* is the most one refill
  spends. Fletcher buys as much as fits and says what it left out. Both are off for a fresh install.

Buying starts when you talk to the vendor. Hold **Shift** while you talk to the vendor to skip it
once, or turn *Auto buy* off and click the Fletcher button when you want a refill. A refill stops at
once if you close the vendor window or the game refuses a purchase (full bags, not enough money).

## The vendor window

- **The mark**: the best ammo's icon gets a soft gold glow and, with *Pulse* on, the gold border that
  runs around an ability when it procs: a burst when the mark appears, then the running border. It
  is the game's own art, the same glow the trade window puts on an item. With *Pulse* off the gold
  glow stays still. The mark follows the pages as you turn them and hides on the buyback tab.
  *Highlight other usable ammo* adds a still green glow, the one the bags put on a new item, around
  the other ammo of the same kind you can use.
- **The Fletcher button**: a small button at the top of the vendor window with the chosen ammo's
  icon, shown while the vendor sells ammo your quiver takes (or any ammo, when you have no quiver,
  to say why nothing is bought). It is grey while a click would buy nothing. Left click to refill,
  right click for the options. Hover it to see your quiver, the best ammo here, what a refill would
  buy and cost, and which page the best ammo is on when it is not on this one.

## Settings page

Type `/ammo`, pick *Settings...* in the button's right-click menu, or open the game's *Options* and
look under *AddOns*:

- **Buying**: *Auto buy*, *Keep gold* and *Spending cap* (drag the slider, or type an exact amount
  of gold such as `0.5` in the box beside it and press Enter), *When my ammo is better* and *Report
  purchases in chat*.
- **Vendor window**: *Show vendor button*, *Highlight best ammo*, *Highlight other usable ammo* and
  *Pulse*.
- **Status**: your quiver, its slots in use and the rounds in it, and the ammo in your ammo slot.
  The game closes the vendor window when you open the settings, so what the vendor sells and what a
  refill would buy are shown at the vendor instead: hover the Fletcher button, or type
  `/ammo status`.
- **Defaults** (top right) puts every setting back to how a fresh install has it. It asks for a
  second click first.

Every change applies at once. The page, the right-click menu and the slash commands all change the
same settings. In combat the game will not open its settings window, so `/ammo` opens the page as
soon as combat ends.

## Slash commands

`/fletcher`, or `/ammo` for short:

```
/ammo                     opens the settings page
/ammo help                lists these commands
/ammo status              your quiver, its rounds, and the best ammo at the open vendor
/ammo refill              fills the quiver now (talk to a vendor first)
/ammo auto on | off       buy when you talk to a vendor that sells your ammo
/ammo highlight on | off  mark the best ammo in the vendor window
/ammo others on | off     mark the other ammo you can use, in green
/ammo pulse on | off      the proc glow on the best ammo, or a still glow
/ammo report on | off     say in chat what was bought
/ammo button on | off     the Fletcher button in the vendor window
/ammo keep <gold>         money a refill never touches, for example: 1, 0.5, 0
/ammo cap <gold>          the most one refill spends, 0 for no cap
/ammo better skip | fill  what to do when your loaded ammo beats the vendor's
/ammo reset               every setting back to its default
```

On a character that is not a hunter Fletcher does nothing at vendors and stops listening after
login. The settings page is still there, since the settings are shared by every character.

## Install

Install it from CurseForge, or copy `Fletcher.toc`, `Fletcher.lua`, `Fletcher_Vendor.lua` and
`Fletcher_Options.lua` into `Interface\AddOns\Fletcher` in the Forever client folder, then restart
the game. The game reads the `.toc` only at startup, so a new addon, or a new file in one, is not
picked up by `/reload`.

## Notes

- Forever only. The toc is `16001`; on any other client the addon prints one line and stays inert,
  leaving `FletcherDB` untouched.
- Settings live in the account-wide `FletcherDB`. The Forever beta writes a per-character
  SavedVariables file but never loads it back. Every setting applies immediately, with no reload.
- Event-driven: away from a vendor a hunter listens only to `MERCHANT_SHOW` and `MERCHANT_CLOSED`.
  At a vendor, buying is one purchase at a time, each sent when the game reports the bags changed
  after the one before (`BAG_UPDATE_DELAYED`). A purchase that has not landed after three seconds
  stops the refill; that one-shot safety net is the only timer. A refill never buys more than it
  counted at its start, whatever the bags do meanwhile.
- The vendor window's parts are built the first time a hunter talks to a vendor. They follow the
  window through `hooksecurefunc` on the functions that draw its pages, and every frame is
  Fletcher's own, so nothing taints the vendor window.
- Item details the client has not cached yet are waited for (`GET_ITEM_INFO_RECEIVED`); after three
  tries Fletcher stops waiting for that visit, buys nothing it could not check, and says so.
- Forever runs on the modern client, so Fletcher uses only the `C_` calls (`C_MerchantFrame`,
  `C_Item`, `C_Container`). A client without one gets one line at login and no Fletcher.

## Tests

`npm install` once, then `npm test`. It loads every file the `.toc` lists into a Lua VM on a mocked
WoW API (`tests/wow_stub.lua`) and runs `tests/spec.lua`: the quiver and ammo logic, the buying
queue, the vendor window, the settings, the slash commands, the secret-value guards and the client
gate. The mock is not the game, so still check Fletcher at a vendor in the client.

`npm run deploy -- --local` copies the working tree into the Forever client's AddOns folder, named
in the gitignored `deploy.local.json` as `{"addonsPath": "<...>\\Interface\\AddOns\\Fletcher"}`,
with the toc's version stamped as `v<version>-dev`. `npm run deploy` installs the latest release
instead, and `--check` only reports the versions.

## Releasing

Add the release's notes to `CHANGELOG.md`, which becomes the file's changelog on CurseForge, then
push a tag such as `v1.0.0`. Neither the changelog nor this readme goes into the zip. The release
workflow (`.github/workflows/release.yml`) runs the tests, then the BigWigs packager builds the zip
from `.pkgmeta`, writes the tag into the toc's `Version`, and publishes it as a GitHub release and
to CurseForge under the Forever flavor. A tag containing `alpha` or `beta` is uploaded as that
release type. CurseForge needs the `CF_API_TOKEN` repository secret and the toc's
`X-Curse-Project-ID`; without them the packager only makes the GitHub release.
