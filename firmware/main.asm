;====================================================================
; Silia 8086 3-Unit Cold-Storage Temperature Monitor & Alarm
; Processor: Intel 8086 (Minimum Mode)
; Clock:     Simulated at 2 MHz; target hardware 5 MHz via 8284A (15 MHz XTAL, 2.5 MHz PCLK)
;            Software delays sized for 5 MHz worst case.
; Compiler:  MASM 6.14 (ml.exe /c /Zd /Zi + link16.exe /CODEVIEW)
;
; Firmware features & fixes:
; 1. ivt_resv (1024 B) at 00000h-003ffh and stack after code so RAM/
;    code/stack never overlap the 8086 IVT; all 256 vectors initialized
;    to isr_dummy before installing IR0..IR3 (20h-23h).
; 2. Early 8259A PIC init with ICW4=01h (normal EOI matching Specific
;    EOIs 60h-63h) and OCW1=0FFh -> 0F0h after IVT & peripherals ready.
; 3. DS12887 RTC 12-hr/binary -> 24-hr BCD safe conversion in
;    rtc_init_cfg (fixes 92:10:31 PM BCD bug under Proteus AUTOINIT=1)
;    plus atomic UIP-safe rtc_read_time and NVRAM bounds validation.
; 4. Immediate LCD refresh via ui_dirty on keypad/door events, instant
;    update_outputs on ACK (PA5), door open (IR2), and menu reset.
; 5. Clock-independent ~1-2 s non-blocking "ACCESS DENIED!" hold via
;    1 Hz tick counter (pin_err_cnt) with queued-key flush.
; 6. ACK falling-edge + active-alarm guard (ack_prev), word-aligned
;    out_secs, 25-pass RTC POR wait, 3x 38h LCD reset with >= 15 ms
;    lead-in, adc_valid pre-first-sample guard, ADC startup dummy reads
;    plus R1 adc_busy/adc_chan watchdog at 1 Hz kick, NVRAM limit bounds
;    check (nvram_bounds_check), UIP re-check retry in rtc_read_time,
;    need_log cause mask, and isr_dummy ISR-checked EOI.
;    Cooling hysteresis: ON >= thigh, OFF <= max(thigh - 2, tlow) (1 C
;    integer hold band at thigh - 1; defaults OFF +6/+2/-2 C).
;    Default bands: Unit 1 +2..+8 C, Unit 2 +1..+4 C (Tlow=+1), Unit 3 -20..0 C.
; 7. Chronological wrapped ring-buffer indexing in draw_logs, working-
;    copy editing in mode_edit (-55 <= lo < hi <= 99, # saves+next,
;    * discards+back), pre-first-ADC stats guard, and exact 20-char
;    4-line formatting across all 5 LCD modes.
;====================================================================

        .8086

;--------------------------------------------------------------------
; I/O PORT MAP (Decoded by U8 74LS138, 80h-bfh)
;--------------------------------------------------------------------
ppi1_pa     equ 080h        ; in:  pa0..3=74c922 a..d, pa4=da, pa5=/ack_btn
ppi1_pb     equ 082h        ; out: pb0..7=lcd d0..d7
ppi1_pc     equ 084h        ; out: pc0=rs, pc1=e, pc3=buzz_en, pc4=grn, pc5=yel, pc6=red
ppi1_ctrl   equ 086h        ; 90h -> pa=in, pb=out, pc=out

adc1_port   equ 088h        ; unit 1 (vaccine fridge +2..+8 c)
adc2_port   equ 0b0h        ; unit 2 (fresh chiller +1..+4 c)
adc3_port   equ 0b8h        ; unit 3 (freezer       -20..0 c, offset -30 c)

pit_c0      equ 090h        ; 2.5 mhz / 25000 (61a8h) = 100.0 hz
pit_c1      equ 092h        ; 100 hz  / 100   (0064h) = 1.000 hz -> pic ir1
pit_c2      equ 094h        ; 2.5 mhz / 1250  (04e2h) = 2.0 khz  -> buzzer
pit_ctrl    equ 096h

pic_cmd     equ 098h        ; icw1=13h, ocw2=60h-63h (specific eoi)
pic_data    equ 09ah        ; icw2=20h, icw4=01h, ocw1=ffh->f0h

rtc_idx     equ 0a0h        ; ds12887 index (as)
rtc_data    equ 0a2h        ; ds12887 data (/cs)

ppi2_pa     equ 0a8h        ; in:  pa0..2=ir_door1..3 (1=open, 0=closed)
ppi2_pb     equ 0aah        ; out: pb0..2=rly1_cmd..rly3_cmd (1=cooling on)
ppi2_pc     equ 0ach        ; out: pc0..2=unit 1..3 alarm leds (1=on)
ppi2_ctrl   equ 0aeh        ; 90h -> pa=in, pb=out, pc=out

;--------------------------------------------------------------------
; CONSTANTS
;--------------------------------------------------------------------
lcd_rs      equ 01h         ; pc0
lcd_e       equ 02h         ; pc1
buzz_bit    equ 08h         ; pc3
led_grn     equ 10h         ; pc4
led_yel     equ 20h         ; pc5
led_red     equ 40h         ; pc6

nvram_cfg   equ 00eh        ; 18 bytes config (0eh..1fh)
nvram_log   equ 020h        ; 12 x 8-byte excursion logs (20h..7fh)
max_logs    equ 12

ui_live     equ 0
ui_pin      equ 1
ui_menu     equ 2
ui_logs     equ 3
ui_edit     equ 4

;--------------------------------------------------------------------
; RESERVED IVT SPACE (00000h-003ffh) - Keeps DATA/CODE/STACK out of IVT
;--------------------------------------------------------------------
ivt_resv segment para public 'ivt'
        db 1024 dup(0)
ivt_resv ends

;--------------------------------------------------------------------
; DATA SEGMENT
;--------------------------------------------------------------------
data    segment public 'data'

; temperature arrays (signed 8-bit degrees c, 3 units)
tcurr       db 5, 2, -10
tmin        db 127, 127, 127
tmax        db -55, -55, -55
tcool_on    db 8, 4, 0          ; cooling on  when T >= thigh
tcool_off   db 6, 2, -2         ; cooling off when T <= max(thigh - 2, tlow)

; per-unit state
excur_flag  db 0, 0, 0
door_open   db 0, 0, 0
alarm_act   db 0, 0, 0
logged_flg  db 0, 0, 0
need_log    db 0, 0, 0
grace_cnt   db 0, 0, 0
        even                    ; word-align out_secs (16-bit counters)
out_secs    dw 0, 0, 0

; config / nvram shadow (18 bytes exact: 0eh..1fh)
cfg_magic0  db 'S'
cfg_magic1  db 'I'
grace_lim   db 10               ; default 10 s grace timer
user_pin    db '1','2','3','4'
log_head    db 0
log_count   db 0
tlow        db 2, 1, -20        ; default lows: U1=+2, U2=+1, U3=-20 c
thigh       db 8, 4, 0
cfg_rsvd    db 0, 0, 0

; interrupt / adc / ui flags
adc_chan    db 0
adc_busy    db 0                ; 1 = adc scan in progress (r1 watchdog)
flag_1hz    db 0
ack_silence db 0
ack_prev    db 20h              ; previous pa5 level (20h = released, 0 = pressed)
adc_valid   db 0, 0, 0          ; 1 = unit has completed its first adc sample
relay_mask  db 0
ppi1_pc_shd db 0                ; shadow register for ppi1 port c
ui_mode     db ui_live
prev_ui_md  db ui_live
stat_page   db 0                ; # key cycles 0..3
log_view_ix db 0
edit_unit   db 0
ui_dirty    db 0                ; 1 = refresh lcd immediately
door_dirty  db 0                ; 1 = door ir2 fired, update outputs+lcd
pin_err_cnt db 0                ; 1 hz tick hold for "ACCESS DENIED!"
edit_lo_tmp db 0                ; uncommitted working copy of tlow[edit_unit]
edit_hi_tmp db 0                ; uncommitted working copy of thigh[edit_unit]

