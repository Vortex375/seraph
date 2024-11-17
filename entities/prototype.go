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
	"fmt"
	"reflect"

	"github.com/iancoleman/strcase"
)

type Prototype interface {
	json.Marshaler
	json.Unmarshaler

	isPrototype()
}

type proto struct {
	v any
}

var _ Prototype = &proto{}

func MakePrototype[T Prototype](v T) T {
	if reflect.TypeOf(v).Kind() != reflect.Pointer {
		panic(errors.New("MakePrototype must be called with pointer value"))
	}
	protoTyp := reflect.TypeFor[Prototype]()
	prot := &proto{v}
	typ := reflect.TypeOf(v).Elem()
	val := reflect.ValueOf(v).Elem()

	for i := 0; i < typ.NumField(); i++ {
		fieldTyp := typ.Field(i)
		if fieldTyp.Anonymous && fieldTyp.Type.Implements(protoTyp) {
			fieldVal := val.Field(i)
			protVal := reflect.ValueOf(prot)
			fieldVal.Set(protVal)
		}
	}
	return v
}

func (*proto) isPrototype() {}

func (p *proto) MarshalJSON() ([]byte, error) {
	if p == nil {
		panic(errors.New("must call InitPrototype() on protoype struct before calling MarshalJSON()"))
	}

	// first, convert to map
	m := make(map[string]any)

	typ := reflect.TypeOf(p.v).Elem()
	val := reflect.ValueOf(p.v).Elem()

	for i := 0; i < typ.NumField(); i++ {
		fieldTyp := typ.Field(i)
		fieldVal := val.Field(i)

		if fieldTyp.Anonymous || !fieldTyp.IsExported() {
			continue
		}

		jsonFieldName := getJsonTag(fieldTyp)
		v := fieldVal.Interface()

		if definable, ok := v.(definableGetter); ok {
			value, defined := definable.getInternal()
			if defined {
				m[jsonFieldName] = value
			}
		} else {
			m[jsonFieldName] = val
		}
	}

	return json.Marshal(m)
}

func (p *proto) UnmarshalJSON(v []byte) error {
	if p == nil {
		panic(errors.New("must call InitPrototype() on protoype struct before calling UnmarshalJSON()"))
	}

	// first, unmarshal to map
	m := make(map[string]any)
	decoder := json.NewDecoder(bytes.NewReader(v))
	decoder.UseNumber()
	err := decoder.Decode(&m)
	if err != nil {
		return err
	}

	typ := reflect.TypeOf(p.v).Elem()
	val := reflect.ValueOf(p.v).Elem()

	for i := 0; i < typ.NumField(); i++ {
		fieldTyp := typ.Field(i)
		fieldVal := val.Field(i)

		if fieldTyp.Anonymous || !fieldTyp.IsExported() {
			continue
		}

		jsonFieldName := getJsonTag(fieldTyp)

		jsonVal, ok := m[jsonFieldName]
		if ok {
			err = tryAssign(fieldTyp, fieldVal, jsonVal)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

func getJsonTag(fieldTyp reflect.StructField) string {
	jsonTag := fieldTyp.Tag.Get("json")
	if jsonTag == "" {
		return strcase.ToLowerCamel(fieldTyp.Name)
	} else {
		return jsonTag
	}
}

func tryAssign(field reflect.StructField, fieldVal reflect.Value, v any) (ret error) {
	defer func() {
		if rec := recover(); rec != nil {
			if recErr, ok := rec.(error); ok {
				ret = fmt.Errorf("error while setting value of '%s': %w", field.Name, recErr)
			} else {
				ret = fmt.Errorf("error while setting value of '%s': %v", field.Name, rec)
			}
		}
	}()

	if number, ok := v.(json.Number); ok {
		valueTyp := getValueType(field, fieldVal)

		if isInt(valueTyp) {
			intVal, err := number.Int64()
			if err != nil {
				return fmt.Errorf("error while setting value of '%s': %w", field.Name, err)
			}
			v = intVal
		} else if isFloat(valueTyp) {
			floatVal, err := number.Float64()
			if err != nil {
				return fmt.Errorf("error while setting value of '%s': %w", field.Name, err)
			}
			v = floatVal
		} else {
			return fmt.Errorf("error while setting value of '%s': unable to convert JSON number to %s", field.Name, field.Type.String())
		}
	}

	switch {
	case tryAssignDefinable(fieldVal, v):
	case fieldVal.CanSet():
		fieldVal.Set(reflect.ValueOf(v))
	default:
		return errors.New("unable to set value of " + field.Name)
	}
	return nil
}

func getValueType(field reflect.StructField, fieldVal reflect.Value) reflect.Type {
	if !fieldVal.IsValid() {
		return nil
	}
	if !fieldVal.CanInterface() {
		return nil
	}

	fieldInterface := fieldVal.Interface()

	definable, ok := fieldInterface.(definableGetter)
	if ok {
		return definable.getType()
	} else {
		return field.Type
	}
}

func isInt(typ reflect.Type) bool {
	switch typ.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return true
	default:
		return false
	}
}

func isFloat(typ reflect.Type) bool {
	switch typ.Kind() {
	case reflect.Float32, reflect.Float64:
		return true
	default:
		return false
	}
}

func tryAssignDefinable(fieldVal reflect.Value, v any) bool {
	if !fieldVal.IsValid() {
		return false
	}
	var fieldPtr reflect.Value
	if fieldVal.Kind() == reflect.Pointer {
		fieldPtr = fieldVal
	} else if fieldVal.CanAddr() {
		fieldPtr = fieldVal.Addr()
	} else {
		return false
	}

	if !fieldPtr.CanInterface() {
		return false
	}

	fieldInterface := fieldPtr.Interface()

	definable, ok := fieldInterface.(definableSetter)
	if !ok {
		return false
	}

	definable.setInternal(v, true)
	return true
}
