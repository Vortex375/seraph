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
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/coreos/go-oidc"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	cachecontrol "go.eigsys.de/gin-cachecontrol/v2"
	"go.mongodb.org/mongo-driver/mongo"

	"github.com/google/uuid"
	"go.uber.org/fx"
	"golang.org/x/oauth2"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"

	"github.com/zitadel/oidc/v3/pkg/client/rs"
	zoidc "github.com/zitadel/oidc/v3/pkg/oidc"
)

var Module = fx.Module("auth",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log   *logging.Logger
	Viper *viper.Viper
	Js    jetstream.JetStream

	Db  *mongo.Database
	Mig Migrations
}

type Result struct {
	fx.Out

	Auth    Auth
	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type Auth interface {
	AuthMiddleware(enablePasswordAuth bool, realm string) func(*gin.Context) bool
	GetUserId(context.Context) string
	IsSpaceAdmin(context.Context) bool
}

type oidcAuth struct {
	log            *slog.Logger
	configUrl      string
	provider       *oidc.Provider
	resourceServer rs.ResourceServer
	config         *oauth2.Config
	offlineConfig  *oauth2.Config
	verifier       *oidc.IDTokenVerifier

	appClientId string

	passwordCache      jetstream.KeyValue
	introspectionCache jetstream.KeyValue

	tokenStore TokenStore
}

type userIdKey struct{}

func New(p Params) (Result, error) {
	log := p.Log.GetLogger("auth")

	p.Viper.SetDefault("auth.enabled", true)
	p.Viper.SetDefault("auth.configURL", "http://localhost:8081/realms/seraph")
	p.Viper.SetDefault("auth.redirectURL", "http://localhost:8080/auth/callback")
	p.Viper.SetDefault("auth.clientId", "seraph")
	p.Viper.SetDefault("auth.appClientId", "seraph-app")
	p.Viper.SetDefault("auth.clientScopes", make([]string, 0))

	if !p.Viper.GetBool("auth.enabled") {
		log.Warn("AUTHENTICATION DISABLED via auth.enabled parameter!! Access to all APIs and data is granted without login.")
		auth := &noAuth{}
		return Result{Auth: auth, Handler: auth}, nil
	}

	configURL := p.Viper.GetString("auth.configURL")
	clientID := p.Viper.GetString("auth.clientId")
	clientSecret := p.Viper.GetString("auth.clientSecret")
	clientScopes := p.Viper.GetStringSlice("auth.clientScopes")
	redirectURL := p.Viper.GetString("auth.redirectURL")
	appClientId := p.Viper.GetString("auth.appClientId")
	ctx := context.Background()

	log.Info("oidc configuration", "issuer", configURL, "clientId", clientID, "clientScopes", clientScopes, "redirectUrl", redirectURL)

	provider, err := oidc.NewProvider(ctx, configURL)
	if err != nil {
		return Result{}, err
	}

	resourceServer, err := rs.NewResourceServerClientCredentials(ctx, configURL, clientID, clientSecret)
	if err != nil {
		return Result{}, err
	}

	scopes := append(append(make([]string, 0, 3+len(clientScopes)), oidc.ScopeOpenID, "profile", "email"), clientScopes...)

	oauth2Config := oauth2.Config{
		ClientID:     clientID,
		ClientSecret: clientSecret,
		RedirectURL:  redirectURL,
		// Discovery returns the OAuth2 endpoints.
		Endpoint: provider.Endpoint(),
		// "openid" is a required scope for OpenID Connect flows.
		Scopes: scopes,
	}

	verifier := provider.Verifier(&oidc.Config{
		ClientID: clientID,
	})

	offlineConfig := oauth2.Config{
		ClientID:     clientID,
		ClientSecret: clientSecret,
		RedirectURL:  redirectURL,
		// Discovery returns the OAuth2 endpoints.
		Endpoint: provider.Endpoint(),
		// "openid" is a required scope for OpenID Connect flows.
		Scopes: append(append(make([]string, 0, len(scopes)+1), scopes...), oidc.ScopeOfflineAccess),
	}

	passwordCache, err := p.Js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
		Bucket: "SERAPH_AUTH_PASSWORD",
		TTL:    5 * time.Minute,
	})
	if err != nil {
		return Result{}, err
	}

	introspectionCache, err := p.Js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
		Bucket: "SERAPH_AUTH_INTROSPECTION",
		TTL:    5 * time.Minute,
	})
	if err != nil {
		return Result{}, err
	}

	auth := &oidcAuth{
		log:                log,
		configUrl:          configURL,
		provider:           provider,
		resourceServer:     resourceServer,
		config:             &oauth2Config,
		offlineConfig:      &offlineConfig,
		verifier:           verifier,
		passwordCache:      passwordCache,
		introspectionCache: introspectionCache,
		tokenStore:         NewTokenStore(p.Db),
		appClientId:        appClientId,
	}

	return Result{Auth: auth, Handler: auth}, nil
}

