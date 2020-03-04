; DZEMMD.ASM--
; Copyright (C) 2012 Doszip Developers
;
; Doszip Expanded Memory Manager
;
; Change history:
; 2012-12-12 - created
; 2012-12-29 - fixed Alter Page Map & Call (Japheth)
; 2012-12-30 - added clipboard functions
; 2013-01-16 - fixed bug in Exchange Memory Region (5701h)
;
    .386
    .model flat
    option casemap:none

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

VERSION         equ 0106h
USEDOSZIP       equ 1
USECLIPBOARD    equ 1

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

includelib kernel32.lib
includelib ntvdm.lib
ifdef USECLIPBOARD
includelib user32.lib
endif

; kernel32.dll

GMEM_FIXED      equ 0
GMEM_DDESHARE   equ 2000h
GMEM_MOVEABLE   equ 2h
GMEM_ZEROINIT   equ 40h

GlobalFree      proto stdcall :dword
GlobalAlloc     proto stdcall :dword, :dword
ifdef USECLIPBOARD
GlobalLock      proto stdcall :dword
GlobalUnlock    proto stdcall :dword
GlobalSize      proto stdcall :dword
GetLastError    proto stdcall

; user32.dll

OpenClipboard   proto stdcall :dword
CloseClipboard  proto stdcall
EmptyClipboard  proto stdcall
GetClipboardData proto stdcall :dword
SetClipboardData proto stdcall :dword, :dword

endif

; ntvdm.exe

getBX       proto stdcall
getCX       proto stdcall
getSI       proto stdcall
getBP       proto stdcall
getSP       proto stdcall
getDI       proto stdcall
getIP       proto stdcall
getES       proto stdcall
getDS       proto stdcall
getCS       proto stdcall
getSS       proto stdcall
getDX       proto stdcall
setAL       proto stdcall :dword
setAH       proto stdcall :dword
setAX       proto stdcall :dword
setBX       proto stdcall :dword
setCX       proto stdcall :dword
setDX       proto stdcall :dword
setSP       proto stdcall :dword
setCS       proto stdcall :dword
setIP       proto stdcall :dword
MGetVdmPointer  proto stdcall :dword, :dword, :dword
VDDSimulate16   proto stdcall

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

EMMPAGES    equ 4
EMMPAGE     equ 4000h
MAXPAGES    equ 4000h
MAXHANDLES  equ 255
MAXMAPLEVEL equ 8
EMMH_INUSE  equ 01h


HANDLE      STRUC
memp        dd ?
size        dd ?
name        db 8 dup(?)
HANDLE      ENDS

EMAP        STRUC
maph        dd EMMPAGES dup(?)
mapp        dd EMMPAGES dup(?)
EMAP        ENDS

SIZESAVEARRAY equ EMAP

    .data
    ALIGN       4
    reg_AX      dd ?
    reg_BX      dd ?
    reg_CX      dd ?
    reg_DX      dd ?
    reg_SI      dd ?
    reg_DI      dd ?
    emm_page    dd ?
    emm_label   dd ?
    emm_seg16   dd ?
    emm_seg32   dd ?
    emmh        HANDLE <0,0,<'SYSTEM'>>
    emmh1       HANDLE MAXHANDLES-1 dup(<?>)
    emm_flag    db MAXHANDLES+1 dup(?)
    emm_maplevel dd ?
    emm_maph    dd EMMPAGES dup(?)
    emm_mapp    dd EMMPAGES dup(?)
    emm_tmph    dd EMMPAGES*2*MAXMAPLEVEL dup(?)
    emm_tmp0    dd MAXMAPLEVEL dup(?)
ifdef USECLIPBOARD
    ClipboardIsOpen dd ?
endif

    .code

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    assume  edx:ptr HANDLE

emm_needhandle proc
    .if !edx || edx >= MAXHANDLES
        pop eax
        jmp emm_error_83
    .endif
emm_needhandle endp

emm_getesdi proc uses edx
    push eax
    shl getES(),16
    mov ax,di
    pop edx
    mov edi,MGetVdmPointer(eax, edx, 0)
    ret
emm_getesdi endp

emm_getdssi proc uses edx
    push eax
    shl getDS(),16
    mov ax,si
    pop edx
    mov esi,MGetVdmPointer(eax, edx, 0)
    ret
emm_getdssi endp

emm_gethandle proc
    xor eax,eax
    mov edx,offset emmh1
    mov ecx,1
    .repeat
        .if emm_flag[ecx] == al
            .return edx
        .endif
        add edx,HANDLE
        inc ecx
    .until ecx >= MAXHANDLES
    ret
emm_gethandle endp

;----------------------------------------------------------
; Allocate Pages
;----------------------------------------------------------

AllocatePages proc uses ebx edx
    shl ebx,14
    .if GlobalAlloc(GMEM_FIXED, ebx)
        mov ecx,ebx
    .endif
    ret
AllocatePages endp

;----------------------------------------------------------
; Map/Unmap Handle Page
; AL = physical_page_number
; BX = logical_page_number
; DX = emm_handle
;----------------------------------------------------------

; - copy bytes from frame segment to logical page

emm_copymap proc uses edx
    mov edx,ebx
    mov ecx,EMMPAGE
    .repeat
        repe cmpsb
        .break .ifz
        mov eax,ecx
        sub eax,EMMPAGE
        not eax
        add eax,edx     ; target offset in lg page
        mov ebx,esi
        dec ebx         ; start source
        repne cmpsb     ; get size of string
        .ifz
            inc ecx
            dec edi
            dec esi
        .endif
        push ecx
        mov ecx,esi
        sub ecx,ebx
        xchg eax,edi
        xchg ebx,esi
        rep movsb
        pop ecx
        mov edi,eax
        mov esi,ebx
    .until !ecx
    ret
