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

package auth

import (
	"context"
	"errors"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/bcrypt"
	"umbasa.net/seraph/entities"
)

type TokenStore interface {
	registerTokenWithPassword(context context.Context, userId string, username string, password string, refreshToken string) error
	getTokenWithPassword(context context.Context, username string, password string) (string, error)
}

type TokenPrototype struct {
	entities.Prototype

	Id           entities.Definable[primitive.ObjectID] `bson:"_id"`
	UserId       entities.Definable[string]             `bson:"userId"`
	UserName     entities.Definable[string]             `bson:"userName"`
	Password     entities.Definable[string]             `bson:"password"`
	RefreshToken entities.Definable[string]             `bson:"refreshToken"`
}

type Token struct {
	Id           primitive.ObjectID `bson:"_id"`
	UserId       string             `bson:"userId"`
	UserName     string             `bson:"userName"`
	Password     string             `bson:"password"`
	RefreshToken string             `bson:"refreshToken"`
}

type tokenStore struct {
	tokens *mongo.Collection
}

func NewTokenStore(db *mongo.Database) TokenStore {
	return &tokenStore{
		db.Collection("tokens"),
	}
}

func (store *tokenStore) registerTokenWithPassword(context context.Context, userId string, username string, password string, refreshToken string) error {
	filter := TokenPrototype{}
	filter.UserId.Set(userId)

	hashedPw, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}

	token := TokenPrototype{}
	token.UserId.Set(userId)
	token.UserName.Set(username)
	token.Password.Set(string(hashedPw))
	token.RefreshToken.Set(refreshToken)

	_, err = store.tokens.UpdateOne(context, &filter, bson.M{"$set": &token}, options.Update().SetUpsert(true))
	return err
}

func (store *tokenStore) getTokenWithPassword(context context.Context, username string, password string) (string, error) {
	filter := TokenPrototype{}
	filter.UserName.Set(username)

	res := store.tokens.FindOne(context, filter)
	if errors.Is(res.Err(), mongo.ErrNoDocuments) {
		return "", nil
	}
	if res.Err() != nil {
		return "", res.Err()
	}

	token := Token{}
	err := res.Decode(&token)
	if err != nil {
		return "", err
	}

	err = bcrypt.CompareHashAndPassword([]byte(token.Password), []byte(password))
	if err != nil {
		return "", nil
	}

	return token.RefreshToken, nil

}