func (a *oidcAuth) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	authGroup := app.Group("/auth", cachecontrol.New(cachecontrol.NoCachePreset))
	authGroup.GET("/config", func(ctx *gin.Context) {
		resp := struct {
			Issuer      string
			AppClientId string
		}{
			Issuer:      a.configUrl,
			AppClientId: a.appClientId,
		}

		ctx.JSON(http.StatusOK, resp)
	})
	authGroup.GET("/callback", func(ctx *gin.Context) {
		sess := sessions.Default(ctx)
		defer sess.Save()

		redirectTo, hasRedirect := sess.Get("auth_callback_redirect").(string)
		password, isRegisterPassword := sess.Get("auth_register_password").(string)
		state, ok := sess.Get("auth_state").(string)

		if !ok || state == "" {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New("auth: missing state"))
			return
		}
		sess.Delete("auth_state")

		if ctx.Query("state") != state {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("auth: state did not match"))
			return
		}

		oauth2Token, err := a.config.Exchange(ctx.Request.Context(), ctx.Query("code"))
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, fmt.Errorf("auth: failed to exchange token: %w", err))
			return
		}

		rawIDToken, ok := oauth2Token.Extra("id_token").(string)
		if !ok {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New("auth: no id_token field in oauth2 token"))
			return
		}

		idToken, err := a.verifier.Verify(ctx.Request.Context(), rawIDToken)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, fmt.Errorf("auth: failed to verify ID Token: %w", err))
			return
		}

		if isRegisterPassword && password != "" {
			sess.Delete("auth_register_password")
			claims := struct {
				Username string `json:"preferred_username"`
			}{}
			idToken.Claims(&claims)
			a.log.Info("Registering new auth password", "username", claims.Username)
			a.tokenStore.registerTokenWithPassword(ctx, idToken.Subject, claims.Username, password, oauth2Token.RefreshToken)
		} else {
			setUserId(ctx, idToken.Subject)
			storeTokenToSession(sess, oauth2Token)
			sess.Save()
		}

		if hasRedirect {
			sess.Delete("auth_callback_redirect")
			if redirectTo != "" {
				ctx.Redirect(http.StatusFound, redirectTo)
				ctx.Abort()
			}
		}
	})

	authGroup.GET("/password", func(ctx *gin.Context) {
		nonce := uuid.NewString()
		resp := struct {
			Nonce string `json:"nonce"`
		}{nonce}

		data, err := json.Marshal(resp)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		sess := sessions.Default(ctx)
		sess.Set("auth_register_password_nonce", nonce)
		sess.Save()

		ctx.Data(http.StatusOK, gin.MIMEJSON, data)
	})

	authGroup.POST("/password", func(ctx *gin.Context) {
		body := struct {
			Nonce    string `json:"nonce" form:"nonce" binding:"required"`
			Password string `json:"password" form:"password" binding:"required"`
		}{}
		err := ctx.ShouldBind(&body)

		if err != nil {
			ctx.AbortWithError(http.StatusBadRequest, err)
			return
		}

		sess := sessions.Default(ctx)

		nonce := sess.Get("auth_register_password_nonce")
		sess.Delete("auth_register_password_nonce")
		if nonce == "" || nonce != body.Nonce {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid nonce"))
			return
		}

		state := uuid.New().String()
		sess.Set("auth_state", state)
		sess.Set("auth_register_password", body.Password)
		sess.Save()
		ctx.Redirect(http.StatusFound, a.offlineConfig.AuthCodeURL(state))
	})

	authGroup.DELETE("/password", func(ctx *gin.Context) {
		userId := a.GetUserId(ctx.Request.Context())
		if userId == "" {
			ctx.AbortWithStatus(http.StatusForbidden)
			return
		}

		sess := sessions.Default(ctx)
		nonce := sess.Get("auth_register_password_nonce")
		sess.Delete("auth_register_password_nonce")
		queryNonce := ctx.Query("nonce")
		if nonce == "" || nonce != queryNonce {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid nonce"))
			return
		}

		err := a.tokenStore.deleteToken(ctx, userId)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		ctx.Status(http.StatusNoContent)
	})

	// check login status for current session or trigger redirect
	authGroup.GET("/login", func(ctx *gin.Context) {
		sess := sessions.Default(ctx)

		var redirect bool = false
		redirectParam := ctx.Query("redirect")
		if redirectParam != "" {
			var err error
			redirect, err = strconv.ParseBool(redirectParam)
			if err != nil {
				redirect = false
			}
		}

		token, _ := a.getTokenFromSession(sess)
		if token == nil {
			if redirect {
				a.sendRedirect(ctx)
			} else {
				ctx.AbortWithStatus(http.StatusForbidden)
			}
			return
		}

		//attempt token refresh
		token, err := a.config.TokenSource(ctx, token).Token()
		if err != nil {
			// token failed to refresh
			// remove the stored token from the session
			sess.Delete("auth_token")
			sess.Save()

			if redirect {
				a.sendRedirect(ctx)
			} else {
				ctx.AbortWithStatus(http.StatusForbidden)
			}
			return
		}

		toParam := ctx.Query("to")
		if toParam != "" {
			ctx.Redirect(http.StatusFound, toParam)
			return
		}

		var idToken *oidc.IDToken = nil
		var idTokenClaims *json.RawMessage = new(json.RawMessage) // ID Token payload is just JSON.

		if rawIDToken, ok := token.Extra("id_token").(string); ok {
			var err error
			idToken, err = a.verifier.Verify(ctx.Request.Context(), rawIDToken)
			if err == nil {
				idToken.Claims(&idTokenClaims)
			}
		}

		var userInfoClaims *json.RawMessage = new(json.RawMessage)
		userInfo, err := a.provider.UserInfo(ctx.Request.Context(), oauth2.StaticTokenSource(token))
		if err == nil {
			userInfo.Claims(&userInfoClaims)
		}

		introspectionResponse, _ := rs.Introspect[*zoidc.IntrospectionResponse](ctx.Request.Context(), a.resourceServer, token.AccessToken)

		resp := struct {
			OAuth2Token           *oauth2.Token
			IDToken               *oidc.IDToken
			IDTokenClaims         *json.RawMessage
			UserInfo              *oidc.UserInfo
			UserInfoClaims        *json.RawMessage
			IntrospectionResponse *zoidc.IntrospectionResponse
		}{token, idToken, idTokenClaims, userInfo, userInfoClaims, introspectionResponse}

		data, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		ctx.Data(http.StatusOK, gin.MIMEJSON, data)
	})
}

