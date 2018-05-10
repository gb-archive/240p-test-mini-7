;
; Motion blur test for 240p test suite
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

; This motion blur test also replaces 100 IRE.

  rsset hTestState
cursor_y     rb 1  ; 0-5; see wndmap for what each row controls
back_shade   rb 1  ; 0-3
on_time      rb 1  ; 1-20
on_shade     rb 1  ; 0-3
off_time     rb 1  ; 1-20
off_shade    rb 1  ; 0-3
is_stripes   rb 1  ; 0: colors 2 and 3 both on or off; 1: one on, other off
is_running   rb 1  ; $00: off; $80: in off time; $80: in on time
frames_left  rb 1  ; until toggle bit 0
bgp_value    rb 1

section "motionblur",ROM0
motionblurtiles_chr:
  incbin "obj/gb/motionblurtiles.chrgb.pb16"
sizeof_motionblurtiles_chr equ 208

wndtxt:
  db   0,"Back shade",10
  db  48,"time",10
  db  64,"Stripes",10
  db  98,"Off",10
  db 114,"On",0

wndmap:
  db $10,$11,$12,$13,$14,$15  ; Back shade
  db $1E,$1F,$0A,$16,$17,$0A  ; On time
  db $0A,$0A,$0A,$13,$14,$15  ;    shade
  db $1C,$1D,$0A,$16,$17,$0A  ; Off time
  db $0A,$0A,$0A,$13,$14,$15  ;     shade
  db $18,$19,$1A,$1B,$0A,$0A  ; Stripes

row_high_low:  ; high and low values for each row
  dw $0400,$1501,$0400,$1501,$0400,$0200

activity_motion_blur::
  xor a
  ldh [frames_left],a  ; = 0
  ldh [is_running],a
  ldh [is_stripes],a
  ldh [off_shade],a
  ldh [cursor_y],a
  inc a
  ldh [back_shade],a   ; = 1
  ldh [off_time],a
  ldh [on_time],a
  ld a,3
  ldh [on_shade],a
.restart:
  call lcd_off
  xor a
  ld [help_bg_loaded],a

  ; Clear tilemaps to $0A
  ld h,$0A
  ld de,_SCRN0
  ld bc,32*18
  call memset

  ; Load basic tiles
  ld hl,CHRRAM0
  ld de,motionblurtiles_chr
  ld b,sizeof_motionblurtiles_chr/16
  call pb16_unpack_block
  
  ; Load label tiles
  call vwfClearBuf
  ld hl,wndtxt
  .labelloadloop:
    ld a,[hl+]
    ld b,a
    call vwfPuts
    ld a,[hl+]
    or a
    jr nz,.labelloadloop
  ld hl,CHRRAM0+$10*16
  ld bc,$0010  ; planes 0 and 1, c=16 tiles
  call vwfPutBuf03

  ; Load label map
  ld bc,$0606  ; size
  ld hl,wndmap
  ld de,_SCRN0+32*11+6
  call load_nam

  ; TODO: Draw 8x8-tile rect of solid $0B starting at (6, 2)
  ld hl,_SCRN0+32*2+6
  ld a,$0B
  ld b,8
  ld de,32-8
  .rectrowloop:
    ld c,8
    call memset_tiny
    add hl,de
    dec b
    jr nz,.rectrowloop

  ; Turn on rendering (no sprites)
  ld a,LCDCF_ON|BG_NT0|BG_CHR01
  ld [vblank_lcdc_value],a
  ldh [rLCDC],a
  ld a,255
  ldh [rLYC],a  ; disable lyc irq
  ld a,%01010101  ; rBGP all gray until calculated
  ldh [rBGP],a

.loop:
  ld b,helpsect_motion_blur
  call read_pad_help_check
  jr nz,.restart

  ; Process input
  ld a,[new_keys]
  bit PADB_B,a
  ret nz
  call motionblur_handle_presses
  call make_help_vram
  call motionblur_calc_bgp
  
  call wait_vblank_irq

  ; Set bg palette
  ldh a,[bgp_value]
  ldh [rBGP],a

  ; Blit help map
  ld bc,$0206  ; size
  ld hl,help_line_buffer
  ld de,_SCRN0+32*11+12
  call load_nam

  ; Draw cursor
  ld hl,_SCRN0+32*11+5
  ldh a,[cursor_y]
  inc a
  ld c,a
  ld b,6
  ld de,32
  .draw_cursor_loop:
    ld a,$0A
    dec c
    jr nz,.draw_cursor_not_this_row
      ld a,$0C
    .draw_cursor_not_this_row:
    ld [hl],a
    add hl,de
    dec b
    jr nz,.draw_cursor_loop

  jr .loop