; keypad ring buffer (16 bytes)
key_buf     db 16 dup(0)
key_head    db 0
key_tail    db 0

; pin entry buffer
pin_buf     db 4 dup(0)
pin_len     db 0

; rtc bcd cache
rtc_sec     db 0
rtc_min     db 0
rtc_hr      db 0
rtc_day     db 1
rtc_mon     db 1

; factory defaults for the 18-byte config block (mirrors cfg_magic0..cfg_rsvd)
cfg_dflt    db 'S','I',10,'1','2','3','4',0,0,2,1,-20,8,4,0,0,0,0

; mm74c922 4-bit code to ascii lookup table
kpd_map     db '1','2','3',0
            db '4','5','6',0
            db '7','8','9',0
            db '*','0','#',0

; lcd strings (20 chars null-terminated unless noted)
str_boot1   db 'SILIA 8086 MONITOR  ',0
str_boot2   db '3-UNIT COLD STORAGE ',0
str_pin_hdr db 'ADMIN ACCESS - PIN: ',0
str_pin_bad db 'ACCESS DENIED!      ',0
str_menu1   db '1:LOGS  2:RST LOG/AL',0
str_menu2   db '3:LIMITS    *:EXIT  ',0
str_nologs  db 'NO EXCURSION LOGS   ',0
str_log_ft  db '#:NEXT      *:BACK  ',0
str_edit_h  db '1/2:LO-/+  3/4:HI-/+',0
str_edit_f  db '#:SAVE+NEXT  *:BACK ',0
str_live_ft db '  *PIN #STAT',0         ; 12 chars after "HH:MM:SS" = 20
str_nosamp  db '---C/---C',0            ; 9 chars for pre-first-ADC stats
str_blank20 db '                    ',0

; unit labels & adc ports
unit_tag    db 'U1:','U2:','U3:'
adc_ports   db adc1_port, adc2_port, adc3_port
line_addrs  db 080h, 0c0h, 094h, 0d4h

; scratch 8-byte buffer for nvram log read
log_rec     db 8 dup(0)

data    ends

;--------------------------------------------------------------------
; CODE SEGMENT
;--------------------------------------------------------------------
code    segment public 'code'
        assume cs:code, ds:data, ss:stack

start:
        cli
        cld
        mov ax, data
        mov ds, ax
        mov es, ax

        ; 1a. initialize 8259a pic early (all irqs masked) to avoid pre-init pit warnings
        mov al, 13h             ; icw1: edge, single, icw4 needed
        out pic_cmd, al
        mov al, 20h             ; icw2: vector base 20h (ir0..3 -> 20h..23h)
        out pic_data, al
        mov al, 01h             ; icw4: 8086 mode, normal eoi (isrs send specific eoi)
        out pic_data, al
        mov al, 0ffh            ; ocw1: mask all irqs until ivt & peripherals are ready
        out pic_data, al

        ; 1b. wait briefly for power-on settle, then initialize 8255a #1 and #2
        call delay_short
        mov al, 90h
        out ppi1_ctrl, al
        nop
        out ppi2_ctrl, al
        nop

        xor al, al
        out ppi1_pc, al
        out ppi2_pb, al
        out ppi2_pc, al
        mov ppi1_pc_shd, al

        ; 2. initialize 8253a pit
        ; counter 0: mode 3, 2.5 mhz / 25000 (61a8h) = 100.0 hz
        mov al, 36h
        out pit_ctrl, al
        mov al, 0a8h
        out pit_c0, al
        mov al, 61h
        out pit_c0, al

        ; counter 1: mode 2, 100 hz / 100 (0064h) = 1.000 hz -> ir1
        mov al, 74h
        out pit_ctrl, al
        mov al, 64h
        out pit_c1, al
        mov al, 00h
        out pit_c1, al

        ; counter 2: mode 3, 2.5 mhz / 1250 (04e2h) = 2.0 khz -> buzzer
        mov al, 0b6h
        out pit_ctrl, al
        mov al, 0e2h
        out pit_c2, al
        mov al, 04h
        out pit_c2, al

        ; 3. initialize 20x4 lcd (lm044l) and show boot splash
        call lcd_init
        mov al, 080h
        call lcd_cmd
        mov si, offset str_boot1
        call lcd_puts
        mov al, 0c0h
        call lcd_cmd
        mov si, offset str_boot2
        call lcd_puts

        ; 4. wait past ds12887 200 ms power-on inhibit, then init rtc (24-hr bcd) & nvram
        mov cx, 25              ; 25 x delay_long >= 170 ms + lcd init > 200 ms at 5 mhz
rtc_por_lp:
        call delay_long
        loop rtc_por_lp
        call rtc_init_cfg
        call rtc_read_time
        call sync_cool_limits

        ; 5. install safe default handler on all 256 ivt vectors, then 20h-23h
        xor ax, ax
        mov es, ax
        xor di, di
        mov cx, 256
ivt_fill_lp:
        mov word ptr es:[di],   offset isr_dummy
        mov word ptr es:[di+2], cs
        add di, 4
        loop ivt_fill_lp

        mov di, 20h * 4
        mov word ptr es:[di],    offset isr_ir0_adc
        mov word ptr es:[di+2],  cs
        mov word ptr es:[di+4],  offset isr_ir1_1hz
        mov word ptr es:[di+6],  cs
        mov word ptr es:[di+8],  offset isr_ir2_door
        mov word ptr es:[di+10], cs
        mov word ptr es:[di+12], offset isr_ir3_keypad
        mov word ptr es:[di+14], cs

        ; restore es to data segment
        mov ax, data
        mov es, ax

        ; 5b. dummy-read all 3 adc0804 so no stuck-low /intr holds ir0 high
        in al, adc1_port
        in al, adc2_port
        in al, adc3_port

        ; 6. unmask ir0..ir3 on 8259a pic (ir4..ir7 remain masked)
        mov al, 0f0h            ; ocw1: unmask ir0..ir3, mask ir4..ir7
        out pic_data, al

        ; initial door read, initial LED/relay output state, and first adc kick
        in al, ppi2_pa
        and al, 07h
        call update_doors
        call update_relays
        call update_outputs
        mov adc_chan, 0
        mov adc_busy, 1
        out adc1_port, al

        sti                     ; enable cpu interrupts

;--------------------------------------------------------------------
; FOREGROUND SUPERLOOP
;--------------------------------------------------------------------
main_loop:
        ; 1. ack push-button (pa5 active low): act only on a falling edge while
        ;    an alarm is latched, so a latched/held sw1 cannot mask future alarms
        in al, ppi1_pa
        and al, 20h
        mov ah, ack_prev
        mov ack_prev, al
        or al, al
        jnz skip_ack            ; released -> no event
        or ah, ah
        jz skip_ack             ; was already low (held/latched) -> no edge
        mov al, alarm_act[0]
        or al, alarm_act[1]
        or al, alarm_act[2]
        jz skip_ack             ; no latched alarm -> ignore press
        cmp ack_silence, 0
        jne skip_ack
        mov ack_silence, 1
        call update_outputs     ; silence buzzer immediately on ack press
skip_ack:

        ; 2. handle immediate door-open irq response
        cmp door_dirty, 0
        je skip_door_imm
        mov door_dirty, 0
        call update_outputs     ; update yellow + per-unit led immediately
        mov ui_dirty, 1         ; show DOR status on lcd immediately
