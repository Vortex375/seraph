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

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	cachecontrol "go.eigsys.de/gin-cachecontrol/v2"
	"go.mongodb.org/mongo-driver/mongo"

	"github.com/google/uuid"
	"go.uber.org/fx"
	"golang.org/x/oauth2"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
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

	Db  *mongo.Database
	Mig Migrations
}

type Result struct {
	fx.Out

	Auth    Auth
	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type Auth interface {
	AuthMiddleware() func(*gin.Context)
	PasswordAuthMiddleware(realm string) func(*gin.Context)
}

type oidcAuth struct {
	log           *slog.Logger
	provider      *oidc.Provider
	config        *oauth2.Config
	offlineConfig *oauth2.Config
	verifier      *oidc.IDTokenVerifier
	tokenStore    TokenStore
}

func New(p Params) (Result, error) {
	log := p.Log.GetLogger("auth")

	p.Viper.SetDefault("auth.disabled", false)
	p.Viper.SetDefault("auth.configURL", "http://localhost:8081/realms/seraph")
	p.Viper.SetDefault("auth.redirectURL", "http://localhost:8080/auth/callback")
	p.Viper.SetDefault("auth.clientId", "seraph")

	if p.Viper.GetBool("auth.disabled") {
		log.Warn("AUTHENTICATION DISABLED via auth.disabled parameter!! Access to all APIs and data is granted without login.")
		auth := &noAuth{}
		return Result{Auth: auth, Handler: auth}, nil
	}

	configURL := p.Viper.GetString("auth.configURL")
	ctx := context.Background()
	provider, err := oidc.NewProvider(ctx, configURL)

	if err != nil {
		return Result{}, err
	}

	clientID := p.Viper.GetString("auth.clientId")
	clientSecret := p.Viper.GetString("auth.clientSecret")

	redirectURL := p.Viper.GetString("auth.redirectURL")

	oauth2Config := oauth2.Config{
		ClientID:     clientID,
		ClientSecret: clientSecret,
		RedirectURL:  redirectURL,
		// Discovery returns the OAuth2 endpoints.
		Endpoint: provider.Endpoint(),
		// "openid" is a required scope for OpenID Connect flows.
		Scopes: []string{oidc.ScopeOpenID, "profile", "email"},
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
		Scopes: []string{oidc.ScopeOpenID, oidc.ScopeOfflineAccess, "profile", "email"},
	}

	auth := &oidcAuth{log, provider, &oauth2Config, &offlineConfig, verifier, NewTokenStore(p.Db)}

	return Result{Auth: auth, Handler: auth}, nil
}

func (a *oidcAuth) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	authGroup := app.Group("/auth", cachecontrol.New(cachecontrol.NoCachePreset))
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

		oauth2Token, err := a.config.Exchange(ctx, ctx.Query("code"))
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, fmt.Errorf("auth: failed to exchange token: %w", err))
			return
		}

		rawIDToken, ok := oauth2Token.Extra("id_token").(string)
		if !ok {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New("auth: no id_token field in oauth2 token"))
			return
		}

		idToken, err := a.verifier.Verify(context.Background(), rawIDToken)
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
			storeTokenToSession(sess, oauth2Token)
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
			Nonce    string `json:"nonce"`
			Password string `json:"password"`
		}{}
		err := ctx.ShouldBindBodyWithJSON(&body)

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

	//TODO: for debugging
	authGroup.GET("/token", func(ctx *gin.Context) {
		sess := sessions.Default(ctx)

		oauth2Token, _ := getTokenFromSession(sess)
		if oauth2Token == nil {
			ctx.String(http.StatusOK, "no session")
			return
		}

		var idToken *oidc.IDToken = nil
		var idTokenClaims *json.RawMessage = new(json.RawMessage) // ID Token payload is just JSON.

		if rawIDToken, ok := oauth2Token.Extra("id_token").(string); ok {
			var err error
			idToken, err = a.verifier.Verify(ctx, rawIDToken)
			if err == nil {
				idToken.Claims(&idTokenClaims)
			}
		}

		resp := struct {
			OAuth2Token   *oauth2.Token
			IDToken       *oidc.IDToken
			IDTokenClaims *json.RawMessage
		}{oauth2Token, idToken, idTokenClaims}

		data, err := json.MarshalIndent(resp, "", "  ")
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		ctx.Data(http.StatusOK, gin.MIMEJSON, data)
	})
}

