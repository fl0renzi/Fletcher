# Fletcher

Refills your quiver or ammo pouch with the best ammo a vendor sells, and marks
it in the vendor window.

Fletcher is for hunters on World of Warcraft: Forever. Walk up to an ammo
vendor, and Fletcher does the rest: it finds the quiver or ammo pouch you have
equipped, picks the best ammo of that kind the vendor sells, highlights its
icon in the vendor window, and buys exactly enough rounds to fill the bag -
one purchase at a time, never more than the bag needs, and never past the gold
you want kept.

## What it does at a vendor

- **The gold border** marks the best ammo you can use: the highest required
  level you meet, then the highest item level, then the cheapest per round.
  It gently pulses; the pulse can be turned off.
- **The dim green border** (off by default) marks the other ammo of your
  bag's kind that the vendor sells.
- **The button** at the vendor window's top right talks to you: its tooltip
  says what your bag holds, what the best ammo here is, and what a refill
  would cost. Left click refills, right click opens the options.
- **Auto buy** fills the bag once per visit. Hold **Shift** while opening the
  vendor to skip it once. The manual click works whatever the setting says.

## The bag decides

A quiver wants arrows; an ammo pouch wants bullets. Whichever ammo bag is
equipped decides what Fletcher buys and highlights, first bag in bag order if
you carry several. With no ammo bag equipped, your ranged weapon decides: a
bow or crossbow wants arrows, a gun wants bullets. A slot that holds other
ammo, or is locked, is never moved, sold or replaced - it just does not count.

## Settings

Under **Options > AddOns > Fletcher**, at the vendor button's right-click
menu, or with the commands:

| Command | Meaning |
| --- | --- |
| `/ammo auto on` / `off` | buy on opening a vendor |
| `/ammo keep 1` | keep gold: never spend below it (`0.5` is half a gold) |
| `/ammo cap 5` | spending cap: the most one refill may spend |
| `/ammo report on` / `off` | one chat line when an automatic refill is done |
| `/ammo button on` / `off` | the vendor window's button |
| `/ammo highlight on` / `off`, `/ammo others on` / `off` | the borders |
| `/ammo pulse on` / `off` | the gold border breathing |
| `/ammo reset` | everything back to a fresh install |
| `/ammo help` | this list |

Every setting applies at once, from wherever it is changed. The settings are
account-wide: set them once, all your characters keep them.

## One more thing

Forever is a beta client, and its SavedVariables can take a reload to show
up. Nothing in Fletcher needs one - every part is live from the moment you
set it, and keeps working if a saved write does not survive.

## Installing

Grab the zip from the Releases page and unpack the `Fletcher` folder into
`Interface/AddOns`, or on the machine that plays the game:

    npm run deploy

See `npm run deploy -- --help` in `scripts/deploy.mjs` for the details.

---

Fletcher targets the Forever client only. It does nothing for a non-hunter
and costs nothing when no vendor is open.