skip_door_imm:

        ; 3. process pending keypad events (sets ui_dirty on any ui change)
        call process_keypad

        ; 4. run 1 hz periodic tasks (pin-error timer, adc scan, relays, leds, logs, lcd)
        cmp flag_1hz, 0
        je chk_ui_dirty
        mov flag_1hz, 0

        ; decrement non-blocking "ACCESS DENIED!" display hold (~1-2 s)
        cmp pin_err_cnt, 0
        je no_pin_err_tick
        dec pin_err_cnt
        jnz no_pin_err_tick
        mov ui_mode, ui_live
no_pin_err_tick:

        pushf
        cli                     ; keep watchdog + adc_chan reset + kick atomic vs ir0 isr
        mov al, adc_busy
        or al, adc_chan
        jz adc_kick_ok          ; previous scan completed cleanly
        in al, adc1_port        ; r1 watchdog: dummy-read all 3 adcs to release stuck /intr
        in al, adc2_port
        in al, adc3_port
adc_kick_ok:
        mov adc_chan, 0
        mov adc_busy, 1
        out adc1_port, al       ; kick adc scan safely outside ir1 isr
        popf
        call update_relays
        call update_outputs
        call process_nvram_logs
        call rtc_read_time
        mov ui_dirty, 0
        call refresh_lcd
        jmp main_loop

chk_ui_dirty:
        cmp ui_dirty, 0
        je main_loop
        mov ui_dirty, 0
        call refresh_lcd
        jmp main_loop

;====================================================================
; INTERRUPT SERVICE ROUTINES
;====================================================================

isr_dummy proc far
        ; failsafe: an unexpected vector lands here; release the pic
        push ax
        mov al, 0bh             ; ocw3: next read of pic_cmd returns isr
        out pic_cmd, al
        in al, pic_cmd
        or al, al
        jz dummy_ret            ; nothing in service (spurious ir7 / non-pic vector)
        mov al, 20h             ; non-specific eoi only if a real irq is in service
        out pic_cmd, al
dummy_ret:
        pop ax
        iret
isr_dummy endp

;--------------------------------------------------------------------
; ir0 (type 20h): adc0804 conversion complete
; reads current channel, updates tcurr/tmin/tmax/excursion, triggers next
;--------------------------------------------------------------------
isr_ir0_adc proc far
        push ax
        push bx
        push dx
        push ds

        mov ax, data
        mov ds, ax

        xor bh, bh
        mov bl, adc_chan
        cmp bl, 2
        ja adc_done

        mov dl, adc_ports[bx]
        xor dh, dh
        in al, dx               ; read 8-bit adc result (clears /intr)

        ; convert to signed c (unit 3 biased by -30 c) and clamp overflow
        cmp bl, 2
        jne adc_clamp_pos
        cmp al, 129
        jbe adc_u3_sub
        mov al, 129
adc_u3_sub:
        sub al, 30
        jmp adc_store
adc_clamp_pos:
        cmp al, 127
        jbe adc_store
        mov al, 127
adc_store:
        mov tcurr[bx], al
        cmp adc_valid[bx], 0
        jne adc_have
        mov adc_valid[bx], 1    ; first sample seeds tmin/tmax
        mov tmin[bx], al
        mov tmax[bx], al
adc_have:

        ; update tmin (signed)
        cmp al, tmin[bx]
        jge chk_tmax
        mov tmin[bx], al
chk_tmax:
        ; update tmax (signed)
        cmp al, tmax[bx]
        jle chk_range
        mov tmax[bx], al
chk_range:
        ; excursion check: t < tlow or t > thigh
        cmp al, tlow[bx]
        jl set_excur
        cmp al, thigh[bx]
        jg set_excur
        mov excur_flag[bx], 0
        jmp next_adc
set_excur:
        mov excur_flag[bx], 1

next_adc:
        inc bl
        cmp bl, 3
        jae adc_done
        mov adc_chan, bl
        mov dl, adc_ports[bx]
        xor dh, dh
        out dx, al              ; start next adc channel
        jmp adc_eoi

adc_done:
        mov adc_chan, 0
        mov adc_busy, 0         ; scan finished cleanly
adc_eoi:
        mov al, 60h             ; specific eoi for ir0
        out pic_cmd, al

        pop ds
        pop dx
        pop bx
        pop ax
        iret
isr_ir0_adc endp

;--------------------------------------------------------------------
; ir1 (type 21h): 1 hz deterministic tick from 8253a out1
;--------------------------------------------------------------------
isr_ir1_1hz proc far
        push ax
        push bx
        push cx
        push dx
        push si
        push ds

        mov ax, data
        mov ds, ax

        mov flag_1hz, 1

        ; refresh door comparator inputs (handles multi-door & door-close states)
        in al, ppi2_pa
        and al, 07h
        call update_doors

        ; update per-unit grace & alarm latch state
        xor bx, bx
        mov cx, 3
tick_loop:
        mov al, excur_flag[bx]
        or al, door_open[bx]
        jz unit_ok
        jmp unit_fault_cnt

unit_ok:
        mov grace_cnt[bx], 0
        mov alarm_act[bx], 0
        mov logged_flg[bx], 0
        jmp tick_next

unit_fault_cnt:
        mov al, grace_cnt[bx]
        cmp al, grace_lim
        jae latch_alarm
        inc al
        mov grace_cnt[bx], al
        cmp al, grace_lim
        jb tick_next
latch_alarm:
        cmp alarm_act[bx], 0
        jne already_latched
        mov ack_silence, 0      ; new alarm un-silences buzzer
already_latched:
        mov alarm_act[bx], 1
        cmp logged_flg[bx], 0
        jne tick_next
        mov al, 0               ; need_log = cause mask (10h tmp, 20h dor)
        cmp excur_flag[bx], 0
        je nl_cause_dor
        or al, 10h
nl_cause_dor:
        cmp door_open[bx], 0
        je nl_cause_set
        or al, 20h
nl_cause_set:
        mov need_log[bx], al

tick_next:
        inc bx
        loop tick_loop

        ; increment word out_secs (clamped at 5999 = 99:59) for each faulted unit
        xor bx, bx
        xor si, si
        mov cx, 3
outsec_lp:
        mov al, excur_flag[bx]
        or al, door_open[bx]
        jz outsec_nxt
        cmp out_secs[si], 5999
        jae outsec_nxt
        inc out_secs[si]
outsec_nxt:
        inc bx
        add si, 2
        loop outsec_lp

        mov al, 61h             ; specific eoi for ir1
        out pic_cmd, al

        pop ds
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        iret
isr_ir1_1hz endp

;--------------------------------------------------------------------
; ir2 (type 22h): door open interrupt (ored ir_door1..3)
;--------------------------------------------------------------------
isr_ir2_door proc far
        push ax
        push ds

        mov ax, data
        mov ds, ax

        in al, ppi2_pa
        and al, 07h
        call update_doors
        mov door_dirty, 1

        mov al, 62h             ; specific eoi for ir2
        out pic_cmd, al

        pop ds
        pop ax
        iret
isr_ir2_door endp

;--------------------------------------------------------------------
; ir3 (type 23h): mm74c922 keypad digit ready (da)
;--------------------------------------------------------------------
isr_ir3_keypad proc far
        push ax
        push bx
        push cx
        push ds

        mov ax, data
        mov ds, ax

        in al, ppi1_pa
        and al, 0fh
        xor bh, bh
        mov bl, al
        mov al, kpd_map[bx]
        or al, al
        jz kpd_eoi

        ; check ring buffer space before writing
        mov ah, al
        mov bl, key_head
        mov cl, bl
        inc cl
        and cl, 0fh
        cmp cl, key_tail
        je kpd_eoi              ; buffer full -> drop
        xor bh, bh
        mov key_buf[bx], ah
        mov key_head, cl