func (a *oidcAuth) AuthMiddleware(passwordAuth bool, realm string) func(*gin.Context) bool {
	return func(ctx *gin.Context) bool {
		var sess sessions.Session
		var token *oauth2.Token
		var err error
		var bearerAuth bool

		// if Authorization header is present, use it
		authHeader := ctx.GetHeader("Authorization")
		if authHeader != "" {
			// first, check for Authorization: Bearer
			token, err = a.getBearerToken(ctx)
			if err != nil {
				ctx.AbortWithError(http.StatusBadRequest, err)
				return false
			}

			if token != nil {
				bearerAuth = true
			}

			// when passwordAuth is enabled, check for Authorization: Basic
			if token == nil && passwordAuth {
				// re-use password authentication from cache
				token, err = a.getTokenFromPasswordCache(ctx)
				if err != nil {
					ctx.AbortWithError(http.StatusInternalServerError, err)
					return false
				}

				// retrieve token from token store
				var hasStored bool
				if token == nil {
					token, hasStored, err = a.getTokenFromTokenStore(ctx)
					if err != nil {
						ctx.AbortWithError(http.StatusInternalServerError, err)
						return false
					}
				}

				// use direct access grant
				if token == nil && !hasStored {
					token, err = a.getTokenWithPassword(ctx)
					if err != nil {
						if authErr, ok := err.(*oauth2.RetrieveError); ok && authErr.ErrorCode != "" {
							// status code returned from Authentication server -> likely invalid credentials
							a.log.Error("unable to authenticate with password", "error", err)
							token = nil
						} else {
							// internal or unknown error
							ctx.AbortWithError(http.StatusInternalServerError, err)
							return false
						}
					}
				}
			}
		} else {
			// otherwise, get token from session
			sess = sessions.Default(ctx)
			token, err = a.getTokenFromSession(sess)
			if err != nil {
				ctx.AbortWithError(http.StatusInternalServerError, err)
				return false
			}
		}

		// no Authorization header and no session
		if token == nil {
			a.authenticationFailed(ctx, bearerAuth, passwordAuth, realm)
			return false
		}

		// attempt token refresh
		token, err = a.config.TokenSource(ctx.Request.Context(), token).Token()
		if err != nil {
			// token failed to refresh
			if sess != nil {
				// remove the stored token from the session
				sess.Delete("auth_token")
				sess.Save()
			}

			a.authenticationFailed(ctx, bearerAuth, passwordAuth, realm)
			return false
		}

		introspection, err := a.introspectToken(ctx, token)
		if err != nil {
			ctx.AbortWithError(http.StatusServiceUnavailable, err)
			return false
		}

		if !a.verifyToken(introspection) {
			a.authenticationFailed(ctx, bearerAuth, passwordAuth, realm)
			return false
		}

		// user authenticated
		setUserId(ctx, introspection.Subject)

		if sess != nil {
			// if no Authorization header was used, token is stored to session
			storeTokenToSession(sess, token)
			sess.Save()
		} else {
			// if Authorization: Basic was used, the token obtained via password is cached
			// (bearer token is never cached)
			a.addTokenToPasswordCache(ctx, token)
		}

		return true
	}
}

