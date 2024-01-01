MODULE WinBoot;  IMPORT SYSTEM;

TYPE
  CodeHeaderPtr = POINTER TO CodeHeader;
  CodeHeader* = RECORD
    length*:   SYSTEM.CARD32;  (* File length *)
    initcode*: SYSTEM.CARD32;
    pointers*: SYSTEM.CARD32;
    commands*: SYSTEM.CARD32;
    exports*:  SYSTEM.CARD32;
    imports*:  SYSTEM.CARD32;  (* VARs start here following import resolution *)
    varsize*:  SYSTEM.CARD32
  END;


VAR
  (* WinPE.mod builds the executable with the following WinBoot variables pre-loaded *)
  Header:             CodeHeaderPtr;
  LoadLibraryA:       PROCEDURE#(libname: INTEGER): INTEGER;
  GetProcAddress:     PROCEDURE#(hmodule, procname: INTEGER): INTEGER;
  VirtualAlloc:       PROCEDURE#(address, size, type, protection: INTEGER): INTEGER;
  ExitProcess:        PROCEDURE#(exitcode: INTEGER);
  GetStdHandle:       PROCEDURE#(nStdHandle: SYSTEM.INT32): INTEGER;
  SetConsoleOutputCP: PROCEDURE#(codepage: INTEGER) (* : INTEGER *);
  WriteFile:          PROCEDURE#(hFile, lpBuffer, nNumberOfBytesToWrite,
                                 lpNumberOfBytesWritten, lpOverlapped: INTEGER
                                ): SYSTEM.CARD32;
  (* End of pre-loaded variables *)

  Stdout:  INTEGER;
  crlf:    ARRAY 3 OF CHAR;
  Log:     PROCEDURE(s: ARRAY OF CHAR);


PROCEDURE NoLog(s: ARRAY OF CHAR); BEGIN END NoLog;

PROCEDURE assert(expectation: BOOLEAN);
BEGIN IF ~expectation THEN
  Log("Assertion failure."); Log(crlf);
  ExitProcess(99)
END END assert;

(* ---------------------------------------------------------------------------- *)

PROCEDURE IntToHex*(n: INTEGER; VAR s: ARRAY OF CHAR);
VAR d, i, j: INTEGER;  ch: CHAR;
BEGIN
  i := 0;  j := 0;
  REPEAT
    d := n MOD 16;  n := n DIV 16 MOD 1000000000000000H;
    IF d <= 9 THEN s[j] := CHR(d + 48) ELSE s[j] := CHR(d + 55) END;
    INC(j)
  UNTIL n = 0;
  s[j] := 0X;  DEC(j);
  WHILE i < j DO ch:=s[i]; s[i]:=s[j]; s[j]:=ch; INC(i); DEC(j) END;
END IntToHex;

PROCEDURE Strlen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN i := 0;  WHILE s[i] # 0X DO INC(i) END
RETURN i END Strlen;

(* ---------------------------------------------------------------------------- *)

PROCEDURE WriteStdout(s: ARRAY OF CHAR);
VAR written, result: INTEGER;
BEGIN
  result := WriteFile(Stdout, SYSTEM.ADR(s), Strlen(s), SYSTEM.ADR(written), 0);
END WriteStdout;

(* ---------------------------------------------------------------------------- *)

PROCEDURE ws(s: ARRAY OF CHAR); BEGIN Log(s) END ws;

PROCEDURE wl; BEGIN Log(crlf) END wl;

PROCEDURE wsl(s: ARRAY OF CHAR); BEGIN Log(s);  Log(crlf) END wsl;

PROCEDURE wh(n: INTEGER);
VAR hex: ARRAY 32 OF CHAR;
BEGIN IntToHex(n, hex);  Log(hex) END wh;

(* ---------------------------------------------------------------------------- *)