kpd_eoi:
        mov al, 63h             ; specific eoi for ir3
        out pic_cmd, al

        pop ds
        pop cx
        pop bx
        pop ax
        iret
isr_ir3_keypad endp

;====================================================================
; CONTROL & LOGIC ROUTINES
;====================================================================

; sync cooling thresholds from thigh/tlow:
;   tcool_on  = thigh                (on  when T >= thigh)
;   tcool_off = max(thigh - 2, tlow) (off when T <= tcool_off; 1 c hold band at thigh - 1)
sync_cool_limits proc near
        push ax
        push bx
        xor bx, bx
scl_lp:
        mov al, thigh[bx]
        mov tcool_on[bx], al
        sub al, 2
        cmp al, tlow[bx]
        jge scl_off_ok          ; signed compare: clamp so tcool_off >= tlow
        mov al, tlow[bx]
scl_off_ok:
        mov tcool_off[bx], al
        inc bx
        cmp bx, 3
        jb scl_lp
        pop bx
        pop ax
        ret
sync_cool_limits endp

; input: al bits 0..2 = door sensor states (1=open)
update_doors proc near
        push bx
        mov bl, al
        and al, 01h
        mov door_open[0], al
        mov al, bl
        shr al, 1
        and al, 01h
        mov door_open[1], al
        mov al, bl
        shr al, 1
        shr al, 1
        and al, 01h
        mov door_open[2], al
        pop bx
        ret
update_doors endp

; hysteresis cooling relay control on ppi2_pb (pb0..pb2)
update_relays proc near
        push ax
        push bx
        push cx

        mov ah, relay_mask
        xor bx, bx
        mov cl, 1               ; bit mask: 01h, 02h, 04h
        mov ch, 3
rly_loop:
        mov al, tcurr[bx]
        cmp al, tcool_on[bx]
        jl rly_chk_off
        or ah, cl               ; turn cooling on (>= thigh)
        jmp rly_next
rly_chk_off:
        cmp al, tcool_off[bx]
        jg rly_next
        not cl
        and ah, cl              ; turn cooling off (<= max(thigh - 2, tlow))
        not cl
rly_next:
        shl cl, 1
        inc bx
        dec ch
        jnz rly_loop

        mov relay_mask, ah
        mov al, ah
        out ppi2_pb, al

        pop cx
        pop bx
        pop ax
        ret
update_relays endp

; update status leds (ppi1_pc), buzzer (pc3), and per-unit leds (ppi2_pc)
update_outputs proc near
        push ax
        push bx
        push cx

        ; per-unit alarm leds on ppi2_pc (pc0..pc2)
        xor al, al
        mov cl, 1
        xor bx, bx
led_u_lp:
        mov ah, excur_flag[bx]
        or ah, door_open[bx]
        or ah, alarm_act[bx]
        jz led_u_nxt
        or al, cl
led_u_nxt:
        shl cl, 1
        inc bx
        cmp bx, 3
        jb led_u_lp
        out ppi2_pc, al

        ; system status leds & buzzer on ppi1_pc (preserve pc0..pc1)
        mov al, ppi1_pc_shd
        and al, 03h

        mov bl, alarm_act[0]
        or bl, alarm_act[1]
        or bl, alarm_act[2]
        jnz sys_red

        mov bl, excur_flag[0]
        or bl, excur_flag[1]
        or bl, excur_flag[2]
        or bl, door_open[0]
        or bl, door_open[1]
        or bl, door_open[2]
        jnz sys_yel

        ; normal
        or al, led_grn
        jmp write_pc

sys_yel:
        or al, led_yel
        jmp write_pc

sys_red:
        or al, led_red
        cmp ack_silence, 0
        jne write_pc
        or al, buzz_bit         ; enable 2.0 khz buzzer

write_pc:
        mov ppi1_pc_shd, al
        out ppi1_pc, al

        pop cx
        pop bx
        pop ax
        ret
update_outputs endp

;====================================================================
; DS12887 RTC & NVRAM (UIP-SAFE)
;====================================================================

; al = register index, returns al = data
; pushf/cli/popf prevents an irq from splitting index write and data read.
rtc_read_reg proc near
        pushf
        cli
        out rtc_idx, al
        nop
        nop
        in al, rtc_data
        popf
        ret
rtc_read_reg endp

; ah = register index, al = data
rtc_write_reg proc near
        pushf
        cli
        xchg al, ah
        out rtc_idx, al
        nop
        nop
        xchg al, ah
        out rtc_data, al
        popf
        ret
rtc_write_reg endp

; wait until uip (reg 0ah bit 7) == 0 (bounded to avoid hang)
rtc_wait_uip proc near
        push ax
        push cx
        mov cx, 2000
wait_uip_lp:
        mov al, 0ah
        call rtc_read_reg
        test al, 80h
        loopnz wait_uip_lp
        pop cx
        pop ax
        ret
rtc_wait_uip endp

; convert binary byte in al (0..99) to packed bcd in al (preserves ah, bx, cx)
bin_to_bcd proc near
        push bx
        push cx
        mov ch, ah
        cmp al, 99
        jbe b2b_ok
        mov al, 99
b2b_ok:
        xor ah, ah
        mov bl, 10
        div bl                  ; al = tens, ah = ones
        mov cl, 4
        shl al, cl
        or al, ah
        mov ah, ch
        pop cx
        pop bx
        ret
bin_to_bcd endp

; read rtc time/date registers atomically inside uip-clear guard window
rtc_read_time proc near
        push ax
        push cx
        mov cx, 4               ; bounded retry if uip re-asserts before cli
rrt_retry:
        call rtc_wait_uip
        pushf
        cli
        mov al, 0ah
        call rtc_read_reg
        test al, 80h
        jz rrt_read
        popf
        loop rrt_retry
        pushf
        cli                     ; retries exhausted: read anyway (bounded)
rrt_read:
        mov al, 00h
        call rtc_read_reg
        mov rtc_sec, al
        mov al, 02h
        call rtc_read_reg
        mov rtc_min, al
        mov al, 04h
        call rtc_read_reg
        mov rtc_hr, al
        mov al, 07h
        call rtc_read_reg
        mov rtc_day, al
        mov al, 08h
        call rtc_read_reg
        mov rtc_mon, al
        popf
        pop cx
        pop ax
        ret
rtc_read_time endp

; normalize ds12887 time to 24-hr bcd (handling 12-hr pm/am and binary modes),
; then load 18-byte config from nvram (0eh..1fh) or write defaults if uninitialized
rtc_init_cfg proc near
        push ax
        push bx
        push cx

        ; enable oscillator (reg 0ah = 20h) and wait until uip == 0
        mov ah, 0ah
        mov al, 20h
        call rtc_write_reg
        call rtc_wait_uip

        ; read existing reg 0bh (bit 2 = DM: 0=BCD/1=BIN, bit 1 = 24/12: 0=12h/1=24h)
        mov al, 0bh
        call rtc_read_reg
        mov bl, al

        ; set SET=1 (bit 7) to inhibit updates during safe mode conversion
        or al, 80h
        mov ah, 0bh
        call rtc_write_reg

        ; check whether rtc started in binary mode (DM=1) or bcd mode (DM=0)
        test bl, 04h
        jnz rtc_conv_bin

        ; --- BCD mode (DM=0; Proteus AUTOINIT=1 default) ---
        mov al, 04h
        call rtc_read_reg
        test bl, 02h            ; already 24-hr mode?
        jz rtc_bcd_12h
        ; already 24-hr BCD: convert only if stray PM bit (bit 7) is set
        test al, 80h
        jz rtc_mode_24bcd
        jmp rtc_bcd_pm

