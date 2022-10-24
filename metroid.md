Playing [Metroid](https://www.youtube.com/channel/UCaiju86ajD19HmflYTSdHRA/home) on NES.
Some random notes

we find a good debugger:
https://fceux.com/web/help/Introduction.html

list of glitches:
https://tasvideos.org/GameResources/NES/Metroid

tons of resources:
https://tcrf.net/Metroid

fceux has a hexedit view, where we can look for clues 

- 0x14: input
- 0x30D: y coordinate


Also Metroid has been reverse engineered somehow, the assembly code is annotated:
https://www.metroid-database.com/wp-content/uploads/Metroid/m1source.txt

To cheat the game
- change y: 0x30D
- bombs: 0x1| 0x6878
- health: 0x09| 0x107 (90 health)
- missiles: 0x6879 

fceux has a "cheat" feature to do that, we can do it through a lua script as well

```lua
local HealthLo = 0x0106
local HealthHi = 0x0107
local SamusBlink = 0x70
local SamusGear = 0x6878
local gr_BOMBS  = 0x1
local gr_MARUMARI = 0x10

-- more health please
memory.writebyte(HealthLo, 0x90)
memory.writebyte(HealthHi, 0x09)

-- get some invincibility frames too
memory.writebyte(SamusBlink, 0x10)

-- give bombs
local currentGear = memory.readbyteunsigned(SamusGear)
memory.writebyte(SamusGear, OR(OR(currentGear,gr_BOMBS),gr_MARUMARI))
```

Some undocumented minor glitches
- when standing on the edge and looking up, Samus will run for a little while while falling
- enemy push while standing: will stand while falling
- pressing down while standing and falling: bounce when hitting the ground
- after morphing: hold right + pause + left + unpause: go right as long as the left button is pushed
- when a bomb explodes and Samus is hit we gain some seconds of invulnerability. code:
```
SamusBlink (0x70)
LCDFA:  lda $030A
        and #$20
        beq +++
        lda #$32  -- 0x32 frames of blinking
        sta SamusBlink
        lda #$FF
        sta $72
        lda $73
        sta $77
        beq ++
        bpl +
        jsr SFX_SamusHit
```


- door glitch is caused by the jump of 11 pixels when unmorphing:
```
    ; break out of "ball mode"
        lda ObjRadY
        clc
        adc #$08
        sta ObjRadY
        jsr CheckMoveUp
        bcc ++          ; branch if not possible to stand up
        ldx #$00
        jsr LE8BE
        stx $05
        lda #$F5  <<<-  XXX little jump by 11 pixels
        sta $04
        jsr LFD8F
        jsr LD638 <- apply little jump after exiting roll to y
        jsr LCF55
        dec AnimIndex
        jsr LD147
        lda #$04
        jmp LD144
```
- clip through decor can be achieved as well ([example](https://www.youtube.com/watch?v=4LX3CcbO5Do))
- we cannot put bomb while in the air everytime: 
```
        CheckBombLaunch:
        lda SamusGear
        lsr a
        bcc ++          ; exit if Samus doesn't have Bombs
        lda JoyFirst
        ora JoyRetrig
        asl a           ; bit 7 = status of FIRE button
        bpl ++          ; exit if FIRE not pressed
        lda $0308
        ora SamusOnElevator
        bne ++
```
Putting a bomb in the air is only allowed when
$0308, which is vertical speed, is zero.


- turning into a ball mid air don't work, see $0314 != 0
```
LD0B5:  lda SamusGear
        and #gr_MARUMARI
        beq +           ; branch if Samus doesn't have Maru Mari
        lda $0314
        bne +
    ; turn Samus into ball
        ldx SamusDir
        lda #an_SamusRoll
```

where $0314 is the result of whether Samus can move down or not:


```
        jsr CheckMoveDown       ; check if Samus obstructed DOWNWARDS
        bcc ++          ; branch if yes
+       jsr LD976
        lda SamusOnElevator
        bne ++
        lda $7D
        bne ++
        lda #$1A
        sta $0314
```


One way of changing the rom is by building an ips file, looks like this:

```
echo -e -n "PATCH" > metroid.nes.ips
# give more health at start
echo -e -n "\x01\xC9\x36\x00\x01\x06" >> metroid.nes.ips
# allow morphing into a ball mid air from a standing position. We erase a jump and put 2 "CLC" instead
echo -e -n "\x01\xD0\xCF\x00\x02\x18\x18" >> metroid.nes.ips
# allow putting a bomb anywhere in air. We load 0 instead of the gravity, and erase 1 more byte
echo -e -n "\x01\xD1\x6D\x00\x03\xA9\x00\x18"  >> metroid.nes.ips
# give 2/8 more chance to get energy
echo -e -n "\x01\xDE\x49\x00\x04\x81\x81\x81\x81"  >> metroid.nes.ips
echo -e -n EOF >> metroid.nes.ips

```

- luck and rng:

```
	lda RandomNumber1
	cmp #$10  
	bcc LDD5B  -- need a number > 0x10 
*	and #$07    
	tay
	lda ItemDropTbl,y -- we take the 3 last bits and look up a table: 80 81 89 80 81 89 81 89
	sta EnAnimFrame,x
	cmp #$80 -> is for missiles (2/8)
	bne ++ 
	ldy MaxMissilePickup
	cpy CurrentMissilePickups
	beq LDD5B
	lda MaxMissiles
	beq LDD5B
	inc CurrentMissilePickups
*       rts

*       ldy MaxEnergyPickup
	cpy CurrentEnergyPickups
	beq LDD5B
	inc CurrentEnergyPickups  -> we draw an energy
	cmp #$89 -> only 
	bne --
	lsr $00
	bcs --
```

```
ItemDropTbl:
LDE35:	.byte $80			;Missile.
LDE36:	.byte $81			;Energy.
LDE37:	.byte $89			;No item.
LDE38:	.byte $80			;Missile.
LDE39:	.byte $81			;Energy.
LDE3A:	.byte $89			;No item.
LDE3B:	.byte $81			;Energy.
LDE3C:	.byte $89			;No item.
```


- positioning sprites

```
LEA8D:*	iny				;Move to the next byte of room data which is-->
LEA8E:	lda (RoomPtr),y			;the index into the structure pointer table.
LEA90:	tax				;Transfer structure pointer index into X. 
   -- put the breakpoint at EA90, check the sequence in A
LEA91:	iny				;Move to the next byte of room data which is-->
LEA92:	lda (RoomPtr),y			;the attrib table info for the structure.
```

Useful for escape:
```

;Room #$0F
LAB12:	.byte $03			;Attribute table data.
AB13: loaded at EB23
;Room object data:
LAB13:	.byte $00, $19, $03, wall
              $01, $1A, $03, wall2
              $0E, $1A, $03, wall2
              $0F, $19, $03, wall 
              $12, $12, $01, triple
              $28
LAB23:	.byte      $12, $01, triple
              $4C, $1B, $01, double
              $51, $1A, $03, wall2
              $55, $1B, $01, double
              $5F, $03, $02, door
              $80, $19       wall
LAB33:	.byte           $03, 
              $83, $1B, $01, double
              $8B, $12, $01, triple
              $8E, $1A, $03, wall2 
              $8F, $19, $03, wall 
              $A1, $1A, $03  wall2
LAB43:	.byte $B1, $18, $03, floor
              $B8, $18, $03, floor
              $FF


;Room #$10
LAB4A:	.byte $03			;Attribute table data.
AB4B: loaded at EB5B
;Room object data:
LAB4B:	.byte $00, $19, $03,   wall
              $01, $1A, $03,   wall2
              $0E, $1A, $03,   wall2
              $0F, $19, $03,   wall
              $1A, $05, $01,   single -> move to 1B, change to triple 0x12, loaded in EB67
              $4D
LAB5B:	.byte      $05, $01,   
              $51, $1A, $03, 
              $5E, $1A, $03, 
              $80, $19, $03,   wall
              $8A, $05, $01,   single -> move to 85, change to triple 0x12, loaded in EB76
              $8F, $19         wall
LAB6B:	.byte           $03,  
              $95, $05, $01,  single -> move to 94, change to tripleo 0x12
              $A1, $1A, $03, 
              $AE, $1A, $03, 
              $CA, $05, $01, 
              $E7, $05, $01
LAB7B:	.byte $FF

```


making a stair case:
```bash
echo -e -n "PATCH" > metroid.nes.ips

# give more health at start
echo -e -n "\x01\xC9\x36\x00\x01\x06" >> metroid.nes.ips

# allow morphing into a ball mid air from a standing position. We erase a jump and put 2 "CLC" instead
echo -e -n "\x01\xD0\xCF\x00\x02\x18\x18" >> metroid.nes.ips

# allow putting a bomb anywhere in air. We load 0 instead of the gravity, and erase 1 more byte
echo -e -n "\x01\xD1\x6D\x00\x03\xA9\x00\x18"  >> metroid.nes.ips

# give 2/8 more chance to get energy
echo -e -n "\x01\xDE\x49\x00\x04\x81\x81\x81\x81"  >> metroid.nes.ips

# stair case:
echo -e -n "\x00\xEB\x76\x00\x02\x86\x12"  >> metroid.nes.ips
echo -e -n "\x00\xEB\x67\x00\x02\x2B\x12"  >> metroid.nes.ips
echo -e -n "\x00\xEB\x7C\x00\x02\x04\x12"  >> metroid.nes.ips

# kraid's health reduced from 96 to 10
echo -e -n "\x01\x16\x43\x00\x01\x0A"  >> metroid.nes.ips


echo -e -n EOF >> metroid.nes.ips
```

- boss health

Kraid has 0x60
see EnemyHitPointTbl

- items location:

```
;Maru Mari.
LA42A:	.byte $0E
LA42B:	.word $A439
LA42D:	.byte $02, $06, $02, $04,	 $96, $00  (01 96?)
```

- we could build a randomizer, exchanging items places

goal: not be blocked in any case and be able to reach the end (without door glitch)

- still did not understand how the NES is loading the ROM