func (a *oidcAuth) AuthMiddleware() func(*gin.Context) {
	return func(ctx *gin.Context) {
		sess := sessions.Default(ctx)

		tokenFromSession, _ := getTokenFromSession(sess)
		bearerToken := ctx.GetHeader("Authorization")

		//TODO: bearer authentication incorrect
		var rawIDToken string
		if bearerToken != "" {
			parts := strings.Split(bearerToken, " ")
			if len(parts) != 2 {
				ctx.AbortWithError(http.StatusBadRequest, errors.New("auth: invalid Authorization header"))
				return
			}
			rawIDToken = parts[1]

		} else if tokenFromSession != nil {
			if token, err := a.config.TokenSource(ctx, tokenFromSession).Token(); err == nil {
				rawIDToken, _ = token.Extra("id_token").(string)
				storeTokenToSession(sess, token)
				sess.Save()
			}
		}

		if rawIDToken == "" {
			a.sendRedirect(ctx)
			ctx.Abort()
			return
		}

		if _, err := a.verifier.Verify(ctx, rawIDToken); err != nil {
			a.sendRedirect(ctx)
			ctx.Abort()
			return
		}
	}
}

func (a *oidcAuth) PasswordAuthMiddleware(realm string) func(*gin.Context) {
	return func(ctx *gin.Context) {
		sess := sessions.Default(ctx)

		token, err := getTokenFromSession(sess)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		if token == nil {
			token, err = a.getTokenFromPassword(ctx)
			if err != nil {
				ctx.AbortWithError(http.StatusInternalServerError, err)
				return
			}
		}

		if token != nil {
			if token, err := a.config.TokenSource(ctx, token).Token(); err == nil {
				rawIDToken, ok := token.Extra("id_token").(string)
				if ok && rawIDToken != "" {
					if _, err := a.verifier.Verify(ctx, rawIDToken); err == nil {
						storeTokenToSession(sess, token)
						sess.Save()
						return
					}
				}
			}
		}

		a.sendPasswordAuth(ctx, realm)
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

func (a *oidcAuth) getTokenFromPassword(ctx *gin.Context) (*oauth2.Token, error) {
	if username, password, ok := ctx.Request.BasicAuth(); ok {
		refreshToken, err := a.tokenStore.getTokenWithPassword(ctx, username, password)
		if err != nil {
			return nil, err
		}
		if refreshToken == "" {
			return nil, nil
		}
		return &oauth2.Token{
			RefreshToken: refreshToken,
		}, nil
	}
	return nil, nil
}

func storeTokenToSession(sess sessions.Session, token *oauth2.Token) error {
	rawIdToken, _ := token.Extra("id_token").(string)

	v, err := json.Marshal(token)
	if err != nil {
		return err
	}
	sess.Set("auth_token", string(v))
	sess.Set("id_token", rawIdToken)

	return nil
}

func getTokenFromSession(sess sessions.Session) (*oauth2.Token, error) {
	jsonToken, _ := sess.Get("auth_token").(string)
	rawIdToken, _ := sess.Get("id_token").(string)

	if jsonToken == "" {
		return nil, nil
	}

	token := oauth2.Token{}

	err := json.Unmarshal([]byte(jsonToken), &token)
	if err != nil {
		return nil, err
	}
	return token.WithExtra(map[string]any{"id_token": rawIdToken}), nil
}
