; Stella Odyssey
; Atari 2600 port of Game Cards 1-6 for the Magnavox Odyssey
; Basic summary of game cards:
;   1:   Pong-like clone with a center bar
;   2:   P0 and P1 move around
;   3:   Pong-like clone without a center bar
;   4:   P0 and P1 play tag. P0 is "it".
;   5:   P0 shoots to kill P1
;   6:   P1 moves around only
;------------------------------------------------------------------------------

    PROCESSOR 6502
    INCLUDE "vcs.h"
    INCLUDE "macro.h"

PIC_H       = 96        ; Picture height - 96 * 2 == 192 scanlines
BL_H        = 4         ; Ball height
INERTIA     = 6         ; How many frames it takes to change BL Y direction
BK_COLU     = $00       ; Background color
OB_COLU     = $0E       ; Object color
P0_X_START  = 10        ; Starting X-position of P0
P1_X_START  = 150       ; Starting Y-position of P1
OB_Y_START  = 50        ; Starting Y-position of P0, P1, BL
Y_OUT       = $F0       ; Hide objects (P0, P1, BL) when not in play
GS_TIMEOUT  = 20        ; Frames between GC changes

;------------------------------------------------------------------------------

    SEG.U VARS
    ORG $80

P0_X    ds 1            ; X position of P0
P1_X    ds 1            ; X position of P1
BL_X    ds 1            ; X position of BL

P0_Y    ds 1            ; Y position of P0
P1_Y    ds 1            ; Y position of P1
BL_Y    ds 1            ; Y position of BL

BL_ctrl ds 1            ; Determines who can English control BL
                        ; 0 = P0, 1 = P1
BL_Xdir ds 1            ; Direction BL travels on X axis - 0 right, 1 left
BL_Ydir ds 1            ; Direction BL travels on Y axis
                        ; If 0, BL moves down. If INERTIA, BL moves up

P0_ptr  ds 2            ; Pointer for P0 sprite
P1_ptr  ds 2            ; Pointer for P1 sprite

P0_end  ds 1            ; Y-end sprite positioning for P0
P1_end  ds 1            ; Y-end sprite positioning for P1
BL_end  ds 1            ; Y-end sprite positioning for BL

P0_buff ds 1            ; Buffer for P0 sprite
P1_buff ds 1            ; Buffer for P1 sprite
BL_buff ds 1            ; Buffer for BL sprite

P0_alive ds 1           ; P0 in play status
P1_alive ds 1           ; P1 in play status
BL_alive ds 1           ; BL in play status

GC      ds 1            ; Game card number
GS_wait ds 1            ; How many frames left before can do another GC change

;------------------------------------------------------------------------------

    SEG code
    ORG $F000

Reset
    ; Clears RAM and all TIA registers
    LDX #0
    TXA
Clear
    DEX
    TXS
    PHA
    BNE Clear

    ; Once only initialization
Init
    CLD                     ; Clears decimal mode
    STA     CXCLR           ; Clears collisions
    
    ; Initialize playfield
    ; D0 - Reflect playfield (for center bar in GC 1)
    ; D2 - Set priority of objects (PF/BL > P0 > P1 > BK, simplifies GC 5)
    ; D5 - Set BL to 4 clocks wide
    LDA     #%00100101
    STA     CTRLPF

    LDA     #BK_COLU        ; Set background color to black
    STA     COLUBK
    LDA     #OB_COLU        ; Set P0, P1, BL colors
    STA     COLUP0
    STA     COLUP1
    STA     COLUPF

    LDA     #1              ; Initialize with Game Card 1
    STA     GC

    JSR     ResetSub        ; Reset variables

    LDA     #%00000010      ; Start vertical blank
    STA     VBLANK

;------------------------------------------------------------------------------
; Start of a new frame

StartOfFrame

;==============================================================================
; Vertical Sync (Lines 1-3)
;==============================================================================