emm_copymap endp

emm_pushmap proc uses esi edi ebx edx eax
    sub edx,edx
    mov edi,emmh.memp
    mov esi,emm_seg32
    .repeat
        .if emm_maph[edx]
            mov ebx,emm_mapp[edx]
            emm_copymap()
        .else
            add esi,EMMPAGE
            add edi,EMMPAGE
        .endif
        add edx,4
    .until edx == SIZESAVEARRAY/2
    ret
emm_pushmap endp

emm_mappage:
    movzx eax,al
    mov emm_page,eax
    .if al >= EMMPAGES
        mov ah,8Bh
        ret
    .endif
    .if !edx && bx != -1
        mov ah,8Ah
        ret
    .endif
    .if bx == -1
        jmp emm_unmappage
    .endif
    .if edx >= MAXHANDLES
        mov ah,8Ah
        ret
    .endif
    shl eax,14              ; EDI to frame segment
    mov edi,emm_seg32
    add edi,eax
    shl edx,4               ; EDX to handle
    add edx,offset emmh
    mov esi,[edx].memp      ; ESI to logical page
    .if esi
        mov ecx,esi
        add ecx,[edx].size
        mov eax,ebx
        shl eax,14
        add esi,eax
        mov eax,esi
        add eax,EMMPAGE
        .if ecx < eax
        mov ah,8Ah
        .else
        sub eax,eax
        .endif
    .else
        mov ah,8Ah
    .endif
    .if ah
        ret
    .endif
    emm_pushmap()
    mov ebx,emm_page
    shl ebx,2
    mov emm_maph[ebx],edx
    mov emm_mapp[ebx],esi
    mov ecx,EMMPAGE/4
    rep movsd
    mov esi,emm_mapp[ebx]   ; extra copy needed for compare..
    shl ebx,12
    mov edi,emmh.memp
    add edi,ebx
    mov ecx,EMMPAGE/4
    rep movsd
    sub eax,eax
    ret

emm_unmappage:
    mov ebx,eax
    shl ebx,2
    sub eax,eax
    mov edx,emm_maph[ebx]
    mov emm_maph[ebx],eax       ; - unmap page
    .if edx && [edx].memp != eax
        mov esi,emm_seg32
        mov edi,emm_mapp[ebx]
        .if esi && edi
            mov ecx,ebx
            shl ecx,12
            add esi,ecx         ; copy the frame to buffer
            mov edx,edi         ; save logical page address
            mov ebx,emmh.memp
            add ebx,ecx
            xchg ebx,edi
            emm_copymap()
            sub eax,eax
            mov ebx,emm_seg32
            .repeat             ; find dublicate address
                .if emm_maph[eax]
                    .if edx == emm_mapp[eax]
                        mov edi,ebx
                        mov esi,edx
                        mov ecx,EMMPAGE/4
                        rep movsd
                    .endif
                .endif
                add eax,4
                add ebx,EMMPAGE
            .until eax == SIZESAVEARRAY/2
        .endif
    .endif
    sub eax,eax
    ret

emm_updatemap proc uses edi ecx eax
    sub eax,eax
    mov ecx,EMMPAGES
    mov edi,offset emm_maph
    .repeat
        mov edx,[edi]
        .if edx && [edx].memp == eax
            mov [edi],eax
        .endif
        add edi,4
    .untilcxz
    ret
emm_updatemap endp

emm_popmap proc uses esi edi ebx ecx eax
    xor eax,eax
    mov ebx,emm_seg32
    .if ebx
        .repeat
            .if emm_maph[eax]
                mov esi,emm_mapp[eax]
                mov edi,ebx
                mov ecx,EMMPAGE/4
                rep movsd
            .endif
            add eax,4
            add ebx,EMMPAGE
        .until  eax == SIZESAVEARRAY/2
    .endif
    ret
emm_popmap endp

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;----------------------------------------------------------
emm_01:         ; Get Status                            40h
;----------------------------------------------------------
    setAX(1)    ; Signature: 0001
    ret

;----------------------------------------------------------
emm_02:         ; Get Page Frame Segment Address        41h
;----------------------------------------------------------
    .if emm_seg16
        setBX(emm_seg16)
        jmp emm_success
    .endif
    jmp emm_error_84

;----------------------------------------------------------
emm_03:         ; Get Unallocated Page Count            42h
;----------------------------------------------------------
    xor ebx,ebx
    mov ecx,MAXHANDLES-1
    mov edx,offset emmh1
    .repeat
        .if [edx].memp
            mov eax,[edx].size
            shr eax,14
            add ebx,eax
        .endif
        add edx,HANDLE
    .untilcxz
    mov eax,MAXPAGES
    .if ebx > eax
        sub eax,eax
    .else
        sub eax,ebx
    .endif
    setBX(eax)      ; unallocated pages
    setDX(MAXPAGES) ; total pages
    jmp emm_success

;----------------------------------------------------------
emm_04:         ; Allocate Pages                        43h
;----------------------------------------------------------
    .if !ebx
        jmp emm_error_89
    .endif

;----------------------------------------------------------
emm_27:         ; Allocate Standard Pages             5A00h
                ; Allocate Raw Pages                  5A01h
;
; BX = num_of_pages_to_alloc
;
;----------------------------------------------------------
    .if emm_gethandle()
        mov emm_flag[ecx],EMMH_INUSE
        .if !ebx
            setDX(ecx)
            jmp emm_success
        .endif
        mov edi,eax
        mov esi,ecx
        emm_pushmap()
        .if AllocatePages()
            mov [edx].memp,eax
            mov [edx].size,ecx
            setDX(esi)
            jmp emm_success
        .endif
        jmp emm_error_87
    .endif
    jmp emm_error_85

