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
	"encoding/json"
	"errors"
	"reflect"

	"github.com/iancoleman/strcase"
)

type Prototype interface {
	json.Marshaler

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
		panic(errors.New("must call MakePrototype() on protoype struct before calling MarshalJSON()"))
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

func getJsonTag(fieldTyp reflect.StructField) string {
	jsonTag := fieldTyp.Tag.Get("json")
	if jsonTag == "" {
		return strcase.ToLowerCamel(fieldTyp.Name)
	} else {
		return jsonTag
	}
}
