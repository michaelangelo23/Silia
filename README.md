# 8086 Multi-Unit Cold-Storage Temperature Monitor and Alarm

**Group:** Silia (CpE 3104 - Microprocessors)
**Members:** Aaron James Monte Siat, Heaven Harley Silay, Mickel Angelo Castroverde
**Instructor:** Engr. Marlowe Edgar Burce

## Overview

An Intel **8086** minimum-mode microprocessor system (**simulated at 2 MHz in Proteus; target hardware 5 MHz via an 8284A clock generator with a 15 MHz crystal and 2.5 MHz PCLK**) supervising **three independent cold-storage units** with distinct temperature profiles, per-unit door-open detection, independent `12 V` cooling relays with integer hysteresis (`ON >= Thigh`, `OFF <= max(Thigh - 2 C, Tlow)`), a `20x4` alphanumeric LCD (`LM044L`), a PIN-protected `3x4` keypad (`MM74C922`), global and per-unit status LEDs, a gated `2.0 kHz` passive `5 V` sounder (`BZ1` / `LS1`), and battery-backed `DS12887` NVRAM configuration and excursion logging.

| Unit | Storage Profile | Default Band | Relay Hysteresis (ON / OFF) | ADC Port | KiCad Ref | Proteus Ref |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Unit 1** | Vaccine Fridge | `+2 C` to `+8 C` | `>= +8 C` / `<= +6 C` | `88H` | `U11` (`LM35`: `U13A`) | `U25` (`LM35`: `U28`) |
| **Unit 2** | Fresh Chiller | `+1 C` to `+4 C` | `>= +4 C` / `<= +2 C` | `B0H` | `U27` (`LM35`: `U13B`) | `U26` (`LM35`: `U29`) |
| **Unit 3** | Deep Freezer | `-20 C` to `0 C` (thaw band) | `>= 0 C` / `<= -2 C` | `B8H` | `U28` (`LM35`: `U13C`) | `U27` (`LM35`: `U30`) |

**Analog Sensing Notes:**
* **Unit 1 & Unit 2:** Single-supply `LM35` (`VIN- = GND`) spans `0 C` to `+127 C` (clamped at `+127 C` in firmware). The basic `LM35` single-supply accuracy floor is `+2 C`; Unit 2 uses `Tlow = +1 C` so a drop to `0 C` triggers a low-side alarm.
* **Unit 3 (Freezer):** Sensing span `-30 C` to `+70 C` (`T = min(D_ADC, 129) - 30`) via two `1N4148` ground-lift diodes + `4.7 kOhm` `+5 V` bias pull-up (`KiCad: R_FRZ3`, `Proteus: R25`) and a `10 kOhm / 2.45 kOhm` divider (`KiCad: R_FRZ1/R_FRZ2`, `Proteus: R12/R13`, `VIN- = 0.984 V`). KiCad Rev `v4.1` powers `U13C.+VS` from `+12 V` for silicon headroom (`LM35/LM35A/LM35C` grade).
* **Designator Collision Note:** `U27` is **Unit 2 ADC** in KiCad but **Unit 3 ADC** in Proteus; `U22` is **DS12887** in KiCad but **8255A #2** in Proteus. See **Annex A** of `docs/Silia_MSP_Systems_Design_v3.pdf` for the complete Proteus-to-KiCad reference designator cross-map.

## Repository Structure

