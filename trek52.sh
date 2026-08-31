#!/usr/bin/env bash

declare -r TITLE="TREK52"
declare -r VERSION="1.0.1"
declare -r AUTHOR="Rodney Shupe <rodney@shupe.ca>"
declare -r ABOUT="A version of Star Trek for standard terminals, ported from VT52 BASIC to Bash."

#
# TREK52 - A version of Star Trek for standard terminals
#
# Ported from DEC BASIC-PLUS (trek52.bas) to Bash.
# Original by Bob Alexander <bob@GalacticStudios.org>, 2022, public domain.
# Inspired by the original Star Trek game by Mike Mayfield.
#
# Original project: https://github.com/galacticstudios/Trek52
# Original source:  https://raw.githubusercontent.com/galacticstudios/Trek52/refs/heads/main/trek52.bas
#
# The original targeted VT52 terminals. This port converts the VT52 escape
# sequences to standard ANSI/VT100 sequences so it runs in any modern terminal
# (Terminal.app, iTerm2, xterm, over ssh, etc.).
#
# Design notes:
#   * Integer game logic uses pure Bash arithmetic.
#   * Real-number math (trigonometry, distance, random scaling) uses a
#     fixed-point integer engine implemented in pure Bash -- see "Fixed-point
#     math engine" below. Values are scaled by 1e6 and the engine provides its
#     own sqrt/sin/cos, so no external math program is needed.
#   * Randomness comes from Bash's $RANDOM.
#
# Requires: bash 3.2+ (works with the stock /bin/bash on macOS), stty, tput.
# No associative arrays, so it runs on the default macOS bash and on older
# systems reached over ssh.

set -u

# Boolean constants. Bash's own convention is that 0 == success/true, so TRUE=0
# and FALSE=1 lets the (( flag == TRUE )) idiom read naturally.
declare -r TRUE=0
declare -r FALSE=1

# Default Constants
# Minimum terminal size the fixed layout needs. The galaxy chart occupies
# columns 31..79 (49 wide) and the lowest drawn row is the hint line at row 23
# (0-indexed), so the screen must be at least 80 columns by 24 rows.
declare -r DEFAULT_MIN_COLS=80
declare -r DEFAULT_MIN_ROWS=24

# Colour is off by default so the original monochrome look is preserved.
declare -r DEFAULT_USE_COLOUR=${FALSE}

# Arguments (initialized from the defaults; set by parse_arguments).
declare arg_use_colour=${DEFAULT_USE_COLOUR}

# ---------------------------------------------------------------------------
#  Global state
# ---------------------------------------------------------------------------

# The galaxy is an 8x8 grid of quadrants; each quadrant an 8x8 grid of sectors.
# Stored as flat indexed arrays addressed by (row*8 + col) so we don't need
# associative arrays (unavailable in bash 3.2).
declare -a galaxy      # galaxy[row*8+col]   encoded quadrant contents
declare -a quadrant    # quadrant[row*8+col] current quadrant sector contents

# Damage array: index 1..7. 0 = working, >0 = turns-to-repair.
# Initialized here (not in main) so the data always exists no matter how the
# script is entered.
declare -a damage
declare -a damage_names
damage_names[1]="Warp Engines"
damage_names[2]="Shields"
damage_names[3]="Phasers"
damage_names[4]="Torpedoes"
damage_names[5]="SR Scanner"
damage_names[6]="LR Scanner"
damage_names[7]="Computer"
damage[1]=0; damage[2]=0; damage[3]=0; damage[4]=0
damage[5]=0; damage[6]=0; damage[7]=0

# Klingons in the current quadrant: parallel arrays indexed 1..3.
declare -a lk_y lk_x lk_pwr   # row, col, energy/power
lk_y=(0 0 0 0); lk_x=(0 0 0 0); lk_pwr=(0 0 0 0)

# Enterprise position (0..63 in each axis) and resources.
enterprise_x=0; enterprise_y=0
stardates=0; shields=0; energy=0; torpedoes=0
klingons=0; bases=0
exit_game=${FALSE}

# Course-track scratch arrays (index 0..N). trk_y / trk_x hold a path.
declare -a trk_y trk_x

# Current alert condition text (needed by the Klingon-attack docking check).
cond=" GREEN"

# System-damage indices (mirror the Basic names).
d_warp=1; d_shields=2; d_phasers=3; d_torpedoes=4; d_sr_scan=5; d_lr_scan=6; d_computer=7

# Message bookkeeping and screen coordinates for prompt / damage report.
message_count=0
command_x=25; command_y=14
damage_x=0;  damage_y=14

# Galaxy chart origin on screen.
galaxy_chart_x=31; galaxy_chart_y=0

# Minimum terminal size the fixed layout needs (see DEFAULT_MIN_* above).
MIN_COLS=${DEFAULT_MIN_COLS}
MIN_ROWS=${DEFAULT_MIN_ROWS}

# (Pi lives in the fixed-point engine below as FP_PI.)

# ---------------------------------------------------------------------------
#  ANSI escape sequences (converted from the original VT52 codes)
# ---------------------------------------------------------------------------
ESC=$'\033'
clear_screen="${ESC}[H${ESC}[2J"
clear_line="${ESC}[K"
start_of_line=$'\r'

# ---------------------------------------------------------------------------
#  Colour support (enabled with -c / --colour / --colour)
# ---------------------------------------------------------------------------
# Off by default so the original monochrome look is preserved. When enabled,
# cwrap wraps text in an SGR colour and a reset. The colour codes have zero
# display width, so screen alignment is unaffected either way. USE_COLOUR is a
# boolean (TRUE/FALSE); parse_arguments sets it from arg_use_colour.
USE_COLOUR=${DEFAULT_USE_COLOUR}
C_RESET="${ESC}[0m"
C_GREEN="${ESC}[32m"
C_YELLOW="${ESC}[33m"
C_RED="${ESC}[31m"
C_CYAN="${ESC}[96m"    # bright cyan: high-contrast for Enterprise/Starbase
C_MSG="${ESC}[93m"     # bright yellow: subtle highlight for status messages

# Torpedo animation: character shown as the torpedo travels the short-range map.
# In colour mode a red '*' reads as a projectile; in monochrome a '*' would be
# indistinguishable from a star, so a '+' is used instead.
TORP_CHAR_MONO='+'
TORP_CHAR_COLOUR='*'

# Print the title/version/author/about banner and the flag/option/arg summary,
# following the same visual layout as the reference travesty.sh.
function usage() {
  echo "${TITLE} ${VERSION}
${AUTHOR}
${ABOUT}

USAGE:
    trek52.sh [FLAGS]

FLAGS:
    -c, --colour     Enable coloured display (damage report, map, status)
    -h, --help       Prints help information
    -V, --version    Prints version information

ARGS:
    Requires a terminal of at least ${MIN_COLS}x${MIN_ROWS}.
"
}

# Parse command-line options into the arg_* globals. Mirrors the reference's
# while/case pattern. --color is kept as an undocumented alias for --colour.
function parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        usage
        exit 0
        ;;
      -V|--version)
        echo "${TITLE} ${VERSION}"
        exit 0
        ;;
      -c|--color|--colour)
        arg_use_colour=${TRUE}
        shift # past argument
        ;;
      --)
        shift # past argument
        break
        ;;
      -*)   # unknown option
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
      *)    # unexpected argument
        printf 'Unexpected argument: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

# cwrap COLOUR TEXT -> echo TEXT wrapped in COLOUR..reset when colour is on,
# otherwise just TEXT. COLOUR is one of the C_* variables above.
function cwrap() {
    if (( USE_COLOUR == TRUE )); then printf '%s%s%s' "$1" "$2" "$C_RESET"
    else printf '%s' "$2"
    fi
}