func (a *oidcAuth) authenticationFailed(ctx *gin.Context, bearerAuth, passwordAuth bool, realm string) {
	if bearerAuth {
		// no redirect is sent when client provided Bearer token
		ctx.AbortWithStatus(http.StatusForbidden)
	} else if passwordAuth {
		a.deleteTokenFromPasswordCache(ctx)
		// respond with HTTP 401 and WWW-Authenticate header to initiate password authentication (for WebDAV)
		a.sendPasswordAuth(ctx, realm)
	} else {
		// redirect to login
		a.sendRedirect(ctx)
		ctx.Abort()
	}
}

func (a *oidcAuth) sendRedirect(ctx *gin.Context) {
	sess := sessions.Default(ctx)

	state := uuid.New().String()
	sess.Set("auth_state", state)
	sess.Set("auth_callback_redirect", ctx.Request.URL.String())
	sess.Save()
	ctx.Redirect(http.StatusFound, a.config.AuthCodeURL(state))
}

func (a *oidcAuth) sendPasswordAuth(ctx *gin.Context, realm string) {
	ctx.Header("WWW-Authenticate", fmt.Sprintf("Basic realm=\"%s\"", realm))
	ctx.AbortWithStatus(http.StatusUnauthorized)
}

func (a *oidcAuth) GetUserId(ctx context.Context) string {
	if v, ok := ctx.Value(userIdKey{}).(string); ok {
		return v
	}
	return ""
}

func setUserId(ctx *gin.Context, subject string) {
	ctx.Request = ctx.Request.WithContext(context.WithValue(ctx.Request.Context(), userIdKey{}, subject))
}

func (a *oidcAuth) getBearerToken(ctx *gin.Context) (*oauth2.Token, error) {
	authHeader := ctx.GetHeader("Authorization")
	if authHeader != "" {
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 {
			return nil, errors.New("auth: invalid Authorization header")
		}
		if !strings.EqualFold("Bearer", parts[0]) {
			return nil, nil
		}
		return &oauth2.Token{
			AccessToken: parts[1],
		}, nil
	}
	return nil, nil
}

func (a *oidcAuth) getTokenFromPasswordCache(ctx *gin.Context) (*oauth2.Token, error) {
	authHeader := ctx.GetHeader("Authorization")
	if authHeader != "" {
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 {
			return nil, errors.New("auth: invalid Authorization header")
		}
		if !strings.EqualFold("Basic", parts[0]) {
			return nil, nil
		}
		kv, err := a.passwordCache.Get(ctx, parts[1])
		if err != nil {
			if errors.Is(err, jetstream.ErrKeyNotFound) || errors.Is(err, jetstream.ErrKeyDeleted) {
				return nil, nil
			}
			return nil, err
		}
		token := oauth2.Token{}
		err = json.Unmarshal(kv.Value(), &token)
		if err != nil {
			a.log.Error("error retrieving token from password cache", "error", err)
			err = a.passwordCache.Delete(ctx, parts[1])
			return nil, err
		}
		return &token, nil
	}
	return nil, nil
}

