;qi.asm V0.9 QRT240524
;
;ATTINY13 - - - - - - - - - - - - - - - - - - - - - - - - - -
;fuse bits  76543210   low
;SPIEN      0|||||||   (default on)
;EESAVE      1||||||   (default off)
;WDTON        1|||||   (default off)
;CKDIV8        1||||   no clock div during startup
;SUT1..0        00||   00 - 14 CK / 01 - 14 CK + 4 ms /  / 10 - 14 CK + 64 ms
;CKSEL1..0        10   01 - 4.8 / 10 - 9.6 MHz system clock
;           01110010   0x72
;
;fuse bits     43210   high
;SELFPRGEN     1||||   (default off)
;DWEN           1|||   (default off)
;BODLEVEL1..0    10|   00 - 4.3 / 01 - 2.7 / 10 - 1.8 V / 11 - default off
;RSTDISBL          1   (default off)
;              11101   0xfd
;
;V0.9  initial version
;
;-------------------------------------------------------------------------------
;       logic           MOSFET      ground              U load      
; 0     negative        P           uC                  uC          
; 1     positive        N           drain of MOSFET     QI          
.define LOADLOGIC   1                   

;-------------------------------------------------------------------------------

;.device ATtiny13A
.include "tn13Adef.inc"

;-------------------------------------------------------------------------------

.cseg
.org $0000
rjmp main                               ;Reset Handler
;.org $0001
;rjmp EXT_INT0                           ;External Interrupt0 Handler
;.org $0002
;rjmp PCINT0                             ;Pin Change Interrrupt Handler
;.org $0003
;rjmp TIM0_OVF                           ;Timer0 Overflow Handler
;.org $0004
;rjmp EE_RDY                             ;EEPROM Ready Handler
;.org $0005
;rjmp ANA_COMP                           ;Analog Comparator Handler
;.org $0006
;rjmp TIM0_COMPA                         ;Timer0 Compare A
;.org $0007
;rjmp TIM0_COMPB                         ;Timer0 CompareB Handler
;.org $0008
;rjmp WATCHDOG                           ;Watchdog Interrupt Handler
;.org $0009
;rjmp ADC                                ;ADC Conversion Handler

;-------------------------------------------------------------------------------

.def    a0          =   r0              ;main registers set a
.def    a1          =   r1
.def    a2          =   r2
.def    a3          =   r3
.def    a4          =   r24             ;immediate
.def    a5          =   r25
.def    a6          =   r22
.def    a7          =   r23

.def    c0          =   r4              ;main register set c
.def    c1          =   r5
.def    c2          =   r6
.def    c3          =   r7
.def    c4          =   r16             ;immediate
.def    c5          =   r17
.def    c6          =   r18
.def    c7          =   r19

.def    srsave      =   r14             ;status register save
.def    NULR        =   r15             ;NULL value register
.def    FLAGR       =   r21             ;flag register

.def    bitState    =   r6              ;c2
.def    checkSum    =   r7              ;c3

.def    adcvL       =   r8              ;ADC current value
.def    adcvH       =   r9              ;

.def    sysTicL     =   r10             ;system ticker
.def    sysTicH     =   r11             ;
.def    recPowCnt   =   r12             ;received power cycle counter

.def    state       =   r20             ;state

;-------------------------------------------------------------------------------
;flags in FLAGR

;-------------------------------------------------------------------------------

.equ    QIP         =   PORTB           ;QI port
.equ    QIPP        =   PINB            ;   pinport
.equ    QIAD        =   PINB3           ;   ADC         in
.equ    QISIG       =   PINB4           ;               out

.equ    CTRLP       =   PORTB           ;control port
.equ    LOAD        =   PINB0           ;load           out
.equ    LED         =   PINB2           ;LED            out (positive logic)

;-------------------------------------------------------------------------------

.equ    data        =   SRAM_START

;-------------------------------------------------------------------------------
;Uad = Uqi / (R1 + R2) * R2
;Uad = Uref / 1023 * AD
;AD  = Uad * 1023 / Uref
;AD  = Uqi / (R1 + R2) * R2 * 1023 / Uref 
;
;AD = Uqi / (R1 + R2) * R2 * 1023 / Uref
;R1 = 47 k, R2 = 4.7 k, Uref = 1.1 V

