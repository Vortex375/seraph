// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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

type TokenStore interface {
	registerTokenWithPassword(userId string, username string, password string, refreshToken string) error
	getTokenWithPassword(username string, password string) string
}

// TODO: dummy implementation, does not verify password
type tokenStore struct {
	tokens map[string]string
}

func NewTokenStore() TokenStore {
	return &tokenStore{
		make(map[string]string),
	}
}

func (store *tokenStore) registerTokenWithPassword(userId string, username string, password string, refreshToken string) error {
	store.tokens[username] = refreshToken
	return nil
}

func (store *tokenStore) getTokenWithPassword(username string, password string) string {
	return store.tokens[username]
}