# ---------------------------------------------------------------------------
#  Fixed-point math engine (pure Bash)
# ---------------------------------------------------------------------------
# Real numbers are represented as integers scaled by FP (fixed-point). A value
# x is stored as round(x * FP). All arithmetic stays within Bash's 64-bit
# signed integer range: the largest intermediate is a*FP or a*b which, for the
# magnitudes this game uses (|x| < ~100), is at most ~1e14 -- comfortably below
# 9.2e18.
#
# Naming: fp_* functions take and return scaled integers unless noted. Values
# from the game (positions, warp*8, etc.) are small; scaling by 1e6 gives ~6
# decimal digits of precision, which is more than enough for the sector-rounding
# decisions in course_track and warp.
FP=1000000                 # scale factor (1.0 == 1000000)
FP_PI=3141593              # pi  * FP
FP_2PI=6283185             # 2pi * FP
FP_HALFPI=1570796          # pi/2 * FP

# fp_mul A B -> (A*B)/FP   (product of two scaled ints, rescaled)
function fp_mul() { echo $(( $1 * $2 / FP )); }

# fp_div A B -> (A*FP)/B   (scaled quotient); B must be nonzero
function fp_div() { echo $(( $1 * FP / $2 )); }

# fp_from_int N -> N scaled
function fp_from_int() { echo $(( $1 * FP )); }

# fp_trunc A -> integer part of scaled A, truncated toward zero
function fp_trunc() { echo $(( $1 / FP )); }

# fp_round A -> nearest integer of scaled A (round half away from zero)
function fp_round() {
    local a=$1
    if (( a >= 0 )); then echo $(( (a + FP/2) / FP ))
    else echo $(( -(( -a + FP/2) / FP) )); fi
}

# fp_abs A -> |A|
function fp_abs() { local a=$1; (( a < 0 )) && a=$(( -a )); echo "$a"; }

# fp_parse STR -> scaled integer from a decimal string like "1.5" or "12".
# Handles an optional leading '-' and up to 6 fractional digits.
function fp_parse() {
    local s=$1 sign=1 int frac
    case "$s" in -*) sign=-1; s=${s#-} ;; esac
    if [[ "$s" == *.* ]]; then
        int=${s%%.*}; frac=${s#*.}
    else
        int=$s; frac=""
    fi
    int=${int:-0}
    # Pad/truncate the fractional part to exactly 6 digits.
    frac="${frac}000000"; frac=${frac:0:6}
    # Strip leading zeros safely for arithmetic (avoid octal interpretation).
    echo $(( sign * (10#$int * FP + 10#$frac) ))
}

# fp_format A -> decimal string (used only where a value is shown to the user).
function fp_format() {
    local a=$1 sign=""
    (( a < 0 )) && { sign="-"; a=$(( -a )); }
    printf '%s%d.%06d' "$sign" $(( a / FP )) $(( a % FP ))
}

# fp_sqrt A -> sqrt of scaled A, returned scaled. Uses integer Newton's method
# on (A*FP) so the result is sqrt(A)*FP.
function fp_sqrt() {
    local a=$1
    (( a <= 0 )) && { echo 0; return; }
    local n=$(( a * FP ))     # sqrt(n) == sqrt(a)*FP
    # Initial guess: start high enough, then iterate.
    local x=$(( n > 1 ? n / 2 : 1 )) prev=0 guard=0
    while (( x != prev && guard < 100 )); do
        prev=$x
        x=$(( (x + n / x) / 2 ))
        guard=$(( guard + 1 ))
    done
    echo "$x"
}

# _fp_sin_small T -> sin of scaled angle T, |T| <= pi/2, via Taylor series.
# sin(x) = x - x^3/3! + x^5/5! - x^7/7! + x^9/9!  (enough for |x|<=pi/2)
function _fp_sin_small() {
    local x=$1
    local x2; x2=$(fp_mul "$x" "$x")
    local term=$x sum=$x n
    # term_{k} = term_{k-1} * (-x^2) / ((2k)(2k+1))
    local k
    for k in 1 2 3 4 5; do
        local d=$(( (2*k) * (2*k+1) ))
        term=$(fp_mul "$term" "$x2")
        term=$(( term / d ))
        term=$(( -term ))
        sum=$(( sum + term ))
    done
    echo "$sum"
}

# fp_sin T -> sin of scaled angle T (any magnitude). Range-reduces to [-pi,pi]
# then to [-pi/2,pi/2] using symmetry.
function fp_sin() {
    local t=$1
    # Reduce modulo 2pi into (-pi, pi].
    t=$(( t % FP_2PI ))
    (( t > FP_PI )) && t=$(( t - FP_2PI ))
    (( t < -FP_PI )) && t=$(( t + FP_2PI ))
    # sin(t) for |t|>pi/2: sin(t)=sin(pi-t).
    if (( t > FP_HALFPI )); then t=$(( FP_PI - t ))
    elif (( t < -FP_HALFPI )); then t=$(( -FP_PI - t )); fi
    _fp_sin_small "$t"
}

# fp_cos T -> cos of scaled angle T. cos(t) = sin(t + pi/2).
function fp_cos() { fp_sin $(( $1 + FP_HALFPI )); }

# fp_sgn A -> -1, 0, or 1 (unscaled integer)
function fp_sgn() { if (( $1 > 0 )); then echo 1; elif (( $1 < 0 )); then echo -1; else echo 0; fi; }

# rnd -> a scaled fixed-point number in [0,FP) i.e. [0,1). Pure Bash.
# Built from two $RANDOM draws for extra resolution.
function rnd() {
    local a=$RANDOM b=$RANDOM
    # (a*32768+b) is in [0, 2^30). Scale to [0,FP).
    echo $(( (a * 32768 + b) * FP / (32768 * 32768) ))
}

# cursor X Y -> emit the ANSI sequence to move the cursor to (x,y), 0-indexed,
# matching the original fnCursor$ semantics (column x, row y).
function cursor() {
    printf '%s[%d;%dH' "$ESC" "$(( $2 + 1 ))" "$(( $1 + 1 ))"
}

# Read a single keypress (no Return, no echo). Skips stray CR/LF so a newline
# left in the buffer by prior line-entry isn't mistaken for a phantom command.
function get_char() {
    local ch
    while :; do
        IFS= read -rsn1 ch </dev/tty || break   # break on EOF to avoid spinning
        [[ -z "$ch" || "$ch" == $'\r' || "$ch" == $'\n' ]] || break
    done
    printf '%s' "$ch"
}

# Read a single keypress, returning on ANY key including Return (empty string).
# For "hit any key" and default-accepting prompts, where Return is a real choice
# rather than the stray newline get_char skips.
function get_any_key() {
    local ch
    IFS= read -rsn1 ch </dev/tty
    printf '%s' "$ch"
}

# Uppercase a single character (enough for command / Y-N handling). Pure Bash.
function upper() {
    case "$1" in
        a) printf A ;; b) printf B ;; c) printf C ;; d) printf D ;;
        e) printf E ;; f) printf F ;; g) printf G ;; h) printf H ;;
        i) printf I ;; j) printf J ;; k) printf K ;; l) printf L ;;
        m) printf M ;; n) printf N ;; o) printf O ;; p) printf P ;;
        q) printf Q ;; r) printf R ;; s) printf S ;; t) printf T ;;
        u) printf U ;; v) printf V ;; w) printf W ;; x) printf X ;;
        y) printf Y ;; z) printf Z ;;
        *) printf '%s' "$1" ;;
    esac
}

# Read a whole line (echoed) for numeric entry: course, warp, phasers, shields.
# Returns via global LINE_RESULT (not stdout), so call it directly, not in $(...).
LINE_RESULT=""
function get_line_at() {
    local x=$1 y=$2 prompt=$3
    cursor "$x" "$y"
    printf '%s%s' "$prompt" "$clear_line"
    stty "$SANE_TTY" </dev/tty   # cooked mode so the user sees what they type
    IFS= read -r LINE_RESULT </dev/tty
    stty -echo </dev/tty
}