rtc_bcd_12h:
        test al, 80h            ; bit 7 = PM flag in 12-hr mode
        jnz rtc_bcd_pm
        ; 12-hr AM BCD: 12h (12 AM) -> 00h; 01h..11h unchanged
        cmp al, 12h
        jne rtc_mode_24bcd
        xor al, al
        jmp rtc_wr_hr

rtc_bcd_pm:
        ; 12-hr PM BCD: 92h (12 PM) -> 12h; 81h..91h (1..11 PM) -> 13h..23h via DAA
        and al, 7fh
        cmp al, 12h
        je rtc_wr_hr
        clc
        add al, 12h
        daa
rtc_wr_hr:
        mov ah, 04h
        call rtc_write_reg
        jmp rtc_mode_24bcd

rtc_conv_bin:
        ; --- Binary mode (DM=1): convert sec/min/day/mon/yr and hr to 24-hr BCD ---
        mov al, 00h
        call rtc_read_reg
        call bin_to_bcd
        mov ah, 00h
        call rtc_write_reg

        mov al, 02h
        call rtc_read_reg
        call bin_to_bcd
        mov ah, 02h
        call rtc_write_reg

        mov al, 07h
        call rtc_read_reg
        call bin_to_bcd
        mov ah, 07h
        call rtc_write_reg

        mov al, 08h
        call rtc_read_reg
        call bin_to_bcd
        mov ah, 08h
        call rtc_write_reg

        mov al, 09h
        call rtc_read_reg
        call bin_to_bcd
        mov ah, 09h
        call rtc_write_reg

        ; convert hours (reg 04h) from binary (12-hr or 24-hr) to 24-hr BCD
        mov al, 04h
        call rtc_read_reg
        test bl, 02h            ; already 24-hr binary?
        jz rtc_bin_12h
        test al, 80h
        jz rtc_bin_hr_bcd
        jmp rtc_bin_pm
rtc_bin_12h:
        test al, 80h
        jnz rtc_bin_pm
        cmp al, 12
        jne rtc_bin_hr_bcd
        xor al, al
        jmp rtc_bin_hr_bcd
rtc_bin_pm:
        and al, 7fh
        cmp al, 12
        je rtc_bin_hr_bcd
        add al, 12
rtc_bin_hr_bcd:
        call bin_to_bcd
        mov ah, 04h
        call rtc_write_reg

rtc_mode_24bcd:
        ; commit 24-hr BCD mode and clear SET=0 (reg 0bh = 02h)
        mov ah, 0bh
        mov al, 02h
        call rtc_write_reg

        ; check nvram magic ('S','I') at 0eh..0fh
        mov al, nvram_cfg
        call rtc_read_reg
        cmp al, 'S'
        jne cfg_defaults
        mov al, nvram_cfg + 1
        call rtc_read_reg
        cmp al, 'I'
        jne cfg_defaults

        ; valid config found -> load 18 bytes into cfg_magic0..cfg_rsvd
        xor bx, bx
        mov cx, 18
cfg_rd_lp:
        mov al, nvram_cfg
        add al, bl
        call rtc_read_reg
        mov cfg_magic0[bx], al
        inc bx
        loop cfg_rd_lp

        ; sanitize loaded ring-buffer indices
        cmp log_head, max_logs
        jb cfg_hd_ok
        mov log_head, 0
cfg_hd_ok:
        cmp log_count, max_logs
        jbe cfg_chk
        mov log_count, max_logs
cfg_chk:
        call nvram_bounds_check
        jnc cfg_done
        ; corrupt limits/grace: restore factory defaults into ram, then rewrite nvram
        push si
        push di
        mov si, offset cfg_dflt
        mov di, offset cfg_magic0
        mov cx, 18
        rep movsb
        pop di
        pop si

cfg_defaults:
        call rtc_save_cfg
cfg_done:
        pop cx
        pop bx
        pop ax
        ret
rtc_init_cfg endp

; validate loaded limits: -55 <= tlow < thigh <= 99 and grace_lim >= 1
; returns cf=0 valid, cf=1 invalid
nvram_bounds_check proc near
        push bx
        cmp grace_lim, 1
        jb nbc_bad
        xor bx, bx
nbc_lp:
        mov al, tlow[bx]
        cmp al, -55
        jl nbc_bad
        cmp al, thigh[bx]
        jge nbc_bad
        cmp thigh[bx], 99
        jg nbc_bad
        inc bx
        cmp bx, 3
        jb nbc_lp
        clc
        pop bx
        ret
nbc_bad:
        stc
        pop bx
        ret
nvram_bounds_check endp

rtc_save_cfg proc near
        push ax
        push bx
        push cx
        xor bx, bx
        mov cx, 18
cfg_wr_lp:
        mov ah, nvram_cfg
        add ah, bl
        mov al, cfg_magic0[bx]
        call rtc_write_reg
        inc bx
        loop cfg_wr_lp
        pop cx
        pop bx
        pop ax
        ret
rtc_save_cfg endp

; check need_log[0..2] and write 8-byte excursion record to ds12887 nvram
process_nvram_logs proc near
        push ax
        push bx
        push cx
        push dx

        xor bx, bx
nlog_loop:
        cmp need_log[bx], 0
        je nlog_next

        pushf
        cli                     ; atomic claim vs isr_ir1_1hz (no double-log)
        mov dh, need_log[bx]    ; dh = cause mask captured at latch time
        mov need_log[bx], 0
        mov logged_flg[bx], 1
        popf

        call rtc_read_time

        ; compute nvram offset = 20h + (log_head * 8)
        mov al, log_head
        mov cl, 3
        shl al, cl
        add al, nvram_log
        mov dl, al              ; dl = base nvram register

        ; byte 0: unit(1..3) in low nibble, fault flags in high nibble
        mov al, bl
        inc al
        or al, dh               ; cause flags captured when alarm latched
        mov ah, dl
        call rtc_write_reg

        ; byte 1: current temp (signed)
        mov ah, dl
        inc ah
        mov al, tcurr[bx]
        call rtc_write_reg

        ; bytes 2..6: hr, min, sec, mon, day
        mov ah, dl
        add ah, 2
        mov al, rtc_hr
        call rtc_write_reg

        mov ah, dl
        add ah, 3
        mov al, rtc_min
        call rtc_write_reg

        mov ah, dl
        add ah, 4
        mov al, rtc_sec
        call rtc_write_reg

        mov ah, dl
        add ah, 5
        mov al, rtc_mon
        call rtc_write_reg

        mov ah, dl
        add ah, 6
        mov al, rtc_day
        call rtc_write_reg

        ; byte 7: grace limit snapshot
        mov ah, dl
        add ah, 7
        mov al, grace_lim
        call rtc_write_reg

        ; advance circular head
        mov al, log_head
        inc al
        cmp al, max_logs
        jb nl_head_ok
        xor al, al
nl_head_ok:
        mov log_head, al
        cmp log_count, max_logs
        jae nl_save
        inc log_count
nl_save:
        call rtc_save_cfg

nlog_next:
        inc bx
        cmp bx, 3
        jb nlog_loop

        pop dx
        pop cx
        pop bx
        pop ax
        ret
process_nvram_logs endp

;====================================================================
; KEYPAD & MENU HANDLER
;====================================================================

; flush any queued keys atomically
key_flush proc near
        push ax
        pushf
        cli
        mov al, key_head
        mov key_tail, al
        popf
        pop ax
        ret
key_flush endp

