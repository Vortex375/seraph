// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option)
// any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

package taglib

import (
	"io"
	"unsafe"

	"golang.org/x/net/webdav"
)

type off_t struct {
	v int64
}

func (o *off_t) Swigcptr() uintptr {
	return uintptr(unsafe.Pointer(&o.v))
}

type WebdavFileStream interface {
	IOStream
	Delete()
	IsWebdavFileStream()
}

type webdavFileStream struct {
	IOStream
	om *overwrittenMethodsOnWebdavFileStream
}

func (m *webdavFileStream) Delete() {
	m.om.file.Close()
	DeleteDirectorIOStream(m.IOStream)
}

func (m *webdavFileStream) IsWebdavFileStream() {
	/* empty */
}

type overwrittenMethodsOnWebdavFileStream struct {
	ioStream IOStream

	name   string
	file   webdav.File
	offset int64
}

func NewWebdavFileStream(name string, file webdav.File) WebdavFileStream {
	om := &overwrittenMethodsOnWebdavFileStream{}
	ioStream := NewDirectorIOStream(om)
	om.ioStream = ioStream

	om.name = name
	om.file = file
	om.offset = 0

	return &webdavFileStream{IOStream: ioStream, om: om}
}

func (om *overwrittenMethodsOnWebdavFileStream) Name() string {
	// fmt.Printf("Name()\n")
	ret := om.name
	// fmt.Printf("Name() => %v\n", ret)
	return ret
}

func (om *overwrittenMethodsOnWebdavFileStream) ReadBlock(arg2 int64) ByteVector {
	// fmt.Printf("ReadBlock(%v)\n", arg2)
	bytes := make([]byte, arg2)
	n, err := om.file.Read(bytes)
	if err != nil || n == 0 {
		ret := NewByteVector()
		// fmt.Printf("ReadBlock(%v) => %v\n", arg2, ret)
		return ret
	}
	ret := NewByteVector(string(bytes[:n]), uint(n))
	// fmt.Printf("ReadBlock(%v) => %v\n", arg2, ret.Data())
	return ret
}

func (om *overwrittenMethodsOnWebdavFileStream) ReadOnly() bool {
	// fmt.Printf("ReadOnly() => true\n")
	return true
}

func (om *overwrittenMethodsOnWebdavFileStream) IsOpen() bool {
	// fmt.Printf("IsOpen() => true\n")
	return true
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek(a ...interface{}) {
	// fmt.Printf("Seek(%v)\n", a)

	offset := a[0].(Off_t)
	addr := offset.Swigcptr()
	ptr := unsafe.Pointer(addr)
	value := *(*int64)(ptr)

	// fmt.Printf("Seek(%v)\n", value)
	whence := io.SeekStart
	if len(a) > 1 {
		pos := a[1].(TagLibIOStreamPosition)
		switch pos {
		case IOStreamBeginning:
			whence = io.SeekStart
		case IOStreamCurrent:
			whence = io.SeekCurrent
		case IOStreamEnd:
			whence = io.SeekEnd
		}
	}
	position, err := om.file.Seek(value, whence)
	if err == nil {
		om.offset = position
	}

	// fmt.Printf("Seek(%v) => %v, %v\n", a, position, err)
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek__SWIG_0(offset Off_t, pos TagLibIOStreamPosition) {
	// fmt.Printf("Seek__SWIG_0(%v,%v)\n", offset, pos)
	om.Seek(offset, pos)
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek__SWIG_1(offset Off_t) {
	// fmt.Printf("Seek__SWIG_1(%v)\n", offset)
	om.Seek(offset)
}

func (om *overwrittenMethodsOnWebdavFileStream) Tell() Off_t {
	ret := om.offset
	// fmt.Printf("Tell() => %v\n", ret)

	return &off_t{ret}
}

func (om *overwrittenMethodsOnWebdavFileStream) Length() Off_t {
	// fmt.Printf("Length()\n")
	currentPos := om.offset
	len, err := om.file.Seek(0, io.SeekEnd)
	if err != nil {
		return &off_t{0}
	}
	om.file.Seek(currentPos, io.SeekStart)
	// fmt.Printf("Length() => %v\n", len)

	return &off_t{len}
}
