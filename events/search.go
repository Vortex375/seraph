package events

const SearchTypeFiles = "files"

type SearchRequest struct {
	RequestId string   `json:"requestId"`
	UserId    string   `json:"userId"`
	Query     string   `json:"query"`
	Types     []string `json:"types"`
}

type SearchAck struct {
	RequestId string   `json:"requestId"`
	ReplyId   string   `json:"replyId"`
	Ack       bool     `json:"ack"`
	Types     []string `json:"types"`
}

type SearchReply struct {
	RequestId string         `json:"requestId"`
	ReplyId   string         `json:"replyId"`
	Type      string         `json:"type"`
	Reply     map[string]any `json:"reply"`
	Error     string         `json:"error"`
	Last      bool           `json:"last"`
}