;----------------------------------------------------------
emm_05:         ; Map/Unmap Handle Page                 44h
;
; AL = physical_page_number
; BX = logical_page_number
; DX = emm_handle
;----------------------------------------------------------
    .if emm_mappage()
        jmp emm_setAX
    .endif
    jmp emm_success

;----------------------------------------------------------
emm_06:         ; Deallocate Pages                      45h
;----------------------------------------------------------
    .if !edx
        jmp emm_success
    .endif
    .if edx < MAXHANDLES
        mov emm_flag[edx],0
        shl edx,4
        add edx,offset emmh
        mov edi,edx
        .if [edx].memp
            GlobalFree([edx].memp)
        .endif
        mov edx,edi
        sub eax,eax
        mov [edx].memp,eax
        mov [edx].size,eax
        mov edi,eax
        mov ecx,EMMPAGES
        .repeat
            .if emm_maph[edi] == edx
                mov emm_maph[edi],eax
            .endif
            add edi,4
        .untilcxz
        mov [edx+8],eax
        mov [edx+12],eax
        jmp emm_success
    .endif
    jmp emm_error_83

;----------------------------------------------------------
emm_07:         ; Get Version                           46h
;----------------------------------------------------------
    setAX(0040h)
    ret

;----------------------------------------------------------
emm_08:         ; Save Page Map                         47h
;----------------------------------------------------------
    cmp emm_maplevel,MAXMAPLEVEL-1
    jae emm_error_8C
    inc emm_maplevel
    emm_pushmap()
    mov esi,offset emm_maph
    mov edi,offset emm_tmph
    mov ecx,EMAP * MAXMAPLEVEL - 1
    add esi,ecx
    add edi,ecx
    inc ecx
    std
    rep movsb
    cld
    .if GlobalAlloc(GMEM_FIXED, EMMPAGES*EMMPAGE*2)
        mov edi,eax
        mov eax,emm_maplevel
        dec eax
        shl eax,2
        mov emm_tmp0[eax],edi
        mov esi,emmh.memp
        mov ecx,(EMMPAGES*EMMPAGE)/4
        rep movsd
        mov esi,emm_seg32
        mov ecx,(EMMPAGES*EMMPAGE)/4
        rep movsd
    .endif
    jmp emm_success

;----------------------------------------------------------
emm_09:         ; Restore Page Map                      48h
;----------------------------------------------------------
    cmp emm_maplevel,0
    je  emm_error_8C
    emm_pushmap()
    dec emm_maplevel
    mov edi,offset emm_maph
    mov esi,offset emm_tmph
    mov ecx,EMAP * MAXMAPLEVEL
    rep movsb
    mov eax,emm_maplevel
    shl eax,2
    mov esi,emm_tmp0[eax]
    mov emm_tmp0[eax],0
    .if esi
        mov ebx,esi
        mov edi,emmh.memp
        mov ecx,(EMMPAGES*EMMPAGE)/4
        rep movsd
        mov edi,emm_seg32
        mov ecx,(EMMPAGES*EMMPAGE)/4
        rep movsd
        GlobalFree(ebx)
    .endif
    emm_updatemap()
    emm_popmap()
    jmp emm_success

;----------------------------------------------------------
emm_10:         ; Reserved                              49h
emm_11:         ; Reserved                              4Ah
    jmp emm_error_84

;----------------------------------------------------------
emm_12:         ; Get Handle Count                      4Bh
;----------------------------------------------------------
    mov eax,1
    mov ecx,MAXHANDLES-1
    mov edx,offset emmh1
    .repeat
        .if [edx].memp
            inc eax
        .endif
        add edx,HANDLE
    .untilcxz
    setBX(eax)
    jmp emm_success

;----------------------------------------------------------
emm_13:         ; Get Handle Pages                      4Ch
;----------------------------------------------------------
    .if edx >= MAXHANDLES
        jmp emm_error_83
    .endif
    shl edx,4
    add edx,offset emmh
    mov eax,[edx].size
    shr eax,14
    setBX(eax)
    jmp emm_success

;----------------------------------------------------------
emm_14:         ; Get All Handle Pages                  4Dh
;
;     handle_page_struct     STRUC
;        emm_handle          DW ?
;        pages_alloc_to_handle   DW ?
;     handle_page_struct     ENDS
;
;     ES:DI = pointer to handle_page
;----------------------------------------------------------
    mov eax,4*MAXHANDLES
    emm_getesdi()
    sub ebx,ebx
    sub esi,esi
    mov ecx,MAXHANDLES
    mov edx,offset emmh
    .repeat
        .if [edx].memp
            mov eax,[edx].size
            shl eax,2
            mov ax,si
            stosd
            inc ebx
        .endif
        inc esi
        add edx,HANDLE
    .untilcxz
    setBX(ebx)
    jmp emm_success

;----------------------------------------------------------
emm_15:         ; Get Page Map                        4E00h
                ; ES:DI = dest_page_map
;----------------------------------------------------------
    test al,al
    jnz emm_1501
    mov eax,SIZESAVEARRAY
    emm_getesdi()
    mov esi,offset emm_maph
    mov ecx,SIZESAVEARRAY
    rep movsb
    jmp emm_success

;----------------------------------------------------------
emm_1501:       ; Set Page Map                        4E01h
                ; DS:SI = source_page_map
;----------------------------------------------------------
    cmp al,1
    jne emm_1502
