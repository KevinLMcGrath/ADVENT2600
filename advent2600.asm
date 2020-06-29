;======================================-=======================================
;								  ADVENT 2600
;
; An attempt to create a pure text adventure game for the Atari 2600 in 4KB.
;
; Assemble with DASM ():
;	dasm advent2600.asm -f3 -v0 -ladvent2600.lst -sadvent2600.sym -oadvent2600.bin
;
; CREDITS:
;	Programming: Kevin McGrath, except where noted
;	Art:
;	Music/SFX:
;
; RELEASE NOTES:
;	2020-06-13:	Started project.
;	2020-06-26: Initial really early WIP release.

; I don't wish to be legally liable if you use this code to make a cart, plug
; that cart into your VCS, and the magic smoke escapes from that machine, so...
;======================================-=======================================
;									LICENSE
;
; Copyright 2020 by Kevin McGrath
;
; Permission to use, copy, modify, and/or distribute this software for any
; purpose with or without fee is hereby granted.
;
; THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
; REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
; INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
; LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
; OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
; PERFORMANCE OF THIS SOFTWARE.
;
; Free Public License 1.0.0 (0BSD): https://opensource.org/licenses/0BSD

			PROCESSOR 6502
			INCLUDE "vcs.h"

NO_ILLEGAL_OPCODES = 1		; We're not under an uber CPU time crunch just yet
USE_NTSC = 1				; Set to 1 for NTSC, 0 for PAL

			IF	[USE_NTSC == 1]
TICKS_PER_DECISECOND = 6	; 60Hz
			ELSE
TICKS_PER_DECISECOND = 5	; 50Hz
			ENDIF

;======================================-=======================================
;									MACROS

			INCLUDE "macro.h"

; BUMP16 cnt
;	Increment by one the 16-bit counter "cnt"
			MAC BUMP16
			inc {1}
			bne .done
			inc {1}+1
.done:
			ENDM

; STRING_WITH_LENGTH "Hello World"
;	Store a string, with the first byte containing the string length in bytes
			MAC STRING_WITH_LENGTH
.length		EQU		[.lastChr - .firstChr]
			IF [.length == 0]
			ECHO	"String at", ., "is zero bytes long!"
			ENDIF
			IF [.length > 255]
			ECHO	"String at", ., "is longer than 255 bytes!"
			ENDIF
			DC.B	<[.length]
.firstChr:	DC.B	{1}
.lastChr	EQU		.
			ENDM

;======================================-=======================================
;								   VARIABLES
			SEG.U VARS
			ORG $80

; Shadows for the Playfield registers; double buffered so we we can render into
; one while displaying the other.  The "Left" and "Right" mean the left and
; right part of the screen since we need to reuse the 3 PF registers during the
; same scanline:

PFBufferA:		DS.B	6
LeftPF0A:		EQU	[PFBufferA + 0]
LeftPF1A:		EQU	[PFBufferA + 1]
LeftPF2A:		EQU	[PFBufferA + 2]
RightPF0A:		EQU	[PFBufferA + 3]
RightPF1A:		EQU	[PFBufferA + 4]
RightPF2A:		EQU	[PFBufferA + 5]

PFBufferB:		DS.B	6
LeftPF0B:		EQU	[PFBufferB + 0]
LeftPF1B:		EQU	[PFBufferB + 1]
LeftPF2B:		EQU	[PFBufferB + 2]
RightPF0B:		EQU	[PFBufferB + 3]
RightPF1B:		EQU	[PFBufferB + 4]
RightPF2B:		EQU	[PFBufferB + 5]

TextBuffer:		DS.B	80	; The 10 column x 8 row character "frame" buffer
; A 40x48 pixel framebuffer would consume 240 bytes, which is slightly larger than our 128 bytes of RAM available

ColorScheme:	DS.B	1	; Offset into which color scheme should be used
Player0Txt:		DS.B	1	; Which font offset should the Player0 sprite use?

; Set these Y positions to anything > 80 to disable
Player0Y:		DS.B	1	; Which vertical text line ((0 - 7) * 10) should the Player0 sprite draw on?
Missile0Y:		DS.B	1	; Which vertical text line ((0 - 7) * 10) should the Missle0 draw on?
Missile1Y:		DS.B	1	; Which vertical text line ((0 - 7) * 10) should the Missle1 draw on?

TextCursor:		DS.B	1	; Offset into the TextBuffer, to help with dynamically generated text screens

FrameCount:		DS.B	1	; How many frames have been rendered? Used for DeciSeconds below, reset often
DeciSeconds:	DS.B	1	; Deci-Second counter (1/10th of a second), for easier animation timing. Rolls after about 25 seconds, reset by game logic often

PrevJoysticks:	DS.B	1	; Previous value of the joysticks (player 0 upper nybble, 1 lower) (right, left, down, up)
CurrJoysticks:	DS.B	1	; Current value of the joysticks (player 0 upper nybble, 1 lower) (right, left, down, up)

StateCodePtr:	DS.W	1	; Address of the current demo state code
StateTempVar1:	DS.B	1
ScrollTextOffs:	EQU		StateTempVar1
DemoOneTxtOffs: EQU		StateTempVar1
StateTempVar2:	DS.B	1
DemoOneFntOffs: EQU		StateTempVar2
StateTempPtr1:	DS.W	1	; A pointer for the tele-typewriter style text output
DescTextPtr:	EQU		StateTempPtr1
ScrollTextPtr:	EQU		StateTempPtr1	; Text that scrolls at the bottom of the screen

LibTempVar:		DS.B	1	; An often trashed temporary variable in RAM (used by DivideBy15, etc.)
LibTempPtr:		DS.W	1	; A pointer argument for a library subroutine

		; Reserve *some* space for the stack...