VerticalSync
    LDA #%00000010  ; 2, Start vertical sync
    STA VSYNC       ; 3

    STA WSYNC       ; 3, 3 scanlines of VSYNC signal
    STA WSYNC       ; 3
    STA WSYNC       ; 3
DoneVerticalSync

;==============================================================================
; Vertical Blank (Lines 3-40)
;==============================================================================

    LDA #%00000000  ; 2, Stop vertical sync
    STA VSYNC       ; 3

    ;---------------------------------------------------------------------------
    ; Game Select and Reset Switch Check
    ; Game Select:
    ;   If switch is activated, switch to the next game card and reset state
    ;   Can only be activated once every GS_TIMEOUT frames
    ; Reset Switch:
    ;   Resets game state if reset switch is active
    ; Should consume two scanlines in all scenarios
    ;   Worst case - GS switch active, no overflow - 68 + WSYNC + 55 + WSYNC

GSCheck
    LDA GS_wait         ; 3
    BNE GSCountdown     ; 2/3
    LDA #%00000010      ; 2, mask for game select switch
    BIT SWCHB           ; 4
    BNE DoneGSCheck     ; 2/3
    LDX GC              ; 3, check if on GC 6
    CPX #6              ; 3
    BEQ GSOverflow      ; 2/3
    INX                 ; 2, On GC 1-5, increase by 1
    STX GC              ; 3
    JMP GSFinish        ; 3
GSOverflow
    LDX #1              ; 2, loop back to Game Card 1
    STX GC              ; 3
GSFinish
    LDA #GS_TIMEOUT     ; 2, Triggered a reset, reset the timeout
    STA GS_wait         ; 3
    JSR ResetSub        ; 6, + ResetSub cycles
    JMP DoneResetCheck  ; 3, skips ResetCheck since we reset
GSCountdown
    DEC GS_wait         ; 5
DoneGSCheck

ResetCheck
    LDA #%00000001          ; 2, Check for reset switch
    BIT SWCHB               ; 4
    BNE SkipReset           ; 2/3
    JSR ResetSub            ; 6 + 29 + 3 WSYNC + 46 + 6 RTS
    JMP DoneResetCheck      ; 3
SkipReset
    STA WSYNC               ; 3, For making scanlines consumed equal
DoneResetCheck
    STA WSYNC               ; 3, ends line 5

    ;---------------------------------------------------------------------------
    ; P0Joy - Check joystick inputs for P0
    ; In GCs 1-5, P0 can move around
    ; In GC 1, 3, 5:
    ;   Pressing fire + up/down will change BL Y-direction, if in control of BL
    ;   If BL is dead, pressing fire will relaunch BL from P0
    ;   Pressing fire will prevent movement of P0
    ;
    ; Worst case - 65 cycles (English control)

P0Joy
    LDA GC                  ; 3, Check fire if on GC 1, 3, 5
    CMP #6                  ; 2, P0 not alive on GC 6
    BEQ DoneP0Joy           ; 2-3
    CMP #2                  ; 2
    BEQ P0JoyMove           ; 2-3
    CMP #4                  ; 2
    BEQ P0JoyMove           ; 2-3
P0JoyCheckFire
    LDA #%10000000          ; 2, Check if P0 is pressing fire button
    BIT INPT4               ; 4
    BNE P0JoyMove           ; 2-3
P0JoyResetBL
    LDA BL_alive            ; 3, Check if BL is alive
    BNE P0JoyCheckEng       ; 2-3
    LDA #1                  ; 2, BL not alive, so reset
    STA BL_alive            ; 3
    LDA #(INERTIA / 2)      ; 2, Reset BL Y-inertia
    STA BL_Ydir             ; 3
    LDA P0_X                ; 3, Launch BL from P0
    STA BL_X                ; 3
    LDA P0_Y                ; 3
    STA BL_Y                ; 3
    JMP DoneP0Joy           ; 3
P0JoyCheckEng
    LDA BL_ctrl             ; 2, Check if P0 is in control
    BNE DoneP0Joy           ; 2-3
