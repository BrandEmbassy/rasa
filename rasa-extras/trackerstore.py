import logging
import socket
import json
import base64
from typing import (
    Any,
    Dict,
    Optional,
    Text,
    Tuple
)

from rasa.core.brokers.broker import EventBroker
from rasa.core.tracker_store import TrackerStore, SerializedTrackerAsText
from rasa.shared.core.trackers import (
    DialogueStateTracker,
)

from elasticsearch import Elasticsearch

logger = logging.getLogger(__name__)


def parse_conversation_id(conversation_id: str) -> Tuple[int, str]:
    dash_pos = conversation_id.find("-")

    if dash_pos >= 0:
        bot_id = conversation_id[0:dash_pos]
        if bot_id.isnumeric():
            return int(bot_id), conversation_id[dash_pos + 1:]

    return 0, conversation_id


class ExtraTrackerStore(TrackerStore, SerializedTrackerAsText):
    """Stores conversation history in ElasticSearch"""

    def __init__(
            self,
            domain,
            es_url: str = None,
            event_broker: Optional[EventBroker] = None,
            record_exp: Optional[float] = None,

            **kwargs: Dict[Text, Any],
    ) -> None:
        self.elasticsearch = None

        if es_url:
            self.elasticsearch = Elasticsearch([es_url])
            es_logger = logging.getLogger('elasticsearch')
            es_logger.setLevel(logging.INFO)

            if self.elasticsearch.ping():
                logger.info("Connected to Elasticsearch url " + es_url)
            else:
                logger.error("Can't connect to Elasticsearch url " + es_url)
                self.elasticsearch = None

        self.record_exp = record_exp

        super().__init__(domain, event_broker, **kwargs)

    def save(self, tracker: DialogueStateTracker, timeout=604800) -> None:
        """Saves the current conversation state"""
        if self.event_broker:
            self.stream_events(tracker)

        if not timeout and self.record_exp:
            timeout = self.record_exp

        serialised_tracker = self.serialise_tracker(tracker)

        bot_id, conversation_id = parse_conversation_id(tracker.sender_id)

        if self.elasticsearch and bot_id > 0:
            index = f"bot-conversations-alias-{str(bot_id)}"
            logger.info(f"ElasticSearch: storing conversation into {index}")
            json_tracker = json.loads(serialised_tracker)
            json_tracker['events'] = self.process_events(json_tracker['events'])
            message_events = self.get_message_events(json_tracker['events'])
            transitions = self.get_transitions(json_tracker['events'])
            msg_count = len(message_events)
            self.elasticsearch.update(
                index=index,
                id=conversation_id,
                body={
                    'doc': {
                        'tracker': json_tracker,
                        'msgCount': msg_count,
                        'customerMsgCount': self.get_customer_msg_count(message_events),
                        'botMsgCount': self.get_bot_msg_count(message_events),
                        'transitions': transitions.get('transitions'),
                        'journey': transitions.get('journey'),
                        'lastMessageAt': self.get_last_message_at(json_tracker['events']),
                    }
                })

    def get_last_message_at(self, events) -> int:
        return round(1000 * (0 if len(events) == 0 else events[-1].get('timestamp', 0)))

    def get_transitions(self, events) -> list:
        prevIntentName = 'start'
        journey = 'start__1'
        transitions = []
        level = 1
        for event in events:
            if 'intent' in event.get('parse_data', {}) and 'name' in event['parse_data']['intent']:
                intentName = event['parse_data']['intent']['name']
                if (intentName == prevIntentName and level != 1):
                    continue
                level += 1
                journey += '->' + self.get_intent_name_with_level(intentName, level)
                key = self.get_intent_name_with_level(prevIntentName, level - 1) + '->' + self.get_intent_name_with_level(intentName, level)
                transitions.append({'name': key})
                prevIntentName = intentName

        journey += '->end'
        transitions.append({'name': self.get_intent_name_with_level(prevIntentName, level) + '->end'})

        return {'transitions': transitions, 'journey': journey}

    def process_events(self, events) -> list:
        for key,value in enumerate(events):
            eventName = events[key].get('name')
            if eventName and eventName.startswith('action_'):
                data = eventName.split('_', 1)
                try:
                    parsedData = json.loads(base64.b64decode(data[1]))
                    events[key]['type'] = parsedData['type']
                except:
                    events[key]['type'] = data[1]

        return events

    def get_intent_name_with_level(self, intentName, level) -> Text:
        return intentName + '__' + str(level)

    def get_message_events(self, events) -> list:
        return list(
            filter(
                lambda event: event['event'] in ['user', 'bot'],
                events
            )
        )

    def get_customer_msg_count(self, events) -> int:
        return len(
            list(
                filter(
                    lambda event: event['event'] == 'user',
                    events
                )
            )
        )

    def get_bot_msg_count(self, events) -> int:
        return len(
            list(
                filter(
                    lambda event: event['event'] == 'bot',
                    events
                )
            )
        )

    def retrieve(self, sender_id: Text) -> Optional[DialogueStateTracker]:
        """Retrieves tracker for the latest conversation session.
        Args:
            sender_id: Conversation ID to fetch the tracker for.
        Returns:
            Tracker containing events from the latest conversation sessions.
        """
        if self.elasticsearch:
            bot_id, conversation_id = parse_conversation_id(sender_id)
            index = f"bot-conversations-alias-{str(bot_id)}"

            logger.info(f"ElasticSearch: retrieving conversation {conversation_id}")
            response = self.elasticsearch.get(index=index, id=conversation_id)
            stored = response['_source']['tracker']

            if stored == []:
                return None

            return self.deserialise_tracker(
                sender_id=sender_id,
                serialised_tracker=json.dumps(stored)
            )

        return None

class ExtraRedisTrackerStore(ExtraTrackerStore):
    def __init__(
            self,
            domain,
            host="localhost",
            port=6379,
            db=0,
            cluster: bool = False,
            password: Optional[Text] = None,
            es_url: str = None,
            event_broker: Optional[EventBroker] = None,
            record_exp: Optional[float] = None,
            key_prefix: Optional[Text] = None,
            use_ssl: bool = False,
            scan_count: int = 50,

            retry_on_timeout: bool = False,
            health_check_interval: int = 0,
            socket_connect_timeout: float = None,
            socket_keepalive: bool = False,
            socket_keepalive_options: dict = {},

            **kwargs: Dict[Text, Any],
    ) -> None:
        super().__init__(domain, es_url, event_broker, record_exp, **kwargs)