; returns zf=1 if empty, else zf=0 and al=ascii key
key_pop proc near
        push bx
        mov al, key_tail
        cmp al, key_head
        je kp_empty
        xor bh, bh
        mov bl, al
        mov al, key_buf[bx]
        inc bl
        and bl, 0fh
        mov key_tail, bl
        or bl, 1                ; clear zf (zf=0)
        pop bx
        ret
kp_empty:
        xor ax, ax              ; set zf=1
        pop bx
        ret
key_pop endp

process_keypad proc near
        push ax
        push bx
        push si

pk_next:
        call key_pop
        jz pk_done_j

        cmp ui_mode, ui_live
        je mode_live
        cmp ui_mode, ui_pin
        je mode_pin
        cmp ui_mode, ui_menu
        je mode_menu
        cmp ui_mode, ui_logs
        je mode_logs
        jmp mode_edit

pk_done_j:
        jmp pk_done

mode_live:
        cmp al, '*'
        jne chk_hash
        mov ui_mode, ui_pin
        mov pin_len, 0
        mov pin_err_cnt, 0
        mov ui_dirty, 1
        jmp pk_next
chk_hash:
        cmp al, '#'
        jne pk_next
        inc stat_page
        and stat_page, 03h
        mov ui_dirty, 1
        jmp pk_next

mode_pin:
        ; ignore/drop keys while "ACCESS DENIED!" hold is active
        cmp pin_err_cnt, 0
        jne pk_next
        cmp al, '*'
        je pin_cancel
        cmp al, '0'
        jb pk_next
        cmp al, '9'
        ja pk_next
        xor bh, bh
        mov bl, pin_len
        cmp bl, 4
        jae pk_next
        mov pin_buf[bx], al
        inc bl
        mov pin_len, bl
        mov ui_dirty, 1
        cmp bl, 4
        jb pk_next

        ; verify 4-digit pin
        mov al, pin_buf[0]
        cmp al, user_pin[0]
        jne pin_fail
        mov al, pin_buf[1]
        cmp al, user_pin[1]
        jne pin_fail
        mov al, pin_buf[2]
        cmp al, user_pin[2]
        jne pin_fail
        mov al, pin_buf[3]
        cmp al, user_pin[3]
        jne pin_fail
        mov ui_mode, ui_menu
        mov ui_dirty, 1
        jmp pk_next
pin_fail:
        ; hold "ACCESS DENIED!" visibly for ~1-2 s via 1 hz ticks (non-blocking)
        mov pin_len, 0
        mov pin_err_cnt, 2
        call key_flush
        mov ui_dirty, 1
        jmp pk_next
pin_cancel:
        mov pin_len, 0
        mov pin_err_cnt, 0
        mov ui_mode, ui_live
        mov ui_dirty, 1
        jmp pk_next

mode_menu:
        cmp al, '*'
        je menu_exit
        cmp al, '1'
        je menu_logs
        cmp al, '2'
        je menu_clr
        cmp al, '3'
        je menu_edit
        jmp pk_next
menu_logs:
        mov log_view_ix, 0
        mov ui_mode, ui_logs
        mov ui_dirty, 1
        jmp pk_next
menu_clr:
        mov log_head, 0
        mov log_count, 0
        call rtc_save_cfg
        pushf
        cli
        mov ack_silence, 1
        xor bx, bx
        xor si, si
clr_lp:
        mov alarm_act[bx], 0
        mov grace_cnt[bx], 0
        mov logged_flg[bx], 0
        mov need_log[bx], 0
        mov out_secs[si], 0
        mov al, tcurr[bx]
        mov tmin[bx], al
        mov tmax[bx], al
        inc bx
        add si, 2
        cmp bx, 3
        jb clr_lp
        popf
        call update_outputs     ; clear alarm leds & buzzer immediately
        mov ui_mode, ui_live
        mov ui_dirty, 1
        jmp pk_next
menu_edit:
        mov edit_unit, 0
        mov al, tlow[0]
        mov edit_lo_tmp, al
        mov al, thigh[0]
        mov edit_hi_tmp, al
        mov ui_mode, ui_edit
        mov ui_dirty, 1
        jmp pk_next
menu_exit:
        mov ui_mode, ui_live
        mov ui_dirty, 1
        jmp pk_next

mode_logs:
        cmp al, '*'
        je logs_exit
        cmp al, '#'
        jne ml_next
        cmp log_count, 0
        je ml_next
        inc log_view_ix
        mov al, log_view_ix
        cmp al, log_count
        jb ml_dirty
        mov log_view_ix, 0
ml_dirty:
        mov ui_dirty, 1
ml_next:
        jmp pk_next
logs_exit:
        mov ui_mode, ui_menu
        mov ui_dirty, 1
        jmp pk_next

mode_edit:
        xor bh, bh
        mov bl, edit_unit
        cmp al, '*'
        je edit_back
        cmp al, '#'
        je edit_save_nxt
        cmp al, '1'
        jne ed_chk2
        mov al, edit_lo_tmp
        cmp al, -55
        jle ed_next
        dec al
        mov edit_lo_tmp, al
        mov ui_dirty, 1
        jmp ed_next
ed_chk2:
        cmp al, '2'
        jne ed_chk3
        mov al, edit_lo_tmp
        inc al
        cmp al, edit_hi_tmp
        jge ed_next
        mov edit_lo_tmp, al
        mov ui_dirty, 1
        jmp ed_next
ed_chk3:
        cmp al, '3'
        jne ed_chk4
        mov al, edit_hi_tmp
        dec al
        cmp al, edit_lo_tmp
        jle ed_next
        mov edit_hi_tmp, al
        mov ui_dirty, 1
        jmp ed_next
ed_chk4:
        cmp al, '4'
        jne ed_next
        mov al, edit_hi_tmp
        cmp al, 99
        jge ed_next
        inc al
        mov edit_hi_tmp, al
        mov ui_dirty, 1
        jmp ed_next
edit_save_nxt:
        ; commit current unit limits atomically, save to nvram, advance unit
        pushf
        cli
        mov al, edit_lo_tmp
        mov tlow[bx], al
        mov al, edit_hi_tmp
        mov thigh[bx], al
        call sync_cool_limits
        popf
        call rtc_save_cfg
        call update_relays
        inc edit_unit
        cmp edit_unit, 3
        jb ed_load_cur
        mov edit_unit, 0
ed_load_cur:
        xor bh, bh
        mov bl, edit_unit
        mov al, tlow[bx]
        mov edit_lo_tmp, al
        mov al, thigh[bx]
        mov edit_hi_tmp, al
        mov ui_dirty, 1
        jmp ed_next
edit_back:
        ; discard uncommitted edits on current unit and return to menu
        mov ui_mode, ui_menu
        mov ui_dirty, 1
ed_next:
        jmp pk_next

pk_done:
        pop si
        pop bx
        pop ax
        ret
process_keypad endp

;====================================================================
; 20x4 LCD DRIVER (8-bit, U20 PB=D0..7, PC0=RS, PC1=E, RW=GND)
;====================================================================

delay_short proc near
        push cx
        mov cx, 160
ds_lp:  loop ds_lp
        pop cx
        ret
delay_short endp

delay_long proc near
        push cx
        mov cx, 2000
dl_lp:  loop dl_lp
        pop cx
        ret
delay_long endp

lcd_pulse_e proc near
        push ax
        mov al, ppi1_pc_shd
        or al, lcd_e
        out ppi1_pc, al
        nop
        nop
        and al, not lcd_e
        out ppi1_pc, al
        pop ax
        ret
lcd_pulse_e endp

