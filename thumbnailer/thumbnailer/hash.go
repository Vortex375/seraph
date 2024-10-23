package thumbnailer

import (
	"crypto/sha256"
	"encoding/hex"
)

func ThumbnailHash(path string) string {
	return hex.EncodeToString(sha256.New().Sum(([]byte(path))))
}
