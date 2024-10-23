package thumbnailer

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestHash(t *testing.T) {
	const path = "/foo/bar"
	const expected = "2f666f6f2f626172e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	var hash = ThumbnailHash(path)
	assert.Equal(t, expected, hash)
}