STACK_SPACE		EQU		8
FREE_RAM		EQU		[$100 - . - STACK_SPACE]d
				ECHO FREE_RAM, "bytes of RAM available"

;======================================-=======================================
;								   CONSTANTS

			INCLUDE "colors.asm"

JOY_BUTTON	EQU %10000000
JOY_RIGHT	EQU %01000000
JOY_LEFT	EQU %00100000
JOY_DOWN	EQU %00010000
JOY_UP		EQU %00001000

;======================================-=======================================
;								  DATA + CODE

			SEG CODE
			ORG $F000		; Standard Atari 4K cartridge, no bank-switching needed


; This is a pair of matching 3x5 fonts, one with normal bit/pixel direction and
; the other identical but with a reversed / mirrored bit/pixel direction.  This
; is needed in order to save cycles in the rendering kernel.
;
; Not every ASCII glyph is represented in this font, I've removed glyphs that
; I figured I could do without for a text adventure game until I had 51 glyphs
; chosen.  51 glyphs times 5 scanlines per glyph works out to 255 bytes, just
; one byte shy of a full 6502 page.  They are placed first in the ROM so the
; code will never cross a page boundary while accessing the fonts.  Crossing
; a page boundary on the Atari 2600 causes an extra CPU cycle for the load, and
; thus will cause graphics glitches.

; NOTE: You don't _have_ to use a font with 51 glyphs if you don't need to.
; For example, if you are making a checkers / draughts game you could use a 25
; glyph font, which would fit in less than one 6502 page (256 bytes):
;	Two sides (black and white) times two square types (light and dark)
;	Plus two empty squares (light and dark)
;	= Six different glyphs needed to represent the pieces on the board.
;		The board would consume 8x8 characters, so the last two characters in
;		each row could represent something else like the score, or a move
;		history, or the currently considered best move (or all of the above!).

NormalFont:
			INCLUDE "normal_font.asm"

ReversedFont:
			INCLUDE "reversed_font.asm"

;======================================-=======================================
;								FONT_KERNEL MACRO

; As the screen is being rasterized, each "font pixel" in a character will
; consume four scanlines.  This gives use enough time to generate what the PF
; registers should contain for the next set of "font pixels".

; Each line of text is five "font pixels" tall.  There is a sixth "font pixel"
; at the bottom of each character which is always blank.  This gives enough
; time to do something fancy, like change the playfield color so that each row
; of text can be a different color.

; The whole idea behind this kernel is two fold:
;	1) To rasterize out the three PF registers, twice, per scanline, to get 40 pixels across
;	2) To render all six PF registers needed for the next font pixel scanlines within one font pixel scanlines time (four scanlines)

; As you can imagine, the code gets complicated when you're rasterizing the
; current scanline as well as rendering a new set of PF registers for the next
; set of "font pixels", so I've indented the instructions that render to keep
; them visually separate from the instructions that rasterize the current set
; of "font pixels".


		MAC FONT_KERNEL
.RASTER_FROM	SET {1}		;	Which PF shadow buffer to rasterize from
.FONT_OFFSET	SET {2}		;	Font pixel scanline
.SPRITE_OFFSET	SET {3}		;	Sprite scanline
.TEXT_OFFSET	SET {4}		;	Additional offset into the text framebuffer
; Y = Line offset into TextBuffer
		IF .RASTER_FROM == PFBufferA
.RENDER_TO		SET PFBufferB
		ELSE
.RENDER_TO		SET PFBufferA
		ENDIF
.LeftPF0A:		SET	[.RASTER_FROM + 0]
.LeftPF1A:		SET	[.RASTER_FROM + 1]
.LeftPF2A:		SET	[.RASTER_FROM + 2]
.RightPF0A:		SET	[.RASTER_FROM + 3]
.RightPF1A:		SET	[.RASTER_FROM + 4]
.RightPF2A:		SET	[.RASTER_FROM + 5]
.LeftPF0B:		SET	[.RENDER_TO + 0]
.LeftPF1B:		SET	[.RENDER_TO + 1]
.LeftPF2B:		SET	[.RENDER_TO + 2]
.RightPF0B:		SET	[.RENDER_TO + 3]
.RightPF1B:		SET	[.RENDER_TO + 4]
.RightPF2B:		SET	[.RENDER_TO + 5]
.RevFont:		SET [ReversedFont + .FONT_OFFSET]
.NormFont:		SET [NormalFont + .FONT_OFFSET]
.SpriteFont:	SET [NormalFont + .SPRITE_OFFSET]
.TxtBuffer:		SET [TextBuffer + .TEXT_OFFSET]
		sta WSYNC					; 3
; Font Character Scanline 1:
		lda .LeftPF0A				; 3		(3)
		sta PF0						; 3		(6)
		lda .LeftPF1A				; 3		(9)
		sta PF1						; 3		(12)
		lda .LeftPF2A				; 3		(15)
		sta PF2						; 3		(18)
			ldx .TxtBuffer+0,y		; 4		(22) Character 0 (into left upper PF0, lower ignored)
			lda .RevFont,x			; 4+	(26)
			sta .LeftPF0B			; 3		(29)
		lda .RightPF0A				; 3		(32)
		sta PF0						; 3		(35)	OK to change PF0 after 29 cycles, but before 49 cycles
		lda .RightPF1A				; 3		(38)
			ldx .TxtBuffer+1,y		; 4		(42) Character 1 (into left upper PF1)
		sta PF1						; 3		(45)	OK to change PF1 after 39 cycles, but before 54 cycles
		lda .RightPF2A				; 3		(48)
		nop							; 2		(50)	<- REQUIRED STALL
		sta PF2						; 3		(53)	OK to change PF2 after 50 cycles, but before 65 cycles
			lda .NormFont,x			; 4+	(57)
			and #$F0				; 2		(59)
			sta .LeftPF1B			; 3		(62)
			ldx .TxtBuffer+2,y		; 4		(66) Character 2 (into left lower PF1)
			lda .NormFont,x			; 4+	(70)
			and #$0F				; 2		(72)
			ora .LeftPF1B			; 3		(75)
