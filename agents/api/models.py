from datetime import datetime

from pydantic import BaseModel, ConfigDict


class SessionCreateRequest(BaseModel):
    title: str


class MessageCreateRequest(BaseModel):
    message: str


class SessionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    title: str
    created_at: datetime
    updated_at: datetime
    last_message_at: datetime


class AcceptedMessageResponse(BaseModel):
    accepted: bool


class ChatMessageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[str]


class DocumentStatusResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    provider_id: str
    path: str
    ingest_status: str
    last_error: str | None = None