P0JoyEngDown
    LDA #%00100000          ; 2, P0 pressing down
    BIT SWCHA               ; 4
    BNE P0JoyEngUp          ; 2/3
    LDA BL_Ydir             ; 3
    BEQ DoneP0Joy           ; 2/3
    DEC BL_Ydir             ; 5
    JMP DoneP0Joy           ; 3
P0JoyEngUp
    LDA #%00010000          ; 2, P0 pressing up
    BIT SWCHA               ; 4
    BNE DoneP0Joy           ; 2/3
    LDA BL_Ydir             ; 3
    CMP #INERTIA            ; 2
    BEQ DoneP0Joy           ; 2/3
    INC BL_Ydir             ; 5
    JMP DoneP0Joy           ; 3

P0JoyMove
P0JoyCheckRight             
    LDA #%10000000          ; 2, P0 pressing right
    BIT SWCHA               ; 4
    BNE P0JoyCheckLeft      ; 2-3
    INC P0_X                ; 5
    JMP P0JoyCheckDown      ; 3
P0JoyCheckLeft
    LDA #%01000000          ; 2, P0 pressing left
    BIT SWCHA               ; 4
    BNE P0JoyCheckDown      ; 2-3
    DEC P0_X                ; 5
P0JoyCheckDown
    LDA #%00100000          ; 2, P0 pressing down
    BIT SWCHA               ; 4
    BNE P0JoyCheckUp        ; 2-3
    DEC P0_Y                ; 5
    JMP DoneP0Joy           ; 3
P0JoyCheckUp
    LDA #%00010000          ; 2, P0 pressing up
    BIT SWCHA               ; 4
    BNE DoneP0Joy           ; 2-3
    INC P0_Y                ; 5
DoneP0Joy

    STA WSYNC               ; 3, ends line 6
 
    ;---------------------------------------------------------------------------
    ; P1Joy - Check joystick inputs for P1
    ; In all GCs, P1 can move around, if alive
    ; In GC 1 and 3:
    ;   Pressing fire + up/down will change BL Y-direction, if in control of BL
    ;   If BL is dead, pressing fire will relaunch BL from P0
    ;   Pressing fire will prevent movement of P1
    ; In GC 4 and 5:
    ;   If P1 is dead, pressing fire will resurrect P1
    ;   Pressing fire will prevent movement of P1
    ; 
    ; Worst case - 70 cycles (English control)

P1Joy
    LDX GC                  ; 3, Fire button does nothing on GCs 2, 6
    CPX #2                  ; 2
    BEQ P1JoyMove           ; 2/3
    CPX #6                  ; 2
    BEQ P1JoyMove           ; 2/3
P1JoyCheckFire
    LDA #%10000000          ; 2, Check if fire button is pressed
    BIT INPT5               ; 4
    BNE P1JoyMove           ; 2/3
P1JoyResurrect
    CPX #1                  ; 2, Cannot resurrect on GCs 4, 5
    BEQ P1JoyResetBL        ; 2/3
    CPX #3                  ; 2
    BEQ P1JoyResetBL        ; 2/3
    LDX OB_COLU             ; 2, Resurrect P1
    STX COLUP1              ; 3
    STX P1_alive            ; 3
    JMP DoneP1Joy           ; 3
P1JoyResetBL
    LDA BL_alive            ; 3, Check if BL is alive
    BNE P1JoyCheckEng       ; 2/3
    LDA #1                  ; 2, BL is dead, so reset
    STA BL_alive            ; 3
    LDA #(INERTIA / 2)      ; 2, Reset BL Y-inertia
    STA BL_Ydir             ; 3
    LDA P1_X                ; 3, Launch BL from P1
    STA BL_X                ; 3
    LDA P1_Y                ; 3
    STA BL_Y                ; 3
    JMP DoneP1Joy           ; 3
P1JoyCheckEng
    LDA BL_ctrl             ; 3, Check if P1 controls BL
    BEQ DoneP1Joy           ; 2/3
