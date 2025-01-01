package webdav

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"strings"

	"golang.org/x/net/webdav"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
)

type delegatingFs struct {
	server *webDavServer
	log    slog.Logger
}

var _ webdav.FileSystem = &delegatingFs{}

func (f *delegatingFs) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	fs, path, err := f.getFsAndPath(ctx, "MkDir", name)
	if err != nil {
		return err
	}
	return fs.Mkdir(ctx, path, perm)
}

func (f *delegatingFs) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	fs, path, err := f.getFsAndPath(ctx, "OpenFile", name)
	if err != nil {
		return nil, err
	}
	return fs.OpenFile(ctx, path, flag, perm)
}

func (f *delegatingFs) RemoveAll(ctx context.Context, name string) error {
	fs, path, err := f.getFsAndPath(ctx, "RemoveAll", name)
	if err != nil {
		return err
	}
	return fs.RemoveAll(ctx, path)
}

func (f *delegatingFs) Rename(ctx context.Context, oldName, newName string) error {
	//TODO: rename across providers!?
	oldProvider, _ := getProviderAndPath(oldName)
	newProvider, newPath := getProviderAndPath(newName)
	if oldProvider != newProvider {
		return fs.ErrInvalid
	}
	fs, path, err := f.getFsAndPath(ctx, "Rename", oldName)
	if err != nil {
		return err
	}
	return fs.Rename(ctx, path, newPath)
}

func (f *delegatingFs) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	fs, path, err := f.getFsAndPath(ctx, "Stat", name)
	if err != nil {
		return nil, err
	}
	return fs.Stat(ctx, path)
}

func (f *delegatingFs) getFsAndPath(ctx context.Context, op string, name string) (webdav.FileSystem, string, error) {
	providerId, path := getProviderAndPath(name)
	f.log.Debug("delegating "+op, "providerId", providerId, "path", path)

	if providerId == "" {
		fs, err := f.getSpacesFs(ctx)
		return fs, path, err
	} else {
		//TODO: handle readOnly
		resolvedProviderId, resolvedPath, err := f.resolveSpace(ctx, providerId, path)
		if err != nil {
			return nil, "", err
		}
		if resolvedProviderId == "" {
			return nil, "", fs.ErrNotExist
		}

		f.log.Debug(fmt.Sprintf("resolved %s:%s to %s:%s", providerId, path, resolvedProviderId, resolvedPath), "providerId", providerId, "path", path, "resolvedProviderId", resolvedProviderId, "resolvedPath", resolvedPath)

		fs := f.server.getClient(resolvedProviderId)
		return fs, resolvedPath, nil
	}
}

func getProviderAndPath(p string) (string, string) {
	split := strings.SplitN(strings.TrimPrefix(p, "/"), "/", 2)

	if len(split) == 1 {
		return "", split[0]
	}

	if len(split) == 2 {
		return split[0], split[1]
	}

	return "", ""
}

func (f *delegatingFs) getSpacesFs(ctx context.Context) (webdav.FileSystem, error) {
	userId := f.server.auth.GetUserId(ctx)

	proto := entities.MakePrototype(&spaces.SpacePrototype{})
	proto.Users.Set([]string{userId})
	req := spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     proto,
	}
	res := spaces.SpaceCrudResponse{}
	err := messaging.Request(ctx, f.server.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		return nil, fmt.Errorf("unable to read spaces for user %s: %w", userId, err)
	}
	if res.Error != "" {
		return nil, fmt.Errorf("unable to read spaces for user %s: %w", userId, errors.New(res.Error))
	}

	return &spacesFileSystem{f.server, res.Space}, nil
}

func (f *delegatingFs) resolveSpace(ctx context.Context, spaceProviderId string, filePath string) (string, string, error) {
	cache := ctx.Value(spaceResolveCacheKey{}).(map[string]spaces.SpaceResolveResponse)
	var res spaces.SpaceResolveResponse
	if fromCache, ok := cache[spaceProviderId]; ok {
		res = fromCache
	} else {
		userId := f.server.auth.GetUserId(ctx)
		req := spaces.SpaceResolveRequest{
			UserId:          userId,
			SpaceProviderId: spaceProviderId,
		}
		err := messaging.Request(ctx, f.server.nc, spaces.SpaceResolveTopic, messaging.Json(&req), messaging.Json(&res))
		if err != nil {
			return "", "", fmt.Errorf("unable to resolve space %s for user %s: %w", spaceProviderId, userId, err)
		}
		if res.Error != "" {
			return "", "", fmt.Errorf("unable to resolve space %s for user %s: %w", spaceProviderId, userId, errors.New(res.Error))
		}
		cache[spaceProviderId] = res
	}

	return res.ProviderId, path.Join(res.Path, filePath), nil
}
