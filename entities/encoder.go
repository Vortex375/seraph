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

package entities

import (
	"errors"
	"reflect"
	"strings"

	"go.mongodb.org/mongo-driver/bson/bsoncodec"
	"go.mongodb.org/mongo-driver/bson/bsonrw"
)

type PrototypeEncoder struct{}

func (e *PrototypeEncoder) EncodeValue(ctx bsoncodec.EncodeContext, vw bsonrw.ValueWriter, val reflect.Value) error {
	typ := val.Type()

	if typ.Kind() == reflect.Pointer {
		typ = typ.Elem()
		val = val.Elem()
	}

	docWriter, err := vw.WriteDocument()
	if err != nil {
		return err
	}

	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		if !field.IsExported() {
			continue
		}
		if field.Anonymous {
			continue
		}

		tag := field.Tag.Get("bson")
		var fieldName string
		if tag == "" {
			fieldName = strings.ToLower(field.Name)
		} else {
			fieldName = tag
		}

		fieldValue := val.Field(i)
		fieldIsNil := safeIsNil(fieldValue)
		fieldValueInterface := fieldValue.Interface()

		if def, ok := fieldValueInterface.(definableInternal); ok {
			if fieldIsNil {
				// Definables are always "omitempty"
				continue
			}
			val, defined := def.getInternal()
			if !defined {
				continue
			}
			fieldValue = reflect.ValueOf(val)
		}
		valWriter, err := docWriter.WriteDocumentElement(fieldName)
		if err != nil {
			return err
		}
		enc, err := ctx.LookupEncoder(fieldValue.Type())
		if err != nil {
			return err
		}
		err = enc.EncodeValue(ctx, valWriter, fieldValue)
		if err != nil {
			return err
		}
	}
	err = docWriter.WriteDocumentEnd()

	return err
}

type DefinableEncoder struct{}

func (e *DefinableEncoder) EncodeValue(ctx bsoncodec.EncodeContext, vw bsonrw.ValueWriter, val reflect.Value) error {

	valDefinable, ok := val.Interface().(definableInternal)
	if !ok {
		return errors.New("value is not Definable")
	}
	value, _ := valDefinable.getInternal()

	encoder, err := ctx.LookupEncoder(reflect.TypeOf(value))
	if err != nil {
		return err
	}

	return encoder.EncodeValue(ctx, vw, reflect.ValueOf(value))
}

func RegisterEncoders(r *bsoncodec.Registry) {
	var d definableInternal
	definableType := reflect.TypeOf(&d).Elem()
	r.RegisterInterfaceEncoder(definableType, &DefinableEncoder{})

	var p Prototype
	prototypeType := reflect.TypeOf(&p).Elem()
	r.RegisterInterfaceEncoder(prototypeType, &PrototypeEncoder{})
}

func safeIsNil(v reflect.Value) bool {
	k := v.Kind()
	switch k {
	case reflect.Chan, reflect.Func, reflect.Map, reflect.Pointer, reflect.UnsafePointer, reflect.Interface, reflect.Slice:
		return v.IsNil()
	default:
		return false
	}
}