motionblur_handle_presses:
  ld b,PADF_UP|PADF_DOWN|PADF_LEFT|PADF_RIGHT
  call autorepeat
  ld a,[new_keys]
  ld b,a

  ; Ignore the Control Pad while flicker is running
  ldh a,[is_running]
  rla
  jr c,.no_cursor_control

  ; Up/Down: Choose a row
  ldh a,[cursor_y]
  bit PADB_UP,b
  jr z,.no_cursor_up
    dec a
  .no_cursor_up:
  bit PADB_DOWN,b
  jr z,.no_cursor_down
    inc a
  .no_cursor_down:

  ; Write back only if within range
  cp 6
  jr nc,.no_writeback_cursor_y
    ldh [cursor_y],a
  .no_writeback_cursor_y:

  ; Fetch value and lower/upper bounds for this row
  ldh a,[cursor_y]
  add low(back_shade)
  ld c,a  ; C points to HRAM for row B
  ldh a,[cursor_y]
  ld de,row_high_low
  call de_index_a  ; Valid values are L <= x < H
  ld a,[$FF00+c]

  ; Left/Right: Change value on this row
  bit PADB_LEFT,b
  jr z,.no_cursor_left
    dec a
  .no_cursor_left:
  bit PADB_RIGHT,b
  jr z,.no_cursor_right
    inc a
  .no_cursor_right:
  
  ; Write back only if within range
  cp l
  jr c,.no_writeback_value
  cp h
  jr nc,.no_writeback_value
    ld [$FF00+c],a
  .no_writeback_value:

.no_cursor_control:
  bit PADB_A,b
  jr z,.no_toggle_running
    ldh a,[is_running]
    and $80
    xor $80
    ldh [is_running],a
    ld a,1
    ld [frames_left],a
  .no_toggle_running:

  ret

make_help_vram:
  xor a
  ld bc,5*256+low(back_shade)
  ld hl,help_line_buffer
  .loop:
    ld a,[$FF00+c]
    push bc
    call bcd8bit
    or a
    jr nz,.has_tens
      ld a,$0A
    .has_tens:
    ld [hl+],a
    ld a,c
    ld [hl+],a
    pop bc
    inc c
    dec b
    jr nz,.loop
  ld a,[is_stripes]
  add a
  add $1C
  ld [hl+],a
  inc a
  ld [hl],a
  ret

motionblur_calc_bgp:
  ; If running, clock the timer forward one frame
  ldh a,[is_running]
  ld b,a
  add a
  jr nc,.not_running
    ldh a,[frames_left]
    dec a
    ldh [frames_left],a
    jr nz,.not_running

    ; Get the remaining time for the new frame.  On is 1 in
    ; is_running but first in the menu, so do this before
    ; toggling the frame bit.
    ld a,b
    add a
    add low(on_time)
    ld c,a
    ld a,[$FF00+c]
    ld [frames_left],a

    ; And toggle to the other frame
    ld a,b
    xor $01
    ld [is_running],a
  .not_running:

  ; Fetch the on and off shades
  ldh a,[off_shade]
  swap a
  ld e,a
  ldh a,[on_shade]
  swap a
  ld d,a
  ldh a,[back_shade]
  ld b,a
  ld c,a
  ; Now b=c=back shade, d=on shade<<4, e=off shade<<4

  ; If current step (bit 0) is off, swap the two
  ldh a,[is_running]
  rr a
  jr c,.no_swap
    ld a,d
    ld d,e
    ld e,a
  .no_swap:
  ; b=c=back shade, d=current frame shade<<4, e=other frame shade<<4

  ; If stripes are off, use the current frame shade for both rows
  ldh a,[is_stripes]
  rr a
  jr c,.no_destripe
    ld e,d
  .no_destripe:
  ; b=c=back shade, d=even rows shade<<4, e=odd rows shade<<4

  ; If running are off, use the front shade with the maximum contrast
  ldh a,[is_running]
  rl a
  jr c,.is_running
    ld c,0
    bit 1,b
    jr nz,.is_running
    ld c,3
  .is_running:
  ; b=back shade, c=front shade,
  ; d=even rows shade<<4, e=odd rows shade<<4

  ; Combine the four shades
  ld a,c
  or e  ; A = odd rows shade << 4 | front shade
  add a
  add a  ; A = odd rows shade << 6 | front shade << 2
  or b
  or d
  ; A = odd rows shade << 6 | even rows shade << 4
  ;     | front shade << 2 | back shade
  ldh [bgp_value],a
  ret
