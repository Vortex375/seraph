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
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
)

type Definable[T any] struct {
	Value   T
	Defined bool
}

type definableGetter interface {
	getInternal() (any, bool)
	getType() reflect.Type
}

type definableSetter interface {
	setInternal(any, bool)
}

var _ definableGetter = Definable[any]{}
var _ definableSetter = &Definable[any]{}

func (d *Definable[T]) Set(value T) {
	d.Value = value
	d.Defined = true
}

func (d *Definable[T]) Unset() {
	var null T
	d.Value = null
	d.Defined = false
}

func (d *Definable[T]) Get() T {
	return d.Value
}

func (d *Definable[T]) IsDefined() bool {
	return d.Defined
}

func (d Definable[T]) getInternal() (any, bool) {
	return d.Value, d.Defined
}

func (d Definable[T]) getType() reflect.Type {
	var t [0]T
	return reflect.TypeOf(t).Elem()
}

func (d *Definable[T]) setInternal(v any, defined bool) {
	if converted, ok := v.(T); ok {
		d.Value = converted
	} else {
		valueTyp := reflect.TypeOf(v)
		valueVal := reflect.ValueOf(v)
		defTyp := d.getType()

		if valueVal.CanConvert(defTyp) {
			converted = valueVal.Convert(defTyp).Interface().(T)
			d.Value = converted
		} else if defTyp.Kind() == reflect.Slice && valueTyp.Kind() == reflect.Slice {
			if valueVal.Len() == 0 {
				d.Defined = defined
				return
			}
			defElemTyp := defTyp.Elem()
			targetSlice := reflect.MakeSlice(defTyp, 0, 0)
			for i := 0; i < valueVal.Len(); i++ {
				v := valueVal.Index(i)
				if v.Kind() == reflect.Interface {
					v = v.Elem()
				}
				if !v.CanConvert(defElemTyp) {
					panic(errors.New("unable to convert " + v.Type().String() + " to " + defElemTyp.String()))
				}
				targetSlice = reflect.Append(targetSlice, v.Convert(defElemTyp))
			}
			d.Value = targetSlice.Interface().(T)
		} else {
			panic(errors.New("unable to convert " + valueVal.Type().String() + " to " + defTyp.String()))
		}
	}
	d.Defined = defined
}

func (d *Definable[T]) UnmarshalJSON(b []byte) error {
	var v T
	decoder := json.NewDecoder(bytes.NewReader(b))
	err := decoder.Decode(&v)
	if err != nil {
		return err
	}

	d.Value = v
	d.Defined = true
	return nil
}