.equ    DETECT_THRES        =   169             ;2.0 V
.equ    PING_THRES          =   296             ;3.5 V
.equ    TARGET_LEVEL        =   566             ;6.7 V      (Utarget - 78L05 dropout 1.7 V = 5 V)
.equ    ERROR_THRES         =   4               ;0.05 V

.equ    STATE_IDLE          =   0               ;state idle
.equ    STATE_PING          =   1               ;      ping
.equ    STATE_IDENT         =   2               ;      identification
.equ    STATE_CONF          =   3               ;      configuration
.equ    STATE_POWC          =   4               ;      power control
.equ    STATE_POWR          =   5               ;            receive
.equ    STATE_END           =   6               ;      end

.equ    PREAMBLE_BITS       =   16              ;number of preamble bits
.equ    EXTRA_PADDING       =   5               ;extra padding len
.equ    REC_POW_CYC         =   8               ;receive power cycle

;-------------------------------------------------------------------------------
;len, data ..., zero padding

sigStre:
.DB     2, 0x01, 0xff, 0

ident:
.DB     8, 0x71, 0x11, 0x10, 0x20, 0x01, 0x02, 0x03, 0x04, 0

config:
.DB     6, 0x51, 10, 0x00, 0x00, 0x43, 0x00, 0

conErr:
.DB     2, 0x03, 0x00, 0

recPow:
.DB     2, 0x04, 128, 0

endPow:
.DB     2, 0x02, 0x01, 0

;-------------------------------------------------------------------------------

main:
        ldi     a4,low(RAMEND)          ;set stack pointer
        out     SPL,a4                  ;to top of RAM


.if LOADLOGIC == 0
;                    --543210
        ldi     a4,0b00000001           ;LOAD off
        out     PORTB,a4                ;
.else
;                    --543210
        ldi     a4,0b00000000           ;LOAD off
        out     PORTB,a4                ;
.endif

;                    --543210
        ldi     a4,0b00010101           ;outputs LED, QISIG, LOAD
        out     DDRB,a4                 ;

        sbi     ACSR,ACD                ;analog comparator off

        clr     ZH                      ;clear registers
        ldi     ZL,29                   ;r0..29 = 0, ZL = $ff, ZH = 0
        st      Z,ZH                    ;
        dec     ZL                      ;
        brpl    PC-2                    ;

        ldi     ZL,low(SRAM_START)      ;clear SRAM
        st      Z+,NULR                 ;
        cpi     ZL,low(RAMEND)          ;
        brne    PC-2                    ;        

        ldi     a4,(1<<CLKPCE)          ;clock division factor 1
        out     CLKPR,a4                ;
        out     CLKPR,NULR              ;

        ldi     a4,(1<<REFS0|1<<MUX1|1<<MUX0)   ;internal reference, ADC3 PB3
        out     ADMUX,a4                        ;

        ldi     a4,(1<<ADEN|1<<ADPS2|1<<ADPS1)  ;ADC enable, DIV 64 -> 150 kHz ADC clock (max 200 kHz)
        out     ADCSRA,a4

        ; sei                             ;enable IRs

;- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

m00:    rcall   sysLed                  ;handle system LED

; -  -  -  -  -  -  -  -  -  -  -  -  -

        rcall   adcRead                 ;ADC >= detect threshold?
        ldi     a4,low(DETECT_THRES)    ;
        ldi     a5,high(DETECT_THRES)   ;
        cp      adcvL,a4                ;    
        cpc     adcvH,a5                ;
        brsh    q00                     ;yes, jump
        ldi     state,STATE_IDLE        ;state = idle

.if LOADLOGIC == 0                      ;drop load while negotiation  
        sbi     CTRLP,LOAD
.else
        cbi     CTRLP,LOAD
.endif

; -  -  -  -  -  -  -  -  -  -  -  -  -

