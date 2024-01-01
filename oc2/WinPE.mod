MODULE WinPE;  (* Create exe from a list of compiled Oberon modules *)
IMPORT SYSTEM, K := Kernel, X64, Files, B := Base, w := Writer;


CONST
  HeaderSize      =  400H;
  MemoryAlignment = 1000H;  (* Sections are a multiple of this size in memory *)
  FileAlignment   =  200H;  (* Sections are a multiple of this size on file *)

  ImageBase   = 400000H;
  FadrImport  = 400H;  RvaImport  = 1000H;  (* Import directory table *)
  FadrModules = 600H;  RvaModules = 2000H;  (* Oberon modules starting with Winboot *)

  ImportCount = 7;          (* Number of Kernel32 imports *)

TYPE
  ObjectFile = POINTER TO ObjectFileDesc;
  ObjectFileDesc = RECORD
    next: ObjectFile;
    name: ARRAY 1204 OF CHAR
  END;

  U8  = BYTE;         U16 = SYSTEM.CARD16;  U32 = SYSTEM.CARD32;
  I8  = SYSTEM.INT8;  I16 = SYSTEM.INT16;   I32 = SYSTEM.INT32;   I64 = INTEGER;

  PEheader = RECORD
    eMagic:     U16;  (* 5AD4 *)
    zeroes:     ARRAY 3AH OF BYTE;
    eLfanew:    U32;
    dosProgram: ARRAY 40H OF CHAR;
    signature:  U32;

    (* COFF file header*)
    machine:              U16;
    numberOfSections:     U16;
    timeDateStamp:        U32;
    pointerToSymbolTable: U32;
    numberOfSymbols:      U32;
    sizeOfOptionalHeader: U16;
    characteristics:      U16;

    (* PE32+ optional header *)
    pe32magic:               U16;
    majorLinkerVersion:      U8;  minorLinkerVersion:  U8;
    sizeOfCode:              U32;
    sizeOfInitializedData:   U32;
    sizeOfUninitializedData: U32;
    addressOfEntryPoint:     U32;
    baseOfCode:              U32;

    (* Windows specific PE32+ fields *)
    imageBase:             I64;
    MemoryAlignment:       U32;  fileAlignment:         U32;
    majorOSVersion:        U16;  minorOSVersion:        U16;
    majorImageVersion:     U16;  minorImageVersion:     U16;
    majorSubsystemVersion: U16;  minorSubsystemVersion: U16;
    win32VersionValue:     U32;
    sizeOfImage:           U32;  sizeOfHeaders:         U32;
    checksum:              U32;
    subsystem:             U16;
    dllCharacteristics:    U16;
    sizeOfStackReserve:    I64;  sizeOfStackCommit:     I64;
    sizeOfHeapReserve:     I64;  sizeOfHeapCommit:      I64;
    loaderFlags:           U32;
    numberOfRvaAndSizes:   U32;

    (* Optional header data directories *)
    exportTableRVA:           U32;  exportTableSize:           U32;
    importTableRVA:           U32;  importTableSize:           U32;
    resourceTableRVA:         U32;  resourceTableSize:         U32;
    exceptionTableRVA:        U32;  exceptionTableSize:        U32;
    certificateTableRVA:      U32;  certificateTableSize:      U32;
    baseRelocationTableRVA:   U32;  baseRelocationTableSize:   U32;
    debugRVA:                 U32;  debugSize:                 U32;
    architectureRVA:          U32;  architectureSize:          U32;
    globalPtrRVA:             U32;  globalPtrSize:             U32;
    tlsTableRVA:              U32;  tlsTableSize:              U32;
    loadConfigTableRVA:       U32;  loadConfigTableSize:       U32;
    boundImportRVA:           U32;  boundImportSize:           U32;
    IATRVA:                   U32;  IATSize:                   U32;
    delayImportDescriptorRVA: U32;  delayImportDescriptorSize: U32;
    CLRRuntimeHeaderRVA:      U32;  CLRRuntimeHeaderSize:      U32;
    reservedZeroRVA:          U32;  reservedZeroSize:          U32
  END;

  ImportDirectoryTable = RECORD
    (* Just one import directory table entry - for kernel32 *)
    LookupTable:  U32;   (*  0: RVA of table of import hint RVAs              *)
    Datestamp:    U32;   (*  4: 0                                             *)
    FwdChain:     U32;   (*  8: 0                                             *)
    Dllnameadr:   U32;   (* 12: RVA of dll name                               *)
    Target:       U32;   (* 16: Where to write imported addresses             *)
    DirectoryEnd: ARRAY 5 OF U32;  (* Sentinel 0 filled directory table entry *)
    (* Import lookup table for kernel32.dll *)
    Lookups:      ARRAY ImportCount + 1 OF I64; (* 40-72: RVA of Hints[] entry below *)
    (* dll name *)
    Dllname:      ARRAY 16 OF CHAR;  (*  80: "kernel32.dll" *)
    (* hint table *)
    Hints:        ARRAY ImportCount OF RECORD
      Num:          U16;               (*  0 - Import 1 import number *)
      Name:         ARRAY 20 OF CHAR;  (*  E.g. "LoadLibraryA"             *)
    END
  END;