# max / min on integers.
function imax() { (( $1 > $2 )) && echo "$1" || echo "$2"; }
function imin() { (( $1 < $2 )) && echo "$1" || echo "$2"; }

# Right-justify integer N in WIDTH columns (fnRNum$).
function rnum() { printf '%*d' "$2" "$1"; }

# ---------------------------------------------------------------------------
#  Sector / quadrant rendering
# ---------------------------------------------------------------------------

# Text for a sector's contents. Blank when the short-range scanner is damaged.
# Colour: Enterprise (E) and Starbase (B) -> cyan, Klingon (K) -> red.
function sector_text() {
    local s=$1
    if (( damage[d_sr_scan] )); then printf ' '
    elif (( s == 0 ));    then printf '.'
    elif (( s == 1 ));    then printf '*'
    elif (( s == 10 ));   then cwrap "$C_CYAN" 'B'
    elif (( s == 100 ));  then cwrap "$C_RED" 'K'
    elif (( s == 1000 )); then cwrap "$C_CYAN" 'E'
    else printf ' '
    fi
}

# Draw the short-range (quadrant) map: 8x8 sectors at the top-left.
function print_quadrant() {
    local row col
    for (( row=0; row<=7; row++ )); do
        cursor 0 $(( row + 1 ))
        for (( col=0; col<=7; col++ )); do
            printf ' %s ' "$(sector_text "${quadrant[(($row)*8+($col))]}")"
        done
    done
}

# Format one quadrant cell for the galaxy chart:
#   " *** " unscanned, "(xxx)" our quadrant, " xxx " scanned, blank if computer down.
function galaxy_quadrant() {
    local row=$1 col=$2
    local erow=$(( enterprise_y / 8 )) ecol=$(( enterprise_x / 8 ))
    if (( damage[d_computer] && (row != erow || col != ecol) )); then
        printf '     '; return
    fi
    local q=${galaxy[(($row)*8+($col))]}
    if (( q < 0 )); then printf ' *** '; return; fi
    # Encode as a 3-digit string (klingons/bases/stars).
    local three; three=$(printf '%03d' $(( q % 1000 )) )
    if (( q >= 1000 )); then printf '(%s)' "$three"
    else printf ' %s ' "$three"
    fi
}

# Draw the galaxy chart (right side of the screen).
function print_galaxy() {
    local row col
    for (( row=0; row<=7; row++ )); do
        cursor 31 $(( row + 1 ))
        printf '|'
        for (( col=0; col<=7; col++ )); do
            printf '%s|' "$(galaxy_quadrant "$row" "$col")"
        done
    done
}

# Redraw a single quadrant cell in the galaxy chart in place.
function update_quadrant() {
    local row=$1 col=$2
    local qx=$(( galaxy_chart_x + 1 + col * 6 ))
    local qy=$(( galaxy_chart_y + 1 + row ))
    cursor "$qx" "$qy"
    galaxy_quadrant "$row" "$col"
}

# Redraw a single sector cell in the quadrant map in place.
function update_sector() {
    local row=$1 col=$2
    cursor $(( col * 3 + 1 )) $(( row + 1 ))
    sector_text "${quadrant[(($row)*8+($col))]}"
}

# ---------------------------------------------------------------------------
#  Status panels
# ---------------------------------------------------------------------------

# Energy: red when below 250.
function update_energy() {
    cursor 20 10
    local text; text=$(rnum "$energy" 4)
    if (( energy < 250 )); then cwrap "$C_RED" "$text"; else printf '%s' "$text"; fi
}
function update_shields()  {
    local s=$shields; (( s < 0 )) && s=0
    cursor 20 11; rnum "$s" 4
    if (( shields <= 200 )); then printf ' LOW'; else printf '    '; fi
}
# Stardates: yellow below 10, red below 5.
function update_stardates() {
    cursor 52 11
    local text; text=$(rnum "$stardates" 2)
    if (( stardates < 5 )); then cwrap "$C_RED" "$text"
    elif (( stardates < 10 )); then cwrap "$C_YELLOW" "$text"
    else printf '%s' "$text"
    fi
}
# Torpedoes: yellow at 2, red below 2.
function update_torpedoes() {
    cursor 22 12
    local text; text=$(rnum "$torpedoes" 2)
    if (( torpedoes < 2 )); then cwrap "$C_RED" "$text"
    elif (( torpedoes == 2 )); then cwrap "$C_YELLOW" "$text"
    else printf '%s' "$text"
    fi
}

function status_report() {
    cursor 0 10;  printf 'ENERGY:';               update_energy
    cursor 31 10; printf 'CONDITION:';             update_condition
    cursor 0 11;  printf 'SHIELDS:';               update_shields
    # Stardates (coloured to match update_stardates thresholds).
    cursor 31 11; printf 'STARDATES REMAINING: '
    local sd; sd=$(rnum "$stardates" 2)
    if (( stardates < 5 )); then cwrap "$C_RED" "$sd"
    elif (( stardates < 10 )); then cwrap "$C_YELLOW" "$sd"
    else printf '%s' "$sd"; fi
    # Torpedoes (coloured to match update_torpedoes thresholds).
    cursor 0 12;  printf 'TORPEDOES:   '
    local tp; tp=$(rnum "$torpedoes" 11)
    if (( torpedoes < 2 )); then cwrap "$C_RED" "$tp"
    elif (( torpedoes == 2 )); then cwrap "$C_YELLOW" "$tp"
    else printf '%s' "$tp"; fi
    cursor 31 12; printf 'KLINGONS REMAINING:  ';  rnum "$klingons" 2
}

function hint_line() {
    cursor 0 23
    printf '   (W)arp  (P)hasers  (T)orpedoes  (S)hields  (L).R. Scan  (A)bandon Ship'
}

function direction_guide() {
    local x=$1 y=$2
    cursor "$x" "$y";        printf '4 3 2'
    cursor "$x" $(( y+1 ));  printf ' \|/'
    cursor "$x" $(( y+2 ));  printf '5---1'
    cursor "$x" $(( y+3 ));  printf ' /|\'
    cursor "$x" $(( y+4 ));  printf '6 7 8'
}

# Time-to-repair display for one system.
# Colour: working -> green, TTR 1 -> yellow, TTR >= 2 -> red.
function update_damage() {
    local di=$1 ttr
    cursor $(( damage_x + 14 )) $(( damage_y + di ))
    ttr=${damage[di]}
    if (( ttr )); then
        local text; text="TTR $(rnum "$ttr" 3)"
        if (( ttr >= 2 )); then cwrap "$C_RED" "$text"
        else cwrap "$C_YELLOW" "$text"
        fi
    else
        cwrap "$C_GREEN" "Working"
    fi
}

function damage_report() {
    local x=$1 y=$2 qi
    cursor "$x" "$y"; printf ' == DAMAGE REPORT =='
    for (( qi=1; qi<=7; qi++ )); do
        cursor "$x" $(( y + qi )); printf '%s: ' "${damage_names[qi]}"
        update_damage "$qi"
    done
}

# Redraw the whole screen.
function refresh_screen() {
    printf '%s' "$clear_screen"
    # Top border: 24 '-' over the quadrant map, gap, then '=' over the galaxy map.
    printf '%s' "$(printf '%0.s-' {1..24})"
    printf '%s' "$(printf '%0.s ' {1..7})"
    printf '%s' "$(printf '%0.s=' {1..49})"
    print_quadrant
    print_galaxy
    cursor 0 9;  printf '%s' "$(printf '%0.s-' {1..24})"
    cursor 31 9; printf '%s' "$(printf '%0.s=' {1..49})"
    status_report
    hint_line
    direction_guide 25 3
    damage_report "$damage_x" "$damage_y"
}

# ---------------------------------------------------------------------------
#  Messages (the scrolling area under the command prompt)
# ---------------------------------------------------------------------------

