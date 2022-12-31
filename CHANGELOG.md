## [1.0.2]

- fix: export realtime presence [#60](https://github.com/supabase/realtime-dart/pull/60)

## [1.0.1]

- fix: bug where leaving existing topic throws [#58](https://github.com/supabase/realtime-dart/pull/58)

## [1.0.0]

- chore: v1.0.0 release 🚀
- fix: set minimum Dart SDK to 2.14.0 [#56](https://github.com/supabase-community/realtime-dart/pull/56)

## [1.0.0-dev.5]

- fix: sends null for access_token when not signed in [#53](https://github.com/supabase-community/realtime-dart/pull/53)

## [1.0.0-dev.4]

- fix: bug where it throws exception when listening to postgres changes on old version of realtime server
- chore: add mock tests for listening to postgres changes

## [1.0.0-dev.3]

- BREAKING: fix payload shape on old version of realtime server to match the new version

## [1.0.0-dev.2]

- fix: bug where presence sync of other clients causes exception

## [1.0.0-dev.1]

- feat: add support for broadcast and presence
- BREAKING: `.on()` no longer takes a event string (e.g. INSERT, UPDATE or DELETE), but takes `RealtimeListenTypes` and a `ChannelFilter`
```dart
final socket = RealtimeClient('ws://SUPABASE_API_ENDPOINT/realtime/v1');
final channel = socket.channel('can_be_any_string');

// listen to insert events on public.messages table
channel.on(
    RealtimeListenTypes.postgresChanges,
    ChannelFilter(
      event: 'INSERT',
      schema: 'public',
      table: 'messages',
    ), (payload, [ref]) {
  print('database insert payload: $payload');
});

// listen to `location` broadcast events
channel.on(
    RealtimeListenTypes.broadcast,
    ChannelFilter(
      event: 'location',
    ), (payload, [ref]) {
  print(payload);
});

// send `location` broadcast events
channel.send(
  type: RealtimeListenTypes.broadcast,
  event: 'location',
  payload: {'lat': 1.3521, 'lng': 103.8198},
);

// listen to presence states
channel.on(RealtimeListenTypes.presence, ChannelFilter(event: 'sync'),
    (payload, [ref]) {
  print(payload);
  print(channel.presenceState());
});

// subscribe to the above changes
channel.subscribe((status) async {
  if (status == 'SUBSCRIBED') {
    // if subscribed successfully, send presence event
    final status = await channel.track({'user_id': myUserId});
  }
});
```

## [0.1.15+1]

- fix: allow null access token to be passed

## [0.1.15]

- fix: use toString() instead of type cast error response

## [0.1.14]

- fix: number transformers

## [0.1.13]

- feat: add setAuth to send user Access Token to Realtime Server
- fix: don't apply toString() to json

## [0.1.12+1]

- fix: parsing bug of boolean values on WALRUS

## [0.1.12]

- feat: update transformers to accept already transformed walrus changes

## [0.1.11]

- chore: added X-Client-Info header

## [0.1.10]

- fix: converted `Callback` from typedef` to function types

## [0.1.9]

- fix: bug where array value is not properly emitted

## [0.1.8]

- fix: add strict typing to `convertChangeData()`

## [0.1.7]

- fix: heartbeatTimer not cancelled upon calling `socket.disconnect()`

## [0.1.6]

- fix: getting value from received response map

## [0.1.5]

- fix: bug where unsubscribe from '\*' type subscription throws exception

## [0.1.4]

- fix: timeout timer not starting

## [0.1.3]

- refactor: rename Column class to PostgresColumn

## [0.1.2]

- fix: subscription type '\*' does not fire callback bug

## [0.1.1]

- fix: converted typedefs in `RealtimeClient` to function types

## [0.1.0]

- fix: heartbeat event name

## [0.0.9]

- fix: default reconnectAfterMs function throws RangeError
- chore: update mocktail version

## [0.0.8]

- feature: Null-Safety

## [0.0.7]

- fix: Web compatibility

## [0.0.6]

- fix: RetryTimer `_tries` is not initialized

## [0.0.5]

- fix: transformers.convertColumn method

## [0.0.4]

- fix: convertChangeData.columns type to List<Map<String, dynamic>>

## [0.0.3]

- fix: binding filter bug on realtimeSubscription trigger method

## [0.0.2]

- chore: replace `Map` with `Map<String, dyanmic>`
- tidy up

## [0.0.1]

- chore: update README
- fix: convertChangeData columns param type

## [0.0.1-dev.5]

- fix: transformers convertChangeData method

## [0.0.1-dev.4]

- Improve docs

#### BREAKING CHANGES

- Rename `socket` to `RealtimeClient`
- Rename `channel` to `RealtimeSubscription`

## [0.0.1-dev.3]

- Update README Usage with more examples
- Update package description

## [0.0.1-dev.2]

- Update README

## [0.0.1-dev.1]

- Initial pre-release.
