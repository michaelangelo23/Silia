# 8086 Multi-Unit Cold-Storage Temperature Monitor and Alarm

**Group:** Silia (CpE 3104 - Microprocessors)  
**Members:** Aaron James Monte Siat, Heaven Harley Silay, Mickel Angelo Castroverde  
**Instructor:** Engr. Marlowe Edgar Burce  

## Overview

An Intel **8086** minimum-mode (`5 MHz`) microprocessor system supervising **three independent cold-storage units** with distinct temperature profiles, per-unit door-open detection, independent `12 V` cooling relays, audible/visual alarms, a `20x4` alphanumeric LCD (`LM044L`), a PIN-protected `3x4` keypad (`MM74C922`), and battery-backed `DS12887` NVRAM excursion logging.

| Unit | Storage Profile | Target Range | ADC Port |
| :--- | :--- | :--- | :--- |
| **Unit 1** | Vaccine Fridge | `+2 °C` to `+8 °C` | `88H` (`U11 ADC0804`) |
| **Unit 2** | Fresh Chiller | `0 °C` to `+4 °C` | `B0H` (`U27 ADC0804`) |
| **Unit 3** | Deep Freezer | `-20 °C` to `0 °C` | `B8H` (`U28 ADC0804`, biased `-30 °C` to `+70 °C`) |

## Repository Structure

```text
Silia/
├── docs/
│   ├── Silia_MSP_Proposal_Round2.pdf          # Combined Case Study + Systems Design (13 pages)
│   ├── Silia_MSP_Case_Study_Report_v2.pdf     # Case Study Report (PDF & DOCX)
│   ├── Silia_MSP_Case_Study_Report_v2.docx
│   ├── Silia_MSP_Systems_Design_v2.pdf        # Systems Design Specification (PDF & DOCX)
│   └── Silia_MSP_Systems_Design_v2.docx
├── schematics/
│   ├── Silia_Proteus_Full_Circuit_Master.pdf  # Full schematic + pin-to-pin netlist
│   └── Silia_Proteus_Circuit_Design.pdf       # 2-sheet detailed schematic
├── proteus/
│   └── FinalProject.pdsprj                  # Proteus 9.2 project file
├── .gitignore
└── README.md
```

## I/O Port Map (`U9 74LS138`)

| Decoder Output | Address Range | Device | Purpose |
| :--- | :--- | :--- | :--- |
| `/Y0` | `80H–86H` | `U10 (8255A #1)` | Keypad (`PA0–PA4`), `ACK` (`PA5`), `20x4` LCD (`PB0–PB7`, `PC0–PC1`), Buzzer & Status LEDs (`PC3–PC6`) |
| `/Y1` | `88H` | `U11 (ADC0804)` | Unit 1 Temperature (`LM35`) |
| `/Y2` | `90H–96H` | `U14 (8253A)` | `100 Hz` (`OUT0`), `1 Hz` tick (`OUT1` -> `IR1`), `2.0 kHz` buzzer tone (`OUT2`) |
| `/Y3` | `98H–9AH` | `U15 (8259)` | `IR0` (Combined ADC EOC), `IR1` (`1 Hz`), `IR2` (ORed Doors `1..3`), `IR3` (Keypad `DA`) |
| `/Y4` | `A0H–A2H` | `U22 (DS12887)` | RTC + `114 B` battery-backed NVRAM |
| `/Y5` | `A8H–AEH` | `U25 (8255A #2)` | Unit 1–3 Doors (`PA0–PA2`), Cooling Relays (`PB0–PB2`), Unit Alarm LEDs (`PC0–PC2`) |
| `/Y6` | `B0H` | `U27 (ADC0804)` | Unit 2 Temperature (`LM35`) |
| `/Y7` | `B8H` | `U28 (ADC0804)` | Unit 3 Temperature (`LM35` + `2x 1N4148` bias) |

## Proteus 9.2 Setup Notes

* **Clocking:** Proteus 9.2 has no `8284A` model; use `CLOCK`/`DCLOCK` generators (`5.0 MHz` on `8086 CLK`, `2.5 MHz` on `8253A CLK0/CLK2`).
* **8086 Memory Mode:** Set `Internal Memory Size = 0x00000` when simulating with external `2764` EPROM (`FC000H–FFFFFH`) and `6264` SRAM (`00000H–03FFFH`), or `0x10000` to load a compiled `.EXE` directly onto `U1`.
* **Door Sensors:** `LED-IR` is absent in Proteus 9.2; `SW-SPST` (`SW_DOOR1..3`) with `10 kΩ` pull-ups into `LM393` comparators is used instead.
