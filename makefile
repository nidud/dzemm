dzemm.sys:
	asmc -bin -Fo $*.sys $*.asm
	asmc -c -Fo $*.obj $*d.asm
	linkw system dll_32 file $*.obj
	del $*.obj