; Font Character Scanline 2
			sta .LeftPF1B			; 3		(78 2)	<- Left over from previous scanline
		lda .LeftPF0A				; 3		(5)
		sta PF0						; 3		(8)
		lda .LeftPF1A				; 3		(11)
		sta PF1						; 3		(14)
		lda .LeftPF2A				; 3		(17)
		sta PF2						; 3		(20)
			ldx .TxtBuffer+3,y		; 4		(24) Character 3 (into left lower PF2)
			lda .RevFont,x			; 4+	(28)
			and #$0F				; 2		(30)
			sta .LeftPF2B			; 3		(33)
		lda .RightPF0A				; 3		(36)
		sta PF0						; 3		(39)	OK to change PF0 after 29 cycles, but before 49 cycles
		lda .RightPF1A				; 3		(42)
		sta PF1						; 3		(45)	OK to change PF1 after 39 cycles, but before 54 cycles
			ldx .TxtBuffer+4,y		; 4		(49) Character 4 (into left upper PF2)
		lda .RightPF2A				; 3		(52)
		sta PF2						; 3		(55)	OK to change PF2 after 50 cycles, but before 65 cycles
			lda .RevFont,x			; 4+	(59)
			and #$F0				; 2		(61)
			ora .LeftPF2B			; 3		(64)
			sta .LeftPF2B			; 3		(67)
			ldx .TxtBuffer+5,y		; 4		(71) Character 5 (into right upper PF0, lower ignored)
			lda .RevFont,x			; 4+	(75)
; Font Character Scanline 3
			sta .RightPF0B			; 3		(78 2)	<- Left over from previous scanline
		lda .LeftPF0A				; 3		(5)
		sta PF0						; 3		(8)
		lda .LeftPF1A				; 3		(11)
		sta PF1						; 3		(14)
		lda .LeftPF2A				; 3		(17)
		sta PF2						; 3		(20)
			ldx .TxtBuffer+6,y		; 4		(24) Character 6 (into right upper PF1)
			lda .NormFont,x			; 4+	(28)
			and #$F0				; 2		(30)
			sta .RightPF1B			; 3		(33)
		lda .RightPF0A				; 3		(36)
		sta PF0						; 3		(39)	OK to change PF0 after 29 cycles, but before 49 cycles
		lda .RightPF1A				; 3		(42)
		sta PF1						; 3		(45)	OK to change PF1 after 39 cycles, but before 54 cycles
			ldx .TxtBuffer+7,y		; 4		(49) Character 7 (into right lower PF1)
		lda .RightPF2A				; 3		(52)
		sta PF2						; 3		(55)	OK to change PF2 after 50 cycles, but before 65 cycles
			lda .NormFont,x			; 4+	(59)
			and #$0F				; 2		(61)
			ora .RightPF1B			; 3		(64)
			sta .RightPF1B			; 3		(67)
			ldx .TxtBuffer+8,y		; 4		(71) Character 8 (into right lower PF2)
			lda .RevFont,x			; 4+	(75)
; Font Character Scanline 4
			and #$0F				; 2		(77 1)	<- Left over from previous scanline
			sta .RightPF2B			; 3		(4)
		lda .LeftPF0A				; 3		(7)
		sta PF0						; 3		(10)
		lda .LeftPF1A				; 3		(13)
		sta PF1						; 3		(16)
		lda .LeftPF2A				; 3		(19)
		sta PF2						; 3		(22)
			ldx .TxtBuffer+9,y		; 4		(26) Character 9 (into right upper PF2)
			lda .RevFont,x			; 4+	(30)
			and #$F0				; 2		(32)
			ora .RightPF2B			; 3		(35)
			sta .RightPF2B			; 3		(38)
		lda .RightPF0A				; 3		(41)
		sta PF0						; 3		(44)	OK to change PF0 after 29 cycles, but before 49 cycles
		lda .RightPF1A				; 3		(47)
		sta PF1						; 3		(50)	OK to change PF1 after 39 cycles, but before 54 cycles
		lda .RightPF2A				; 3		(53)
		sta PF2						; 3		(56)	OK to change PF2 after 50 cycles, but before 65 cycles
; 20 CPU cycles remaining every "font pixel line" (4 scanlines), hmm, what should we do with it?!

