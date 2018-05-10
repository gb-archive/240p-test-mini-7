;
; Overscan test for 240p test suite
; Copyright 2018 Damian Yerrick
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License along
; with this program; if not, write to the Free Software Foundation, Inc.,
; 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
;
include "src/gb.inc"
include "src/global.inc"

; Drawing the side borders is quite a bit easier on the Game Boy
; than on the NES for 3 reasons.
; 
; 1. Game Boy has window
; 2. Game Boy has rSTAT IRQ on rLY=rLYC
; 3. Game Boy has more horizontal sprite coverage
; 
; So I simplify the UI to what can be drawn as sprites, letting me
; use scrolling regs for most of it:
; rSCX=-left_border, rSCY=-top border, rWX=167-right_border, rWY=0,
; rLYC=144-bottom_border

  rsset hTestState
right_border  rb 1
left_border   rb 1
top_border    rb 1
bottom_border rb 1
cur_side      rb 1
cur_palette   rb 1

section "overscan",ROM0
overscan_chr:
  incbin "obj/gb/overscan.chrgb.pb16"



activity_overscan::
  xor a
  ld a,2
  ldh [right_border],a
  ldh [left_border],a
  ldh [top_border],a
  ldh [bottom_border],a
  ld a,PADF_RIGHT>>4
  ldh [cur_side],a
  ld a, %00010011
  ldh [cur_palette],a
.restart:
  call lcd_off
  xor a
  ld [help_bg_loaded],a
  ld [oam_used],a
  ldh [rWY],a

  ld hl,CHRRAM0
  ld de,overscan_chr
  ld b,16
  call pb16_unpack_block

  ; Blank both tilemaps
  ld de,_SCRN0
  ld h,10
  ld bc,2048
  call memset

  ; Make a screen-sized area in the primary tilemap that isn't blank
  ld a,11
  ld b,18
  ld de,12
  ld hl,_SCRN0
  .initrowloop:
    ld c,20
    call memset_tiny
    add hl,de
    dec b
    jr nz,.initrowloop

  call lcd_clear_oam
  call run_dma

  ld a,LCDCF_ON|BG_NT0|WINDOW_NT1|BG_CHR01|OBJ_ON
  ld [vblank_lcdc_value],a
  ld [stat_lcdc_value],a
  ldh [rLCDC],a
  ld a,STAT_LYCIRQ
  ld [rSTAT],a
  ld a,IEF_VBLANK|IEF_LCDC
  ldh [rIE],a  ; enable rSTAT IRQ

  xor a
  ldh [rBGP],a   ; Hide BG and OBJ until ready
  ldh [rOBP0],a
  dec a
  ldh [rLYC],a  

.loop:
  ld b,helpsect_overscan
  call read_pad_help_check
  jr nz,.restart
  ld b,PADF_RIGHT|PADF_LEFT|PADF_UP|PADF_DOWN
  call autorepeat

  ; Process input
  ld a,[new_keys]
  ld b,a
  bit PADB_B,b
  ret nz

  ; Select: Invert
  bit PADB_SELECT,b
  jr z,.not_invert
    ldh a,[cur_palette]
    cpl
    ldh [cur_palette],a
  .not_invert:
  
  ld a,[cur_keys]
  bit PADB_A,a
  jr nz,.a_held

    ; Control Pad: Choose a side
    ld a,PADF_RIGHT|PADF_LEFT|PADF_UP|PADF_DOWN
    and b
    jr z,.a_done
    swap a
    ld [cur_side],a
    jr .a_done
  .a_held:
    ; A+Control Pad: Change side value
    ld a,[cur_side]
    call ctz
    ld c,b    ; C: Current side being changed (0-3)

    ld a,[new_keys]
    and PADF_RIGHT|PADF_LEFT|PADF_UP|PADF_DOWN
    jr z,.a_done
    swap a
    call ctz
    ld a,b    ; B: Direction pressed (0: R, 1: L, 2: U, 3: D)
    xor c
    ld b,a    ; 0: Decrease; 1: Increase: 2: Pressed perpendicularly
    ld a,low(right_border)
    add c
    ld c,a

    ; Regs at this point:
    ; C: HRAM pointer to border position
    ; B: Direction (0: decrease; 1: increase; 2: Nothing)
    ld a,[$FF00+c]
    srl b  ; direction in carry, z true if valid
    jr nz,.a_done
    jr c,.dir_is_increase
      dec a
      jr .writeback_c
    .dir_is_increase:
      inc a
    .writeback_c:

    ; Regs: C is HRAM pointer; A is new value to write if valid
    cp 25
    jr nc,.a_done
    ld [$FF00+c],a
  .a_done:
  
  xor a
  ld [oam_used],a
  call overscan_draw_arrow
  call overscan_draw_sides
  call overscan_draw_rborder
  call lcd_clear_oam
  
  ; Wait for the line above the overscan top and set window to
  ; the far left
  ldh a,[rLYC]
  cp 143
  jr nc,.lycdone
  ld b,a
  ldh a,[cur_palette]
  .lycwait:
    halt
    ldh a,[rLY]
    cp b
    jr c,.lycwait
  ld a,7
  ldh [rWX],a
  .lycdone:

  call wait_vblank_irq
  call run_dma

  ; Set the borders using scrolling, window, and rLYC IRQ.
  ldh a,[left_border]
  cpl
  inc a
  ldh [rSCX],a

  ; In theory, rWX=166 is supposed to show the leftmost pixel of
  ; the window on the rightmost pixel of the screen.  But a bug
  ; in mono (not GBC) hardware causes rWX=166 rWY=0 to behave as
  ; rWX=some low number rWY=1.  So instead, snap the window to
  ; 8-pixel boundaries and use a sprite column to fix the rest.
  ldh a,[right_border]
  and %11111000
  cpl
  add 168
  ldh [rWX],a

  ; Set rLYC to the last line of the safe area, so that window can be
  ; moved to the left for the following line
  ldh a,[top_border]
  cpl
  inc a
  ldh [rSCY],a
  ldh a,[bottom_border]
  cpl
  add 144
  cp 143
  jr c,.bottom_border_exists
    ld a,255
  .bottom_border_exists:
  ldh [rLYC],a

  ldh a,[cur_palette]
  ldh [rBGP],a
  cpl
  ldh [rOBP0],a

  jp .loop