emm_150102:
    mov eax,SIZESAVEARRAY
    emm_getdssi()
    emm_pushmap()
    mov edi,offset emm_maph
    mov ecx,SIZESAVEARRAY
    rep movsb
    emm_updatemap()
    emm_popmap()
    jmp emm_success

;----------------------------------------------------------
emm_1502:       ; Get & Set Page Map                  4E02h
;----------------------------------------------------------
    cmp al,2
    jne emm_1503
    mov eax,SIZESAVEARRAY
    emm_getesdi()
    push esi
    mov esi,offset emm_maph
    mov ecx,SIZESAVEARRAY
    rep movsb
    pop esi
    jmp emm_150102

;----------------------------------------------------------
emm_1503:       ; Get Size of Page Map Save Array     4E03h
;----------------------------------------------------------
    setAX(SIZESAVEARRAY)
    ret

;----------------------------------------------------------
emm_16:         ; Get Partial Page Map                4F00h
    ;
    ;  partial_page_map_struct     STRUC
    ;     mappable_segment_count   DW  ?
    ;     mappable_segment   DW  (?) DUP (?)
    ;  partial_page_map_struct     ENDS
    ;
    ;  DS:SI = partial_page_map
    ;  ES:DI = dest_array
    ;   pointer to the destination array address in
    ;   Segment:Offset format.
;----------------------------------------------------------
    test al,al
    jnz emm_1601
    mov eax,EMMPAGES*4
    emm_getesdi()
    mov eax,emm_seg16
    movzx ecx,word ptr [edi]
    add edi,2
    .repeat
        stosw
        add eax,EMMPAGE/16
    .untilcxz
    jmp emm_success

;----------------------------------------------------------
emm_1601:       ; Set Partial Page Map                4F01h
                ; DS:SI = source_array
;----------------------------------------------------------
    cmp al,1
    je  emm_150102

;----------------------------------------------------------
emm_1602:; Get Size of Partial Page Map Save Array    4F02h
;----------------------------------------------------------
    jmp emm_1503

;----------------------------------------------------------
emm_17: ; Map/Unmap Multiple Handle Pages (Physical)  5000h
    ;
    ; log_to_phys_map_struct   STRUC
    ;     log_page_number      DW  ?
    ;     phys_page_number     DW  ?
    ;  log_to_phys_map_struct  ENDS
    ;
    ;  DS:SI = pointer to log_to_phys_map array
    ;  DX = handle
    ;  CX = log_to_phys_map_len
;----------------------------------------------------------
    .if !ecx || edx >= MAXHANDLES
        jmp emm_error_8F
    .endif
    push eax
    push ecx
    mov eax,ecx
    shl eax,2
    emm_getdssi()
    pop ecx
    pop eax
    test al,al
    jnz emm_1701
    .repeat
        push esi
        push ecx
        push edx
        movzx ebx,word ptr [esi]
        mov al,[esi+2]
        emm_mappage()
        pop edx
        pop ecx
        pop esi
        .if eax
            jmp emm_setAX
        .endif
        add esi,4
    .untilcxz
    jmp emm_success

;----------------------------------------------------------
emm_1701:; Map/Unmap Multiple Handle Pages (Segment)  5001h
    ;
    ;  log_to_seg_map_struct    STRUC
    ;     log_page_number       DW  ?
    ;     mappable_segment_address  DW  ?
    ;  log_to_seg_map_struct    ENDS
    ;
    ;  DX = handle
    ;  CX = log_to_segment_map_len
    ;  DS:SI = pointer to log_to_segment_map array
;----------------------------------------------------------
    .repeat
        push esi
        push ecx
        push edx
        movzx ebx,word ptr [esi]
        movzx eax,word ptr [esi+2]
        sub eax,emm_seg16
        shr eax,10
        emm_mappage()
        pop edx
        pop ecx
        pop esi
        .if eax
            jmp emm_setAX
        .endif
        add esi,4
    .untilcxz
    jmp emm_success

;----------------------------------------------------------
emm_18:         ; Reallocate Pages                      51h
    ; DX = handle
    ; BX = number of pages to be allocated to handle
    ; return:
    ; BX = actual number of pages allocated to handle
;----------------------------------------------------------
    ;
    ; No realloc of handle 0 !!
    ;
    emm_needhandle()
    emm_pushmap()
    shl edx,4
    add edx,offset emmh
    .if AllocatePages()
        mov edi,eax     ; pointer
        mov ebx,ecx     ; new size
        mov esi,[edx].memp
        .if esi
            ;
            ; Copy content from old buffer
            ;
            mov ecx,[edx].size
            .if ecx > ebx
                mov ecx,ebx
            .endif
            rep movsb
            mov edi,eax
            mov esi,edx
            GlobalFree([edx].memp)
            mov edx,esi
        .endif
        ;
        ; Reset mapping table
        ;
        sub esi,esi
        mov ecx,EMMPAGES
        .repeat
            .if emm_maph[esi] == edx
                mov eax,emm_mapp[esi]
                sub eax,[edx].memp
                add eax,EMMPAGE
                .if eax <= ebx
                    sub eax,EMMPAGE
                    add eax,edi
                    mov emm_mapp[esi],eax
                .else
                    sub eax,eax
                    mov emm_maph[esi],eax
                    ;
                    ; @@ TODO !!
                    ;
                .endif
            .endif
            add esi,4
        .untilcxz
        mov [edx].memp,edi
        mov [edx].size,ebx
        shr ebx,14
        setBX(ebx)
        jmp emm_success
    .endif
    mov [esi+8],eax
    mov [esi+12],eax
    jmp emm_error_87 ; There aren't enough expanded memory pages