func (a *oidcAuth) deleteTokenFromPasswordCache(ctx *gin.Context) error {
	authHeader := ctx.GetHeader("Authorization")
	if authHeader != "" {
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 {
			return errors.New("auth: invalid Authorization header")
		}
		if !strings.EqualFold("Basic", parts[0]) {
			return nil
		}
		return a.passwordCache.Delete(ctx, parts[1])
	}
	return nil
}

func (a *oidcAuth) addTokenToPasswordCache(ctx *gin.Context, token *oauth2.Token) error {
	authHeader := ctx.GetHeader("Authorization")
	if authHeader != "" {
		parts := strings.Split(authHeader, " ")
		if len(parts) != 2 {
			return errors.New("auth: invalid Authorization header")
		}
		if !strings.EqualFold("Basic", parts[0]) {
			return nil
		}

		data, err := json.Marshal(token)
		if err != nil {
			return err
		}

		_, err = a.passwordCache.Put(ctx, parts[1], data)

		return err
	}
	return nil
}

func (a *oidcAuth) getTokenFromTokenStore(ctx *gin.Context) (*oauth2.Token, bool, error) {
	if username, password, ok := ctx.Request.BasicAuth(); ok {
		refreshToken, has, err := a.tokenStore.getTokenWithPassword(ctx, username, password)
		if err != nil {
			return nil, has, err
		}
		if refreshToken == "" {
			return nil, has, nil
		}
		return &oauth2.Token{
			RefreshToken: refreshToken,
		}, has, nil
	}
	return nil, false, nil
}

func (a *oidcAuth) getTokenWithPassword(ctx *gin.Context) (*oauth2.Token, error) {
	if username, password, ok := ctx.Request.BasicAuth(); ok {
		return a.config.PasswordCredentialsToken(ctx, username, password)
	}
	return nil, nil
}

func storeTokenToSession(sess sessions.Session, token *oauth2.Token) error {
	v, err := json.Marshal(token)
	if err != nil {
		return err
	}
	sess.Set("auth_token", string(v))

	return nil
}

func (a *oidcAuth) getTokenFromSession(sess sessions.Session) (*oauth2.Token, error) {
	jsonToken, _ := sess.Get("auth_token").(string)

	if jsonToken == "" {
		return nil, nil
	}

	token := oauth2.Token{}

	err := json.Unmarshal([]byte(jsonToken), &token)
	if err != nil {
		a.log.Error("error retrieving token from session", "error", err)
		sess.Delete("auth_token")
		return nil, err
	}
	return &token, nil
}

func (a *oidcAuth) introspectToken(ctx *gin.Context, token *oauth2.Token) (*zoidc.IntrospectionResponse, error) {
	kv, err := a.introspectionCache.Get(ctx.Request.Context(), token.AccessToken)
	if err != nil {
		if !errors.Is(err, jetstream.ErrKeyNotFound) && !errors.Is(err, jetstream.ErrKeyDeleted) {
			a.log.Error("error retrieving token introspection from cache", "error", err)
		}
		kv = nil
	}

	if kv != nil {
		resp := zoidc.IntrospectionResponse{}
		err = json.Unmarshal(kv.Value(), &resp)
		if err != nil {
			a.log.Error("error retrieving token introspection from cache", "error", err)
			a.introspectionCache.Delete(ctx.Request.Context(), token.AccessToken)
		} else {
			return &resp, nil
		}
	}

	resp, err := rs.Introspect[*zoidc.IntrospectionResponse](ctx.Request.Context(), a.resourceServer, token.AccessToken)
	if err != nil {
		return nil, err
	}

	data, err := json.Marshal(resp)
	if err != nil {
		a.log.Error("error putting introspection value to cache", "error", err)
		return nil, err
	}
	_, err = a.introspectionCache.Put(ctx.Request.Context(), token.AccessToken, data)
	if err != nil {
		a.log.Error("error putting introspection value to cache", "error", err)
		return nil, err
	}
	return resp, nil
}

func (a *oidcAuth) verifyToken(introspection *zoidc.IntrospectionResponse) bool {
	// check token is active
	if !introspection.Active {
		return false
	}

	// check token is not expired (required when using token from cache)
	if time.Now().UTC().After(introspection.Expiration.AsTime()) {
		return false
	}

	// check issuer matches
	if !(a.configUrl == introspection.Issuer) {
		return false
	}

	// check all requested scopes are present
	for _, scope := range a.config.Scopes {
		if !slices.Contains(introspection.Scope, scope) {
			return false
		}
	}

	return true
}

func (a *oidcAuth) IsSpaceAdmin(ctx context.Context) bool {
	//TODO: role check
	return false
}