; al = command byte
lcd_cmd proc near
        push ax
        mov ah, al
        mov al, ppi1_pc_shd
        and al, not lcd_rs
        mov ppi1_pc_shd, al
        out ppi1_pc, al
        mov al, ah
        out ppi1_pb, al
        call lcd_pulse_e
        call delay_short
        cmp ah, 02h
        ja lc_ret
        call delay_long
lc_ret:
        pop ax
        ret
lcd_cmd endp

; al = data char
lcd_data proc near
        push ax
        mov ah, al
        mov al, ppi1_pc_shd
        or al, lcd_rs
        mov ppi1_pc_shd, al
        out ppi1_pc, al
        mov al, ah
        out ppi1_pb, al
        call lcd_pulse_e
        call delay_short
        pop ax
        ret
lcd_data endp

; ds:si -> null-terminated string
lcd_puts proc near
        push ax
lp_lp:
        lodsb
        or al, al
        jz lp_end
        call lcd_data
        jmp lp_lp
lp_end:
        pop ax
        ret
lcd_puts endp

lcd_init proc near
        ; >= 15 ms after vcc (3 x delay_long = ~20 ms at 5 mhz), then 3 x 38h.
        ; lcd_cmd waits only delay_short after 38h, so explicit delay_long
        ; calls provide the > 4.1 ms (after #1) and > 100 us (after #2) gaps.
        call delay_long
        call delay_long
        call delay_long
        mov al, 38h             ; function set #1: 8-bit
        call lcd_cmd
        call delay_long         ; > 4.1 ms (6.8 ms at 5 mhz)
        mov al, 38h             ; function set #2
        call lcd_cmd
        call delay_long         ; > 100 us
        mov al, 38h             ; function set #3: 8-bit, 2+ lines, 5x8
        call lcd_cmd
        mov al, 0ch             ; display on, cursor off
        call lcd_cmd
        mov al, 06h             ; entry mode: increment
        call lcd_cmd
        mov al, 01h             ; clear display
        call lcd_cmd
        call delay_long
        ret
lcd_init endp

; print signed al as "+xxc" or "-xxc" (4 chars)
lcd_put_temp proc near
        push ax
        push bx
        test al, 80h
        jz pt_pos
        neg al
        mov bl, al
        mov al, '-'
        call lcd_data
        jmp pt_dig
pt_pos:
        mov bl, al
        mov al, '+'
        call lcd_data
pt_dig:
        mov al, bl
        cmp al, 99
        jbe pt_ok
        mov al, 99
pt_ok:
        xor ah, ah
        mov bl, 10
        div bl                  ; al = tens, ah = ones
        add al, '0'
        call lcd_data
        mov al, ah
        add al, '0'
        call lcd_data
        mov al, 'C'
        call lcd_data
        pop bx
        pop ax
        ret
lcd_put_temp endp

; print bcd byte in al as 2 ascii digits
lcd_put_bcd2 proc near
        push ax
        push cx
        mov ah, al
        mov cl, 4
        shr al, cl
        add al, '0'
        call lcd_data
        mov al, ah
        and al, 0fh
        add al, '0'
        call lcd_data
        pop cx
        pop ax
        ret
lcd_put_bcd2 endp

; print unsigned 16-bit ax as 2 digits (00..99)
lcd_put_dec2 proc near
        push ax
        push bx
        cmp ax, 99
        jbe pd2_ok
        mov ax, 99
pd2_ok:
        mov bl, 10
        div bl
        add al, '0'
        call lcd_data
        mov al, ah
        add al, '0'
        call lcd_data
        pop bx
        pop ax
        ret
lcd_put_dec2 endp

refresh_lcd proc near
        push ax
        push bx
        push cx
        push dx
        push si

        ; clear display once whenever ui_mode changes
        mov al, ui_mode
        cmp al, prev_ui_md
        je ui_same
        mov prev_ui_md, al
        mov al, 01h
        call lcd_cmd
ui_same:

        cmp ui_mode, ui_live
        jne chk_m_pin
        jmp draw_live
chk_m_pin:
        cmp ui_mode, ui_pin
        je draw_pin
        cmp ui_mode, ui_menu
        je draw_menu
        cmp ui_mode, ui_logs
        je draw_logs
        jmp draw_edit

draw_pin:
        cmp pin_err_cnt, 0
        jne dp_denied

        ; line 1 (20 chars): "ADMIN ACCESS - PIN: "
        mov al, 080h
        call lcd_cmd
        mov si, offset str_pin_hdr
        call lcd_puts
        ; line 2 (20 chars): "****                " / "____                "
        mov al, 0c0h
        call lcd_cmd
        mov cl, 4
        xor bl, bl
dp_lp:
        cmp bl, pin_len
        jae dp_blank
        mov al, '*'
        jmp dp_out
dp_blank:
        mov al, '_'
dp_out:
        call lcd_data
        inc bl
        dec cl
        jnz dp_lp
        mov cx, 16
dp_pad: mov al, ' '
        call lcd_data
        loop dp_pad
        jmp dp_clr34

dp_denied:
        ; line 1 (20 chars): "ACCESS DENIED!      "
        mov al, 080h
        call lcd_cmd
        mov si, offset str_pin_bad
        call lcd_puts
        ; line 2 (20 chars): blank
        mov al, 0c0h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts

dp_clr34:
        ; lines 3 & 4 (20 chars each): blank
        mov al, 094h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        mov al, 0d4h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        jmp lcd_done

draw_menu:
        ; lines 1-2: menu options; lines 3-4: blank (all 20 chars)
        mov al, 080h
        call lcd_cmd
        mov si, offset str_menu1
        call lcd_puts
        mov al, 0c0h
        call lcd_cmd
        mov si, offset str_menu2
        call lcd_puts
        mov al, 094h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        mov al, 0d4h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        jmp lcd_done

draw_logs:
        mov al, 080h
        call lcd_cmd
        cmp log_count, 0
        jne dl_has
        mov si, offset str_nologs
        call lcd_puts
        mov al, 0c0h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        jmp dl_footer
dl_has:
        ; clamp log_view_ix < log_count
        mov al, log_view_ix
        cmp al, log_count
        jb dl_ix_ok
        xor al, al
        mov log_view_ix, al
dl_ix_ok:
        ; map chronological index (L01=oldest .. Lnn=newest) to physical nvram slot
        cmp log_count, max_logs
        jb dl_slot_ok           ; not wrapped: oldest is slot 0
        add al, log_head        ; wrapped: oldest is slot log_head
        cmp al, max_logs
        jb dl_slot_ok
        sub al, max_logs
dl_slot_ok:
        ; read 8-byte log from nvram slot al
        mov cl, 3
        shl al, cl
        add al, nvram_log
        mov dl, al
        xor bx, bx
dl_rd:
        mov al, dl
        add al, bl
        call rtc_read_reg
        mov log_rec[bx], al
        inc bx
        cmp bx, 8
        jb dl_rd

        ; line 1 (20 chars): "L01 U1 +05C 12:34:56"
        mov al, 'L'
        call lcd_data
        mov al, log_view_ix
        inc al
        xor ah, ah
        call lcd_put_dec2
        mov al, ' '
        call lcd_data
        mov al, 'U'
        call lcd_data
        mov al, log_rec[0]
        and al, 0fh
        add al, '0'
        call lcd_data
        mov al, ' '
        call lcd_data
        mov al, log_rec[1]
        call lcd_put_temp
        mov al, ' '
        call lcd_data
        mov al, log_rec[2]      ; hr
        call lcd_put_bcd2
        mov al, ':'
        call lcd_data
        mov al, log_rec[3]      ; min
        call lcd_put_bcd2
        mov al, ':'
        call lcd_data
        mov al, log_rec[4]      ; sec
        call lcd_put_bcd2

        ; line 2 (20 chars): "MM/DD  TMP DOR      "
        mov al, 0c0h
        call lcd_cmd
        mov al, log_rec[5]      ; mon
        call lcd_put_bcd2
        mov al, '/'
        call lcd_data
        mov al, log_rec[6]      ; day
        call lcd_put_bcd2
        mov al, ' '
        call lcd_data
        mov al, ' '
        call lcd_data
        test log_rec[0], 10h
        jz dl_no_tmp
        mov al, 'T'
        call lcd_data
        mov al, 'M'
        call lcd_data
        mov al, 'P'
        call lcd_data
        jmp dl_chk_dor
dl_no_tmp:
        mov al, '-'
        call lcd_data
        mov al, '-'
        call lcd_data
        mov al, '-'
        call lcd_data
dl_chk_dor:
        mov al, ' '
        call lcd_data
        test log_rec[0], 20h
        jz dl_no_dor
        mov al, 'D'
        call lcd_data
        mov al, 'O'
        call lcd_data
        mov al, 'R'
        call lcd_data
        jmp dl_l2_pad
dl_no_dor:
        mov al, '-'
        call lcd_data
        mov al, '-'
        call lcd_data
        mov al, '-'
        call lcd_data
dl_l2_pad:
        mov cx, 6
dl_p2:  mov al, ' '
        call lcd_data
        loop dl_p2

dl_footer:
        ; line 3 (20 chars): blank; line 4 (20 chars): footer
        mov al, 094h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        mov al, 0d4h
        call lcd_cmd
        mov si, offset str_log_ft
        call lcd_puts
        jmp lcd_done

draw_edit:
        ; line 1 (20 chars): "U1 LO:+02C HI:+08C  "
        mov al, 080h
        call lcd_cmd
        xor bh, bh
        mov bl, edit_unit
        mov al, 'U'
        call lcd_data
        mov al, bl
        add al, '1'
        call lcd_data
        mov al, ' '
        call lcd_data
        mov al, 'L'
        call lcd_data
        mov al, 'O'
        call lcd_data
        mov al, ':'
        call lcd_data
        mov al, edit_lo_tmp
        call lcd_put_temp
        mov al, ' '
        call lcd_data
        mov al, 'H'
        call lcd_data
        mov al, 'I'
        call lcd_data
        mov al, ':'
        call lcd_data
        mov al, edit_hi_tmp
        call lcd_put_temp
        mov al, ' '
        call lcd_data
        call lcd_data
        ; line 2 (20 chars): "1/2:LO-/+  3/4:HI-/+"
        mov al, 0c0h
        call lcd_cmd
        mov si, offset str_edit_h
        call lcd_puts
        ; line 3 (20 chars): "#:SAVE+NEXT  *:BACK "
        mov al, 094h
        call lcd_cmd
        mov si, offset str_edit_f
        call lcd_puts
        ; line 4 (20 chars): blank
        mov al, 0d4h
        call lcd_cmd
        mov si, offset str_blank20
        call lcd_puts
        jmp lcd_done

draw_live:
        ; lines 1-3 (20 chars each): "Ux:+xxC ALM R:ON    "
        xor bx, bx
dlv_lp:
        mov al, line_addrs[bx]
        call lcd_cmd

        ; "Ux:" (3 chars)
        mov al, 'U'
        call lcd_data
        mov al, bl
        add al, '1'
        call lcd_data
        mov al, ':'
        call lcd_data

        ; "+xxC " (5 chars -> 8)
        mov al, tcurr[bx]
        call lcd_put_temp
        mov al, ' '
        call lcd_data

        ; status: ALM / DOR / EXC / OK  (3 chars -> 11)
        cmp alarm_act[bx], 0
        je dlv_chk_dor
        mov al, 'A'
        call lcd_data
        mov al, 'L'
        call lcd_data
        mov al, 'M'
        call lcd_data
        jmp dlv_rly
dlv_chk_dor:
        cmp door_open[bx], 0
        je dlv_chk_exc
        mov al, 'D'
        call lcd_data
        mov al, 'O'
        call lcd_data
        mov al, 'R'
        call lcd_data
        jmp dlv_rly
dlv_chk_exc:
        cmp excur_flag[bx], 0
        je dlv_ok
        mov al, 'E'
        call lcd_data
        mov al, 'X'
        call lcd_data
        mov al, 'C'
        call lcd_data
        jmp dlv_rly
dlv_ok:
        mov al, 'O'
        call lcd_data
        mov al, 'K'
        call lcd_data
        mov al, ' '
        call lcd_data

dlv_rly:
        ; " R:ON " or " R:OFF" (6 chars -> 17)
        mov al, ' '
        call lcd_data
        mov al, 'R'
        call lcd_data
        mov al, ':'
        call lcd_data
        mov cl, bl
        mov al, relay_mask
        shr al, cl
        test al, 01h
        jz dlv_roff
        mov al, 'O'
        call lcd_data
        mov al, 'N'
        call lcd_data
        mov al, ' '
        call lcd_data
        jmp dlv_pad
dlv_roff:
        mov al, 'O'
        call lcd_data
        mov al, 'F'
        call lcd_data
        mov al, 'F'
        call lcd_data
dlv_pad:
        ; 3 trailing spaces (3 chars -> 20 exact)
        mov al, ' '
        call lcd_data
        call lcd_data
        call lcd_data

        inc bx
        cmp bx, 3
        jb dlv_lp

        ; line 4 (20 chars): page 0 = clock/prompts, pages 1-3 = unit 1-3 stats
        mov al, 0d4h
        call lcd_cmd
        cmp stat_page, 0
        jne dlv_stat

        ; page 0 (20 chars): "HH:MM:SS  *PIN #STAT"
        mov al, rtc_hr
        call lcd_put_bcd2
        mov al, ':'
        call lcd_data
        mov al, rtc_min
        call lcd_put_bcd2
        mov al, ':'
        call lcd_data
        mov al, rtc_sec
        call lcd_put_bcd2
        mov si, offset str_live_ft
        call lcd_puts
        jmp lcd_done

dlv_stat:
        ; pages 1..3 (20 chars): "Ux:+xxC/+xxC MM:SS  " (or "Ux:---C/---C MM:SS  ")
        mov bl, stat_page
        dec bl
        xor bh, bh

        mov al, 'U'
        call lcd_data
        mov al, bl
        add al, '1'
        call lcd_data
        mov al, ':'
        call lcd_data

        ; guard pre-first-ADC state: show dashes until adc_valid[bx] is set
        cmp adc_valid[bx], 0
        je dlv_no_samp
        mov al, tmin[bx]
        call lcd_put_temp
        mov al, '/'
        call lcd_data
        mov al, tmax[bx]
        call lcd_put_temp
        jmp dlv_stat_tm
dlv_no_samp:
        mov si, offset str_nosamp
        call lcd_puts

dlv_stat_tm:
        mov al, ' '
        call lcd_data

        ; convert out_secs[bx*2] -> MM:SS
        mov si, bx
        shl si, 1
        mov ax, out_secs[si]
        xor dx, dx
        mov cx, 60
        div cx                  ; ax = mm, dx = ss
        call lcd_put_dec2
        mov al, ':'
        call lcd_data
        mov ax, dx
        call lcd_put_dec2
        mov al, ' '
        call lcd_data
        call lcd_data

lcd_done:
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
refresh_lcd endp

code    ends

;--------------------------------------------------------------------
; STACK SEGMENT (Placed after CODE so it never overlaps IVT 00000h-003ffh)
;--------------------------------------------------------------------
stack   segment stack 'stack'
        dw 512 dup(?)
stack   ends

        end start