;----------------------------------------------------------
emm_19:         ; Get Handle Attribute                5200h
;----------------------------------------------------------
    .if edx >= MAXHANDLES
        jmp emm_error_83
    .endif
    .if al == 2 || al == 0
        setAX(0) ; only volatile handles supported
        ret
    .endif
    jmp emm_error_91

;----------------------------------------------------------
emm_20:         ; Get Handle Name                     5300h
                ; DX = handle number
                ; ES:DI = pointer to handle_name array
;----------------------------------------------------------
    .if edx >= MAXHANDLES
        jmp emm_error_83
    .endif
    cmp al,0
    jne emm_2001
    mov eax,8
    emm_getesdi()
    shl edx,4
    add edx,offset emmh
    mov eax,[edx+8]
    mov [edi],eax
    mov eax,[edx+12]
    mov [edi+4],eax
    jmp emm_success

;----------------------------------------------------------
emm_2001:       ; Set Handle Name                     5301h
;----------------------------------------------------------
    mov eax,8
    emm_getdssi()
    shl edx,4
    add edx,offset emmh
    mov eax,[esi]
    mov [edx+8],eax
    mov eax,[esi+4]
    mov [edx+12],eax
    jmp emm_success

;----------------------------------------------------------
emm_21:         ; Get Handle Directory                  54h
;     handle_dir_struct   STRUC
;        handle_value     DW  ?
;        handle_name      DB  8  DUP  (?)
;     handle_dir_struct   ENDS
;
;     ES:DI = pointer to handle_dir
;----------------------------------------------------------
    cmp al,0
    jne emm_2101
    mov eax,10*MAXHANDLES
    emm_getesdi()
    sub ebx,ebx
    mov ecx,MAXHANDLES
    mov edx,offset emmh
    .repeat
        .if [edx].memp
            mov eax,ebx
            stosw
            mov eax,[edx+8]
            stosd
            mov eax,[edx+12]
            stosd
            inc ebx
        .endif
        add edx,HANDLE
    .untilcxz
    setAX(ebx)
    ret

;----------------------------------------------------------
emm_2101:       ; Search for Named Handle             5401h
;----------------------------------------------------------
    cmp al,1
    jne emm_2102
    mov eax,8
    emm_getdssi()
    mov eax,[esi]
    mov edx,[esi+4]
    sub ebx,ebx
    mov edi,ebx
    mov esi,offset emmh + 8
    .repeat
        .if [esi] == eax && [esi+4] == edx
            sub esi,8
            mov ebx,esi
            .break
        .endif
        inc edi
        add esi,HANDLE
    .until edi == MAXHANDLES
    .if ebx
        .if !eax && !edx
            jmp emm_error_A1
        .else
            setDX(edi)
            jmp emm_success
        .endif
    .else
        jmp emm_error_A0
    .endif
    ret

;----------------------------------------------------------
emm_2102:       ; Get Total Handles                   5402h
;----------------------------------------------------------
    setBX(MAXHANDLES)
    jmp emm_success

;----------------------------------------------------------
emm_22: ; Alter Page Map & Jump (Physical page mode)  5500h
;----------------------------------------------------------
emm_2201:; Alter Page Map & Jump (Segment mode)       5501h
;----------------------------------------------------------
    ;
    ;  log_phys_map_struct       STRUC
    ;     log_page_number   DW ?
    ;     phys_page_number_seg   DW ?
    ;  log_phys_map_struct       ENDS
    ;
    ;  map_and_jump_struct       STRUC
    ;    target_address      DD ?
    ;    log_phys_map_len   DB ?
    ;    log_phys_map_ptr   DD ?
    ;  map_and_jump_struct       ENDS
    ;
    ; AL = physical page number/segment selector
    ;  0 = physical page numbers
    ;  1 = segment address
    ;
    ; DX = handle number
    ;
    ; DS:SI = pointer to map_and_jump structure
    ;
;----------------------------------------------------------
    .if al > 1
        jmp emm_error_8F
    .endif
    push    eax
    mov eax,9
    emm_getdssi()
    movzx   ecx,byte ptr [esi+4]
    pop eax
    mov ah,50h
    push    esi
    mov esi,[esi+5]
    emm_17()
    pop esi
    test ah,ah
    jnz emm_setAX
    mov eax,[esi]
    shr eax,16
    setCS(eax)
    mov eax,[esi]
    and eax,0FFFEh
    setIP(eax)
    jmp emm_success

;----------------------------------------------------------
; Alter Page Map & Call (Physical page mode)          5600h
; Alter Page Map & Call (Segment mode)                5601h
;----------------------------------------------------------
    ;
    ;  log_phys_map_struct       STRUC
    ;     log_page_number   DW ?
    ;     phys_page_number_seg   DW ?
    ;  log_phys_map_struct       ENDS
    ;
    ;  map_and_call_struct       STRUC
    ;     target_address     DD ?
    ;     new_page_map_len       DB ?
    ;     new_page_map_ptr       DD ?
    ;     old_page_map_len       DB ?
    ;     old_page_map_ptr       DD ?
    ;     reserved           DW  4 DUP (?)
    ;  map_and_call_struct       ENDS
    ;
    ;  AL = physical page number/segment selector
    ;
    ;  DX = handle number
    ;
    ;  DS:SI = pointer to map_and_call structure
    ;
;----------------------------------------------------------

    .data

; -- from jemm/ems.asm --

;--- this is 16-bit code which is copied onto the client's stack
;--- to restore the page mapping in int 67h, ah=56h

;--- rewritten by Japheth 2012-12-29

