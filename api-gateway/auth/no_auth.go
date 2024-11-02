package auth

import "github.com/gin-gonic/gin"

type noAuth struct{}

func (a *noAuth) AuthMiddleware() func(*gin.Context) bool {
	return func(ctx *gin.Context) bool {
		/* no-op */
		return true
	}
}

func (a *noAuth) PasswordAuthMiddleware(realm string) func(*gin.Context) bool {
	return func(ctx *gin.Context) bool {
		/* no-op */
		return true
	}
}

func (a *noAuth) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	/* no-op */
}

func (a *noAuth) GetUserId(ctx *gin.Context) string {
	return "anonymous"
}