function display_message() {
    local msg=$1
    if (( command_y + message_count + 1 >= 23 )); then
        cursor "$command_x" $(( message_count + command_y + 1 ))
        (( USE_COLOUR == TRUE )) && printf '%s%s' "$C_RESET" "$C_MSG"
        printf -- '-- More -- (hit any key)'
        get_any_key >/dev/null
        clear_messages
    fi
    cursor "$command_x" $(( message_count + command_y + 1 ))
    # In colour mode, reset attributes then tint the message in bright yellow.
    # The explicit colour both highlights the message subtly and guarantees it
    # is visible regardless of any foreground colour left active by a prior draw.
    if (( USE_COLOUR == TRUE )); then printf '%s%s%s%s' "$C_RESET" "$C_MSG" "$msg" "$C_RESET"
    else printf '%s' "$msg"; fi
    message_count=$(( message_count + 1 ))
}

function clear_messages() {
    local qmi
    for (( qmi=0; qmi<=message_count; qmi++ )); do
        cursor "$command_x" $(( qmi + command_y + 1 )); printf '%s' "$clear_line"
    done
    message_count=0
}

# ---------------------------------------------------------------------------
#  Damage handling
# ---------------------------------------------------------------------------

function sgn() { if (( $1 > 0 )); then echo 1; elif (( $1 < 0 )); then echo -1; else echo 0; fi; }

function adjust_damage() {
    local di=$1 amt=$2
    local old=${damage[di]}
    local new=$(( old + amt ))
    (( new < 0 )) && new=0
    damage[di]=$new
    update_damage "$di"
    if (( $(sgn "$old") != $(sgn "$new") )); then
        if (( di == d_sr_scan )); then print_quadrant
        elif (( di == d_computer )); then print_galaxy
        fi
    fi
}

# Randomly damage a system; heavier hits when shields are weak.
function wreak_damage() {
    local sh=$1
    # sys = int(rnd*7)+1. rnd is scaled; (rnd*7)/FP is the integer part.
    local sys=$(( ($(rnd) * 7 / FP) + 1 ))
    (( sys > 7 )) && sys=7
    # amt = int( rnd*5*(3000-sh)/3000 + 2 ). Work in scaled fixed point.
    local r; r=$(rnd)                          # scaled [0,FP)
    local amt_scaled=$(( r * 5 * (3000 - sh) / 3000 ))   # still scaled
    local amt=$(( amt_scaled / FP + 2 ))       # truncate + 2
    adjust_damage "$sys" "$amt"
    display_message "${damage_names[sys]} damaged."
}

# Randomly fully-repair one damaged system, with a bit of crew flavor.
function repair_damage() {
    local start qdi found=0 idx
    start=$(( $(rnd) * 6 / FP ))
    for (( qdi=start; qdi<=13; qdi++ )); do
        idx=$(( qdi % 7 + 1 ))
        if (( damage[idx] )); then found=1; break; fi
    done
    (( found == 0 )) && return
    adjust_damage "$idx" -1000
    local quip; quip=$(( $(rnd) * 3 / FP ))
    if (( quip == 0 )); then
        display_message "Spock repaired ${damage_names[idx]} using a new technique."
    elif (( quip == 1 )); then
        display_message "Scotty exaggerated the time to repair"
        display_message "   the ${damage_names[idx]}."
    else
        display_message "McCoy repaired the ${damage_names[idx]}."
        display_message "It turns out he's not just a doctor."
    fi
}

# Repair every damaged system by one unit each turn.
function normal_repair() {
    local qdi
    for (( qdi=1; qdi<=7; qdi++ )); do
        if (( damage[qdi] )); then
            adjust_damage "$qdi" -1
            (( damage[qdi] == 0 )) && display_message "${damage_names[qdi]} repaired."
        fi
    done
}

# ---------------------------------------------------------------------------
#  Setup
# ---------------------------------------------------------------------------

function recharge_enterprise() {
    shields=0; energy=3000; torpedoes=10
    local di
    for (( di=1; di<=7; di++ )); do adjust_damage "$di" -1000; done
}

function initialize_quadrant() {
    local qx qy x y s contents
    for (( qy=0; qy<=7; qy++ )); do
        for (( qx=0; qx<=7; qx++ )); do quadrant[(($qy)*8+($qx))]=0; done
    done
    qx=$(( enterprise_x / 8 )); qy=$(( enterprise_y / 8 ))
    x=$(( enterprise_x % 8 ));  y=$(( enterprise_y % 8 ))
    quadrant[(($y)*8+($x))]=1000

    contents=${galaxy[(($qy)*8+($qx))]}; (( contents < 0 )) && contents=$(( -contents ))

    # Stars
    local n_stars=$(( contents % 10 ))
    for (( s=1; s<=n_stars; s++ )); do
        x=$(( RANDOM % 8 )); y=$(( RANDOM % 8 ))
        if (( quadrant[(($y)*8+($x))] == 0 )); then quadrant[(($y)*8+($x))]=1; else (( s-- )); fi
    done

    # Bases
    local n_bases=$(( (contents / 10) % 10 ))
    for (( s=1; s<=n_bases; s++ )); do
        x=$(( RANDOM % 8 )); y=$(( RANDOM % 8 ))
        if (( quadrant[(($y)*8+($x))] == 0 )); then quadrant[(($y)*8+($x))]=10; else (( s-- )); fi
    done

    # Klingons
    lk_y=(0 0 0 0); lk_x=(0 0 0 0); lk_pwr=(0 0 0 0)
    local n_k=$(( (contents / 100) % 10 ))
    for (( s=1; s<=n_k; s++ )); do
        x=$(( RANDOM % 8 )); y=$(( RANDOM % 8 ))
        if (( quadrant[(($y)*8+($x))] != 0 )); then
            (( s-- ))
        else
            quadrant[(($y)*8+($x))]=100
            lk_y[$s]=$y; lk_x[$s]=$x; lk_pwr[$s]=200
        fi
    done
}

function initialize_game() {
    klingons=0; bases=0
    local row col r k b s val
    for (( row=0; row<=7; row++ )); do
        for (( col=0; col<=7; col++ )); do
            r=$(rnd)                       # scaled [0,FP)
            k=0; b=0
            if (( r > 800000 )); then k=1; fi
            if (( r > 950000 )); then k=2; fi
            if (( r > 980000 )); then k=3; fi
            if (( $(rnd) > 960000 )); then b=1; fi
            s=$(( $(rnd) * 8 / FP + 1 ))
            (( s > 8 )) && s=8
            galaxy[(($row)*8+($col))]=$(( -(k * 100 + b * 10 + s) ))
            klingons=$(( klingons + k ))
            bases=$(( bases + b ))
        done
    done

    # Guarantee at least one starbase.
    if (( bases == 0 )); then
        bases=1
        row=$(( RANDOM % 8 )); col=$(( RANDOM % 8 ))
        galaxy[(($row)*8+($col))]=$(( ${galaxy[(($row)*8+($col))]} - 10 ))
    fi

    # Place the Enterprise and mark its quadrant scanned (+1000).
    enterprise_x=$(( RANDOM % 64 )); enterprise_y=$(( RANDOM % 64 ))
    local x=$(( enterprise_x / 8 )) y=$(( enterprise_y / 8 ))
    galaxy[(($y)*8+($x))]=$(( -${galaxy[(($y)*8+($x))]} + 1000 ))

    stardates=30; shields=0; energy=3000; torpedoes=10
    local i
    for (( i=1; i<=7; i++ )); do damage[$i]=0; done
    initialize_quadrant
    exit_game=${FALSE}
}

# ---------------------------------------------------------------------------
#  Movement / course tracking
# ---------------------------------------------------------------------------