q00:    cpi     state,STATE_IDLE        ;idle state?
        brne    q10                     ;no, jump

        ldi     a4,low(PING_THRES)      ;ADC >= ping threshold
        ldi     a5,high(PING_THRES)     ;
        cp      adcvL,a4                ;    
        cpc     adcvH,a5                ;
        brlo    m00                     ;no, main loop     
        ldi     state,STATE_PING        ;next state ping
        rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

q10:    cpi     state,STATE_PING        ;ping state?
        brne    q20                     ;no, jump

        ldi     ZL,low(sigStre<<1)      ;send signal strength max
        ldi     ZH,high(sigStre<<1)     ;
        rcall   prepComTx               ;

        ldi     state,STATE_IDENT       ;next state ident
        rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

 q20:   cpi     state,STATE_IDENT       ;ident state?
        brne    q30                     ;no, jump

        ldi     ZL,low(ident<<1)        ;send signal strength max
        ldi     ZH,high(ident<<1)       ;
        rcall   prepComTx               ;

        ldi     state,STATE_CONF        ;next state config
        rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

q30:    cpi     state,STATE_CONF        ;config state?
        brne    q40                     ;no, jump

        ldi     ZL,low(config<<1)       ;send signal strength max
        ldi     ZH,high(config<<1)      ;
        rcall   prepComTx               ;

        ldi     a4,(REC_POW_CYC - 1)    ;set first received power cycle
        mov     recPowCnt,a4            ;
        ldi     state,STATE_POWC        ;next state power control
        rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

q40:    cpi     state,STATE_POWC        ;power control state?
        brne    q50                     ;no, main loop

        ldi     a7,0                    ;assume no correction

        ldi     a4,low(TARGET_LEVEL)    ;target - adv value
        ldi     a5,high(TARGET_LEVEL)   ;
        sub     a4,adcvL                ;
        sbc     a5,adcvH                ;
        in      a0,SREG                 ;store C
        brcc    q41                     ;<0? no jump

        com     a5                      ;16-bit neg
        neg     a4                      ;
        sbci    a5,-1                   ;

q41:    cpi     a4,ERROR_THRES          ;>= error threshold?
        cpc     a5,NULR                 ;
        brlo    q42                     ;no, no correction

        ldi     a7,1                    ;assume correction = 1
        sbrc    a0,SREG_C               ;negative result?
        neg     a7                      ;yes, -correction

q42:    ldi     ZL,low(conErr<<1)       ;prepare error command
        ldi     ZH,high(conErr<<1)      ;
        rcall   prepComDaTx             ;correction in a7

        inc     recPowCnt               ;received power cycle counter
        mov     a4,recPowCnt            ;
        cpi     a4,REC_POW_CYC          ;
        brlo    q49                     ;next state power received?
        ldi     state,STATE_POWR        ;yes, set state
q49:    rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

q50:    cpi     state,STATE_POWR        ;power received state?
        brne    q59                     ;no, main loop

        ldi     ZL,low(recPow<<1)       ;prepare received power command
        ldi     ZH,high(recPow<<1)      ;
        rcall   prepComTx               ;       

.if LOADLOGIC == 0                      ;take up load after negotiation 
        cbi     CTRLP,LOAD
.else
        sbi     CTRLP,LOAD
.endif

        clr     recPowCnt               ;reset received power cycle counter
        ldi     state,STATE_POWC        ;next state power correction
q59:    rjmp    m00                     ;main loop

; -  -  -  -  -  -  -  -  -  -  -  -  -

; q60:    cpi     state,STATE_END         ;end state?
;         brne    q69                     ;no, main loop
; 
;         ldi     ZL,low(endPow<<1)       ;prepare end power command
;         ldi     ZH,high(endPow<<1)      ;
;         rcall   prepComTx               ;       
; 
; q69:    rjmp    m00                     ;main loop

;-------------------------------------------------------------------------------

adcRead:
        sbi     ADCSRA,ADSC                 ;ADC start    

        sbic    ADCSRA,ADSC                 ;wait for conversion ready
        rjmp    PC-1                        ;

        in      adcvL,ADCL                  ;store current value
        in      adcvH,ADCH                  ;
        ret