overscan_draw_sides:
  ld h,high(SOAM)
  ld a,[oam_used]
  ld l,a

  ldh a,[right_border]
  ld de,127*256+80
  call .one_side
  ldh a,[left_border]
  ld de,47*256+80
  call .one_side
  ldh a,[top_border]
  ld de,87*256+48
  call .one_side
  ldh a,[bottom_border]
  ld de,87*256+112
  call .one_side
  ld a,l
  ld [oam_used],a
  ret
.one_side:
  ; Convert to 2 digits
  ld c,0
  .tenloop:
  cp 10
  jr c,.lessthanten
    sub 10
    inc c
    jr .tenloop
  .lessthanten:

  ; Draw ones digit in A
  ; D=x coord of 2nd tile, E=y coord
  ld [hl],e
  inc l
  ld [hl],d
  inc l
  ld [hl+],a
  xor a
  ld [hl+],a

  ; Draw tens digit in C
  ld a,c
  or a
  jr z,.no_tens

    ld [hl],e
    inc l
    ld a,d
    sub 8
    ld [hl+],a
    ld [hl],c
    inc l
    ld c,a  ; C = x coord of 1st tile
    xor a
    ld [hl+],a
  .no_tens:

  ; Draw "p"
  ld a,e  ; Advance E to 2nd row
  add 10
  ld [hl+],a
  ld e,a
  ld a,d
  sub 8
  ld [hl+],a
  ld a,12  ; 'p' tile
  ld [hl+],a
  xor a
  ld [hl+],a

  ld [hl],e
  inc l
  ld [hl],d
  inc l
  ld a,13
  ld [hl+],a
  xor a
  ld [hl+],a
  ret

;;
; Sets B to the trailing zero bits in A, trashing A.
ctz::
  ld b,0
.sidepick:
  rra
  ret c
  inc b
  jr nz,.sidepick
  ret

overscan_draw_arrow:
  ld h,high(SOAM)
  ld a,[oam_used]
  ld l,a

  ; Find which side is in use and how big the border is set
  ldh a,[cur_side]
  call ctz  ; B = 0 for right, 1 for left, 2 for top, 3 for bottom
  ld a,low(right_border)
  add b
  ld c,a
  ld a,[$FF00+c]
  ld c,a  ; C = size of this border

  ; Regmap:
  ; B=side ID, C=distance, D=X coord, E=Y coord, HL=OAM pointer

  ; Calculate Y coordinate of first sprite.  Right and left sides
  ; have constant Y
  ld a,84
  bit 1,b
  jr z,.have_y_coord
  ; Top is at X
  ld a,c
  add 16
  bit 0,b
  jr z,.have_y_coord
  ld a,144
  sub c
.have_y_coord:
  ld e,a
  ld [hl+],a
  
  ; Calculate Y coordinate of first sprite.  Top and bottom sides
  ; have constant Y
  ld a,84
  bit 1,b
  jr nz,.have_x_coord
  ; Left is at X
  ld a,c
  add 8
  bit 0,b
  jr nz,.have_x_coord
  ld a,152
  sub c
.have_x_coord:
  ld d,a
  ld [hl+],a

  ; Left or right arrow
  ld a,b
  srl a
  add 14
  ld [hl+],a
  ld a,1<<BOAM_HFLIP|1<<BOAM_VFLIP
  ld [hl+],a

  ; Now draw the second sprite
  ld a,e
  bit 1,b
  jr z,.have_y2_coord
    add 8
  .have_y2_coord:
  ld [hl+],a
  ld a,d
  bit 1,b
  jr nz,.have_x2_coord
    add 8
  .have_x2_coord:
  ld [hl+],a
  ld a,b
  srl a
  add 14
  ld [hl+],a
  xor a
  ld [hl+],a

  ld a,l
  ld [oam_used],a
  ret

; Window can't be drawn exactly one pixel from the right side on
; mono.  Cover up the difference with sprites.
overscan_draw_rborder:
  ld h,high(SOAM)
  ld a,[oam_used]
  ld l,a
  ld a,[right_border]
  cpl
  add 169
  ld c,a

  ld a,16
  ld de,$0B00
.loop:
  ld [hl+],a
  ld [hl],c
  inc l
  ld [hl],d
  inc l
  ld [hl],e
  inc l
  add 8
  cp 160
  jr c,.loop

  ld a,l
  ld [oam_used],a
  ret
