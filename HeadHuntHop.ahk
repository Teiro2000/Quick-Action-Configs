#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook true              ; catch F7/F11 even while the game has focus
; HeadHuntHop - server hops until a Head Hunt is running.
;
; Loop (start it while you're loaded into a server with the HUD showing):
;   1. Ctrl+Tab  - open the mod menu
;   2. F3        - join Head Hunt
;   3. Loading screen appears?  -> Head Hunt found: beep and stop
;      No loading screen?       -> PgUp to server hop, wait for the HUD (HP/AP bars)
;                                  on the new server, then back to step 1
;
;   F7  = start / stop
;   F11 = exit script
;   (different keys from EventHop, so both scripts can run at once)
;
; Screen checks use colours from a 1920x1080 screenshot and scale to the window size.

; ---- settings -------------------------------------------------------------
EVENT_KEY         := "{F3}"
HOP_KEY           := "{PgUp}"
MENU_OPEN_SEC     := 1.5   ; (fallback if the menu can't be detected) pause after Ctrl+Tab before pressing F3
LOAD_CHECK_SEC    := 2     ; how long to watch for a loading screen after F3
HOP_LEAVE_SEC     := 10    ; after PgUp, wait this long for the old server to disconnect before looking for the new one
HUD_BACK_TIMEOUT  := 300   ; max wait for the HUD on the new server
HUD_SETTLE_SEC    := 3     ; extra pause once the HUD is back
MAX_HOPS          := 50    ; safety stop
IDLE_MS           := 500   ; background use: wait until you stop typing/moving the mouse this long before switching to the game
IDLE_MAX_WAIT_SEC := 3     ; ...but take focus anyway after this long
FOCUS_SETTLE_MS   := 800   ; after switching to the game, wait this long before pressing keys (raise if keys get ignored)
PEEK_EVERY_SEC    := 10    ; while a new server loads in the background, switch to the game this often to check for the HUD
PEEK_SEC          := 2     ; how long each check looks for the HUD before switching back
BLOCK_INPUT       := false ; true = block your mouse/keyboard while the script is switched into the game (needs admin)
MAX_BLOCK_SEC     := 20    ; safety: never block input longer than this (Ctrl+Alt+Del also unblocks)
GAME              := "ahk_exe Fallout76.exe"
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
menuCheck := ""           ; "" = not tested yet, true = can see the mod menu, false = can't (fixed timing)
borrowed := false, prevWin := 0, prevX := 0, prevY := 0
TrayTip "Loaded. Press F7 in game to start/stop, F11 to exit.", "HeadHuntHop"

F7:: {
    global running
    running := !running
    if running {
        SoundBeep 800, 150     ; one beep = started
        SetTimer HopLoop, -300
    } else {
        SoundBeep 500, 150     ; low beep = stopped
        SoundBeep 400, 150
        Status("HeadHuntHop stopped")
    }
}

F11::ExitApp

HopLoop() {
    global running
    hops := 0
    loop {
        if !running
            return
        if !BorrowFocus()
            return Stop("Fallout 76 window not found")

        Status("Server " hops + 1 ": opening mod menu")
        if !OpenMenu()
            return

        Status("Server " hops + 1 ": trying to join Head Hunt (F3)")
        Send EVENT_KEY
        found := WaitFor(IsLoadingScreen, LOAD_CHECK_SEC, "Server " hops + 1 ": watching for loading screen")
        if found {
            ReturnFocus()
            SoundBeep 1000, 300
            SoundBeep 1500, 300
            return Stop("Head Hunt found on server " hops + 1 "! Fast travelling.")
        }
        if !running || hops >= MAX_HOPS {
            ReturnFocus()
            return running ? Stop("Gave up after " MAX_HOPS " hops") : ""
        }
        hops++
        BorrowFocus()   ; normally still in the game (and blocked) from the event check
        if menuCheck = true && !IsMenuOpen() {   ; menu got closed (e.g. a stray scroll) - reopen so PgUp works
            Status("Hop " hops ": mod menu closed - reopening")
            PressCtrlTab()
            WaitFor(IsMenuOpen, 2.5, "Hop " hops ": reopening mod menu")
        }
        Status("Hop " hops ": server hopping (PgUp)")
        Send HOP_KEY
        Sleep 200
        ReturnFocus()   ; you get your mouse/keyboard back while the hop happens
        if !Pause(HOP_LEAVE_SEC)
            return
        if !WaitForHud(HUD_BACK_TIMEOUT, "Hop " hops ": loading new server")
            return running ? Stop("New server never loaded (no HUD after " HUD_BACK_TIMEOUT "s)") : ""
        if !Pause(HUD_SETTLE_SEC)
            return
    }
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

; Polls check() until it's true (returns true) or the timeout / F7 stop (returns false).
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
    TrayTip msg, "HeadHuntHop"
}

Status(msg) {
    ToolTip msg, 10, 10
    SetTimer ClearTip, -8000
}

ClearTip() => ToolTip()