VDDUnsimulate16 macro
db 0C4h, 0C4h, 0FEh
endm

clproc label byte
    db 9Ah
clp dd 0
    VDDUnsimulate16
sizeclproc equ $ - offset clproc


    .code

emm_23:
    cmp     al,1
    ja      emm_2302
    mov     eax,22
    emm_getdssi()
    push    esi
    movzx   ecx,byte ptr [esi+4]    ; .new_page_map_len
    mov     esi,[esi+5]             ; .new_page_map_ptr
    mov     eax,reg_AX              ; AL: 0 or 1
    emm_17()
    pop     esi
    test    ah,ah
    jnz     emm_setAX

;--- save client's CS:IP

    push    getCS()                 ; Get CS:IP
    push    getIP()

;--- adjust code that will be copied onto client's stack
    mov     ebx,[esi]               ; .target_address
    mov     clp,ebx

;--- get client's SS:SP

    mov     ebx,getSS()
    movzx   eax,ax
    shl     eax,4
    mov     edi,eax
    push    getSP()                 ; save client's SP
    movzx   eax,ax

;--- reserve space for helper code on client's stack (8 bytes)
    sub     eax,sizeclproc
    add     edi,eax

;--- set client's new SP and CS:IP
    push    eax
    invoke  setSP, eax
    pop     eax
    invoke  setIP, eax
    invoke  setCS, ebx

;--- copy helper code onto client stack
;--- it's just 2 lines: call far16 client_proc + VDDUnsimulate()
    push    esi
    mov     ecx,sizeclproc          ; copy function to stack
    mov     esi,offset clproc
    rep     movsb
    pop     esi

;--- run helper code
    call    VDDSimulate16

;--- restore client's SP and CS:IP
    pop     eax
    invoke  setSP, eax
    pop     eax
    invoke  setIP, eax
    pop     eax
    invoke  setCS, eax

;--- set old mapping
    movzx   ecx,byte ptr [esi+9]    ; .old_page_map_len
    mov     esi,[esi+10]            ; .old_page_map_ptr
    mov     eax,reg_AX              ; AL: 0 or 1
    mov     edx,reg_DX              ; restore handle
    call    emm_17
    jmp     emm_success

;----------------------------------------------------------
emm_2302:   ; Get Page Map Stack Space Size           5602h
;----------------------------------------------------------
    .if al != 2
        jmp emm_error_8F
    .endif
    setBX(sizeclproc+4)
    jmp emm_success

;----------------------------------------------------------
emm_24:     ; Move Memory Region                        57h
; DS:SI = pointer to exchange_source_dest structure
;----------------------------------------------------------

conventional    equ 0
expanded        equ 1

EMM             STRUC
dlength         dd ? ; region length in bytes
src_type        db ? ; source memory type
src_handle      dw ? ; 0000h if conventional memory
src_offset      dw ? ; within page if EMS
src_seg_page    dw ? ; segment or logical page (EMS)
des_type        db ? ; destination memory type
des_handle      dw ? ;
des_offset      dw ? ;
des_seg_page    dw ? ;
EMM             ENDS

    mov eax,EMM
    emm_getdssi()
    mov ebx,esi

    .if [ebx].EMM.src_type == conventional
        mov ax,[ebx].EMM.src_seg_page
        shl eax,16
        mov ax,[ebx].EMM.src_offset
        mov esi,MGetVdmPointer(eax, [ebx].EMM.dlength, 0)
    .else
        movzx eax,[ebx].EMM.src_seg_page
        movzx edx,[ebx].EMM.src_handle
        cmp edx,MAXHANDLES
        jae emm_24_8F       ; out of range..
        shl edx,4
        add edx,offset emmh
        mov esi,[edx].memp
        test esi,esi
        jz  emm_24_93       ; out of range..
        mov edx,[edx].size
        add edx,esi         ; limit
        shl eax,14          ; page * size of page (4000h)
        add esi,eax         ; ESI to page adress in buffer
        movzx eax,[ebx].EMM.src_offset
        add esi,eax
        mov eax,esi
        add eax,[ebx].EMM.dlength
        cmp eax,edx
        ja  emm_24_93       ; out of range..
    .endif
    .if [ebx].EMM.des_type == conventional
        mov ax,[ebx].EMM.des_seg_page
        shl eax,16
        mov ax,[ebx].EMM.des_offset
        mov edi,MGetVdmPointer(eax, [ebx].EMM.dlength, 0)
    .else
        movzx eax,[ebx].EMM.des_seg_page
        movzx edx,[ebx].EMM.des_handle
        cmp edx,MAXHANDLES
        jae emm_24_8F   ; out of range..
        shl edx,4
        add edx,offset emmh
        mov edi,[edx].memp
        test edi,edi
        jz  emm_24_93   ; out of range..
        mov edx,[edx].size
        add edx,edi     ; limit
        shl eax,14      ; page * size of page (4000h)
        add edi,eax     ; EDI to page adress in buffer
        movzx eax,[ebx].EMM.des_offset
        add edi,eax
        mov eax,edi
        add eax,[ebx].EMM.dlength
        cmp eax,edx
        ja  emm_24_93   ; out of range..
    .endif
    mov ecx,[ebx].EMM.dlength
    cmp byte ptr reg_AX,01h
    je  emm_2401
    cmp edi,esi
    ja  emm_24_move
    rep movsb
    jmp emm_success
emm_24_move:
    std
    add esi,ecx
    add edi,ecx
    sub esi,1
    sub edi,1
    rep movsb
    cld
    jmp emm_success

emm_24_8F:
    jmp emm_error_8F ; The subfunction parameter is invalid