```text
Silia/
|-- docs/
|   |-- Silia_MSP_Proposal_Round3.pdf           # Combined Case Study v3 + Systems Design v3 (17 pages)
|   |-- Silia_MSP_Case_Study_Report_v3.docx     # Case Study Report (v3.0, DOCX & PDF)
|   |-- Silia_MSP_Case_Study_Report_v3.pdf
|   |-- Silia_MSP_Systems_Design_v3.docx        # Systems Design Specification (v3.0, DOCX & PDF)
|   |-- Silia_MSP_Systems_Design_v3.pdf
|   |-- Silia_MSP_Proposal_Round2.pdf           # Archived Round 2 submission (13 pages)
|   |-- Silia_MSP_Case_Study_Report_v2.docx     # Archived v2.0 documents
|   |-- Silia_MSP_Case_Study_Report_v2.pdf
|   |-- Silia_MSP_Systems_Design_v2.docx
|   `-- Silia_MSP_Systems_Design_v2.pdf
|-- firmware/
|   |-- main.asm                                # 8086 MASM 6.14 firmware (2,192 lines, 54,577 B)
|   |-- Build_Firmware.bat                      # Automated build script (ml.exe + link16.exe)
|   `-- Debug/
|       `-- Debug.exe                           # Compiled 16-bit DOS MZ binary (25,548 B, CodeView)
|-- kicad/
|   |-- Silia_8086_ColdStorage.kicad_pro        # KiCad 10.0 project (Rev v4.1)
|   |-- Silia_8086_ColdStorage.kicad_sch        # Full pin-by-pin schematic (Rev v4.1, 2026-11-26)
|   |-- Silia_Project.kicad_sym                 # Project symbol library
|   |-- sym-lib-table
|   |-- Silia_8086_ColdStorage.pdf              # Vector PDF export (Rev v4.1)
|   `-- erc.rpt                                 # KiCad 10.0.4 ERC report (0 Errors, 49 Warnings)
|-- proteus/
|   |-- FinalProject.pdsprj                     # Proteus 9.2 VSM project file
|   `-- FinalProject.pdf                        # Proteus schematic PDF export
|-- schematics/                                 # Archived legacy 1-unit schematics (superseded reference)
|   |-- Silia_Proteus_Full_Circuit_Master.pdf   # Legacy 1-unit master schematic (predates 3-unit redesign)
|   `-- Silia_Proteus_Circuit_Design.pdf        # Legacy 1-unit 2-sheet schematic (differs on PA5/PA6/PC2)
|-- .gitignore
`-- README.md
```

**Note on `schematics/*.pdf` (Archived Reference):** The two PDFs in `schematics/` are archived legacy 1-unit schematics from an earlier iteration (different `PA5`/`PA6`/`PC2` assignments, legacy `SW_RST`, and `J1`/`J2` jumpers). They are preserved for historical reference only; the authoritative 3-unit schematics are `kicad/Silia_8086_ColdStorage.kicad_sch` (Rev `v4.1`, exported to `kicad/Silia_8086_ColdStorage.pdf`) and `proteus/FinalProject.pdsprj`.

**KiCad ERC Status (`kicad/erc.rpt`, KiCad `10.0.4`):** **0 Errors, 49 Warnings** with `single_global_label` and `four_way_junction` checks enabled (0 violations for both; only `SPICE model issue` and `footprint_filter` ignored). All 49 warnings are pre-existing graphical `net_not_bus_member` warnings where bus labels sit beside Zone 1-3 bus bars; all electrical nets connect via matching labels.

## I/O Port Map (`74LS138` Decoder: `U9` KiCad / `U8` Proteus)

I/O decoding checks `M/IO = 0`, `A7 = 1`, `A6 = 0`, `A0 = 0`, with `A5:A3` selecting `/Y0../Y7` (even-byte `D0-D7` transfers; `A15:A8` are not decoded, so `80H-BFH` aliases every `100H`).

| Decoder Output | Address Range | KiCad Ref | Proteus Ref | Device & Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `/Y0` | `80H-86H` | `U10` | `U20` | `8255A #1` (ctrl `90H`): Keypad (`PA0-PA3`), `DA` (`PA4`), `ACK` (`PA5` active-low); `20x4` LCD (`PB0-PB7`, `PC0=RS`, `PC1=E`); Sounder Enable (`PC3`) & Global G/Y/R LEDs (`PC4-PC6`, written via shadow register) |
| `/Y1` | `88H` | `U11` | `U25` | `ADC0804` Unit 1 Vaccine Fridge (`LM35`) |
| `/Y2` | `90H-96H` | `U14` | `U16` | `8253-5` PIT (`2.5 MHz` clock): `100.0 Hz` (`OUT0`), `1.000 Hz` tick (`OUT1` -> `IR1`), `2.0 kHz` sounder tone (`OUT2`) |
| `/Y3` | `98H-9AH` | `U15` | `U17` | `8259A` PIC (`ICW4=01H` normal EOI, Specific EOIs `60H-63H`): `IR0` (Type `20H`, combined ADC EOC), `IR1` (Type `21H`, `1 Hz`), `IR2` (Type `22H`, ORed Doors `1..3`), `IR3` (Type `23H`, Keypad `DA`) |
| `/Y4` | `A0H-A2H` | `U22` | `U13` | `DS12887` RTC + `114 B` NVRAM: index `A0H` (`AS`), data `A2H` (`/CS`); config `0EH-1FH` (`18 B`) + excursion log `20H-7FH` (`12 x 8 B = 96 B`) |
| `/Y5` | `A8H-AEH` | `U25` | `U22` | `8255A #2` (ctrl `90H`): Unit 1-3 Door Sensors (`PA0-PA2`, `1=open`), Cooling Relays (`PB0-PB2`, `1=ON`), Per-Unit Red Alarm LEDs (`PC0-PC2`) |
| `/Y6` | `B0H` | `U27` | `U26` | `ADC0804` Unit 2 Fresh Chiller (`LM35`) |
| `/Y7` | `B8H` | `U28` | `U27` | `ADC0804` Unit 3 Deep Freezer (`LM35` + `2x 1N4148` bias) |

## Firmware and Build

* **Source & Binary:** `firmware/main.asm` (`2,192` lines, `54,577` bytes, 16-bit 8086 MASM syntax) compiles cleanly (`0` errors, `0` warnings) to `firmware/Debug/Debug.exe` (`25,548` bytes, 16-bit DOS MZ with CodeView `NB09` symbols).
* **Build Command:** Run `firmware\Build_Firmware.bat` (uses MASM 6.14 `ml.exe` + 16-bit `link16.exe` from `C:\masm32\bin\` or `PATH`):
  ```cmd
  cmd /c "firmware\Build_Firmware.bat"
  ```
* **Proteus Compiler Registration:** In Proteus 9, run **System -> Compilers Configuration -> Check All** so VSM Studio detects `C:\masm32`, then compile/load `firmware\main.asm` (or point `U1` Program File to `firmware\Debug\Debug.exe`).
* **Runtime Behavior & Controls:**
  * **Default PIN:** `1234` (wrong PIN holds `ACCESS DENIED!` for `1-2 s` non-blocking via 1 Hz ticks).
  * **Default Grace Delay:** `10 s` (stored in NVRAM; `out_secs` counts every faulted second and saturates at `5999 s` = `99:59`).
  * **Keypad (`3x4`):** Live screen `#` cycles Line 4 (`HH:MM:SS` clock -> U1/U2/U3 `Tmin/Tmax` with `---C/---C` pre-first-sample guard and `MM:SS`), `*` opens PIN prompt; Admin Menu: `1` View Logs (`#` next across wrapped 12-entry ring, `*` back), `2` Reset Logs/Alarms/Stats, `3` Edit Per-Unit Limits (`1/2` Tlow `-/+`, `3/4` Thigh `-/+`, `#` Save+Next, `*` Discard+Back; signed `-55 <= Tlow < Thigh <= 99`), `*` Exit.
  * **ACK Button (`PA5`, active-low):** Falling-edge triggered and active only while at least one unit alarm is latched; silences the `2.0 kHz` sounder immediately while keeping Red LEDs ON and re-arming if another unit latches a new alarm.
  * **NVRAM Layout (`0EH-7FH`, `114 B`):** `0EH-1FH` (`18 B`) = `'S','I'` magic, `grace_lim`, 4-byte ASCII PIN, `log_head`, `log_count`, `tlow[0..2]`, `thigh[0..2]`, 3 reserved bytes (bounds-validated on boot, restoring defaults on corruption); `20H-7FH` (`96 B`) = 12 x 8-byte records (`[0]` unit `1..3` | `10H` TMP | `20H` DOR, `[1]` signed temp C, `[2..6]` BCD `hr, min, sec, mon, day`, `[7]` `grace_lim`). `Tmin`, `Tmax`, and `out_secs` are volatile in SRAM.

## Proteus 9.2 Setup Notes

* **Clocking:** Proteus 9.2 has no `8284A` model. The project runs `U1` (`8086`) at **`CLOCK = 2MHz`** (`CLOCK_EXT = 0`, internal clock) for simulation speed and **`CLK2 = 2.5MHz`** into `U16` (`8253A` `CLK0`/`CLK2`), while the target PCB design is **`5.0 MHz`** via an `8284A` (`15.0 MHz` crystal, `2.5 MHz` PCLK). The `1.000 Hz` system tick derives solely from `CLK2`, and all firmware delay loops (`>= 200 ms` RTC POR, `3x 38H` LCD init) are sized for `5 MHz` worst-case execution and work cleanly at `2-5 MHz`.
* **8086 Memory Mode:** The Proteus project uses `Internal Memory Size = 0x10000` (Cheat Mode) to execute the compiled `Debug.exe` directly on `U1`. `Debug.exe` is a relocatable DOS MZ executable and is **not** a flat EPROM image (`FFFF0H` reset vector + ROM-to-RAM data copy are future PCB work).
* **Door Sensors & ACK Switch:** `LED-IR` is absent in Proteus 9.2; `SW-SPST` switches (`SW_DOOR1..3`) with `10 kOhm` pull-ups into `LM393` comparators simulate the doors (**closed switch = Door CLOSED (`0`), open switch = Door OPEN (`1`)**). `SW1` (`ACK`) is an active-low switch on `PA5` (momentary `BUTTON` preferred; firmware falling-edge detection prevents a held switch from masking future alarms).
* **Target Simulation Calibration Notes:** Compile/load `firmware\main.asm` into `U1`, verify Unit 3 freezer offset divider `R13 = 2.45 kOhm` (`VIN- ~ 0.984 V` against `R25 = 4.7 kOhm` + `D7`/`D8`), use passive `LS1 (SOUNDER)` on `BUZZ_GATE` (matching KiCad `BZ1`), verify `U31` (`74LS00`) Motorola RTC glue nets, and keep `U17` (`8259A`) trace logging disabled.
