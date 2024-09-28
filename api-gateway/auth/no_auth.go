package auth

import "github.com/gin-gonic/gin"

type noAuth struct{}

func (a *noAuth) AuthMiddleware() func(*gin.Context) {
	return func(ctx *gin.Context) { /* no-op */ }
}

func (a *noAuth) PasswordAuthMiddleware(realm string) func(*gin.Context) {
	return func(ctx *gin.Context) { /* no-op */ }
}

func (a *noAuth) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	/* no-op */
}