P1JoyEngDown
    LDA #%00000010          ; 2, P1 pressing down
    BIT SWCHA               ; 4
    BNE P1JoyEngUp          ; 2/3
    LDA BL_Ydir             ; 3
    BEQ DoneP1Joy           ; 2/3
    DEC BL_Ydir             ; 5
    JMP DoneP1Joy           ; 3
P1JoyEngUp
    LDA #%00000001          ; 2, P1 pressing up
    BIT SWCHA               ; 4
    BNE DoneP1Joy           ; 2/3
    LDA BL_Ydir             ; 3
    CMP #INERTIA            ; 2
    BEQ DoneP1Joy           ; 2/3
    INC BL_Ydir             ; 5
    JMP DoneP1Joy           ; 3

P1JoyMove
    LDA P1_alive            ; 3
    BEQ DoneP1Joy           ; 2-3
P1JoyRight                  
    LDA #%00001000          ; 2, P1 pressing right
    BIT SWCHA               ; 4
    BNE P1JoyLeft           ; 2-3
    INC P1_X                ; 5
    JMP P1JoyDown           ; 3
P1JoyLeft
    LDA #%00000100          ; 2, P1 pressing left
    BIT SWCHA               ; 4
    BNE P1JoyDown           ; 2-3
    DEC P1_X                ; 5
P1JoyDown
    LDA #%00000010          ; 2, P1 pressing down
    BIT SWCHA               ; 4
    BNE P1JoyUp             ; 2-3
    DEC P1_Y                ; 5
    JMP DoneP1Joy           ; 3
P1JoyUp
    LDA #%00000001          ; 2, P1 pressing up
    BIT SWCHA               ; 4
    BNE DoneP1Joy           ; 2-3
    INC P1_Y                ; 5
DoneP1Joy
    
    STA WSYNC               ; 3, ends line 7

    ;---------------------------------------------------------------------------
    ; Player positioning check
    ; Makes sure that P0 and P1 are within screen bounds - 17 cycles per axis

P0XPosCheck
    LDY P0_X                ; 3, Leftmost position is 158
    CPY #159                ; 2
    BNE P0XPosLeftCheck     ; 2-3
    DEC P0_X                ; 5
    JMP DoneP0XPosCheck     ; 3
P0XPosLeftCheck
    CPY #3                  ; 2, Leftmost position is 4
    BNE DoneP0XPosCheck     ; 2-3
    INC P0_X                ; 5
DoneP0XPosCheck

P0YPosCheck
    LDY P0_Y                ; 3, Upmost pos is Y = 97
    CPY #98                 ; 2
    BNE P0YPosBotCheck      ; 2-3
    LDY #97                 ; 2
    STY P0_Y                ; 3
    JMP DoneP0YPosCheck     ; 3
P0YPosBotCheck
    CPY #6                  ; 2, Downmost pos is Y = 7
    BNE DoneP0YPosCheck     ; 2-3
    LDY #7                  ; 2
    STY P0_Y                ; 3
DoneP0YPosCheck

P1XPosCheck
    LDY P1_X                ; 3, Leftmost position is 158
    CPY #159                ; 2
    BNE P1XPosLeftCheck     ; 2-3
    DEC P1_X                ; 5
    JMP DoneP1XPosCheck     ; 3
P1XPosLeftCheck
    CPY #3                  ; 2, Leftmost position is 4
    BNE DoneP1XPosCheck     ; 2-3
    INC P1_X                ; 5
DoneP1XPosCheck

P1YPosCheck
    LDY P1_Y                ; 3, Upmost pos is Y = 97
    CPY #98                 ; 2
    BNE P1YPosBotCheck      ; 2-3
    LDY #97                 ; 2
    STY P1_Y                ; 3
    JMP DoneP1YPosCheck     ; 3
P1YPosBotCheck
    CPY #6                  ; 2, Downmost pos is X = 7
    BNE DoneP1YPosCheck     ; 2-3
    LDY #7                  ; 2
    STY P1_Y                ; 3
