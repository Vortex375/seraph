# SWIG's Go string-argument code writes a NUL terminator through the
# `const char *` it copied into; cast the const away so it compiles.
taglib.go taglib_wrap.cxx taglib_wrap.h: taglib.i
	swig -I/usr/include -go -cgo -c++ taglib.i
	sed -i 's|arg1\[_swig_go_0.n\] = |((char*)arg1)[_swig_go_0.n] = |' taglib_wrap.cxx
	gofmt -w taglib.go
