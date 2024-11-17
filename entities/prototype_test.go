package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"umbasa.net/seraph/entities"
)

type TestProto struct {
	entities.Prototype

	StringProp entities.Definable[string]
	NumberProp entities.Definable[int]
	FloatProp  entities.Definable[float64]
}

func TestPanicNonPointer(t *testing.T) {
	assert.PanicsWithError(t, "MakePrototype must be called with pointer value", func() {
		entities.MakePrototype(TestProto{})
	})
}

func TestMarshal(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})
	testProto.StringProp.Set("Hello, World")
	testProto.NumberProp.Set(21)
	testProto.FloatProp.Set(21.3)

	data, err := testProto.MarshalJSON()
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{\"floatProp\":21.3,\"numberProp\":21,\"stringProp\":\"Hello, World\"}", str)
}

func TestMarshalEmpty(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	data, err := testProto.MarshalJSON()
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{}", str)
}

func TestUnmarshalProp(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"stringProp\": \"testValue\", \"numberProp\": 42, \"floatProp\": 42.5 }"

	err := testProto.UnmarshalJSON([]byte(jsonString))

	assert.Nil(t, err)
	assert.Equal(t, "testValue", testProto.StringProp.Get())
	assert.Equal(t, 42, testProto.NumberProp.Get())
	assert.Equal(t, 42.5, testProto.FloatProp.Get())
	assert.True(t, testProto.StringProp.IsDefined())
}

func TestUnmarshalEmpty(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{}"

	err := testProto.UnmarshalJSON([]byte(jsonString))

	assert.Nil(t, err)
	assert.Equal(t, "", testProto.StringProp.Get())
	assert.False(t, testProto.StringProp.IsDefined())
	assert.Equal(t, 0, testProto.NumberProp.Get())
	assert.False(t, testProto.NumberProp.IsDefined())
	assert.Equal(t, 0.0, testProto.FloatProp.Get())
	assert.False(t, testProto.FloatProp.IsDefined())
}

func TestUnmarshalUnknownProp(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"foo\": \"bar\" }"

	err := testProto.UnmarshalJSON([]byte(jsonString))

	assert.Nil(t, err)
	assert.Equal(t, "", testProto.StringProp.Get())
	assert.False(t, testProto.StringProp.IsDefined())
}

func TestUnmarshalWrongType(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"stringProp\": 42 }"

	err := testProto.UnmarshalJSON([]byte(jsonString))

	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "error while setting value of 'StringProp'")
}

func TestUnmarshalWrongType2(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"numberProp\": 42.5 }"

	err := testProto.UnmarshalJSON([]byte(jsonString))

	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "error while setting value of 'NumberProp'")
}