emm_24_93:
    jmp emm_error_93 ; The length expands memory region specified

;----------------------------------------------------------
emm_2401:   ; Exchange Memory Region                  5701h
;----------------------------------------------------------
    mov al,[edi]
    movsb
    mov [esi-1],al
    dec ecx
    jnz emm_2401
    jmp emm_success

;----------------------------------------------------------
emm_25: ; Get Mappable Physical Address Array         5800h
;----------------------------------------------------------
    cmp al,1
    je  emm_2501
;
;     mappable_phys_page_struct   STRUC
;        phys_page_segment  DW ?
;        phys_page_number    DW ?
;     mappable_phys_page_struct   ENDS
;
;     ES:DI = mappable_phys_page
;
    mov eax,EMMPAGES*4
    emm_getesdi()
    sub ecx,ecx
    mov eax,emm_seg16
    .repeat
        mov [edi],ax
        mov [edi+2],cx
        add eax,EMMPAGE/16
        add edi,4
        inc ecx
    .until ecx == EMMPAGES

;----------------------------------------------------------
emm_2501:; Get Mappable Physical Address Array Entries 5801h
;----------------------------------------------------------
    setCX(EMMPAGES)
    jmp emm_success

;----------------------------------------------------------
emm_26:     ; Get Hardware Configuration Array        5900h
;
;     hardware_info_struct   STRUC
;        raw_page_size       DW ?
;        alternate_register_sets   DW ?
;        context_save_area_size    DW ?
;        DMA_register_sets   DW ?
;        DMA_channel_operation     DW ?
;     hardware_info_struct   ENDS
;
;----------------------------------------------------------
    cmp al,1
    je  emm_2601
    mov eax,10
    emm_getesdi()
    sub eax,eax
    mov word ptr [edi],EMMPAGE/16
    mov [edi+2],ax
    mov word ptr [edi+4],SIZESAVEARRAY
    mov [edi+6],eax
    jmp emm_success

;----------------------------------------------------------
emm_2601:   ; Get Unallocated Raw Page Count          5901h
;----------------------------------------------------------
    jmp emm_03

emm_28:     ; Get Alternate Map Register Set 5B00h
emm_2801:   ; Set Alternate Map Register Set 5B01h
emm_2802:   ; Get Alternate Map Save Array Size 5B02h
emm_2803:   ; Allocate Alternate Map Register Set 5B03h
emm_2804:   ; Deallocate Alternate Map Register Set 5B04h
emm_2805:   ; Allocate DMA Register Set 5B05h
emm_2806:   ; Enable DMA on Alternate Map Register Set 5B06h
emm_2807:   ; Disable DMA on Alternate Map Register Set 5B07h
emm_2808:   ; Deallocate DMA Register Set 5B08h
emm_29:     ; Prepare Expanded Memory Hardware for Warmboot 5Ch
emm_30:     ; Enable OS/E Function Set 5D00h
emm_3001:   ; Disable OS/E Function Set 5D01h
emm_3002:   ; Return OS/E Access Key 5D02h
    jmp emm_error_84

;----------------------------------------------------------
emm_31:     ; Called from dzemm.com on init             5Eh
;----------------------------------------------------------

    .if emm_seg16
        jmp emm_error_84
    .endif

    mov emm_seg16,edx
    .if edx
        shl edx,16
        mov emm_seg32,MGetVdmPointer(edx, EMMPAGES*EMMPAGE, 0)
        mov ebx,EMMPAGES
        .if AllocatePages()
            mov emmh.memp,eax
            mov emmh.size,ecx
            setAX(1)
        .endif
    .endif
    ret

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

emm_success:
    sub ah,ah
emm_setAX:
    mov al,byte ptr reg_AX
    push eax
    setAX(eax)
    pop eax
    ret

emm_error_83:
    mov ah,83h      ; No EMM handle
    jmp emm_setAX
emm_error_84:
    mov ah,84h
    jmp emm_setAX
emm_error_85:
    mov ah,85h      ; All EMM handles are being used
    jmp emm_setAX
emm_error_87:
    mov ah,87h      ; There aren't enough expanded memory pages
    jmp emm_setAX
emm_error_89:
    mov ah,89h      ; Attempted to allocate zero pages
    jmp emm_setAX
emm_error_8A:
    mov ah,8Ah      ; The logical page is out of the range of logical pages
    jmp emm_setAX
emm_error_8C:
    mov ah,8Ch      ; There is no room to store the page mapping registers.
    jmp emm_setAX
emm_error_8F:
    mov ah,8Fh      ; The subfunction parameter is invalid.
    jmp emm_setAX
emm_error_91:
    mov ah,91h      ; This feature is not supported.
    jmp emm_setAX
emm_error_93:
    mov ah,93h      ; The length expands memory region specified
    jmp emm_setAX
emm_error_A0:
    mov ah,0A0h
    jmp emm_setAX
emm_error_A1:
    mov ah,0A1h
    jmp emm_setAX

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ifdef USEDOSZIP

;----------------------------------------------------------
emm_70:         ; Version                               70h
;----------------------------------------------------------
    setAX(VERSION)
    ret

;----------------------------------------------------------
emm_71:         ; Memset Handle                         71h
;----------------------------------------------------------
    emm_needhandle()    ; DX handle
    shl edx,4           ; AL char
    add edx,offset emmh
    mov edi,[edx].memp
    mov ecx,[edx].size
    .if ecx && edi
        rep stosb
        jmp emm_success
    .endif
    jmp emm_error_8F

endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ifdef USECLIPBOARD

