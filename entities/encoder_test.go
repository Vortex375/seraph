package entities_test

import (
	"bytes"
	"testing"

	"github.com/stretchr/testify/assert"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/bsoncodec"
	"go.mongodb.org/mongo-driver/bson/bsonrw"
	"umbasa.net/seraph/entities"
)

type testEncEmpty struct {
	entities.Prototype
}

type testEnc1 struct {
	entities.Prototype

	StrVal entities.Definable[string] `bson:"strVal"`
	NumVal entities.Definable[int]    `bson:"numVal"`
}

func getCustomRegistry() *bsoncodec.Registry {
	r := bson.NewRegistry()

	// Register Definable encoder
	entities.RegisterEncoders(r)

	return r
}

func getEncoder(buf *bytes.Buffer) (*bson.Encoder, error) {
	vw, err := bsonrw.NewBSONValueWriter(buf)
	if err != nil {
		return nil, err
	}
	enc, err := bson.NewEncoder(vw)
	if err != nil {
		return nil, err
	}
	enc.SetRegistry(getCustomRegistry())
	return enc, nil
}

func TestDefinableEncoderEmpty(t *testing.T) {
	v := testEncEmpty{}
	expected := bson.M{}
	doTest(t, v, expected)
}

func TestDefinableEncoder1(t *testing.T) {
	v := testEnc1{}
	v.StrVal.Set("hello")
	v.NumVal.Set(42)

	expected := bson.M{
		"strVal": "hello",
		"numVal": int32(42),
	}

	doTest(t, v, expected)
}

func TestDefinableEncoder2(t *testing.T) {
	v := testEnc1{}
	v.NumVal.Set(27)

	expected := bson.M{
		"numVal": int32(27),
	}

	doTest(t, v, expected)
}

func TestDefinableEncoder3(t *testing.T) {
	v := testEnc1{}
	v.StrVal.Set("foo")

	expected := bson.M{
		"strVal": "foo",
	}

	doTest(t, v, expected)
}

func TestDefinableEncoder4(t *testing.T) {
	v := testEnc1{}

	expected := bson.M{}

	doTest(t, v, expected)
}

func doTest[T entities.Prototype](t *testing.T, v T, expected bson.M) {
	buf := new(bytes.Buffer)
	enc, err := getEncoder(buf)
	if err != nil {
		t.Fatal(err)
	}

	err = enc.Encode(v)
	if err != nil {
		t.Fatal(err)
	}

	data := buf.Bytes()

	var result bson.M
	err = bson.Unmarshal(data, &result)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, expected, result)
}
