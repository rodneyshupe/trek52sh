# TREK52

A faithful Bash port of **TREK52**, a version of the classic *Star Trek* game
originally written in DEC BASIC-PLUS for VT52 terminals. This port runs in any
modern terminal — Terminal.app, iTerm2, xterm, or over SSH — using standard
ANSI escape sequences and **pure Bash for everything, including the math**. No
external tools are required beyond a shell.

```text
------------------------       =================================================
 .  .  *  .  .  .  .  *        | *** | *** | *** | *** | *** | *** | *** | *** |
 .  .  .  K  .  .  .  .        | *** | *** | *** | *** | *** | *** | *** | *** |
 .  .  .  .  *  .  .  .  4 3 2 | *** | *** | *** | *** | *** | *** | *** | *** |
 .  .  .  E  .  .  .  .   \|/  | *** | *** | *** | *** |(116)| *** | *** | *** |
 .  *  .  .  .  .  .  .  5---1 | *** | *** | *** | *** | *** | *** | *** | *** |
 .  .  .  .  .  .  *  .   /|\  | *** | *** | *** | *** | *** | *** | *** | *** |
 *  .  .  .  .  .  .  .  6 7 8 | *** | *** | *** | *** | *** | *** | *** | *** |
 .  .  .  .  .  .  B  .        | *** | *** | *** | *** | *** | *** | *** | *** |
------------------------       =================================================
ENERGY:             3000       CONDITION:          RED
SHIELDS:               0 LOW   STARDATES REMAINING: 30
TORPEDOES:            10       KLINGONS REMAINING:  12
 == DAMAGE REPORT ==
Warp Engines: Working
Shields:      Working
Phasers:      Working
Torpedoes:    Working
SR Scanner:   Working
LR Scanner:   Working
Computer:     Working
   (W)arp  (P)hasers  (T)orpedoes  (S)hields  (L).R. Scan  (A)bandon Ship
```

## A little history

I first played this game in high school in the mid-1980s. Our school had a
**DEC PDP-11/70** running **RSTS/E**, and I spent more study-hall time than I
should admit hunched over a **VT52 terminal**, warping the Enterprise around an
8×8 galaxy and lobbing photon torpedoes at Klingons. The whole thing was text —
plain monochrome, white characters on a black screen, the cursor dancing around
via VT52 escape codes — and it was completely captivating. It was one of the
first times a computer felt less like a machine and more like a place.

Decades later I found a BASIC-PLUS implementation that captured exactly that
VT52 experience, and I wanted to be able to play it again on a modern machine
without dragging a PDP-11 out of a museum. So I ported it to Bash. The goal was
to preserve the original's look and feel — the same layout, the same commands,
the same slightly ruthless difficulty — while making it run anywhere a shell
does.

