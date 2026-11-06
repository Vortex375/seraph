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

	"golang.org/x/net/webdav"
)

type WebdavFileStream interface {
	IOStream
	Delete()
	IsWebdavFileStream()
}

type webdavFileStream struct {
	IOStream
	om *overwrittenMethodsOnWebdavFileStream
}

// Delete frees the stream and closes its file. Delete any FileRef reading
// from the stream first: the FileRef does not own the stream.
func (m *webdavFileStream) Delete() {
	m.om.freeLastBlock()
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

	// lastBlock is the ByteVector most recently returned by ReadBlock. The
	// director copies it (ByteVectors are implicitly shared, so that is
	// cheap) but never frees the wrapper's heap object; it is freed on the
	// next read or on Delete.
	lastBlock ByteVector
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

func (om *overwrittenMethodsOnWebdavFileStream) freeLastBlock() {
	if om.lastBlock != nil {
		DeleteByteVector(om.lastBlock)
		om.lastBlock = nil
	}
}

func (om *overwrittenMethodsOnWebdavFileStream) Name() string {
	return om.name
}

func (om *overwrittenMethodsOnWebdavFileStream) ReadBlock(length int64) ByteVector {
	om.freeLastBlock()

	bytes := make([]byte, length)
	n, err := io.ReadFull(om.file, bytes)
	om.offset += int64(n)
	if n == 0 {
		om.lastBlock = NewByteVector()
	} else {
		// a short read at the end of the file is not an error for TagLib
		_ = err
		om.lastBlock = NewByteVector(string(bytes[:n]), uint(n))
	}
	return om.lastBlock
}

func (om *overwrittenMethodsOnWebdavFileStream) ReadOnly() bool {
	return true
}

func (om *overwrittenMethodsOnWebdavFileStream) IsOpen() bool {
	return true
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek(a ...interface{}) {
	offset := a[0].(int64)
	whence := io.SeekStart
	if len(a) > 1 {
		switch a[1].(TagLibIOStreamPosition) {
		case IOStreamBeginning:
			whence = io.SeekStart
		case IOStreamCurrent:
			whence = io.SeekCurrent
		case IOStreamEnd:
			whence = io.SeekEnd
		}
	}
	position, err := om.file.Seek(offset, whence)
	if err == nil {
		om.offset = position
	}
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek__SWIG_0(offset int64, pos TagLibIOStreamPosition) {
	om.Seek(offset, pos)
}

func (om *overwrittenMethodsOnWebdavFileStream) Seek__SWIG_1(offset int64) {
	om.Seek(offset)
}

func (om *overwrittenMethodsOnWebdavFileStream) Tell() int64 {
	return om.offset
}

func (om *overwrittenMethodsOnWebdavFileStream) Length() int64 {
	length, err := om.file.Seek(0, io.SeekEnd)
	if err != nil {
		return 0
	}
	om.file.Seek(om.offset, io.SeekStart)
	return length
}