DoneP1YPosCheck

    STA WSYNC               ; 3, Ends line 8
 
    ;---------------------------------------------------------------------------
    ; CheckCXBL - Checks for collisions between P0/P1 and BL
    ; If on GC 1 and 3, BL will bounce off P0/P1
    ; If on GC 5, P1 and BL will die
    ; Worst case - 40 cycles

CheckCXBL
    LDA #%01000000          ; 2
    LDX #0                  ; 2
    LDY #1                  ; 2
CheckCXP0BL
    BIT CXP0FB              ; 4
    BEQ CheckCXP1BL         ; 2-3
    STX BL_ctrl             ; 3
    STX BL_Xdir             ; 3
    JMP DoneCheckCXBL       ; 3
CheckCXP1BL
    BIT CXP1FB              ; 4
    BEQ DoneCheckCXBL       ; 2-3
    LDA #5                  ; 2, Check GC
    CMP GC                  ; 3
    BNE CXP1BLBounce        ; 2/3
    LDA P1_alive            ; 3, on GC 5, kill P1, BL
    BEQ DoneCheckCXBL       ; 2/3
    STX P1_alive            ; 3
    STX BL_alive            ; 3
    JMP DoneCheckCXBL       ; 3
CXP1BLBounce
    STY BL_ctrl             ; 3
    STY BL_Xdir             ; 3
DoneCheckCXBL

    ;---------------------------------------------------------------------------
    ; Check for collisions between P0 and P1
    ; If on GC 4, if P0 touches P1, P1 will die
    ; Max - 20 cycles

CheckCXP0P1
    LDA #4                  ; 2
    CMP GC                  ; 3
    BNE DoneCheckCXP0P1     ; 2-3
    LDA #%10000000          ; 2, masks D7 on CXPPMM (P0, P1)
    BIT CXPPMM              ; 4
    BEQ DoneCheckCXP0P1     ; 2-3
    LDA #0                  ; 2
    STA P1_alive            ; 3
DoneCheckCXP0P1
    STA CXCLR               ; 3, Clear collisions

    STA WSYNC               ; 3, Ends line 9
    
    ;---------------------------------------------------------------------------
    ; Adjust BL coordinates, if ball is still in play
    ; If ball is not in play, make ball disappear
    ; Max 35 cycles
BLChangeXPos
    LDA BL_alive            ; 3, Check if ball is still in play
    BEQ DoneBLChangePos     ; 2/3
    LDA BL_Xdir             ; 3
    BNE BLGoLeft            ; 2-3
    INC BL_X                ; 5
    JMP BLChangeYPos        ; 3
BLGoLeft
    DEC BL_X                ; 5
BLChangeYPos
    LDA BL_Ydir             ; 3
    CMP #INERTIA            ; 2
    BNE BLGoDown            ; 2/3
    INC BL_Y                ; 5
    JMP DoneBLChangePos     ; 3
BLGoDown
    CMP #0                  ; 2
    BNE DoneBLChangePos     ; 2/3
    DEC BL_Y                ; 5
DoneBLChangePos

    ;---------------------------------------------------------------------------
    ; BLWithinBounds - Checks if BL is within game boundaries
    ;
    ; Out of bounds if:
    ;   Hit top, bottom, or right
    ;   Hit right on GCs 1 or 3
    ; If BL is out of bounds, kill BL
    ; If BL hits the right on GC 5, have BL bounce to the left
    ; 
    ; Maximum - 34 cycles (if hitting bottom)

BLWithinBounds
    LDX #0                  ; 2
BLLeftCheck
    LDA BL_X                ; 3
    CMP #4                  ; 2, Leftmost BL position is X = 5
    BNE BLRightCheck        ; 2-3
    STX BL_alive            ; 3, BL hit the left, kill
    JMP DoneBLWithinBounds  ; 3