memmove proc stdcall uses esi edi s1:dword, s2:dword, cnt:dword
    mov edi,s1
    mov esi,s2
    mov ecx,cnt
    mov eax,edi
    cld
    .if eax > esi
        std
        add esi,ecx
        add edi,ecx
        sub esi,1
        sub edi,1
    .endif
    rep movsb
    cld
    ret
memmove endp

;----------------------------------------------------------
emm_90:         ; Clipboard                             90h
;----------------------------------------------------------
    movzx eax,al
    .switch pascal eax
    .case 0
        setAX(0103h)
    .case 1 ; Open Clipboard
        mov eax,ClipboardIsOpen
        .if !eax
            OpenClipboard(eax)
        .endif
        mov ClipboardIsOpen,eax
        setAX(eax)
    .case 2 ; Empty Clipboard
        .if EmptyClipboard()
            setAX(1)
        .endif
    .case 3 ; Write to clipboard
        shl esi,16 ; DX format
        mov si,cx  ; SI:CX size
        inc esi
        .if GlobalAlloc(GMEM_MOVEABLE or GMEM_DDESHARE, esi)
            mov ebx,eax
            .if GlobalLock(eax)
                mov reg_SI,eax
                getES()
                shl eax,16
                mov ax,word ptr reg_BX
                mov edi,eax
                MGetVdmPointer(edi, esi, 0)
                memmove(reg_SI, eax, esi)
                GlobalUnlock(reg_SI)
                SetClipboardData(reg_DX, ebx)
                setAX(eax)
                ret
            .endif
            GlobalFree(ebx)
        .endif
        GetLastError()
        setAX(eax)
    .case 4 ; Clipboard size
        .if GetClipboardData(reg_DX); DX format
            GlobalSize(eax)
            push eax
            setAX(eax)
            pop eax
            shr eax,16
            setDX(eax)
        .else
            setAX(0)
            setDX(0)
        .endif
    .case 5 ; Read clipboard
        getES()     ; ES:BX pointer
        shl eax,16  ; DX format
        mov ax,word ptr reg_BX
        mov esi,eax
        .if GetClipboardData(reg_DX)
            mov ebx,eax
            GlobalSize(eax)
            mov edi,eax
            .if GlobalLock(ebx)
                mov ebx,eax
                MGetVdmPointer(esi, edi, 0)
                memmove(eax, ebx, edi)
                GlobalUnlock(ebx)
                mov eax,1
            .endif
        .endif
        setAX(eax)
    .case 8 ; Close Clipboard
        mov eax,ClipboardIsOpen
        .if eax
            .if CloseClipboard()
                sub eax,eax
                mov ClipboardIsOpen,eax
                inc eax
            .endif
        .endif
        setAX(eax)
    .case 9
        getCS()
        setAX(eax)
        setDX(reg_SI)
    .endsw
    ret

endif

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    .data

emm_functionsAH label byte
    db 40h,41h,42h,43h,44h,45h,46h,47h,48h,49h,4Ah,4Bh,4Ch,4Dh,4Eh,4Fh
    db 50h,51h,52h,53h,54h,55h,56h,57h,58h,59h,5Ah,5Bh,5Ch,5Dh,5Eh
ifdef USEDOSZIP
    db 70h,71h
endif
ifdef USECLIPBOARD
    db 90h
endif
emm_funccount equ $ - offset emm_functionsAH

emm_functions label dword
    dd emm_01,emm_02,emm_03,emm_04,emm_05,emm_06,emm_07,emm_08
    dd emm_09,emm_10,emm_11,emm_12,emm_13,emm_14,emm_15,emm_16
    dd emm_17,emm_18,emm_19,emm_20,emm_21,emm_22,emm_23,emm_24
    dd emm_25,emm_26,emm_27,emm_28,emm_29,emm_30,emm_31
ifdef USEDOSZIP
    dd emm_70,emm_71
endif
ifdef USECLIPBOARD
    dd emm_90
endif
    dd emm_error_84

    .code

dzemm:
    movzx getBX(),ax
    mov reg_BX,eax
    movzx getCX(),ax
    mov reg_CX,eax
    movzx getDX(),ax
    mov reg_DX,eax
    movzx getSI(),ax
    mov reg_SI,eax
    movzx getDI(),ax
    mov reg_DI,eax
    movzx getBP(),ax
    mov reg_AX,eax
    mov al,ah
    mov edi,offset emm_functionsAH
    mov ecx,emm_funccount
    repne scasb
    .ifz
        dec edi
    .endif
    sub edi,offset emm_functionsAH
    shl edi,2
    mov eax,emm_functions[edi]
    mov emm_label,eax
    mov eax,reg_AX
    mov ebx,reg_BX
    mov ecx,reg_CX
    mov edx,reg_DX
    mov esi,reg_SI
    mov edi,reg_DI
    emm_label()
    ret

emm_dispatch proc uses esi edi
    mov edi,MAXHANDLES
    mov esi,offset emmh
    .repeat
        mov eax,[esi].HANDLE.memp
        .if eax
            invoke GlobalFree,eax
        .endif
        add esi,HANDLE
        dec edi
    .until  !edi
    ret
emm_dispatch endp

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

DZEmmInitVDD proc export
    ret
DZEmmInitVDD endp

DZEmmCallVDD proc export uses esi edi ebx
    dzemm()
    ret
DZEmmCallVDD endp

DLL_PROCESS_DETACH equ 0
DLL_PROCESS_ATTACH equ 1

LibMain proc stdcall hModule:dword, dwReason:dword, dwReserved:dword
    .if dwReason == DLL_PROCESS_DETACH
        emm_dispatch()
    .endif
    mov eax,1
    ret
LibMain endp

    end LibMain
