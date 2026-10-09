#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true              ; catch F6/F9/Home even while the game has focus
; InfestationHop - opens the map on each server, drags it around looking for an
; Infestation cloud (cloudscan.py), and server hops when there isn't one.
;
; Loop (start it while you're loaded into a server with the HUD showing):
;   1. Esc       - open the map
;   2. Drag the map to its top-left corner, then sweep it in a grid, checking each view
;      for the dark grey cloud
;   3. Cloud found?  -> drag the cloud to the middle and fast travel (FAST TRAVEL, then Yes
;                       to pay the caps) to each spawn spot
;                       (magenta dot) inside it, checking for INFESTATION in the quest list
;                       after each trip (AUTO_TRAVEL):
;        - Infestation found          -> "found it" tune, stops - you're there
;        - every spot tried, nothing  -> low tone, carries on hopping
;        (since game update 1.7.25 every spawn spot can be fast travelled to, so a spot
;        with no FAST TRAVEL button just means the click missed - it's retried, then skipped)
;      No cloud?     -> Esc to close the map, Ctrl+Tab, PgUp to server hop
;   4. Wait for the HUD (HP/AP bars) on the new server, then back to step 1
;   With AUTO_SCAN := false it skips step 2 and waits for you to check the map and press Home.
;
;   F6   = start / stop
;   Home = "OK, hop" (only while it's waiting for you - otherwise Home works as normal)
;   F9   = exit script
;   (different keys from EventHop / HeadHuntHop, so they can all run at once)
;
; Screen checks use colours from a 1920x1080 screenshot and scale to the window size.

; ---- settings -------------------------------------------------------------
MAP_KEY           := "{Esc}"
HOP_KEY           := "{PgUp}"
CLOSE_MAP_FIRST   := true  ; press Esc to close the map before opening the mod menu (false if you close it yourself)
MAP_CLOSE_SEC     := 1     ; pause after closing the map before Ctrl+Tab
MENU_OPEN_SEC     := 1.5   ; (fallback if the menu can't be detected) pause after Ctrl+Tab before PgUp
HOP_LEAVE_SEC     := 10    ; after PgUp, wait this long for the old server to disconnect before looking for the new one
HUD_BACK_TIMEOUT  := 300   ; max wait for the HUD on the new server
HUD_SETTLE_SEC    := 3     ; extra pause once the HUD is back, before opening the map
MAX_HOPS          := 100   ; safety stop
IDLE_MS           := 500   ; background use: wait until you stop typing/moving the mouse this long before switching to the game
IDLE_MAX_WAIT_SEC := 3     ; ...but take focus anyway after this long
FOCUS_SETTLE_MS   := 800   ; after switching to the game, wait this long before pressing keys (raise if keys get ignored)
PEEK_EVERY_SEC    := 10    ; while a new server loads in the background, switch to the game this often to check for the HUD
PEEK_SEC          := 2     ; how long each check looks for the HUD before switching back
BLOCK_INPUT       := false ; true = block your mouse/keyboard while the script is switched into the game (needs admin)
MAX_BLOCK_SEC     := 45    ; safety: never block input longer than this (Ctrl+Alt+Del also unblocks) - the map scan takes ~25s
GAME              := "ahk_exe Fallout76.exe"
; map scan
AUTO_SCAN         := true  ; scan the map for the cloud and hop by itself when there isn't one
MAP_OPEN_SEC      := 1.5   ; wait after Esc for the map to open
CORNER_DRAGS      := 5     ; drags towards the top-left to start the sweep from the map's corner
SCAN_COLS         := 4     ; views across (map is ~2 screens wide)
SCAN_ROWS         := 3     ; views down (3 rows = 2 downward drags covers the map)
STEP_X            := 700   ; how far each sideways drag moves (pixels at 1920x1080, max 750)
STEP_Y            := 800   ; how far each downward drag moves (max 800)
DRAG_SETTLE_MS    := 350   ; wait after a drag before checking the view
PYTHON            := "python"
AUTO_TRAVEL       := true  ; fast travel to the spots in the cloud to find the Infestation
HUNT_MAX_TRIES    := 15    ; safety: most fast travel attempts per cloud
POPUP_SEC         := 0.8   ; wait after clicking a spot for its popup
CONFIRM_SEC       := 0.8   ; wait after FAST TRAVEL for the "Pay N Caps ...?" box
TRAVEL_START_SEC  := 20    ; wait after Yes for the loading screen (fast travel takes ~15s while in combat)
INFEST_CHECK_SEC  := 3     ; after arriving, how long to look for INFESTATION before going back to the map
HOVER_MS          := 300   ; after gliding onto a spot, wait this long so the map registers the hover
CENTER_TOL_X      := 250   ; only drag the map if the cloud's centre is further than this from
CENTER_TOL_Y      := 150   ; the middle of the screen (1920x1080 pixels)
NEAR_PX           := 35    ; spots this close (relative to the cloud's centre) count as the same spot
SAVE_ALL_SCANS    := false ; true = save every view to cloudshots\ (views with a cloud are always saved)
; ---------------------------------------------------------------------------

; BlockInput needs admin: relaunch elevated (if you decline, it runs without blocking)
if BLOCK_INPUT && !A_IsAdmin {
    try {
        Run '*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"'
        ExitApp
    }
}

SendMode "Event"
SetKeyDelay 50, 80         ; hold keys briefly so the game registers them
CoordMode "Pixel", "Client"

running := false
waitingForOk := false     ; true while the map is open and it's waiting for you to press Home
menuCheck := ""           ; "" = not tested yet, true = can see the mod menu, false = can't (fixed timing)
borrowed := false, prevWin := 0, prevX := 0, prevY := 0
TrayTip "Loaded. Press F6 in game to start/stop, Home to hop after checking the map, F9 to exit.", "InfestationHop"

F6:: {
    global running, waitingForOk
    running := !running
    waitingForOk := false
    if running {
        SoundBeep 800, 150     ; one beep = started
        SetTimer HopLoop, -300
    } else {
        SoundBeep 500, 150     ; low beep = stopped
        SoundBeep 400, 150
        UnblockUser()
        Status("InfestationHop stopped")
    }
}

F9::ExitApp

#HotIf waitingForOk
Home:: {
    global waitingForOk
    waitingForOk := false
    SoundBeep 1000, 80
}
#HotIf

HopLoop() {
    HopLoopRun()
    ReturnFocus()   ; if it was stopped while switched into the game, switch back
}

HopLoopRun() {
    global running, waitingForOk
    hops := 0
    loop {
        if !running
            return

        ; 1. open the map
        if !BorrowFocus()
            return Stop("Fallout 76 window not found")
        Status("Server " hops + 1 ": opening map (Esc)")
        Send MAP_KEY
        if !Pause(MAP_OPEN_SEC)
            return

        ; 2. scan it for a cloud - or, if there is one / scanning is off, wait for your OK
        result := AUTO_SCAN ? ScanMap("Server " hops + 1) : "manual"
        if result = "stopped" || !running
            return
        if result = "found" && AUTO_TRAVEL {
            result := HuntInfestation("Server " hops + 1)
            if result = "stopped" || !running
                return
            if result = "infestation" {
                ReturnFocus()
                PlayFound()
                TrayTip "INFESTATION found on server " hops + 1 " - you're there!", "InfestationHop"
                return Stop("Infestation found on server " hops + 1 "!")
            }
            if result = "none" {
                PlayNothing()
                TrayTip "Tried every spot in the cloud - no Infestation. Hopping on.", "InfestationHop"
                result := "none"   ; fall through to the hop below
            }
        }
        if result != "none" {
            ReturnFocus()
            if result = "lost" {
                SoundBeep 400, 300
                TrayTip "Lost track of the cloud - check the map yourself. Home = hop, F6 = stop", "InfestationHop"
            } else if result = "found" {
                SoundBeep 1500, 150
                SoundBeep 1500, 150
                SoundBeep 1500, 150
                TrayTip "Infestation cloud on server " hops + 1 "! Home = hop anyway, F6 = stop", "InfestationHop"
            } else if result = "error" {
                SoundBeep 400, 300
                TrayTip "Couldn't scan the map (see cloudscan.py) - check it yourself, Home to hop", "InfestationHop"
            } else
                SoundBeep 1200, 150    ; map is up - have a look
            waitingForOk := true
            while running && waitingForOk {
                Status("Server " hops + 1 ": " (result = "found" ? "cloud found" : "check the map") " - Home to hop, F6 to stop")
                Sleep 250
            }
            waitingForOk := false
            if !running
                return
        }
        if hops >= MAX_HOPS
            return Stop("Gave up after " MAX_HOPS " hops")
        hops++

        ; 3. close the map, open the mod menu, hop
        if !BorrowFocus()
            return Stop("Fallout 76 window not found")
        if CLOSE_MAP_FIRST {
            Status("Hop " hops ": closing map (Esc)")
            Send MAP_KEY
            if !Pause(MAP_CLOSE_SEC)
                return
        }
        Status("Hop " hops ": opening mod menu")
        if !OpenMenu()
            return
        Status("Hop " hops ": server hopping (PgUp)")
        Send HOP_KEY
        Sleep 200
        ReturnFocus()   ; you get your mouse/keyboard back while the hop happens

        ; 4. wait for the new server
        if !Pause(HOP_LEAVE_SEC)
            return
        if !WaitForHud(HUD_BACK_TIMEOUT, "Hop " hops ": loading new server")
            return running ? Stop("New server never loaded (no HUD after " HUD_BACK_TIMEOUT "s)") : ""
        if !Pause(HUD_SETTLE_SEC)
            return
    }
}

; ---- map scan -------------------------------------------------------------

; Drags the map to its top-left corner, then sweeps it row by row (zig-zag), checking
; each view with cloudscan.py. Returns "found", "none", "error" or "stopped".
; Leaves the map on the cloud when it finds one.
ScanMap(label) {
    WinGetClientPos &cx, &cy, &cw, &ch, GAME
    if !cw
        return "error"
    Status(label ": moving map to the top-left corner")
    loop CORNER_DRAGS {
        if !running
            return "stopped"
        DragMap(750, 700)
    }
    loop SCAN_ROWS {
        row := A_Index
        loop SCAN_COLS {
            if !running
                return "stopped"
            Status(label ": scanning map " row "," A_Index)
            res := CheckForCloud(cx, cy, cw, ch)
            if res != "none"
                return res
            if A_Index < SCAN_COLS
                DragMap(Mod(row, 2) ? -STEP_X : STEP_X, 0)   ; zig-zag across
        }
        if row < SCAN_ROWS
            DragMap(0, -STEP_Y)                              ; next row down
    }
    return "none"
}

; Runs cloudscan.py on the game window: exit code 2 = cloud, 0 = none, anything else = error.
CheckForCloud(cx, cy, cw, ch) {
    ParkMouse()
    Sleep DRAG_SETTLE_MS
    try code := RunWait('"' PYTHON '" "' A_ScriptDir '\cloudscan.py" ' cx ' ' cy ' ' cw ' ' ch (SAVE_ALL_SCANS ? " --save-all" : ""), A_ScriptDir, "Hide")
    catch
        return "error"
    return code = 2 ? "found" : code = 0 ? "none" : "error"
}

; Left-click drags the map by dx,dy (1920x1080 pixels; the map follows the mouse, so a
; negative dx shows more of the map to the right). Moves in small relative steps so the
; game sees a real drag. Starts where the whole drag stays on open map, clear of panels.
DragMap(dx, dy) {
    WinGetClientPos &cx, &cy, &cw, &ch, GAME
    sx := cw / 1920, sy := ch / 1080
    x0 := dx > 0 ? 450 : dx < 0 ? 1200 : 800
    y0 := dy > 0 ? 250 : dy < 0 ? 980 : 600   ; 980: just above the key-hint bar
    CoordMode "Mouse", "Client"
    MouseMove Round(x0 * sx), Round(y0 * sy), 0
    Sleep 60
    Click "Down"
    Sleep 60
    steps := 15
    loop steps {
        MouseMove Round(dx * sx / steps), Round(dy * sy / steps), 0, "R"
        Sleep 12
    }
    Sleep 60
    Click "Up"
    Sleep 60
}

; ---- fast travel to the spots in the cloud ---------------------------------

; With the map open on a cloud: centre the cloud, then fast travel to each spawn spot in it
; until INFESTATION shows in the quest list. Spots are remembered by their position relative
; to the cloud's centre (the map re-centres on you after every trip, the cloud doesn't move).
; Every spawn spot can be fast travelled to, so a spot that never shows a FAST TRAVEL
; button (the click missed twice) is skipped rather than retried forever.
; Returns "infestation", "none", "lost" or "stopped".
HuntInfestation(label) {
    tried := []
    loop HUNT_MAX_TRIES {
        if !running
            return "stopped"
        if !BorrowFocus()
            return "lost"
        RefreshBlock()
        info := CenterCloud(label)
        if !running
            return "stopped"
        if !IsObject(info)
            return "lost"
        next := 0
        for s in info.spots {
            off := [s[1] - info.cx, s[2] - info.cy]
            if !NearAny(off, tried) {
                next := s
                break
            }
        }
        if !next
            return "none"

        tried.Push(off)
        Status(label ": spot " tried.Length " of " info.spots.Length " - clicking it")
        btn := 0
        loop 2 {                       ; second try in case the first click didn't register on the icon
            ClickSpot(next[1], next[2])
            if !Pause(POPUP_SEC)
                return "stopped"
            if btn := FindButton(next[1], next[2])
                break
        }
        if !btn {                      ; click missed twice - skip this spot
            ParkMouse()
            Sleep 300
            continue
        }
        Status(label ": fast travelling to spot " tried.Length)
        MouseMove btn[1], btn[2], 0
        Sleep 120
        Click
        if !Pause(CONFIRM_SEC)
            return "stopped"
        if yes := FindYes() {          ; "Pay N Caps to travel to this location?" -> Yes
            MouseMove yes[1], yes[2], 0
            Sleep 120
            Click
        }
        if !WaitFor(IsLoadingScreen, TRAVEL_START_SEC, label ": waiting for fast travel") {
            ParkMouse()
            continue                   ; didn't travel - try the next spot
        }
        ReturnFocus()                  ; you get your input back during the trip
        if !WaitForHud(HUD_BACK_TIMEOUT, label ": arriving")
            return running ? "lost" : "stopped"
        if WaitFor(IsInfestation, INFEST_CHECK_SEC, label ": looking for INFESTATION")
            return "infestation"
        if !running
            return "stopped"

        ; not here - back to the map and find the cloud again
        if !BorrowFocus()
            return "lost"
        Status(label ": not here - opening map")
        Send MAP_KEY
        if !Pause(MAP_OPEN_SEC)
            return "stopped"
        ParkMouse()
        if !IsObject(GetSpots()) {     ; the map opens on you, so the cloud is normally in view
            r := ScanMap(label)
            if r != "found"
                return r = "stopped" ? "stopped" : "lost"
        }
    }
    return "none"
}

; Drags the map so the cloud sits in the middle of the screen (clear of the side panels),
; then returns {cx, cy, spots: [[x, y], ...]} in window pixels, or "" if the cloud is gone.
CenterCloud(label) {
    loop 3 {
        info := GetSpots()
        if !IsObject(info) || !running
            return info
        WinGetClientPos , , &cw, &ch, GAME
        dx := (cw * 0.5 - info.cx) * 1920 / cw     ; in 1920x1080 pixels, like DragMap
        dy := (ch * 0.52 - info.cy) * 1080 / ch
        if Abs(dx) < CENTER_TOL_X && Abs(dy) < CENTER_TOL_Y
            return info
        Status(label ": centring the cloud")
        DragMap(Max(-750, Min(750, Round(dx))), Max(-800, Min(700, Round(dy))))
        ParkMouse()
        Sleep DRAG_SETTLE_MS
    }
    return GetSpots()
}

; cloudscan.py spots -> {cx, cy, spots}, or "" when there's no cloud
GetSpots() {
    outFile := A_Temp "\infhop_spots.txt"
    if RunScan('spots', ' "' outFile '"') != 2
        return ""
    lines := StrSplit(Trim(FileRead(outFile)), "`n", "`r")
    c := StrSplit(lines[1], " ")
    spots := []
    loop lines.Length - 1 {
        p := StrSplit(lines[A_Index + 1], " ")
        spots.Push([Integer(p[1]), Integer(p[2])])
    }
    return {cx: Integer(c[1]), cy: Integer(c[2]), spots: spots}
}

; cloudscan.py button -> [x, y] of the gold FAST TRAVEL button near a clicked spot, or 0
FindButton(x, y) {
    outFile := A_Temp "\infhop_button.txt"
    if RunScan('button', ' ' x ' ' y ' "' outFile '"') != 2
        return 0
    p := StrSplit(Trim(FileRead(outFile)), " ")
    return [Integer(p[1]), Integer(p[2])]
}

; cloudscan.py yes -> [x, y] of the gold "Yes" in the pay-caps confirmation box, or 0
FindYes() {
    outFile := A_Temp "\infhop_yes.txt"
    if RunScan('yes', ' "' outFile '"') != 2
        return 0
    p := StrSplit(Trim(FileRead(outFile)), " ")
    return [Integer(p[1]), Integer(p[2])]
}

; INFESTATION in the quest list (top right)?
IsInfestation() => RunScan('infest') = 2

; Runs a cloudscan.py check on the game window; returns its exit code (-1 on failure).
RunScan(cmd, extra := "") {
    WinGetClientPos &cx, &cy, &cw, &ch, GAME
    if !cw
        return -1
    try return RunWait('"' PYTHON '" "' A_ScriptDir '\cloudscan.py" ' cmd ' ' cx ' ' cy ' ' cw ' ' ch extra, A_ScriptDir, "Hide")
    catch
        return -1
}

; Clicks a spawn spot's icon dead centre: re-measures the dot, glides onto it, nudges the
; mouse so the map registers the hover, waits, then clicks. (Jumping straight onto the
; icon and clicking at once can miss the hover and drop a waypoint next to it instead.)
ClickSpot(x, y) {
    outFile := A_Temp "\infhop_dot.txt"
    if RunScan('dot', ' ' x ' ' y ' "' outFile '"') = 2 {
        p := StrSplit(Trim(FileRead(outFile)), " ")
        x := Integer(p[1]), y := Integer(p[2])
    }
    CoordMode "Mouse", "Client"
    MouseMove x + 25, y + 25, 0
    Sleep 50
    MouseMove x, y, 4
    Sleep 80
    MouseMove 1, 0, 0, "R"
    Sleep 40
    MouseMove -1, 0, 0, "R"
    Sleep HOVER_MS
    Click
}

NearAny(off, list) {
    for p in list
        if Abs(p[1] - off[1]) <= NEAR_PX && Abs(p[2] - off[2]) <= NEAR_PX
            return true
    return false
}

; Cursor onto the key-hint bar (ignored by cloudscan, nothing to hover) so no map
; tooltip pops up and gets mistaken for smoke.
ParkMouse() {
    WinGetClientPos , , &cw, &ch, GAME
    CoordMode "Mouse", "Client"
    MouseMove Round(1200 * cw / 1920), Round(1062 * ch / 1080), 0
}

; Restart the input-block safety timer during long stretches in the game.
RefreshBlock() {
    if borrowed
        BlockUser(true)
}

PlayFound() {        ; rising tune, twice
    loop 2 {
        for f in [800, 1000, 1200, 1600]
            SoundBeep f, 130
        Sleep 150
    }
}

PlayNothing() {      ; one low tone
    SoundBeep 350, 450
}

; ---- screen checks --------------------------------------------------------

; Mod menu is open if the Pip-Boy green box borders show on the left edge (Friends box).
IsMenuOpen() {
    WinGetClientPos , , &w, &h, GAME
    if !w
        return false
    return PixelSearch(&fx, &fy, 0, Round(90 * h / 1080), Round(30 * w / 1920), Round(210 * h / 1080), 0x1AFF80, 60)
}

; Opens the mod menu with Ctrl+Tab and waits until it's showing. The first time, checks
; whether the menu can be seen at all; if not, falls back to a fixed wait from then on.
OpenMenu() {
    global menuCheck
    if menuCheck = true && IsMenuOpen()
        return true
    PressCtrlTab()
    if menuCheck = false
        return Pause(MENU_OPEN_SEC)
    if WaitFor(IsMenuOpen, 2.5, "Waiting for mod menu") {
        menuCheck := true
        return Pause(0.3)
    }
    if !running
        return false
    if menuCheck = ""
        menuCheck := false   ; can't see the menu on this setup - use fixed timing
    return true
}

; HUD is showing if the AP bar is solid cream, or the HP bar is cream/red.
IsHudVisible() {
    ap := 0, hp := 0, n := 0
    x := 1500
    while x <= 1790 {
        ap += IsColor(Px(x, 1006), 0xFFFFCB, 30)
        n++
        x += 15
    }
    x := 125, m := 0
    while x <= 420 {
        c := Px(x, 1006)
        hp += IsColor(c, 0xFFFFCB, 30) || IsColor(c, 0xF5725A, 35)
        m++
        x += 15
    }
    return ap / n >= 0.7 || hp / m >= 0.7
}

; Loading screen: gold spinning "76" gear bottom-right + dark tip banner along the bottom.
IsLoadingScreen() {
    gold := 0, g := 0
    y := 960
    while y <= 1040 {
        x := 1790
        while x <= 1870 {
            gold += IsColor(Px(x, y), 0xF3CA5A, 40)
            g++
            x += 16
        }
        y += 16
    }
    dark := 0, d := 0
    x := 250
    while x <= 1300 {
        dark += Brightness(Px(x, 1037)) < 45
        d++
        x += 75
    }
    return gold / g >= 0.2 && dark / d >= 0.8
}

; Colour of a 1920x1080 reference point, scaled to the game window.
Px(x, y) {
    WinGetClientPos , , &w, &h, GAME
    return Integer(PixelGetColor(Round(x * w / 1920), Round(y * h / 1080)))
}

IsColor(c, ref, tol) {
    return Abs(((c >> 16) & 0xFF) - ((ref >> 16) & 0xFF)) <= tol
        && Abs(((c >> 8) & 0xFF) - ((ref >> 8) & 0xFF)) <= tol
        && Abs((c & 0xFF) - (ref & 0xFF)) <= tol
}

Brightness(c) => (((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) + (c & 0xFF)) / 3

; ---- helpers --------------------------------------------------------------

; Polls check() until it's true (returns true) or the timeout / F6 stop (returns false).
WaitFor(check, sec, label) {
    global running
    end := A_TickCount + sec * 1000
    while A_TickCount < end {
        if !running || !WinExist(GAME)
            return false
        if check()
            return true
        Status(label " (" Ceil((end - A_TickCount) / 1000) "s)")
        Sleep 400
    }
    return false
}

; Waits for the HUD on a new server. Checks in the background, and every PEEK_EVERY_SEC
; switches to the game briefly in case the HUD can't be seen while you're in another
; window. If the HUD is there it stays in the game (the next step needs it anyway).
WaitForHud(sec, label) {
    global running
    end := A_TickCount + sec * 1000
    nextPeek := A_TickCount + PEEK_EVERY_SEC * 1000
    while A_TickCount < end {
        if !running || !WinExist(GAME)
            return false
        if IsHudVisible()
            return true
        if !WinActive(GAME) && A_TickCount >= nextPeek {
            if BorrowFocus() {
                if WaitFor(IsHudVisible, PEEK_SEC, label " - checking game")
                    return true
                ReturnFocus()
            }
            nextPeek := A_TickCount + PEEK_EVERY_SEC * 1000
        }
        Status(label " (" Ceil((end - A_TickCount) / 1000) "s)")
        Sleep 400
    }
    return false
}

Pause(sec) {
    global running
    end := A_TickCount + sec * 1000
    while A_TickCount < end {
        if !running
            return false
        Sleep 100
    }
    return true
}

PressCtrlTab() {
    Send "{Ctrl down}"
    Sleep 80
    Send "{Tab}"
    Sleep 80
    Send "{Ctrl up}"
}

; Switches to the game to press keys. If you're using another window, waits for a
; pause in your typing/mouse use, and remembers the window and mouse position.
BorrowFocus() {
    global borrowed, prevWin, prevX, prevY
    if !WinExist(GAME)
        return false
    if WinActive(GAME)
        return true
    borrowed := false
    end := A_TickCount + IDLE_MAX_WAIT_SEC * 1000
    while running && A_TimeIdlePhysical < IDLE_MS && A_TickCount < end {
        Status("Waiting for you to pause before switching to the game")
        Sleep 100
    }
    prevWin := WinExist("A")
    CoordMode "Mouse", "Screen"
    MouseGetPos &prevX, &prevY
    if !FocusGame()
        return false
    borrowed := true
    BlockUser(true)
    Sleep FOCUS_SETTLE_MS   ; let the game notice it has focus before sending keys
    return true
}

; Switches back to the window you were using, if BorrowFocus took focus.
ReturnFocus() {
    global borrowed
    if !borrowed
        return
    borrowed := false
    try WinActivate "ahk_id " prevWin
    CoordMode "Mouse", "Screen"
    MouseMove prevX, prevY, 0
    BlockUser(false)
}

; Blocks/unblocks your physical mouse and keyboard (the script's own keypresses still work).
BlockUser(on) {
    if !BLOCK_INPUT || !A_IsAdmin
        return
    if on {
        BlockInput true
        SetTimer UnblockUser, -MAX_BLOCK_SEC * 1000   ; safety release
    } else
        UnblockUser()
}

UnblockUser() {
    SetTimer UnblockUser, 0
    BlockInput false
}

FocusGame() {
    if !WinExist(GAME)
        return false
    if !WinActive(GAME) {
        WinActivate GAME
        WinWaitActive GAME, , 3
    }
    return WinActive(GAME)
}

Stop(msg) {
    global running
    running := false
    UnblockUser()
    Status(msg)
    TrayTip msg, "InfestationHop"
}

Status(msg) {
    ToolTip msg, 10, 10
    SetTimer ClearTip, -8000
}

ClearTip() => ToolTip()