BLRightCheck
    CMP #162                ; 2, Rightmost BL position is X = 161
    BNE BLTopCheck          ; 2-3
    LDA GC                  ; 3, Checking if on GC 5
    CMP #5                  ; 2
    BNE BLRightDie          ; 2-3
    LDA #1                  ; 2, Not GC 5 so bounce BL to the left
    STA BL_Xdir             ; 3
    DEC BL_X                ; 5, keeps BL within bounds
    JMP DoneBLWithinBounds  ; 3
BLRightDie
    STX BL_alive            ; 3, BL hit the right, kill
    JMP DoneBLWithinBounds  ; 3
BLTopCheck
    LDA BL_Y                ; 3
    CMP #101                ; 2, Allow BL to go completely into VBlank
    BNE BLBotCheck          ; 2-3
    STX BL_alive            ; 3, BL hit the top, kill
    JMP DoneBLWithinBounds  ; 3
BLBotCheck
    CMP #0                  ; 2, Allow BL to go completely into Overscan
    BNE DoneBLWithinBounds  ; 2-3
    STX BL_alive            ; 3, BL hit the bottom, kill
DoneBLWithinBounds

    STA WSYNC               ; 3, Ends line 10

    ;---------------------------------------------------------------------------
    ; DeleteDead - Check alive status of P1, BL
    ; If P0/BL dead, then move out of bounds
    ; If P1 is dead, then just change P1 to COLUBK
    ; Max - 18 cycles

DeleteDead
    LDY #Y_OUT              ; 2
    LDX BK_COLU             ; 3
DeleteDeadP0
    LDA P0_alive            ; 3
    BNE DeleteDeadP1        ; 2/3
    STY P0_Y                ; 3
DeleteDeadP1
    LDA P1_alive            ; 3
    BNE DeleteDeadBL        ; 2/3
    STX COLUP1              ; 3
DeleteDeadBL
    LDA BL_alive            ; 3
    BNE DoneDeleteDead      ; 2/3
    STY BL_Y                ; 3
DoneDeleteDead

    ;---------------------------------------------------------------------------
    ; Position objects horizontally

SetHorizontal
    ; Position P0 horizontally
    LDA     P0_X                    ; 3
    LDX     #0                      ; 2, 0 == P0
    JSR     SetXPos                 ; 6, 5 + line + 6

    ; Position P1 horizontally
    LDA     P1_X                    ; 3
    LDX     #1                      ; 2, 1 == P1
    JSR     SetXPos                 ; 6, 5 + line + 6

    ; Position BL horizontally
    LDA     BL_X                    ; 3
    LDX     #4                      ; 2, 4 == BL
    JSR     SetXPos                 ; 6, 5 + line + 6
DoneSetHorizontal
    STA     WSYNC                   ; 3, ends line 17
    STA     HMOVE                   ; 3


    ;---------------------------------------------------------------------------
    ; Filler VBLANK section - lines 18-39
    LDX     #21                     ; 2
VerticalBlank
    DEX                             ; 2
    STA     WSYNC                   ; 3
    BNE     VerticalBlank           ; 2-3

    ;---------------------------------------------------------------------------
    ; Update variables used for Y-positioning objects in DoDraw
    ; Idea from Darrell Spice, Jr.
    ; Setting ends:     10 cycles
    ; Setting pointers: 17 cycles
    ; Total:            64 cycles
SetP0End
    LDA #(PIC_H + PL_H)         ; 2
    SEC                         ; 2
    SBC P0_Y                    ; 3
    STA P0_end                  ; 3
SetP1End
    LDA #(PIC_H + PL_H)         ; 2
    SEC                         ; 2
    SBC P1_Y                    ; 3
    STA P1_end                  ; 3
SetBLEnd
    LDA #(PIC_H + BL_H)         ; 2
    SEC                         ; 2
    SBC BL_Y                    ; 3
    STA BL_end                  ; 3

SetP0Ptr
    LDA #<(PLSprite + PL_H - 1) ; 2
    SEC                         ; 2
    SBC P0_Y                    ; 3
    STA P0_ptr                  ; 3
    LDA #>(PLSprite + PL_H - 1) ; 2
    SBC #0                      ; 2
    STA P0_ptr + 1              ; 3