# Distance from Klingon k to the Enterprise, returned as a scaled fixed-point
# value. dy/dx are small integers, so the sum of squares is an exact integer;
# fp_sqrt takes a scaled operand, so scale the sum first.
function dist() {
    local k=$1
    local ey=$(( enterprise_y % 8 )) ex=$(( enterprise_x % 8 ))
    local dy=$(( ey - ${lk_y[$k]} )) dx=$(( ex - ${lk_x[$k]} ))
    local sumsq=$(( dy*dy + dx*dx ))          # exact integer
    fp_sqrt $(( sumsq * FP ))                  # sqrt of scaled sum -> scaled result
}

# Compute a course track through the current quadrant.
# Populates the global trk_y[] / trk_x[] arrays and sets COURSE_RESULT to:
#   +N : left the quadrant at step N
#   -N : hit an obstruction at step N
# NOTE: this MUST be called directly (not in $(...)), otherwise the trk_y/trk_x
# updates would be lost in the subshell. The result comes back via COURSE_RESULT.
COURSE_RESULT=0
# course and warp arrive as scaled fixed-point values (see callers). trk_y/trk_x
# are stored scaled.
function course_track() {
    local course=$1 warp=$2
    trk_y=(); trk_x=()
    trk_y[0]=$(( (enterprise_y % 8) * FP )); trk_x[0]=$(( (enterprise_x % 8) * FP ))

    # theta = (course-1)/4 * pi.  deltaX=cos(theta), deltaY=sin(theta).
    local theta d_x d_y ad_x ad_y
    theta=$(fp_mul $(( (course - FP) / 4 )) "$FP_PI")
    d_x=$(fp_cos "$theta"); d_y=$(fp_sin "$theta")
    ad_x=$(fp_abs "$d_x"); ad_y=$(fp_abs "$d_y")
    # Scale to a unit square's edges (match the original's branch logic).
    if (( ad_x <= ad_y )); then
        d_x=$(fp_div "$d_x" "$ad_y"); d_y=$(( $(fp_sgn "$d_y") * FP ))
    fi
    ad_x=$(fp_abs "$d_x"); ad_y=$(fp_abs "$d_y")
    if (( ad_y < ad_x )); then
        d_y=$(fp_div "$d_y" "$ad_x"); d_x=$(( $(fp_sgn "$d_x") * FP ))
    fi

    local steps qi py px ry rx
    steps=$(( warp * 8 / FP ))                  # int(warp*8)
    local hi=$(( 7 * FP ))
    for (( qi=1; qi<=steps; qi++ )); do
        py=${trk_y[$(( qi-1 ))]}; px=${trk_x[$(( qi-1 ))]}
        trk_y[$qi]=$(( py - d_y ))
        trk_x[$qi]=$(( px + d_x ))
        # Left the quadrant?
        if (( ${trk_y[$qi]} < 0 || ${trk_y[$qi]} > hi || ${trk_x[$qi]} < 0 || ${trk_x[$qi]} > hi )); then
            COURSE_RESULT=$qi; return
        fi
        # Obstruction? Round to nearest sector.
        ry=$(fp_round "${trk_y[$qi]}"); rx=$(fp_round "${trk_x[$qi]}")
        if (( quadrant[(($ry)*8+($rx))] != 0 )); then
            COURSE_RESULT=$(( -qi )); return
        fi
    done
    COURSE_RESULT=$steps
}

function change_sector() {
    local row=$1 col=$2 new_val=$3
    local r=$(( ((row % 8) + 8) % 8 )) c=$(( ((col % 8) + 8) % 8 ))
    quadrant[(($r)*8+($c))]=$new_val
    update_sector "$r" "$c"
}

# ---------------------------------------------------------------------------
#  Condition / docking
# ---------------------------------------------------------------------------

function update_condition() {
    local eq_y=$(( enterprise_y / 8 )) eq_x=$(( enterprise_x / 8 ))
    if (( ${galaxy[(($eq_y)*8+($eq_x))]} - 1000 >= 100 )); then cond='   RED'; else cond=' GREEN'; fi

    local qs_x=$(( enterprise_x % 8 )) qs_y=$(( enterprise_y % 8 ))
    local qrow qcol lo_r hi_r lo_c hi_c docked=0
    lo_r=$(imax $(( qs_y-1 )) 0); hi_r=$(imin $(( qs_y+1 )) 7)
    lo_c=$(imax $(( qs_x-1 )) 0); hi_c=$(imin $(( qs_x+1 )) 7)
    for (( qrow=lo_r; qrow<=hi_r; qrow++ )); do
        for (( qcol=lo_c; qcol<=hi_c; qcol++ )); do
            if (( quadrant[(($qrow)*8+($qcol))] == 10 )); then docked=1; fi
        done
    done
    if (( docked )); then
        cond='DOCKED'
        recharge_enterprise
        update_energy; update_shields; update_torpedoes
        display_message "Shields lowered for docking."
    fi
    cursor 48 10; printf '%s' "$(colour_for_condition "$cond")"
}

# Return the colour code matching a condition string (GREEN/RED/DOCKED).
function condition_colour() {
    case "$1" in
        *RED*)    printf '%s' "$C_RED" ;;
        *DOCKED*) printf '%s' "$C_CYAN" ;;
        *)        printf '%s' "$C_GREEN" ;;
    esac
}

# Wrap a condition string in its matching colour (or plain text if colour off).
function colour_for_condition() {
    cwrap "$(condition_colour "$1")" "$1"
}

# ---------------------------------------------------------------------------
#  Combat
# ---------------------------------------------------------------------------

function klingon_destroyed() {
    local ki=$1
    local eq_y=$(( enterprise_y / 8 )) eq_x=$(( enterprise_x / 8 ))
    galaxy[(($eq_y)*8+($eq_x))]=$(( ${galaxy[(($eq_y)*8+($eq_x))]} - 100 ))
    update_quadrant "$eq_y" "$eq_x"
    quadrant[$(( ${lk_y[$ki]} * 8 + ${lk_x[$ki]} ))]=0
    update_sector "${lk_y[$ki]}" "${lk_x[$ki]}"
    lk_pwr[$ki]=0
    if (( (${galaxy[(($eq_y)*8+($eq_x))]} % 1000) < 100 )); then update_condition; fi
    klingons=$(( klingons - 1 ))
    cursor 52 12; rnum "$klingons" 2
}

function klingon_destroyed_rc() {
    local row=$1 col=$2 qi
    for (( qi=1; qi<=3; qi++ )); do
        if (( ${lk_y[$qi]} == row && ${lk_x[$qi]} == col && ${lk_pwr[$qi]} )); then
            klingon_destroyed "$qi"
        fi
    done
}

function klingon_attack() {
    local hit=0 cnt=0 qi d contrib
    for (( qi=1; qi<=3; qi++ )); do
        if (( ${lk_pwr[$qi]} == 0 )); then continue; fi
        d=$(dist "$qi")                                   # scaled
        # contrib = int( pwr / d * (2 + rnd) )
        local pwr_over_d; pwr_over_d=$(fp_div $(( ${lk_pwr[$qi]} * FP )) "$d")
        local factor=$(( 2 * FP + $(rnd) ))               # (2 + rnd), scaled
        contrib=$(( $(fp_mul "$pwr_over_d" "$factor") / FP ))
        hit=$(( hit + contrib ))
        cnt=$(( cnt + 1 ))
    done
    if (( cnt != 0 )) && [[ "$cond" == "DOCKED" ]]; then
        display_message "Starbase shields protect Enterprise."
        return
    fi
    if (( cnt == 1 )); then
        display_message "$hit unit hit on Enterprise from Klingon!"
    elif (( cnt > 1 )); then
        display_message "$hit unit hits on Enterprise from Klingons!"
    fi
    if (( cnt > 0 )); then
        # int(rnd * shields) < hit
        if (( $(rnd) * shields / FP < hit )); then wreak_damage "$shields"; fi
        shields=$(( shields - hit )); update_shields
    fi
}

