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
	// Registers a token for a user with a password. The token can later be retrieved using the same username and password.
	// If there's already a token registered for the user it is replaced with the new token and the new password.
	registerTokenWithPassword(context context.Context, userId string, username string, password string, refreshToken string) error

	// Retrieves a stored token using username and password. Returns empty string if no token was found with the given username/password
	// combination. Second parameter is set to true if the user has a token stored (but the password might have been incorrect)
	// and to false if no token is stored at all (meaning no password will be sucessful for this user)
	getTokenWithPassword(context context.Context, username string, password string) (string, bool, error)

	// Deletes the stored token for this user, if any
	deleteToken(context context.Context, userId string) error
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

func (store *tokenStore) getTokenWithPassword(context context.Context, username string, password string) (string, bool, error) {
	filter := TokenPrototype{}
	filter.UserName.Set(username)

	res := store.tokens.FindOne(context, filter)
	if errors.Is(res.Err(), mongo.ErrNoDocuments) {
		return "", false, nil
	}
	if res.Err() != nil {
		return "", false, res.Err()
	}

	token := Token{}
	err := res.Decode(&token)
	if err != nil {
		return "", false, err
	}

	err = bcrypt.CompareHashAndPassword([]byte(token.Password), []byte(password))
	if err != nil {
		return "", true, nil
	}

	return token.RefreshToken, true, nil

}

func (store *tokenStore) deleteToken(context context.Context, userId string) error {
	filter := TokenPrototype{}
	filter.UserId.Set(userId)

	_, err := store.tokens.DeleteOne(context, filter)

	return err
}