VAR
  FileName:   ARRAY 512 OF CHAR;
  ExeFile:    Files.File;
  Exe:        Files.Rider;
  OberonSize: INTEGER;
  ImportSize: INTEGER;
  Objects:    ObjectFile;
  LastObject: ObjectFile;

  Bootstrap:  RECORD
    Header:  X64.CodeHeader;
    Content: ARRAY 4096 OF BYTE
  END;

  Idt: ImportDirectoryTable;

  (* Section layout - generates 2 sections:
     1. Imports section requesting standard system functions
     2. Oberon section containing concatenated modules in link sequence
  *)


(* Convenience functions *)
PROCEDURE spos(p: INTEGER);
BEGIN Files.Set(Exe, ExeFile, p) END spos;

PROCEDURE ZeroFill(VAR buf: ARRAY OF BYTE);  VAR i: INTEGER;
BEGIN FOR i := 0 TO LEN(buf)-1 DO buf[i] := 0 END END ZeroFill;




(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

PROCEDURE Align(a: INTEGER;  align: INTEGER): INTEGER;
BEGIN IF a > 0 THEN INC(a, align - 1) END;
RETURN a DIV align * align END Align;


(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

PROCEDURE WriteImports;  (* target: RVA to receive imported addresses *)
  PROCEDURE FieldRVA(VAR field: ARRAY OF BYTE): U32;
  BEGIN RETURN RvaImport + SYSTEM.ADR(field) - SYSTEM.ADR(Idt) END FieldRVA;
  PROCEDURE IDTentry(i: INTEGER; name: ARRAY OF CHAR);
  BEGIN
    Idt.Lookups[i]    := FieldRVA(Idt.Hints[i]);
    Idt.Hints[i].Name := name
  END IDTentry;
BEGIN
  ZeroFill(Idt);
  Idt.LookupTable   := FieldRVA(Idt.Lookups);
  Idt.Dllnameadr    := FieldRVA(Idt.Dllname);
  Idt.Dllname       := "KERNEL32.DLL";
  Idt.Target        := RvaModules + Bootstrap.Header.imports + 8;  (* 8 for HeaderAdr var *)
  IDTentry(0, "LoadLibraryA");
  IDTentry(1, "GetProcAddress");
  IDTentry(2, "VirtualAlloc");
  IDTentry(3, "ExitProcess");
  IDTentry(4, "GetStdHandle");
  IDTentry(5, "SetConsoleOutputCP");
  IDTentry(6, "WriteFile");
  spos(FadrImport);
  Files.WriteBytes(Exe, Idt, SYSTEM.SIZE(ImportDirectoryTable));
  ImportSize := Align(Files.Pos(Exe), 16) - FadrImport;
  w.s("IDT size "); w.h(ImportSize); w.sl("H.");
END WriteImports;


(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

PROCEDURE CopyFile(name: ARRAY OF CHAR);
VAR  f: Files.File;  r: Files.Rider;  buf: ARRAY 1000H OF BYTE;
BEGIN
  f := Files.Old(name);
  IF f = NIL THEN
    w.s("Couldn't copy '"); w.s(name); w.sl("'."); K.Halt(99)
  END;
  Files.Set(r, f, 0);
  WHILE ~r.eof DO
    Files.ReadBytes(r, buf, LEN(buf));
    Files.WriteBytes(Exe, buf, LEN(buf) - r.res);
  END
END CopyFile;


(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

PROCEDURE WriteModules;
VAR object: ObjectFile;
BEGIN
  object := Objects;
  WHILE object # NIL DO CopyFile(object.name);  object := object.next END;

  Files.WriteInt(Exe, 0);  (* Mark end of modules - appears as header.length = 0 *)

  (* Fill Oberon section to a whole multiple of section alignment *)
  (* by writing 0 to its last byte *)
  IF Files.Pos(Exe) - FadrModules MOD FileAlignment # 0 THEN
    spos(Align(Files.Pos(Exe), FileAlignment)-1);
    Files.WriteByte(Exe, 0);
  END;

  OberonSize := Files.Pos(Exe) - FadrModules;
END WriteModules;


(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)
(* PE Header *)

PROCEDURE WriteSectionHeader(name:         ARRAY OF CHAR;
                             vsize, fsize: INTEGER;
                             rva,   fadr:  INTEGER;
                             flags:        INTEGER);
TYPE
  SectionHeader = RECORD
    Name:                 ARRAY 8 OF CHAR;
    VirtualSize:          U32;
    VirtualAddress:       U32;
    SizeOfRawData:        U32;
    PointerToRawData:     U32;
    PointerToRelocations: U32;
    PointerToLinenumbers: U32;
    NumberOfRelocations:  U32;
    Characteristics:      U32;
  END;

VAR
  shdr: SectionHeader;

BEGIN
  ZeroFill(shdr);
  shdr.Name             := name;
  shdr.VirtualSize      := vsize;
  shdr.VirtualAddress   := rva;
  shdr.SizeOfRawData    := fsize;
  shdr.PointerToRawData := fadr;
  shdr.Characteristics  := flags;
  Files.WriteBytes(Exe, shdr, SYSTEM.SIZE(SectionHeader));
END WriteSectionHeader;


PROCEDURE WritePEHeader;
CONST
  (* Section flags *)
  SWriteable     = 80000000H;
  SReadable      = 40000000H;
  SExecutable    = 20000000H;
  SUninitialised =       80H;
  SInitialised   =       40H;
  SCode          =       20H;

VAR
  hdr: PEheader;

BEGIN
  ZeroFill(hdr);

  (* MSDOS stub *)
  hdr.eMagic               := 5A4DH;
  hdr.eLfanew              := 128;
  hdr.dosProgram           := $ 0E 1F BA 0E 00 B4 09 CD  21 B8 01 4C CD 21 54 68
                                69 73 20 70 72 6F 67 72  61 6D 20 63 61 6E 6E 6F
                                74 20 20 72 75 6E 20 69  6E 20 44 4F 53 20 6D 6F
                                64 65 2E 0D 0A 24 $;
  hdr.signature            := 4550H;

  (* COFF file header*)
  hdr.machine              := 8664H;  (* AMD64/Intel 64 *)
  hdr.numberOfSections     := 2;
  hdr.sizeOfOptionalHeader := 240;
  hdr.characteristics      := 200H  (* Windows debug information stripped               *)
                            + 20H   (* Large address aware                              *)
                            + 8     (* Coff symbol tables removed (should really be 0?) *)
                            + 4     (* Coff linenumbers removed   (should really be 0?) *)
                            + 2     (* Executable image                                 *)
                            + 1;    (* Relocs stripped *)

  (* PE32+ optional header *)
  hdr.pe32magic               := 20BH;  (* PE32+ *)
  hdr.majorLinkerVersion      := 1;
  hdr.minorLinkerVersion      := 49H;
  hdr.sizeOfCode              := Align(OberonSize, FileAlignment);
  hdr.sizeOfInitializedData   := Align(ImportSize, MemoryAlignment);
  hdr.sizeOfUninitializedData := 0;
  hdr.addressOfEntryPoint     := RvaModules + Bootstrap.Header.initcode;
  hdr.baseOfCode              := RvaModules;

  (* Windows specific PE32+ fields *)
  hdr.imageBase               := ImageBase;
  hdr.MemoryAlignment         := MemoryAlignment;
  hdr.fileAlignment           := FileAlignment;
  hdr.majorOSVersion          := 1;
  hdr.majorSubsystemVersion   := 5;
  hdr.sizeOfImage             := Align(HeaderSize, MemoryAlignment)
                               + Align(OberonSize, MemoryAlignment)
                               + 4096;   (* import section *)
  hdr.sizeOfHeaders           := HeaderSize;
  hdr.subsystem               := 3;    (* Console *)
(*hdr.subsystem               := 2;*)  (* Windows *)
  hdr.dllCharacteristics      := 400H;   (* No SEH *)
  hdr.sizeOfStackReserve      := 1000H;
  hdr.sizeOfStackCommit       := 1000H;
  hdr.sizeOfHeapReserve       := 1000H;  (* Minimal heap - Windows may use it, we don't *)
  hdr.numberOfRvaAndSizes     := 16;

  (* Optional header data directories *)
  hdr.importTableRVA          := RvaImport;
  hdr.importTableSize         := ImportSize;

  spos(0);
  Files.WriteBytes(Exe, hdr, SYSTEM.SIZE(PEheader));

  (* Write section headers *)
  WriteSectionHeader(".idata",
                     Align(ImportSize, MemoryAlignment),   (* Size in memory *)
                     Align(ImportSize, FileAlignment),     (* Size on disk *)
                     RvaImport, FadrImport,
                     SReadable + SWriteable + SInitialised);
  WriteSectionHeader("Oberon",
                     Align(OberonSize, MemoryAlignment),    (* Size in memory *)
                     Align(OberonSize, FileAlignment),      (* Size on disk *)
                     RvaModules, FadrModules,
                     SReadable + SWriteable + SExecutable + SCode);
END WritePEHeader;

(* -------------------------------------------------------------------------- *)
(* -------------------------------------------------------------------------- *)

PROCEDURE AddObject*(fn: ARRAY OF CHAR);
BEGIN
  IF LastObject = NIL THEN
    NEW(Objects);  Objects.name := fn;  LastObject := Objects
  ELSE
    NEW(LastObject.next);  LastObject := LastObject.next;
    LastObject.name := fn
  END
END AddObject;


PROCEDURE GetBootstrap;
VAR
  f: Files.File;
  r: Files.Rider;
BEGIN
  f := Files.Old("winboot.code");
  IF f = NIL THEN w.sl("Couldn't open winboot.code."); K.Halt(99) END;
  Files.Set(r, f, 0);
  Files.ReadBytes(r, Bootstrap.Header,  SYSTEM.SIZE(X64.CodeHeader));
  Files.ReadBytes(r, Bootstrap.Content, LEN(Bootstrap.Content));
  Files.Close(f)
END GetBootstrap;

PROCEDURE WriteZeroes(n: INTEGER);
VAR i: INTEGER;
BEGIN FOR i := 1 TO n DO Files.WriteByte(Exe, 0) END END WriteZeroes;

PROCEDURE WriteBootstrap;
BEGIN
  spos(FadrModules);
  Files.WriteBytes(Exe, Bootstrap, Bootstrap.Header.imports);  (* Code and tables   *)
  Files.WriteInt(Exe, ImageBase + RvaModules);                 (* Header address    *)
  Files.WriteBytes(Exe, Idt.Lookups, ImportCount*8);           (* Import references *)
  WriteZeroes(Bootstrap.Header.varsize - (ImportCount*8 + 8))
END WriteBootstrap;


PROCEDURE Generate*(filename: ARRAY OF CHAR);
VAR fpos: INTEGER;
BEGIN
  ExeFile := Files.New(filename);

  GetBootstrap;

  WriteImports;

  WriteBootstrap;

  WriteModules;

  WritePEHeader;

  Files.Register(ExeFile)
END Generate;

BEGIN (* w.sl("WinPE loaded.") *)
END WinPE.