;-------------------------------------------------------------------------------
;command pointer in ZH:ZL -> len and data in SRAM

prepCom:
        ldi     XL,data                     ;copy command to SRAM
        lpm     c5,Z+                       ;len
        st      X+,c5                       ;
pc01:   lpm     c4,Z+                       ;data
        st      X+,c4                       ;
        dec     c5                          ;
        brne    pc01                        ;

        ret

prepComDaTx:
        rcall   prepCom
        st      -X,a7
        rjmp    txPacket

prepComTx:
        rcall   prepCom

;- - - - - - - - - - - - - - - - - - - -
;len and data in SRAM

txPacket:
        ldi     c4,PREAMBLE_BITS            ;send preamble
tx01:   sbi     QIP,QISIG                   ;
        rcall   delay_250us                 ;
        cbi     QIP,QISIG                   ;
        rcall   delay_250us                 ;
        dec     c4                          ;
        brne    tx01                        ;

        clr     bitState                    ;reset bit state
        clr     checkSum                    ;      checksum

        ldi     XL,data                     ;send data
        ld      c5,X+                       ;len
tx02:   ld      c4,X+                       ;data
        eor     checkSum,c4                 ;
        rcall   txByte                      ;
        dec     c5                          ;
        brne    tx02                        ;

        mov     c4,checkSum                 ;send checksum
        rcall   txByte                      ;

        clr     bitState                    ;end packet with LOW
        ldi     c4,(1 + EXTRA_PADDING)      ;+ extra padding
tx03:   rcall   writeBitState               ;
        dec     c4                          ;
        brne    tx03                        ;

        ret

;---------------------------------------
;byte in c4

txByte:
        rcall   comWriteBitState            ;write start bit
        rcall   writeBitState               ;

        clr     c7                          ;reset parity
        ldi     c6,1                        ;8 bit transfer with shift counter
tb01:   rcall   comWriteBitState            ;invert and write bitstate
        mov     c0,c4                       ;copy data byte
        and     c0,c6                       ;mask with shift counter
        breq    PC+3                        ;result != 0?
        inc     c7                          ;yes, parity++
        com     bitState                    ;     invert bitstate
        rcall   writeBitState               ;write bitstate
        lsl     c6                          ;advance shift counter
        brcc    tb01                        ;all bits? no, loop

        rcall   comWriteBitState            ;write parity

        sbrs    c7,0                        ;parity even?
        com     bitState                    ;yes, invert bitstate
        rcall   writeBitState               ;write bitstate

        rcall   comWriteBitState            ;write stop bit

;- - - - - - - - - - - - - - - - - - - 

comWriteBitState:
        com     bitState

writeBitState:
        sbrc    bitState,0
        sbi     QIP,QISIG
        sbrs    bitState,0
        cbi     QIP,QISIG

;- - - - - - - - - - - - - - - - - - - 

delay_250us:
        ldi     ZH,6
        ldi     ZL,132
        dec     ZL
        brne    PC-1
        dec     ZH
        brne    PC-4

        ret

; delay_10ms:
;         ldi     ZH,125
;         ldi     ZL,255
;         dec     ZL
;         brne    PC-1
;         dec     ZH
;         brne    PC-4

;         ret

;-------------------------------------------------------------------------------

sysLed:
        inc     sysTicL                 ;sysTic++
        brne    PC+2
        inc     sysTicH

        mov     a4,sysTicH              ;copy sysTciH

; -  -  -  -  -  -  -  -  -  -  -  -  -

        cpi     state,STATE_IDLE        ;idle state?
        brne    sl01                    ;no jump

        andi    a4,0b00111111           ;-    -    -    -
        cpi     a4,0b00111111
        breq    slon
        rjmp    sloff

; -  -  -  -  -  -  -  -  -  -  -  -  -

sl01:   cpi     state,STATE_POWC        ;negotiation states?
        brsh    slon                    ;no, must be a power state -> ------

        andi    a4,0b00100000           ;- - - - -
        breq    slon

; -  -  -  -  -  -  -  -  -  -  -  -  -

sloff:  cbi     CTRLP,LED
        ret

slon:   sbi     CTRLP,LED
        ret