function phasers() {
    printf 'Phasers'
    if (( damage[d_phasers] )); then
        display_message "Phasers inoperable."; return
    fi
    local eq_y=$(( enterprise_y / 8 )) eq_x=$(( enterprise_x / 8 ))
    local k=$(( (${galaxy[(($eq_y)*8+($eq_x))]} - 1000) / 100 ))
    if (( k == 0 )); then
        display_message "No Klingons in this quadrant."; return
    fi
    display_message "Phasers locked on target."
    local input phasers_units
    get_line_at "$command_x" $(( command_y + message_count + 1 )) "Units to fire? "; input=$LINE_RESULT
    message_count=$(( message_count + 1 ))
    [[ "$input" =~ ^[0-9]+$ ]] && phasers_units=$(( 10#$input )) || phasers_units=0
    if (( phasers_units <= 0 )); then
        clear_messages; display_message "Phaser command cancelled."; return
    fi
    if (( phasers_units > energy )); then
        clear_messages; display_message "Only $energy units available"; return
    fi
    energy=$(( energy - phasers_units )); update_energy
    clear_messages
    local qi pwr d hit
    for (( qi=1; qi<=3; qi++ )); do
        pwr=${lk_pwr[$qi]}
        (( pwr == 0 )) && continue
        d=$(dist "$qi")                                   # scaled
        # hit = int( phasers_units / d * rnd )
        local pu_over_d; pu_over_d=$(fp_div $(( phasers_units * FP )) "$d")
        hit=$(( $(fp_mul "$pu_over_d" "$(rnd)") / FP ))
        pwr=$(( pwr - hit )); (( pwr < 0 )) && pwr=0
        lk_pwr[$qi]=$pwr
        if (( pwr )); then
            display_message "$hit unit hit on Klingon. $pwr left."
        else
            display_message "$hit unit hit on Klingon. Klingon destroyed!"
            klingon_destroyed "$qi"
        fi
    done
    klingon_attack
}
function format_coord() { fp_round "$1"; }

# Animate a torpedo travelling the short-range map. Takes the number of track
# steps to show (last); draws the torpedo char at each sector in turn, pausing
# briefly, then restores the sector to its real contents before advancing. Does
# nothing when the SR scanner is damaged (the map is blank).
function animate_torpedo() {
    local last=$1 ti r c char
    (( damage[d_sr_scan] )) && return
    if (( USE_COLOUR == TRUE )); then char="${C_RED}${TORP_CHAR_COLOUR}${C_RESET}"
    else char="$TORP_CHAR_MONO"; fi
    for (( ti=1; ti<=last; ti++ )); do
        r=$(fp_round "${trk_y[$ti]}"); c=$(fp_round "${trk_x[$ti]}")
        # Draw the torpedo at this sector.
        cursor $(( c * 3 + 1 )) $(( r + 1 )); printf '%s' "$char"
        sleep 0.25 2>/dev/null
        # Erase: restore the sector's true contents.
        update_sector "$r" "$c"
    done
}


function torpedoes_cmd() {
    printf 'Torpedo'
    if (( damage[d_torpedoes] )); then
        display_message "Torpedo tubes not operational."; return
    fi
    if (( torpedoes == 0 )); then
        display_message "All torpedoes expended."; return
    fi
    local qc input qc_fp
    get_line_at "$command_x" $(( command_y + message_count + 1 )) "Course? "; input=$LINE_RESULT
    message_count=$(( message_count + 1 ))
    if ! [[ "$input" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        clear_messages; display_message "Torpedo command cancelled."; return
    fi
    qc_fp=$(fp_parse "$input")
    if (( qc_fp < FP || qc_fp >= 9 * FP )); then
        clear_messages; display_message "Torpedo command cancelled."; return
    fi
    qc=$qc_fp
    torpedoes=$(( torpedoes - 1 )); update_torpedoes

    local qi; course_track "$qc" "$FP"; qi=$COURSE_RESULT   # warp factor 1 == FP
    local last
    if (( qi > 0 )); then last=$(( qi - 1 )); else last=$(( -qi )); fi
    animate_torpedo "$last"     # show the torpedo travel the short-range map
    # Build the torpedo track coordinate string (kept for reference; the
    # animation above now shows the path, so it is intentionally not displayed).
    local t="" ti
    for (( ti=1; ti<=last; ti++ )); do
        t+="$(format_coord $(( ${trk_x[$ti]} + FP )))-$(format_coord $(( ${trk_y[$ti]} + FP )))  "
    done



    if (( qi >= 0 )); then
        display_message "Torpedo missed."
        klingon_attack
        return
    fi

    qi=$(( -qi ))
    local trow=$(fp_round "${trk_y[$qi]}") tcol=$(fp_round "${trk_x[$qi]}")
    local h=${quadrant[(($trow)*8+($tcol))]}
    local qrow=$(( enterprise_y / 8 )) qcol=$(( enterprise_x / 8 ))
    if (( h == 1 )); then
        display_message "Torpedo vaporized by star"
    elif (( h == 10 )); then
        display_message "Starbase destroyed! Court martial assured!"
        change_sector "$trow" "$tcol" 0
        galaxy[(($qrow)*8+($qcol))]=$(( ${galaxy[(($qrow)*8+($qcol))]} - 10 ))
        update_quadrant "$qrow" "$qcol"
    elif (( h == 100 )); then
        display_message "Klingon destroyed!"
        klingon_destroyed_rc "$trow" "$tcol"
    fi
    klingon_attack
}

# ---------------------------------------------------------------------------
#  Commands
# ---------------------------------------------------------------------------

function shields_cmd() {
    printf 'Shields'
    if (( damage[d_shields] )); then
        display_message "Shield control inoperable."; return
    fi
    display_message "Energy available: $(( energy + shields ))"
    local input new_shields
    get_line_at "$command_x" $(( command_y + message_count + 1 )) "Shield level? "; input=$LINE_RESULT
    message_count=$(( message_count + 1 ))
    clear_messages
    if ! [[ "$input" =~ ^[0-9]+$ ]]; then
        display_message "Shield setting unchanged."; return
    fi
    new_shields=$input
    if (( new_shields < 0 || new_shields > energy + shields )); then
        display_message "Shield setting unchanged."; return
    fi
    energy=$(( energy + shields - new_shields )); shields=$new_shields
    update_energy; update_shields
}

function lr_scan() {
    printf 'Long Range Scan'
    # Brief pause so the "Long Range Scan" label registers before results draw.
    sleep 1 2>/dev/null
    if (( damage[d_lr_scan] )); then
        display_message "Long range scanner inoperable."; return
    fi
    local qx=$(( enterprise_x / 8 )) qy=$(( enterprise_y / 8 ))
    local comp_damage=${damage[d_computer]}
    damage[d_computer]=0
    local qrow qcol lo_r hi_r lo_c hi_c qquad
    lo_r=$(imax $(( qy-1 )) 0); hi_r=$(imin $(( qy+1 )) 7)
    lo_c=$(imax $(( qx-1 )) 0); hi_c=$(imin $(( qx+1 )) 7)
    for (( qrow=lo_r; qrow<=hi_r; qrow++ )); do
        for (( qcol=lo_c; qcol<=hi_c; qcol++ )); do
            qquad=${galaxy[(($qrow)*8+($qcol))]}
            if (( qquad < 0 || comp_damage )); then
                local a=$qquad; (( a < 0 )) && a=$(( -a ))
                galaxy[(($qrow)*8+($qcol))]=$a
                update_quadrant "$qrow" "$qcol"
                (( comp_damage )) && galaxy[(($qrow)*8+($qcol))]=$qquad
            fi
        done
    done
    damage[d_computer]=$comp_damage
}

function abandon() {
    printf 'Abandon Ship'
    display_message "Do you want to exit the game? "
    local a
    a=$(upper "$(get_char)")
    if [[ "$a" == "Y" ]]; then printf '%s' "$clear_screen"; exit_game=${TRUE}; return 1; fi
    return 0
}

# ---------------------------------------------------------------------------
#  Warp
# ---------------------------------------------------------------------------

function warp() {
    printf 'Warp'; clear_messages
    if (( damage[d_warp] )); then
        display_message "Engines damaged. Max. speed warp 0.2!"
    fi
    local qc qw input          # qc, qw are scaled fixed-point
    get_line_at "$command_x" $(( command_y + message_count + 1 )) "Course? "; input=$LINE_RESULT
    message_count=$(( message_count + 1 ))
    if ! [[ "$input" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        clear_messages; display_message "Warp command cancelled."; return
    fi
    qc=$(fp_parse "$input")
    if (( qc < FP || qc >= 9 * FP )); then
        clear_messages; display_message "Warp command cancelled."; return
    fi
    get_line_at "$command_x" $(( command_y + message_count + 1 )) "Warp factor? "; input=$LINE_RESULT
    message_count=$(( message_count + 1 ))
    clear_messages
    if ! [[ "$input" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        display_message "Warp command cancelled."; return
    fi
    qw=$(fp_parse "$input")
    if (( qw < 125000 )) || { (( damage[d_warp] )) && (( qw > 200000 )); }; then
        display_message "Warp command cancelled."; return
    fi

    local qmsg=""
    # Not enough energy? Shorten the trip.  qw*8 + 5 > energy
    if (( qw * 8 + 5 * FP > energy * FP )); then
        local avail=$(( energy - 5 )); (( avail < 0 )) && avail=0
        qw=$(( avail * FP / 8 ))                       # avail / 8.0, scaled
        qmsg="Engines shut down due to low energy."
    fi

    # Track through the quadrant; shorten on collision.
    local qi; course_track "$qc" "$qw"; qi=$COURSE_RESULT
    if (( qi < 0 )); then
        local idx=$(( -qi - 1 ))
        local ddy=$(( ${trk_y[0]} - ${trk_y[$idx]} )) ddx=$(( ${trk_x[0]} - ${trk_x[$idx]} ))
        local sq=$(( $(fp_mul "$ddy" "$ddy") + $(fp_mul "$ddx" "$ddx") ))   # scaled
        qw=$(( $(fp_sqrt "$sq") / 8 ))                 # sqrt(...)/8, scaled
        qmsg="Engines shut down to avoid collision."
    fi

    # New absolute location, clamped to the galactic barrier.
    local theta ctheta stheta new_x new_y
    theta=$(fp_mul $(( qc - FP )) $(( FP_PI / 4 )) )   # (qc-1)*pi/4
    local guard=0
    while :; do
        ctheta=$(fp_cos "$theta"); stheta=$(fp_sin "$theta")
        # new_x = int( eX + cos*qw*8 + 0.5 ); cos*qw is fp_mul, *8 keeps scaled.
        new_x=$(fp_round $(( enterprise_x * FP + $(fp_mul "$ctheta" "$qw") * 8 )) )
        new_y=$(fp_round $(( enterprise_y * FP - $(fp_mul "$stheta" "$qw") * 8 )) )
        guard=$(( guard + 1 )); (( guard > 8 )) && break
        if (( new_x < 0 )); then
            qw=$(( qw * enterprise_x / (enterprise_x - new_x) ))
            qmsg="Engines shut down at galactic barrier."; continue
        fi
        if (( new_x > 63 )); then
            qw=$(( qw * (63 - enterprise_x) / (new_x - enterprise_x) ))
            qmsg="Engines shut down at galactic barrier."; continue
        fi
        if (( new_y < 0 )); then
            qw=$(( qw * enterprise_y / (enterprise_y - new_y) ))
            qmsg="Engines shut down at galactic barrier."; continue
        fi
        if (( new_y > 63 )); then
            qw=$(( qw * (63 - enterprise_y) / (new_y - enterprise_y) ))
            qmsg="Engines shut down at galactic barrier."; continue
        fi
        break
    done
    (( new_x < 0 )) && new_x=0; (( new_x > 63 )) && new_x=63
    (( new_y < 0 )) && new_y=0; (( new_y > 63 )) && new_y=63

    [[ -n "$qmsg" ]] && { display_message "$qmsg"; qmsg=""; }

    # Determine quadrant change.
    local q_x=$(( enterprise_x / 8 )) q_y=$(( enterprise_y / 8 ))
    local qn_x=$(( new_x / 8 )) qn_y=$(( new_y / 8 ))
    local new_quadrant=0
    (( q_x != qn_x || q_y != qn_y )) && new_quadrant=1

    if (( new_quadrant == 0 )); then
        change_sector "$enterprise_y" "$enterprise_x" 0
        change_sector "$new_y" "$new_x" 1000
    fi

    enterprise_x=$new_x; enterprise_y=$new_y

    if (( new_quadrant )); then
        galaxy[(($q_y)*8+($q_x))]=$(( ${galaxy[(($q_y)*8+($q_x))]} - 1000 ))
        update_quadrant "$q_y" "$q_x"
        local a=${galaxy[(($qn_y)*8+($qn_x))]}; (( a < 0 )) && a=$(( -a ))
        galaxy[(($qn_y)*8+($qn_x))]=$(( a + 1000 ))
        update_quadrant "$qn_y" "$qn_x"
        initialize_quadrant
        print_quadrant
        (( damage[d_computer] )) && print_galaxy
    fi

    # Energy, time, repairs, hazards.  cost = int(qw*8 + 5)
    energy=$(( energy - (qw * 8 / FP + 5) )); update_energy
    stardates=$(( stardates - 1 )); update_stardates
    normal_repair
    if (( $(rnd) < 200000 )); then repair_damage; fi        # rnd < 0.2
    if (( $(rnd) < 100000 )); then                         # rnd < 0.1
        display_message "** SPACE STORM **"; wreak_damage "$shields"
    fi
    update_condition
    klingon_attack
}

# ---------------------------------------------------------------------------
#  Welcome / instructions
# ---------------------------------------------------------------------------

instructions=(
"     Instructions"
" "
"The galaxy is divided into an 8,8 quadrant grid"
"which is in turn divided into an 8,8 sector grid."
" "
"The cast of characters is as follows:"
" E = Enterprise"
" K = Klingon"
" B = Starbase"
" *  = star"
"Command W = Warp engine control:"
"  Course is in a circular numerical       4  3  2"
"  vector arrangement as shown.             \\ | /"
"  Integer and real values may be            \\|/"
"  used.  Therefore course 1.5 is         5 ----- 1"
"  half way between 1 and 2.                 /|\\"
"                                           / | \\"
"  A vector of 9 is undefined, but         6  7  8"
"  values may approach 9."
"                                          Course"
"  One warp factor is the size of"
"  one quadrant.  Therefore to get from"
"  quadrant 6,5 to 5,5 you would use course 3, warp factor 1."
" "
"Command L = Long range sensor scan"
"  shows conditions in space for one quadrant on each side"
"  of the Enterprise in the middle of the scan. The scan"
"  is coded in the form xxx, where the units digit is the "
"  number of stars, the tens digit is the number of star-"
"  bases.  The hundreds digit is the number of Klingons."
" "
"Command P = Phaser control"
"  Allows you to destroy the Klingons by hitting them with"
"  suitably large numbers of energy units to deplete their "
"  shield power.  Keep in mind that when you shoot at them,"
"  they gonna shoot at you, too!"
" "
"Command T = Photon Torpedo control"
"  Course is the same as used in warp engine control."
"  If you hit the Klingon, he is destroyed  If you miss,"
"  you are subject to his phaser fire."
" "
"Command S = Shield control"
"  Defines number of energy units to be assigned to shields."
"  Energy is taken from total ship's energy."
"  Note that total energy includes shield energy."
)

function welcome() {
    printf '%s' "$clear_screen"
    printf '                  * * *  VT52 STAR TREK  * * *\n\n'
    printf 'Do you want instructions (Y, [N])? '
    local a; a=$(upper "$(get_any_key)"); a=${a:0:1}
    printf '%s' "$clear_screen"
    [[ "$a" != "Y" ]] && return
    local idx=0 total=${#instructions[@]} ln
    while (( idx < total )); do
        for (( ln=1; ln<=23 && idx<total; ln++, idx++ )); do
            printf '%s\n' "${instructions[$idx]}"
        done
        if (( idx < total )); then
            printf 'More ([Y], N)? '
            a=$(upper "$(get_any_key)"); a=${a:0:1}
            printf '%s%s' "$start_of_line" "$clear_line"
            printf '%s' "$clear_screen"
            [[ "$a" == "N" ]] && break
        fi
    done
    printf 'Done. Hit any key...'; get_any_key >/dev/null
}

# ---------------------------------------------------------------------------
#  Main game loop
# ---------------------------------------------------------------------------

# If the window has been shrunk below the minimum mid-game, pause and wait for
# the player to enlarge it, then redraw. Returns once the size is adequate.
# IMPORTANT: only redraw if we actually had to pause for a resize. Redrawing
# unconditionally on every loop iteration would wipe the messages the previous
# command just displayed (that was the "message flashes then a screen refresh
# blanks it" bug).
function ensure_screen_size() {
    term_size || return 0   # can't detect: don't block
    local paused=0
    while (( TERM_COLS < MIN_COLS || TERM_ROWS < MIN_ROWS )); do
        paused=1
        printf '%s' "$clear_screen"
        cursor 0 0
        printf 'Window too small: %dx%d. Need at least %dx%d.' \
            "$TERM_COLS" "$TERM_ROWS" "$MIN_COLS" "$MIN_ROWS"
        cursor 0 1; printf 'Enlarge the window, then press any key...'
        get_any_key >/dev/null
        term_size || return 0
    done
    # Only refresh when we had to clear the screen for a too-small warning.
    (( paused )) && refresh_screen
}

function play_game() {
    local game_over=${FALSE} prompt cmd
    while (( game_over == FALSE )); do
        ensure_screen_size
        local prompt_coloured
        if (( shields <= 200 )); then
            prompt="Command: (shields up, Captain?) "
            # If the condition is not green and shields are below 200, tint the
            # warning prompt with the current condition colour.
            if (( shields < 200 )) && [[ "$cond" != *GREEN* ]]; then
                prompt_coloured="Command: $(cwrap "$(condition_colour "$cond")" '(shields up, Captain?)') "
            else
                prompt_coloured="$prompt"
            fi
        else
            prompt="Command: "
            prompt_coloured="$prompt"
        fi
        cursor "$command_x" "$command_y"; printf '%s%s' "$prompt_coloured" "$clear_line"
        cmd=$(upper "$(get_char)")
        clear_messages
        cursor $(( command_x + ${#prompt} )) "$command_y"
        case "$cmd" in
            W) warp ;;
            P) phasers ;;
            T) torpedoes_cmd ;;
            S) shields_cmd ;;
            L) lr_scan ;;
            A) abandon || return ;;
            R) refresh_screen ;;
        esac
        if (( shields < 0 || energy + shields <= 0 || klingons == 0 || stardates == 0 )); then
            game_over=${TRUE}
        fi
    done

    # End-of-game messages.
    if (( klingons == 0 )); then
        if (( energy + shields >= 0 )); then
            display_message "The Federation has been saved!"
            display_message "You are promoted to Admiral... until you"
            display_message "steal a starship or something."
        else
            display_message "The Federation has been saved!"
            display_message "But the Enterprise was destroyed."
            display_message "You are promoted to Admiral posthumously."
        fi
    else
        if (( shields < 0 )); then
            display_message "The Enterprise has been destroyed!"
            display_message "The Federation will be conquered."
        elif (( energy + shields == 0 )); then
            display_message "The Enterprise is dead in space!"
            display_message "The Federation will be conquered."
        else
            display_message "Time has run out!"
            display_message "The Federation has been conquered."
            display_message "You will be imprisoned on Rura Penthe."
        fi
    fi
}

function offer_replay() {
    local cmd
    while :; do
        cursor "$command_x" "$command_y"
        printf 'Would you like to play again? %s' "$clear_line"
        cmd=$(upper "$(get_char)")
        [[ "$cmd" == "Y" ]] && return 0
        [[ "$cmd" == "N" ]] && return 1
    done
}

# ---------------------------------------------------------------------------
#  Terminal size check
# ---------------------------------------------------------------------------

# Determine the current terminal size, setting globals TERM_ROWS and TERM_COLS.
# Tries several standard methods so it works on macOS and over ssh with a
# minimal toolset. Returns 1 if the size could not be determined.
function term_size() {
    TERM_ROWS=0; TERM_COLS=0
    # Preferred: stty size (rows cols). Read from the controlling terminal.
    local sz
    if sz=$(stty size 2>/dev/null </dev/tty); then
        TERM_ROWS=${sz%% *}; TERM_COLS=${sz##* }
    fi
    # Fall back to tput if stty didn't give usable numbers.
    if ! [[ "$TERM_ROWS" =~ ^[0-9]+$ && "$TERM_COLS" =~ ^[0-9]+$ ]] \
       || (( TERM_ROWS == 0 || TERM_COLS == 0 )); then
        TERM_ROWS=$(tput lines 2>/dev/null </dev/tty || echo 0)
        TERM_COLS=$(tput cols  2>/dev/null </dev/tty || echo 0)
    fi
    # Last resort: the LINES / COLUMNS environment variables.
    [[ "$TERM_ROWS" =~ ^[0-9]+$ ]] || TERM_ROWS=${LINES:-0}
    [[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=${COLUMNS:-0}
    (( TERM_ROWS > 0 && TERM_COLS > 0 ))
}

# Verify the terminal is large enough. On success returns 0. On failure prints
# a clear message and returns 1. The caller decides whether to abort or wait.
function check_screen_size() {
    if ! term_size; then
        # Couldn't detect a size (e.g. not a real terminal). Warn but allow.
        printf 'Warning: could not detect terminal size; assuming it is at least %dx%d.\n' \
            "$MIN_COLS" "$MIN_ROWS" >&2
        return 0
    fi
    if (( TERM_COLS < MIN_COLS || TERM_ROWS < MIN_ROWS )); then
        printf '\n' >&2
        printf 'TREK52 needs a terminal of at least %d columns x %d rows.\n' \
            "$MIN_COLS" "$MIN_ROWS" >&2
        printf 'Your terminal is currently %d columns x %d rows.\n' \
            "$TERM_COLS" "$TERM_ROWS" >&2
        printf 'Please enlarge the window (or run: resize / stty) and try again.\n\n' >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
#  Bootstrap
# ---------------------------------------------------------------------------

function main() {
    # Apply parsed arguments to the runtime globals.
    USE_COLOUR=${arg_use_colour}

    # Make sure the window is big enough before we touch the terminal or draw.
    check_screen_size || exit 1

    # Save the sane terminal state, then switch to no-echo for single-key input.
    # Operate on /dev/tty (the real terminal) rather than stdin, so terminal
    # modes are set correctly even when the script was piped in on stdin, e.g.
    # `cat trek52.sh | bash`.
    SANE_TTY=$(stty -g </dev/tty)
    stty -echo </dev/tty
    printf '%s[?25l' "$ESC"   # hide cursor

    trap 'stty "$SANE_TTY" </dev/tty; printf "%s[?25h" "$ESC"; printf "%s" "$clear_screen"; exit 0' EXIT INT TERM

    welcome
    while (( exit_game == FALSE )); do
        initialize_game
        refresh_screen
        play_game
        (( exit_game == TRUE )) && break
        offer_replay || exit_game=${TRUE}
    done
    printf '%s' "$clear_screen"
}

# Only run automatically when executed directly (allows sourcing for tests).
if [[ "${TREK52_NO_MAIN:-}" != "1" ]]; then
    parse_arguments "$@"
    main
fi
