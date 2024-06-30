To build the wrapper:

```
swig -v -I/usr/include -go -cgo -c++ taglib.i
```

Add to `taglib.go`:
```
#cgo CXXFLAGS: -fpermissive
#cgo LDFLAGS: -ltag -lz
```

In `taglib_wrap.cxx` search for
```
arg1[_swig_go_0.n] = '\0';
```
replace with
```
((char*)arg1)[_swig_go_0.n] = '\0';
```