SetP1Ptr
    LDA #<(PLSprite + PL_H - 1) ; 2
    SEC                         ; 2
    SBC P1_Y                    ; 3
    STA P1_ptr                  ; 3
    LDA #>(PLSprite + PL_H - 1) ; 2
    SBC #0                      ; 2
    STA P1_ptr + 1              ; 3
DoneSetEndPtr

    STA WSYNC                   ; 3, ends line 39

    ;---------------------------------------------------------------------------
    ; PreDraw - Presets buffer for objects, if applicable
    ; Makes sure that P0, P1, and BL have the top scanline in the right color
    ; Kind of a messy way, but my brain is running on fumes right now
    ;
    ; Maximum 37 cycles

PreDraw
    LDY #%11111100      ; 2
PreDrawP0
    LDA #97             ; 2
    CMP P0_Y            ; 3
    BNE PreDrawP1       ; 2/3
    STY P0_buff         ; 3
PreDrawP1
    CMP P1_Y            ; 3
    BNE PreDrawBL       ; 2/3
    STY P1_buff         ; 3
PreDrawBL
    LDX BL_alive        ; 3
    BEQ DonePreDraw     ; 2/3
    LDA #96             ; 2
    CMP BL_Y            ; 3
    BCS DonePreDraw     ; 2/3
    LDY #%00000010      ; 2
    STY ENABL           ; 3
DonePreDraw

    ;---------------------------------------------------------------------------
    ; End of vertical blank
    LDY     #PIC_H          ; 2, set up counter for picture
    LDA     #%00000000      ; 2, Stop vertical blank
    STA     WSYNC           ; 3, ends line 40

;==============================================================================
; Picture (lines 41-232)
; Uses a double line kernel
; Line 1 - Draws P0, P1, then calculate P0, P1
; Line 2 - Draws BL, then calculates BL
;==============================================================================
    STA VBLANK              ; 3, stop vertical blank

Picture
    ;---------------------------------------------------------------------------
    ; Line 1 - Drawing P0, P1, calculate P0, P1, BL
    ; Draw P0, P1 (12 cycles)
    LDA     P0_buff         ; 3
    STA     GRP0            ; 3
    LDA     P1_buff         ; 3
    STA     GRP1            ; 3

    ; DoDraw P0 buffer (18 cycles)
    LDA     #PL_H - 1       ; 2
    DCP     P0_end          ; 5
    BCS     DrawP0          ; 2/3
    LDA     #0              ; 2
    DC.B    $2C             ; -1
DrawP0
    LDA     (P0_ptr),Y      ; 5
    STA     P0_buff         ; 3

    ; DoDraw P1 buffer (18 cycles)
    LDA     #PL_H - 1       ; 2
    DCP     P1_end          ; 5
    BCS     DrawP1          ; 2/3
    LDA     #0              ; 2
    DC.B    $2C             ; -1
DrawP1
    LDA     (P1_ptr),Y      ; 5
    STA     P1_buff         ; 3

    ; DoDraw BL buffer (18 cycles)
    LDA     #BL_H - 1       ; 2
    DCP     BL_end          ; 5
    BCS     DrawBL          ; 2/3
    LDA     #%00000000      ; 2
    DC.B    $2C             ; -1
DrawBL
    LDA     #%00000010      ; 5
    STA     BL_buff         ; 3

    STA WSYNC               ; 3

    ;---------------------------------------------------------------------------
    ; Line 2 - Drawing BL
    LDA BL_buff             ; 3
    STA ENABL               ; 3

    DEY                     ; 2
    STA WSYNC               ; 3
    BNE Picture             ; 2/3

