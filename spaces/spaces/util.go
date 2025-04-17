package spaces

import (
	"context"
	"errors"
	"fmt"

	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/messaging"
)

func GetSpacesForUser(ctx context.Context, nc *nats.Conn, userId string) ([]Space, error) {
	proto := entities.MakePrototype(&SpacePrototype{})
	proto.Users.Set([]string{userId})
	req := SpaceCrudRequest{
		Operation: "READ",
		Space:     proto,
	}
	res := SpaceCrudResponse{}
	err := messaging.Request(ctx, nc, SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		return nil, fmt.Errorf("unable to read spaces for user %s: %w", userId, err)
	}
	if res.Error != "" {
		return nil, fmt.Errorf("unable to read spaces for user %s: %w", userId, errors.New(res.Error))
	}

	return res.Space, nil
}