Why Bash, of all things? Because I have a habit of writing things in Bash that
have no business being written in Bash, purely for the fun of it. My
[travesty.sh](https://github.com/rodneyshupe/travestysh) project, for instance,
implements Markov-chain text generation entirely in the shell. A text-mode game
with trigonometry, floating-point course plotting, and a full-screen
cursor-addressed interface is squarely in the same category — Bash has no real
floating-point math and no business drawing a game board, which is exactly why
it was an enjoyable challenge. I leaned into it: the game carries its own
fixed-point math engine — sine, cosine, and square root included — written
entirely in Bash arithmetic. Half the point of this project was seeing how far
the shell could be pushed on its own.

## A torpedo you can watch

There's one thing I added that the original doesn't have. I have a vivid memory
from those PDP-11 days of *watching* a photon torpedo cross the short-range
scanner — a little marker stepping sector by sector toward its target, so you
could actually see whether your aim was true. When I first played Bob's faithful
VT52 recreation, that piece wasn't there: the torpedo's path was reported as a
list of coordinates (something like `4-2  5-3  6-4  7-5`) rather than animated.

I couldn't tell, decades on, whether I was remembering a different Star Trek
variant or simply misremembering — the old games blur together — but the memory
was strong enough that I wanted it back. So this port animates the torpedo: when
you fire, a marker travels across the short-range scanner, drawn and erased
sector by sector as it flies (a red `*` in colour mode, a `+` in monochrome so it
doesn't blend into the stars). Because you now see the path, the old textual
coordinate list is no longer shown — the animation says everything it did.


## Credits

This game stands on the shoulders of several people, and it's worth naming them:

- **Mike Mayfield** wrote the original *Star Trek* game in 1971 (famously on a
  Sysorex/SDS Sigma 7, later ported to BASIC and spread far and wide). Nearly
  every text-mode Star Trek game since — including this one — descends from his
  idea of hunting Klingons across a quadrant grid.
- **Bob Alexander** (bob@GalacticStudios.org) wrote **TREK52**, the DEC
  BASIC-PLUS implementation for the VT52 terminal, in 2022 and released it to
  the public domain. That program is the direct source this port is based on,
  and all the game design and screen layout are his work. The original project
  lives at [github.com/galacticstudios/Trek52](https://github.com/galacticstudios/Trek52).
- This **Bash port** simply translates Bob's BASIC-PLUS program to a POSIX-ish
  shell script, converting the VT52 escape sequences to ANSI and reimplementing
  the floating-point math as a pure-Bash fixed-point engine.

If you enjoy this, the credit for the fun belongs to Mike and Bob. I just made
it run on your laptop.

## What this port is

The original was written for VT52 hardware and the DEC RSTS/E environment. This
version keeps the gameplay identical but modernizes the plumbing:

- **VT52 → ANSI.** The original's VT52 cursor-addressing and clear-screen codes
  are converted to standard ANSI/VT100 sequences, so it renders correctly in
  today's terminals and over SSH.
- **Decimal math in pure Bash.** Bash has no floating-point arithmetic, and the
  game needs it for course headings (trigonometry), distances, and random
  scaling. This port carries a small fixed-point math engine — values scaled by
  a million, with its own `sqrt`, `sin`, and `cos` — written entirely in Bash
  integer arithmetic, so the math runs in-process with nothing to fork.
- **Minimal dependencies.** No associative arrays are used, so it runs on the
  stock `/bin/bash` (version 3.2) that macOS still ships, as well as on older
  systems you might reach over SSH.
- **Optional colour.** A `-c` / `--colour` flag adds status-aware colour to the
  display (see below). Off by default, so the original monochrome look is
  preserved.

## Requirements

- `bash` 3.2 or newer (the macOS system shell works)
- A terminal at least **80 columns × 24 rows** (the game checks and will ask you
  to enlarge the window if it's too small)

## Running it

```bash
chmod +x trek52.sh
./trek52.sh              # play in classic monochrome
./trek52.sh --colour     # play with colour (see below)
./trek52.sh --help       # usage
```

You can also run it explicitly with bash: `bash trek52.sh`.

### Run it straight from the web

You don't have to download the script first — you can pipe it into bash
directly from the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/rodneyshupe/trek52sh/main/trek52.sh | bash
```

To pass flags such as `--colour`, don't add them after `bash` in the pipe —
they'd be treated as arguments to bash, not the script. Use one of these forms
instead, which keep your terminal attached to stdin:

```bash
# Process substitution (bash/zsh): the script's own stdin stays on the terminal
bash <(curl -fsSL https://raw.githubusercontent.com/rodneyshupe/trek52sh/main/trek52.sh) --colour

# Or forward args through the pipe with bash -s
curl -fsSL https://raw.githubusercontent.com/rodneyshupe/trek52sh/main/trek52.sh | bash -s -- --colour
```

As always, piping a script from the internet straight into a shell runs
whatever that URL serves. Have a look at the source first if you'd rather be
sure of what you're running.

## How to play

You command the Starship Enterprise. The galaxy is an 8×8 grid of **quadrants**,
and each quadrant is an 8×8 grid of **sectors**. Your mission: destroy every
Klingon before you run out of stardates or energy.

### The display

- **Short-range scan** (top left): the sectors of your current quadrant.
  `E` is the Enterprise, `K` a Klingon, `B` a starbase, `*` a star, `.` empty
  space.
- **Galaxy chart** (top right): a summary of each quadrant you've scanned, shown
  as a three-digit code `KBS` — **K**lingons, **B**ases, **S**tars. Unscanned
  quadrants show `***`; your current quadrant is shown in parentheses.
- **Status panel**: energy, shields, torpedoes, stardates remaining, current
  alert condition, and Klingons remaining.
- **Damage report**: the repair status of each of your seven systems.

### Commands

Press a single key (no Enter needed):

| Key | Command | Description |
|-----|---------|-------------|
| `W` | Warp | Move the ship. You'll be asked for a **course** (1–8, circular, decimals allowed) and a **warp factor** (one quadrant = warp 1). |
| `P` | Phasers | Fire energy weapons at Klingons in the current quadrant. Damage falls off with distance. |
| `T` | Torpedoes | Fire a photon torpedo along a course. You watch it streak across the short-range scanner; a direct hit destroys a Klingon, a miss lets them fire back. |
| `S` | Shields | Transfer energy to/from shields. Shields absorb Klingon hits. |
| `L` | L.R. Scan | Long-range scan of the nine quadrants around you. |
| `A` | Abandon Ship | Quit the current game. |
| `R` | Refresh | Redraw the screen. |

Course headings follow a circular dial (the direction guide is drawn on screen):

```text
      4  3  2
       \ | /
        \|/
     5 ----- 1
        /|\
       / | \
      6  7  8
```

### Staying alive

- **Energy and stardates are everything.** Every warp burns energy *and* a
  stardate, and you only get 30 stardates. You lose if you run out of time,
  energy, or shields.
- **Repairs happen over time.** Damaged systems repair themselves a little with
  each warp; occasionally the crew fixes one outright.
- **Dock at a starbase to refuel.** Manoeuvre next to a `B` and your condition
  changes to `DOCKED`: energy, torpedoes, and all repairs are restored at once.
  Note that shields drop to zero when you dock, so raise them again before you
  leave a dangerous quadrant.

## Colour mode

Running with `-c` / `--colour` adds status-aware colour. Alignment is
unaffected — the colour codes have zero display width — and gameplay is
identical.

- **Damage report:** green when working, yellow at TTR 1, red at TTR 2 or more.
- **Short-range map:** Enterprise (`E`) and starbases (`B`) in cyan, Klingons
  (`K`) in red.
- **Energy:** red below 250.
- **Stardates:** yellow below 10, red below 5.
- **Torpedoes:** yellow at 2, red below 2.
- **Condition:** coloured to match its state (green / red / cyan when docked).
- **Messages:** the status/combat messages below the command line are tinted a
  subtle bright yellow so they stand out from the rest of the board.
- **Torpedo track:** a fired torpedo is drawn travelling across the short-range
  scanner as a red `*` (a `+` in monochrome, to avoid confusion with stars).

## Implementation notes

- The 8×8 galaxy and quadrant grids are stored in flat, index-addressed Bash
  arrays (`row * 8 + col`) rather than associative arrays, which is what lets
  the script run on bash 3.2.
- Floating-point work (`cos`, `sin`, `sqrt`, distance, random scaling) is done
  by a fixed-point math engine written in pure Bash: real numbers are stored as
  integers scaled by 1,000,000, with `sqrt` via Newton's method and `sin`/`cos`
  via a range-reduced Taylor series. Random numbers are built from `$RANDOM`.
- The terminal is switched to no-echo single-key mode for commands and briefly
  back to cooked mode for numeric entry, and it's always restored on exit.

## Licence

Bob Alexander released the original TREK52 to the public domain with no rights
reserved. This Bash port is offered in the same spirit — public domain, no
rights reserved. Have fun, and give Mike Mayfield and Bob Alexander the credit.
