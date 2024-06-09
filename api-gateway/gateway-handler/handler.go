package gateway

import (
	"github.com/gin-gonic/gin"
)

type GatewayHandler interface {
	Setup(engine *gin.Engine, apiGroup *gin.RouterGroup)
}
