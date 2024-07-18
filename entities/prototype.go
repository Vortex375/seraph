package entities

import (
	"reflect"
	"strings"

	"go.mongodb.org/mongo-driver/bson"
)

type Prototype interface {
	isPrototype()
}

func ToBson(p Prototype) bson.M {
	t := reflect.TypeOf(p)
	v := reflect.ValueOf(p)

	if t.Kind() == reflect.Pointer {
		t = t.Elem()
		v = v.Elem()
	}

	ret := bson.M{}

	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if !field.IsExported() {
			continue
		}
		if field.Anonymous {
			continue
		}

		fieldValue := v.Field(i)
		fieldIsNil := safeIsNil(fieldValue)
		fieldValueInterface := fieldValue.Interface()

		tag := field.Tag.Get("bson")
		var fieldName string
		if tag == "" {
			fieldName = strings.ToLower(field.Name)
		} else {
			fieldName = tag
		}

		if def, ok := fieldValueInterface.(definableInternal); ok {
			if fieldIsNil {
				continue
			}
			if val, defined := def.getInternal(); defined {
				ret[fieldName] = val
			}
		} else {
			ret[fieldName] = fieldValueInterface
		}
	}

	return ret
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
