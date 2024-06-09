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