; Here's a way to sort-of have one Player sprite, using one of the font characters,
; with limited Y positioning and a four scanline offset from the top of the characters :(
; Plus the sprite will be 8 large pixels wide, where the fonts are 4 large pixels wide :(
; But worst, it won't be lined up to the rest of the text since this is the last scanline
; of the four font scanlines :(
; The _good_ news is that the X position is able to be from 0 to 159, single pixel accuracy
; The _bad_ news is, just two more CPU cycles added to the following code will mess up everything
		lda #0						; 2		(58)
		cpy Player0Y				; 3		(61)
		bne .skipPlayer0			; 2+	(63)
		ldx Player0Txt				; 3		(66)
		lda .SpriteFont,x			; 4+	(70)
.skipPlayer0
		sta GRP0					; 3		(73)

			ENDM

TopOfScreenKernelEntry:
			ldx #43		; 36 scanlines * 76 cycles per / 64 clocks per timer tick = 42.75 = rounded up to 43
			VERTICAL_SYNC
			stx TIM64T

	; VERTICAL BLANK FREE TIME: Should have ~2,812 CPU ticks for general game code

			ldy #0					; Y = an offset into the text framebuffer, bumping by ten for each line

	; Render into the "A" shadow buffer for the PF registers, in preparation for
	; rasterizing it out during the next scanline:
			ldx TextBuffer+0,y		; Character 0 (into left upper PF0, lower ignored)
			lda ReversedFont,x
			sta LeftPF0A
			ldx TextBuffer+1,y		; Character 1 (into left upper PF1)
			lda NormalFont,x
			and #$F0
			sta LeftPF1A
			ldx TextBuffer+2,y		; Character 2 (into left lower PF1)
			lda NormalFont,x
			and #$0F
			ora LeftPF1A
			sta LeftPF1A
			ldx TextBuffer+3,y		; Character 3 (into left lower PF2)
			lda ReversedFont,x
			and #$0F
			sta LeftPF2A
			ldx TextBuffer+4,y		; Character 4 (into left upper PF2)
			lda ReversedFont,x
			and #$F0
			ora LeftPF2A
			sta LeftPF2A
			ldx TextBuffer+5,y		; Character 5 (into right upper PF0, lower ignored)
			lda ReversedFont,x
			sta RightPF0A
			ldx TextBuffer+6,y		; Character 6 (into right upper PF1)
			lda NormalFont,x
			and #$F0
			sta RightPF1A
			ldx TextBuffer+7,y		; Character 7 (into right lower PF1)
			lda NormalFont,x
			and #$0F
			ora RightPF1A
			sta RightPF1A
			ldx TextBuffer+8,y		; Character 8 (into right lower PF2)
			lda ReversedFont,x
			and #$0F
			sta RightPF2A
			ldx TextBuffer+9,y		; Character 9 (into right upper PF2)
			lda ReversedFont,x
			and #$F0
			ora RightPF2A
			sta RightPF2A

AwaitNextTextRow:
			lda INTIM
			bne AwaitNextTextRow

	; First scanline before the first visible scanline, set colors and enable missiles
			sta WSYNC				; 3
	; Set the background/foreground colors for the first line of text
			ldx ColorScheme
			lda ColorSchemes,x
			sta COLUPF
			lda ColorSchemes+8,x
			sta COLUBK
			stx ColorScheme

	; Enable or disable Missile0 and Missile1 for this next line of text
			ldx #0
			lda Missile0Y
			bne SkipMissileEnableA0
			ldx #%00000010
SkipMissileEnableA0:
			stx ENAM0
			ldx #0
			lda Missile1Y
			bne SkipMissileEnableA1
			ldx #%00000010
SkipMissileEnableA1:
			stx ENAM1

NextTextRow:
	; Each FONT_KERNEL macro consumes 4 scanlines
			FONT_KERNEL PFBufferA, 1, 0, 0		; We rendered line 0 before this
			FONT_KERNEL PFBufferB, 2, 1, 0
			FONT_KERNEL PFBufferA, 3, 2, 0
			FONT_KERNEL PFBufferB, 4, 3, 0
	; The very last set of font pixels can render the first font pixel line for
	; the upcoming text row because we want a blank line between text rows (no
	; rasterizing)
			FONT_KERNEL PFBufferA, 0, 4, 10		; Rendering line 0 for the next text line

	; Here we have four scanlines of time before we need to rasterizer out the next line of text

; Blank Scanline #1
			sta WSYNC				; 3
			lda #0					; 2		(2)	Clear out the PF registers
			sta PF0					; 3		(5)
			sta PF1					; 3		(8)
			sta PF2					; 3		(11)
			sta GRP0				; 3		(14)
			sta ENAM0				; 3		(17)
			sta ENAM1				; 3		(20)

	; During the last FONT_KERNEL, the first pixel row for the upcoming text
	; row was rendered into PFBufferB, but we need it in PFBufferA so move it
	; This is akin to a graphical page flip, on a teeny tiny scale
			lda PFBufferB+0			; 3		(23)
			sta PFBufferA+0			; 3		(26)
			lda PFBufferB+1			; 3		(29)
			sta PFBufferA+1			; 3		(32)
			lda PFBufferB+2			; 3		(35)
			sta PFBufferA+2			; 3		(38)
			lda PFBufferB+3			; 3		(41)
			sta PFBufferA+3			; 3		(44)
			lda PFBufferB+4			; 3		(47)
			sta PFBufferA+4			; 3		(50)
			lda PFBufferB+5			; 3 	(53)
			sta PFBufferA+5			; 3		(56)

			cpy #[10 * 7]			; 2		(58)	Don't change the color scheme at the bottom of the last line of text!
			beq NoMoreColorScheme	; 2+	(60+)
	; Change the foreground and background colors for the next line of text
			ldx ColorScheme			; 3		(63)
			inx						; 2		(65)
			stx ColorScheme			; 3		(69)

; Blank Scanline #2 (change background/foreground colors as early as possible)
			sta WSYNC				; 3
			lda ColorSchemes,x
			sta COLUPF
			lda ColorSchemes+8,x
			sta COLUBK
			jmp BlankScanline3

NoMoreColorScheme:
; Blank Scanline #2 (don't change the background/foreground colors at all)
			sta WSYNC				; 3
			nop

BlankScanline3:
; Blank Scanline #3
			sta WSYNC				; 3
			nop

; Blank Scanline #4
			sta WSYNC				; 3
			tya						; Y is our offset into the text frame buffer
			clc						; we need to bump it by ten for every line of
			adc #10					; text.
			tay

	; Enable or disable Missile0 and Missile1 for this next line of text
			lda #0
			cpy Missile0Y
			bne SkipMissileEnableB0
			lda #%00000010
SkipMissileEnableB0:
			sta ENAM0
			lda #0
			cpy Missile1Y
			bne SkipMissileEnableB1
			lda #%00000010
SkipMissileEnableB1:
			sta ENAM1

	; Should we continue displaying more lines of text?
			cpy #[10 * 8]			; 8 lines of text
			beq DoneWithKernels
			jmp NextTextRow

DoneWithKernels:
			lda #36		; 30 scanlines * 76 cycles per / 64 clocks per timer tick = 35.625 = rounded up to 36
			sta WSYNC				; 3
			sta TIM64T

	; OVER SCAN FREE TIME: Should have ~2,280 CPU ticks for general game code

			lda #0
			sta COLUPF
			sta COLUBK

			lda ColorScheme			; Reset the color scheme offset every frame
			sec
			sbc #7
			sta ColorScheme

	; Bump the frame counter and deci-seconds (will roll after about 1 hour 49 minutes)
			inc FrameCount
			lda #TICKS_PER_DECISECOND
			cmp FrameCount
			bcc DontBumpDeciSeconds
			lda #0
			sta FrameCount
			inc DeciSeconds
DontBumpDeciSeconds:

	; Sample the joystick directions and button, saving the old state for edge detection
			lda CurrJoysticks
			sta PrevJoysticks
			lda SWCHA
			rol INPT4
			ror
			eor #$FF			; The joystick directions are inverted (0 = button down, 1 = button up)
			sta CurrJoysticks
			eor PrevJoysticks	; Rising edge detection = (Curr ^ Prev) & Curr
			and CurrJoysticks	; Now a set bit in A means that input has a rising edge (has just been pressed)
			tay					; Save the rising edge bits in Y, for the various states that are interested in input

#if 0
	; Example of how to print the hex value for what's in the accumulator onto the screen at the end of the second line of text
			tya
			pha
			ldx #8
			ldy #1
			jsr SetCursor
			lda CurrJoysticks
			jsr PrintHexValue
			pla
			tay
#endif

	; Jump into the code handling the current game state
			jmp (StateCodePtr)

;======================================-=======================================
;	MAIN MENU INITIALIZATION STATE

InitMainMenu:
			jsr ClearScreen		; Clear text screen
			lda #0
			sta TextCursor		; Reset text cursor to 0,0
			sta ScrollTextOffs	; Reset "PRESS BUTTON" scroller offset for next state
			lda #<[CS_MainMenu2 - ColorSchemes]
			sta ColorScheme
			ldy #0
InitMainMenuLineLoop:
			ldx ScrnMainMenu,y
			bmi InitMainMenuDone
			iny
InitMainMenuCharLoop:
			lda ScrnMainMenu,y
			iny
			cmp #0
			beq InitMainMenuLineLoop
			sty LibTempVar
			sec
			sbc #32
			tay
			lda ASCII2Font,y
			sta TextBuffer,x
			ldy LibTempVar
			inx
			bne InitMainMenuCharLoop
InitMainMenuDone:
			SET_POINTER ScrollTextPtr, TxtMainMenuButton
	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, MainMenuInput
			jmp AwaitOverscan

;======================================-=======================================
;	MAIN MENU INPUT STATE

MainMenuInput:
			and #JOY_UP		; Did the up direction change since last time?
			beq MainMenuInputNoUp
			lda #<[CS_MainMenu2 - ColorSchemes]
			cmp ColorScheme
			beq MainMenuInputNoUp
			lda ColorScheme
			sec
			sbc #16
			sta ColorScheme
MainMenuInputNoUp
			tya
			and #JOY_DOWN	; Did the down direction change since last time?
			beq MainMenuInputNoDown
			lda #<[CS_MainMenu4 - ColorSchemes]
			cmp ColorScheme
			beq MainMenuInputNoDown
			lda ColorScheme
			clc
			adc #16
			sta ColorScheme
MainMenuInputNoDown
			tya
			and #JOY_BUTTON	; Did the joystick button become depressed since last time?  Sad, poor little button, it'll be better soon...
			beq MainMenuInputNoButton
	; The players menu selection is actually the ColorScheme, since that shows which menu item is currently selected
			lda ColorScheme
			sec
			sbc #<[CS_MainMenu2 - ColorSchemes]
			lsr
			lsr
			lsr
			tax
			lda MainMenuJumpTable,x
			sta StateCodePtr
			lda MainMenuJumpTable+1,x
			sta StateCodePtr+1
MainMenuInputNotItem2:
MainMenuInputNoButton:
	; Scroll the "PRESS BUTTON" message on the bottom line
			lda DeciSeconds
			and #$0F
			bne MainMenuInputSkipScroll
			jsr ScrollBottomMsg
MainMenuInputSkipScroll:
			jmp AwaitOverscan

MainMenuJumpTable:
			DC.W	InitPlay
			DC.W	InitDemoOne
			DC.W	InitDemoTwo

;======================================-=======================================
;	PLAY STATE INITIALIZE

InitPlay:
			jsr ClearScreen		; Clear text screen
			lda #0
			sta TextCursor		; Reset text cursor to 0,0
			sta ColorScheme		; Reset the color scheme to all white text on a black background
	; Set up a pointer to our scrolling text
			SET_POINTER DescTextPtr, TxtLocStart
	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, PresentLocDesc
			jmp AwaitOverscan

;======================================-=======================================
;	PRESENT A LOCATION DESCRIPTION (kind of like a tele-typewriter output)

PresentLocDesc:
	; Calculate where the visible cursor (Missile0) should go
			lda TextCursor
			ldx #0
			sec
Pow10Loop:
			inx
			sbc #10
			bcs Pow10Loop
			dex
			adc #10
			asl
			asl
			asl
			asl
			sta LibTempVar		; Save the X offset for later
			lda PowersOfTen,x	; Calculate the Y offset
			sta Missile0Y
			lda LibTempVar
			clc
			adc #2+4			; For some reason the missiles X position needs a little position bump
			ldx #2				; Set Missile0 X offset
			jsr SetSpriteXPos
	; Latch all of the X positions for all sprites
			sta WSYNC
			sta HMOVE
	; Don't output a character every frame, it'll be too fast to read
			lda #7				; ~four characters per second
			and DeciSeconds
			bne PresentLocDescOut
	; Output one character of the text string per frame...
			ldy #0
			lda (DescTextPtr),y
			beq PresentLocDescDone
			cmp #$20
			bne NotASpace
			cpy LibTempVar		; If the text cursor is over the first character of a line, skip the output (if it's a space)
			beq SkipChr
NotASpace:
			jsr ChrOut
SkipChr:
			BUMP16 DescTextPtr
PresentLocDescOut:
			jmp AwaitOverscan
PresentLocDescDone:
	; Done with the location description display, set up for player command/verb input
			lda #81				; Disable the cursor
			sta Missile0Y
			lda #<[CS_LocationCmd - ColorSchemes]
			sta ColorScheme
			lda TextCursor		; If there's actual text on the last line, we should scroll once for the player command input
			cmp #71
			bcc PresentLocDescNoCmdScroll
			jsr ScrollUp
PresentLocDescNoCmdScroll:
	; Set up a pointer to the state machine code we want to run next
			lda #0
			sta ScrollTextOffs	; Reset "L/R THEN BUTTON OR U/D TO SCROLL" scroller offset for next state
			SET_POINTER ScrollTextPtr, TxtPrompt
	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, PlayerCmdInputState
			jmp AwaitOverscan

;======================================-=======================================
;	PLAYER COMMAND INPUT STATE

PlayerCmdInputState:
	; Scroll the "L/R THEN BUTTON OR U/D TO SCROLL" message on the bottom line
			lda DeciSeconds
			and #$0F
			bne PlayerCmdInputSkipScroll
			jsr ScrollBottomMsg
PlayerCmdInputSkipScroll:
			jmp AwaitOverscan

;======================================-=======================================
;	DEMO ONE STATE INITIALIZE

InitDemoOne:
			jsr ClearScreen		; Clear text screen
			lda #0
			sta TextCursor		; Reset text cursor to 0,0
			sta DemoOneTxtOffs
			sta DemoOneFntOffs
			lda #<[CS_Rainbow - ColorSchemes]
			sta ColorScheme		; Reset the color scheme to the rainbow scheme
	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, DemoOne
			jmp AwaitOverscan

;======================================-=======================================
;	DEMO ONE STATE

DemoOne:
			and #JOY_BUTTON
			beq DemoOneContinue
	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, InitMainMenu
			jmp AwaitOverscan
DemoOneContinue:
			lda #21				; 21 is co-prime with 80, so we'll visit every text location
			clc
			adc DemoOneTxtOffs
			cmp #80
			bcc DemoOneTxtOK
			sec
			sbc #80
DemoOneTxtOK:
			sta DemoOneTxtOffs
			tax
			lda #5
			clc
			adc DemoOneFntOffs
			cmp #$F5
			bcc DemoOneFntOK
			sec
			sbc #$F5
DemoOneFntOK:
			sta DemoOneFntOffs
			sta TextBuffer,x
			jmp AwaitOverscan


;======================================-=======================================
;	DEMO TWO STATE INITIALIZE

InitDemoTwo:
			jsr ClearScreen		; Clear text screen
			lda #0
			sta TextCursor		; Reset text cursor to 0,0
			sta ColorScheme		; Reset the color scheme to all white text on a black background
			jmp AwaitOverscan



;======================================-=======================================
;	AWAIT THE END OF THE OVERSCAN PERIOD

AwaitOverscan:
			lda INTIM
			bne AwaitOverscan
			jmp TopOfScreenKernelEntry

ColdBoot:
			CLEAN_START

			lda #C_WHITE
			sta COLUPF

			lda #%00110111		; Missile sprites 8 clocks, Player sprites set to quad size
			sta NUSIZ0
			sta NUSIZ1

	; Set up colors for the missiles and player0 sprite
			lda #C_GREEN
			sta COLUP0
			lda #C_YELLOW
			sta COLUP1

	; Set these Y positions to anything > 80 to disable them
			lda #81
			sta Player0Y
			sta Missile0Y
			sta Missile1Y

	; Set up a pointer to the state machine code we want to run next
			SET_POINTER StateCodePtr, InitMainMenu

			jmp TopOfScreenKernelEntry

;======================================-=======================================
;						GAME STATE LIBRARY ROUTINES

ScrollBottomMsg: SUBROUTINE
			ldy #7				; Scroll the bottom line one character...
			jsr ScrollLineLeft
			ldy ScrollTextOffs
			lda (ScrollTextPtr),y
			bne .notEnd
			ldy #0
			lda (ScrollTextPtr),y
.notEnd:	iny
			sty ScrollTextOffs
			sec
			sbc #32
			tay
			lda ASCII2Font,y
			sta TextBuffer+79
			rts

;======================================-=======================================
;								LIBRARY ROUTINES

; SetCursor: Set the horizontal and vertical character position for the next
;			character out from ChrOut.
;	IN: X - Desired horizontal character position (0 - 9)
;	IN: Y - Desired vertical text line position (0 - 7)
;	TRASHED: A, flags
;	NOTES:
;		There's no error checking here, if X/Y aren't within range, really
;		bad things will happen then next time ChrOut is called (like trashed
;		RAM/Stack)
SetCursor:	SUBROUTINE
			stx TextCursor
			lda PowersOfTen,y
			clc
			adc TextCursor
			sta TextCursor
			rts

; ChrOut: Output one ASCII character to the cursor position in the text
;		buffer, and bump the cursor one position
;	IN: A - ASCII character to be displayed
;	TRASHED: A, X, flags
;	!! WARNING !!:
;		There's no error checking here, if X/Y aren't within range, really
;		bad things will happen then next time ChrOut is called (like trashed
;		RAM/Stack)
ChrOut:		SUBROUTINE
			sec
			sbc #32
			tax
			lda ASCII2Font,x
			ldx TextCursor
			sta TextBuffer,x
			inx
			cpx #80
			bcc .noScroll
			jsr ScrollUp
			ldx #70			; The beginning of the last line of text
.noScroll:	stx TextCursor
			rts

; PrintTextStr: 
;	IN: LibTempPtr points to the ZERO TERMINATED (C style) text string
;	TRASHED: A, X, Y, flags
;	NOTES:
;		Strings longer than 255 characters can't be printed, which should be
;		OK because there can only be 80 characters visible anyway!
;	!! WARNING !!:
;		There's no error checking here, if the string ends up printing beyond
;		the bounds of the TextBuffer then really bad things will happen (like
;		trashed RAM/Stack and this subroutine returning to some unknown
;		location!)
PrintTextStr:	SUBROUTINE
			ldy #0
.loop:		lda (LibTempPtr),y
			beq .exit
			jsr ChrOut
			iny
			bne .loop
.exit:		rts

; PrintHexValue: Output a two digit hex number for the value in A
;	TRASHED: A, X, Y, flags
PrintHexValue:	SUBROUTINE
			tay
			lsr
			lsr
			lsr
			lsr
			clc
			adc #'0
			cmp #':
			bcc .notAlpha1
			adc #6
.notAlpha1: jsr ChrOut
			tya
			and #$0F
			clc
			adc #'0
			cmp #':
			bcc .notAlpha2
			adc #6
.notAlpha2: jsr ChrOut
			rts

; ClearScreen: Clear the screen to the first glyph in the font
;	TRASHED: A, X, flags
ClearScreen:	SUBROUTINE
			ldx #80
			lda #00
.loop:		sta TextBuffer-1,x
			dex
			bne .loop
			rts

; ScrollUp: Shift (scroll) the text screen up one text line
;	TRASHED: A, X, flags
ScrollUp:	SUBROUTINE
			ldx #0		; Need to walk through the buffer forward, or we will just duplicate lines
.scrlloop:	lda TextBuffer+10,x
			sta TextBuffer,x
			inx
			txa
			cmp #<[80-10]
			bcc .scrlloop
			ldx #10		; Clear the last/bottom line of text
			lda #0
.clrloop:	sta TextBuffer+70-1,x
			dex
			bne .clrloop
			rts

; ScrollLineLeft: Shift (scroll) a single line of text left one character
;	IN: Y - Desired vertical text line to scroll one left (0 - 7)
;	TRASHED: A, X, Y, flags
ScrollLineLeft:	SUBROUTINE
			lda PowersOfTen,y
			tax
			ldy #9
.loop		lda TextBuffer+1,x
			sta TextBuffer,x
			inx
			dey
			bne .loop
			rts

; SetSpriteXPos: Set the course and fine horizontal position for a sprite, missile or the ball
;	IN: A - Desired horizontal pixel position for the sprite (0 - 159)
;	IN: X - TIA RES/HM offset (Player0 = 0, Player1 = 1, Missile0 = 2, Missile1 = 3, Ball = 4)
;	TRASHED: A, Y, flags
;	NOTES:
;		This routine consumes one whole scanline
;		Reverse engineered from the Atari game "Adventure" by Warren Robinett
SetSpriteXPos:	SUBROUTINE
			ldy #2
			sec
.divLoop:	iny				; Divide by 15, calculating number of course loops needed in Y
			sbc #15
			bcs .divLoop
			eor #$FF		; Convert remainder into a TIA horizontal motion value
			sbc #6
			asl				;   Shift the fine position offset into the desired
			asl				;   bits within a horizontal motion value register
			asl
			asl
			sty WSYNC
.courseLp:	dey				; 2		Delay for course horizontal positioning
			bpl .courseLp	; 2/3	Five CPU ticks per iteration, or 15 TIA ticks/pixels
			sta RESP0,x		; 4		Latch course horizontal position
			sta HMP0,x		; 4		Set fine horizontal position adjustment
			rts

; Used to save one byte (a BRK instead of a JSR) for a commonly used subroutine
; Or could be used to pass a one byte argument (next byte after BRK), since the
; RTI will return to the address of the BRK instruction + 2.
BRKInst:	SUBROUTINE
			rti

;======================================-=======================================
;								   GAME DATA

ColorSchemes:
		;		Line 0   Line 1   Line 2   Line 3   Line 4   Line 5   Line 6   Line 7
		DC.B	C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE	; Foreground colors
		DC.B	C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK	; Background colors

CS_MainMenu2:	; First line of text "selected"
		DC.B	C_YELLOW, C_WHITE, C_BLACK, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_BLACK		; Foreground colors
		DC.B	C_PURPLE, C_BLACK, C_WHITE, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_YELLOW	; Background colors

CS_MainMenu3:	; Second line of text "selected"
		DC.B	C_YELLOW, C_WHITE, C_WHITE, C_BLACK, C_WHITE, C_WHITE, C_WHITE, C_BLACK		; Foreground colors
		DC.B	C_PURPLE, C_BLACK, C_BLACK, C_WHITE, C_BLACK, C_BLACK, C_BLACK, C_YELLOW	; Background colors

CS_MainMenu4:	; Third line of text "selected"
		DC.B	C_YELLOW, C_WHITE, C_WHITE, C_WHITE, C_BLACK, C_WHITE, C_WHITE, C_BLACK		; Foreground colors
		DC.B	C_PURPLE, C_BLACK, C_BLACK, C_BLACK, C_WHITE, C_BLACK, C_BLACK, C_YELLOW	; Background colors

CS_MainMenu5:	; Fourth line of text "selected"
		DC.B	C_YELLOW, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_BLACK, C_WHITE, C_BLACK		; Foreground colors
		DC.B	C_PURPLE, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_WHITE, C_BLACK, C_YELLOW	; Background colors

CS_LocationCmd:	; Awaiting a command on a location description screen
		DC.B	C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_WHITE, C_BLACK	; Foreground colors
		DC.B	C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_BLACK, C_YELLOW	; Background colors

CS_Rainbow:	; For Demo One
		DC.B	C_VIOLET,	C_INDIGO,	C_BLUE,		C_BLACK,	C_YELLOW,	C_ORANGE,	C_RED,		C_BLACK
		DC.B	C_RED,		C_ORANGE,	C_YELLOW,	C_GREEN,	C_BLUE,		C_INDIGO,	C_VIOLET,	C_WHITE

ASCII2Font:	; 64 byte translation table used to convert ASCII into a Font offset
		; $FA is the "unknown" solid block character, so if you see any
		; characters that get translated into $FA, it means the glyph is missing.

		;		Spc	!	"	#	$	%	&	'	(	)	*	+	,	-	.	/
		DC.B	$00,$05,$0A,$FA,$FA,$0F,$FA,$14,$19,$1E,$FA,$23,$28,$2D,$32,$FA
		;		0	1	2	3	4	5	6	7	8	9	:	;	<	=	>	?
		DC.B	$37,$3C,$41,$46,$4B,$50,$55,$5A,$5F,$64,$69,$FA,$FA,$6E,$FA,$73
		;		@	A	B	C	D	E	F	G	H	I	J	K	L	M	N	O
		DC.B	$FA,$78,$7D,$82,$87,$8C,$91,$96,$9B,$A0,$A5,$AA,$AF,$B4,$B9,$BE
		;		P	Q	R	S	T	U	V	W	X	Y	Z	[	\	]	^	_
		DC.B	$C3,$C8,$CD,$D2,$D7,$DC,$E1,$E6,$EB,$F0,$F5,$FA,$FA,$FA,$FA,$FA

PowersOfTen:
		DC.B	0,10,20,30,40,50,60,70,80,90

TxtLocStart:
		DC.B	"YOU ARE STANDING AT THE END OF A ROAD BEFORE A SMALL BRICK BUILDING. AROUND YOU IS A FOREST. A SMALL STREAM FLOWS OUT OF THE BUILDING AND DOWN A GULLY.",$00
;TxtLocHill:
;		DC.B	"YOU HAVE WALKED UP A HILL, STILL IN THE FOREST. THE ROAD SLOPES BACK DOWN THE OTHER SIDE OF THE HILL. THERE IS A BUILDING IN THE DISTANCE.",$00
;TxtLocBuilding:
;		DC.B	"YOU ARE INSIDE A BUILDING, A WELL HOUSE FOR A LARGE SPRING.",$00
;TxtLocValley:
;		DC.B	"YOU ARE IN A VALLEY IN THE FOREST BESIDE A STREAM TUMBLING ALONG A ROCKY BED.",$00
;TxtLocForest1:
;		DC.B	"YOU ARE WANDERING AIMLESSLY THROUGH THE FOREST.",$00
;TxtLocGrate:
;		DC.B	"YOU ARE IN A 20-FOOT DEPRESSION FLOORED WITH BARE DIRT. SET INTO THE DIRT IS A STRONG STEEL GRATE MOUNTED IN CONCRETE. A DRY STREAMBED LEADS INTO THE DEPRESSION.",$00

TxtPrompt:
		DC.B	"( ) THEN BUTTON OR + = TO SCROLL  ", $00


				;1234567890
;		DC.B	"GO WEST", TxtLocHill
;		DC.B	"BUILDING", TxtLocBuilding
;		DC.B	"GO SOUTH", TxtLocValley
;		DC.B	"GO NORTH", TxtLocForest1
;		DC.B	"DEPRESSION", TxtLocGrate


ScrnMainMenu:
		; "Screens" are sets of offsets and string combinations, with strings
		; terminating with a zero (like in C) and the screen itself terminating
		; with the high-bit set in the offset.
		; Offsets take the form "<[X + (Y * 10)]", where "X" is the horizontal
		; character position and "Y" is the vertical text line position.
		; "X" should always be between 0 and 9.
		; "Y" should always be between 0 and 7.
		DC.B	<[[5 - [10 / 2]] + (0 * 10)], "ADVENT2600", $00
		DC.B	<[[5 - [4 / 2]] + (2 * 10)], "PLAY", $00
		DC.B	<[[5 - [8 / 2]] + (3 * 10)], "DEMO ONE", $00
		DC.B	<[[5 - [8 / 2]] + (4 * 10)], "DEMO TWO", $00
		DC.B	$80

TxtMainMenuButton:
		DC.B	"PRESS BUTTON  ", $00

;======================================-=======================================

			ECHO ([$FFFC-.]d), "bytes available for 4KB cartridge"

;======================================-=======================================
;								BANK SWITCHING
; Reserve $FFFA - $FFFB (normally the 6502 NMI vector) for bank-switching

;======================================-=======================================
;							RESET AND IRQ/BRK VECTORS

			ORG $FFFC
			DC.W ColdBoot		; Reset
			DC.W BRKInst		; IRQ / BRK
