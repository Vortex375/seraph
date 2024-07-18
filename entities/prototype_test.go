package entities_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"go.mongodb.org/mongo-driver/bson"
	"umbasa.net/seraph/entities"
)

type test struct {
	entities.Prototype
}

type test2 struct {
	entities.Prototype

	StrVal entities.Definable[string] `bson:"strVal"`
	NumVal entities.Definable[int]    `bson:"numVal"`
}

func TestToBsonEmpty(t *testing.T) {
	foo := test{}

	assert.Equal(t, bson.M{}, entities.ToBson(foo))
}

func TestToBsonEmpty2(t *testing.T) {
	foo := test2{}

	assert.Equal(t, bson.M{}, entities.ToBson(foo))
}

func TestToBson(t *testing.T) {
	foo := test2{}

	foo.StrVal.Set("hello, world")
	foo.NumVal.Set(42)

	assert.Equal(t, bson.M{
		"strVal": "hello, world",
		"numVal": 42,
	}, entities.ToBson(foo))
}

func TestToBson1(t *testing.T) {
	foo := test2{}

	foo.StrVal.Set("hello, world")

	assert.Equal(t, bson.M{
		"strVal": "hello, world",
	}, entities.ToBson(foo))
}

func TestToBson2(t *testing.T) {
	foo := test2{}

	foo.NumVal.Set(42)

	assert.Equal(t, bson.M{
		"numVal": 42,
	}, entities.ToBson(foo))
}
