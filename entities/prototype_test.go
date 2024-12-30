package entities_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"umbasa.net/seraph/entities"
)

type TestProto struct {
	entities.Prototype

	StringProp entities.Definable[string]
	NumberProp entities.Definable[int]
	FloatProp  entities.Definable[float64]

	StructProp entities.Definable[TestRecord]

	SliceProp       entities.Definable[[]string]
	SliceStructProp entities.Definable[[]TestRecord]
}

type TestRecord struct {
	Value string
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
	testProto.SliceProp.Set([]string{"foo", "bar"})

	data, err := json.Marshal(testProto)
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{\"floatProp\":21.3,\"numberProp\":21,\"sliceProp\":[\"foo\",\"bar\"],\"stringProp\":\"Hello, World\"}", str)
}

func TestMarshalEmpty(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	data, err := json.Marshal(testProto)
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{}", str)
}

func TestUnmarshalProp(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"stringProp\": \"testValue\", \"numberProp\": 42, \"floatProp\": 42.5, \"sliceProp\": [\"foo\", \"bar\"] }"

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.Nil(t, err)
	assert.True(t, testProto.StringProp.IsDefined())
	assert.Equal(t, "testValue", testProto.StringProp.Get())
	assert.True(t, testProto.NumberProp.IsDefined())
	assert.Equal(t, 42, testProto.NumberProp.Get())
	assert.True(t, testProto.FloatProp.IsDefined())
	assert.Equal(t, 42.5, testProto.FloatProp.Get())
	assert.True(t, testProto.SliceProp.IsDefined())
	assert.Equal(t, []string{"foo", "bar"}, testProto.SliceProp.Get())
}

func TestUnmarshalEmpty(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{}"

	err := json.Unmarshal([]byte(jsonString), &testProto)

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

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.Nil(t, err)
	assert.Equal(t, "", testProto.StringProp.Get())
	assert.False(t, testProto.StringProp.IsDefined())
}

func TestUnmarshalWrongType(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"stringProp\": 42 }"

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.NotNil(t, err)
}

func TestUnmarshalWrongType2(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{ \"numberProp\": 42.5 }"

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.NotNil(t, err)
}

func TestMarshalStruct(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})
	testProto.StructProp.Set(TestRecord{
		Value: "hello",
	})

	data, err := json.Marshal(testProto)
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{\"structProp\":{\"Value\":\"hello\"}}", str)
}

func TestUnMarshalStruct(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{\"structProp\":{\"Value\":\"hello\"}}"

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.Nil(t, err)
	assert.False(t, testProto.StringProp.IsDefined())
	assert.True(t, testProto.StructProp.IsDefined())
	assert.Equal(t, TestRecord{"hello"}, testProto.StructProp.Get())
}

func TestMarshalStructSlice(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})
	testProto.SliceStructProp.Set([]TestRecord{
		{Value: "hello"},
		{Value: "world"},
	})

	data, err := json.Marshal(testProto)
	str := string(data)

	assert.Nil(t, err)
	assert.Equal(t, "{\"sliceStructProp\":[{\"Value\":\"hello\"},{\"Value\":\"world\"}]}", str)
}

func TestUnMarshalStructSlice(t *testing.T) {
	testProto := entities.MakePrototype(&TestProto{})

	jsonString := "{\"sliceStructProp\":[{\"Value\":\"hello\"},{\"Value\":\"world\"}]}"

	err := json.Unmarshal([]byte(jsonString), &testProto)

	assert.Nil(t, err)
	assert.False(t, testProto.StringProp.IsDefined())
	assert.False(t, testProto.StructProp.IsDefined())
	assert.True(t, testProto.SliceStructProp.IsDefined())
	assert.Equal(t, []TestRecord{{"hello"}, {"world"}}, testProto.SliceStructProp.Get())
}