;==============================================================================
; Overscan (lines 233-262)
;==============================================================================

    LDA #%00000010          ; 2, start vertical blank
    STA VBLANK              ; 3

    LDA #00000000           ; 2, Prevents P0, P1 from looping around
    STA P0_buff             ; 3
    STA GRP0                ; 3
    STA P1_buff             ; 3
    STA GRP1                ; 3
    STA BL_buff             ; 3
    STA ENABL               ; 3

    LDX #30                 ; 2, 30 lines of overscan
Overscan
    STA WSYNC               ; 3
    DEX                     ; 2
    BNE Overscan            ; 2-3

EndOfFrame
    JMP StartOfFrame        ; Start new frame

;==============================================================================
; Other stuff
;==============================================================================
    
    ;---------------------------------------------------------------------------
    ; ResetSub - Resets game
    ; Consumes 29 cycles + WSYNC + 46 cycles + 6 cycles RTS

    ; Resets object positions - 29 cycles
ResetSub
    LDA #P0_X_START         ; 2, X-coordinates
    STA P0_X                ; 3
    STA BL_X                ; 3
    LDA #P1_X_START         ; 2
    STA P1_X                ; 3
    LDA #OB_Y_START         ; 2, Y-coordinates
    STA P0_Y                ; 3
    STA P1_Y                ; 3
    STA BL_Y                ; 3
    LDA #(INERTIA / 2)      ; 2, Reset BL Y-inertia
    STA BL_Ydir             ; 3

    STA WSYNC

    ; Sets alive status of objects based on GC - max 46 cycles
ResetGCCheck
    LDA GC                  ; 3
    LDX #0                  ; 2
    LDY #OB_COLU            ; 2
ResetGC6
    CMP #6                  ; 2
    BNE ResetGC2            ; 2/3
    STX P0_alive            ; 3
    STX BL_alive            ; 3
    JMP EndResetGCCheck     ; 3
ResetGC2
    STY P0_alive            ; 3, GCs 1-5 will have P0 alive
    CMP #2                  ; 2
    BNE ResetGC4            ; 2/3
    STX BL_alive            ; 3
    JMP EndResetGCCheck     ; 3
ResetGC4
    CMP #4                  ; 2
    BNE ResetGC1            ; 2/3
    STX BL_alive            ; 3
    JMP EndResetGCCheck     ; 3
ResetGC1
    STY BL_alive            ; 3, GCs 1, 3, 5 will have BL alive
    CMP #1                  ; 2
    BNE ResetGC3            ; 2/3
    LDX #%10000000          ; 2, GC 1 is the only one that has PF
    JMP EndResetGCCheck     ; 3
ResetGC3                    ; GC 3 and GC 5 don't need more stuff
ResetGC5
EndResetGCCheck
    STX PF2                 ; 3, Reset playfiled
    STY P1_alive            ; 3, P1 is always alive in GCs 1-6
    STY COLUP1              ; 3
DoneResetGCCheck
    RTS                     ; 6

    ; Positions an object horizontally - from batari
    ; Inputs:
    ;   A = X-coord of object
    ;   X = object to be moved
    ; Timing:
    ;   Consumes 5 cycles + 1 line + 6 cycles
SetXPos
    CLC                 ; 2
    STA WSYNC           ; 3, ends line 1
DivideLoop
    SBC #15
    BCS DivideLoop      ; Max 54 cycles
    EOR #7              ; 2
    ASL                 ; 2
    ASL                 ; 2
    ASL                 ; 2
    ASL                 ; 2
    STA HMP0,X          ; 4
    STA RESP0,X         ; 4
    STA WSYNC           ; 3, ends line 2
    RTS                 ; 6

    ; Sprite for the P0, P1
    ; Literally just a square
PLSprite
    DC.B #%11111100
    DC.B #%11111100
    DC.B #%11111100
    DC.B #%11111100
    DC.B #%11111100
    DC.B #%11111100
PL_H = * - PLSprite


;-------------------------------------------------------------------------------

    ORG $FFFA

InterruptVectors

    .word Reset     ; NMI
    .word Reset     ; Reset
    .word Reset     ; IRQ

    END