PROCEDURE IncPC(increment: INTEGER);  (* Update return address by increment *)
VAR pc: INTEGER;
BEGIN
  SYSTEM.GET(SYSTEM.ADR(pc) + 8, pc);
  SYSTEM.PUT(SYSTEM.ADR(pc) + 8, pc + increment);
END IncPC;

PROCEDURE GetPC(): INTEGER;
VAR pc: INTEGER;
BEGIN SYSTEM.GET(SYSTEM.ADR(pc) + 8, pc);
RETURN pc END GetPC;

PROCEDURE PrepareOberonMachine;
CONST
  MEMRESERVE           = 2000H;
  MEMCOMMIT            = 1000H;
  PAGEEXECUTEREADWRITE = 40H;
VAR
  reserveadr: INTEGER;
  commitadr:  INTEGER;
  moduleadr:  INTEGER;
  modulesize: INTEGER;
  bootsize:   INTEGER;
  res:        INTEGER;
  hdr:        CodeHeaderPtr;
BEGIN
  (* Reserve 2GB memory for the Oberon machine *)
  reserveadr := VirtualAlloc(0, 80000000H, MEMRESERVE, PAGEEXECUTEREADWRITE);
  ws("Reserved 2GB mem at ");  wh(reserveadr);  wsl("H.");

  (* Determine loaded size of all modules *)
  bootsize   := Header.imports + Header.varsize;
  modulesize := bootsize;
  moduleadr  := SYSTEM.VAL(INTEGER, Header) + bootsize;  (* Address of first module for Oberon machine *)
  hdr        := SYSTEM.VAL(CodeHeaderPtr, moduleadr);
  WHILE hdr.length > 0 DO
    ws("Module at "); wh(moduleadr); ws("H, length "); wh(hdr.length); wsl("H.");
    INC(modulesize, hdr.imports + hdr.varsize);
    INC(moduleadr, hdr.length);
    hdr := SYSTEM.VAL(CodeHeaderPtr, moduleadr);
  END;

  (* Commit enough for the modules being loaded. *)
  commitadr  := VirtualAlloc(reserveadr, modulesize, MEMCOMMIT, PAGEEXECUTEREADWRITE);
  ws("Committed ");  wh(modulesize);  ws("H bytes at ");  wh(commitadr);  wsl("H.");

  (* Copy boot module into reserved memory *)
  SYSTEM.COPY(SYSTEM.VAL(INTEGER, Header), commitadr, bootsize);

  ws("Transferring PC from original load at ");  wh(GetPC());  wsl("H.");
  IncPC(commitadr - SYSTEM.VAL(INTEGER, Header));  (* Transfer to copied code *)
  ws("Transferred PC to code copied to Oberon memory at ");  wh(GetPC());  wsl("H.");
END PrepareOberonMachine;

(* ---------------------------------------------------------------------------- *)

BEGIN
  Log := NoLog;

  (* Initialise console output *)
  Stdout := GetStdHandle(-11);  (* -11:   StdOutputHandle *)
  SetConsoleOutputCP(65001);    (* 65001: UTF8            *)
  crlf := $0D 0A 00$;
  Log := WriteStdout;

  wsl("Hello");
  ws("Stdout handle "); wh(Stdout);     wsl("H.");
  ws("Winboot header at ");  wh(SYSTEM.VAL(INTEGER, Header));  wsl("H:");
  ws("  length:   ");  wh(Header.length);    wsl("H.");
  ws("  initcode: ");  wh(Header.initcode);  wsl("H.");
  ws("  pointers: ");  wh(Header.pointers);  wsl("H.");
  ws("  commands: ");  wh(Header.commands);  wsl("H.");
  ws("  exports:  ");  wh(Header.exports);   wsl("H.");
  ws("  imports:  ");  wh(Header.imports);   wsl("H.");
  ws("  varsize:  ");  wh(Header.varsize);   wsl("H.");

  PrepareOberonMachine;

  wsl("WinBoot complete.");  ExitProcess(0);
END WinBoot.
