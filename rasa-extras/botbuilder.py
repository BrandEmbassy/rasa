import logging
import asyncio
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Optional, Text
from rasa.core.channels.channel import CollectingOutputChannel, UserMessage
from rasa.core.channels.callback import CallbackInput
from rasa.utils.endpoints import EndpointConfig, ClientResponseError
from sanic import Blueprint, response
from sanic.request import Request
from sanic.response import HTTPResponse

logger = logging.getLogger(__name__)


class CustomCollectingOutputChannel(CollectingOutputChannel):
    """BotBuilder communication channel"""

    @classmethod
    def name(cls) -> Text:
        return "botbuilder"

    @staticmethod
    def _message(
        recipient_id: Text,
        text: Text = None,
        image: Text = None,
        buttons: List[Dict[Text, Any]] = None,
        quick_replies: List[Dict[Text, Any]] = None,
        attachment: Text = None,
        custom: Dict[Text, Any] = None,
    ) -> Dict:
        """Create a message object that will be stored."""

        obj = {
            "recipient_id": recipient_id,
            "text": text,
            "image": image,
            "buttons": buttons,
            "quick_replies": quick_replies,
            "attachment": attachment,
            "custom": custom,
        }

        # filter out any values that are `None`
        return {k: v for k, v in obj.items() if v is not None}

    async def send_quick_replies(
        self,
        recipient_id: Text,
        text: Text,
        quick_replies: List[Dict[Text, Any]],
        **kwargs: Any,
    ) -> None:
        """Sends quick replies to the output."""

        await self._persist_message(
            self._message(recipient_id, text=text, quick_replies=quick_replies)
        )


class BotBuilderOutput(CustomCollectingOutputChannel):
    """BotBuilder communication channel"""

    @classmethod
    def name(cls) -> Text:
        return "botbuilder"

    def __init__(self, endpoint: EndpointConfig) -> None:

        self.callback_endpoint = endpoint
        super().__init__()

    async def _persist_message(self, message: Dict[Text, Any]) -> None:
        await super()._persist_message(message)

        try:
            traceId = str(uuid.uuid4())
            logger.debug("[" + traceId + "] Responding through BotBuilderOutput channel")

            await self.callback_endpoint.request(
                "post", content_type="application/json", json=message, headers={'X-Trace-ID': traceId}
            )
            logger.debug("[" + traceId + "] Responding through BotBuilderOutput channel finished")
        except ClientResponseError as e:
            logger.error(
                "Failed to send output message to callback. "
                "Status: {} Response: {}"
                "".format(e.status, e.text)
            )


class BotBuilderInput(CallbackInput):
    """A custom REST http input channel that responds using a callback server.

    Incoming messages are received through a REST interface. Responses
    are sent asynchronously by calling a configured external REST endpoint."""

    @classmethod
    def name(cls) -> Text:
        return "botbuilder"

    def blueprint(
        self, on_new_message: Callable[[UserMessage], Awaitable[Any]]
    ) -> Blueprint:
        callback_webhook = Blueprint("botbuilder_webhook", __name__)

        @callback_webhook.route("/", methods=["GET"])
        async def health(_: Request) -> HTTPResponse:
            return response.json({"status": "ok"})

        @callback_webhook.route("/webhook", methods=["POST"])
        def webhook(request: Request) -> HTTPResponse:
            asyncio.get_running_loop().create_task(
                process_async_message(request)
            )

            return response.text("success")

        async def process_async_message(request) -> None:
            sender_id = await self._extract_sender(request)
            text = self._extract_message(request)

            collector = self.get_output_channel()
            await on_new_message(
                UserMessage(text, collector, sender_id, input_channel=self.name())
            )

        return callback_webhook

    def get_output_channel(self) -> CustomCollectingOutputChannel:
        return BotBuilderOutput(self.callback_endpoint)
