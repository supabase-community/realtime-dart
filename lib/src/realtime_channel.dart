import 'dart:async';
import 'dart:convert';

import 'package:realtime_client/realtime_client.dart';
import 'package:realtime_client/src/constants.dart';
import 'package:realtime_client/src/push.dart';
import 'package:realtime_client/src/realtime_presence.dart';
import 'package:realtime_client/src/retry_timer.dart';

typedef BindingCallback = void Function(dynamic payload, [String? ref]);

class Binding {
  String type;
  Map<String, String> filter;
  BindingCallback callback;
  String? id;

  Binding(
    this.type,
    this.filter,
    this.callback, [
    this.id,
  ]);

  Binding copyWith({
    String? type,
    Map<String, String>? filter,
    BindingCallback? callback,
    String? id,
  }) {
    return Binding(
      type ?? this.type,
      filter ?? this.filter,
      callback ?? this.callback,
      id ?? this.id,
    );
  }
}

class ChannelFilter {
  final String? event;
  final String? schema;
  final String? table;
  final String? filter;

  ChannelFilter({
    this.event,
    this.schema,
    this.table,
    this.filter,
  });

  Map<String, String> toMap() {
    return {
      if (event != null) 'event': event!,
      if (schema != null) 'schema': schema!,
      if (table != null) 'table': table!,
      if (filter != null) 'filter': filter!,
    };
  }
}

enum ChannelResponse {
  ok,
  timedOut,
  rateLimited;

  String get name {
    switch (this) {
      case ChannelResponse.ok:
        return 'ok';
      case ChannelResponse.timedOut:
        return 'timed out';
      case ChannelResponse.rateLimited:
        return 'rate limited';
    }
  }
}

enum RealtimeListenTypes {
  postgresChanges,
  broadcast,
  presence;

  String toType() {
    if (this == RealtimeListenTypes.postgresChanges) {
      return 'postgres_changes';
    } else {
      return name;
    }
  }
}

class RealtimeChannel {
  final Map<String, List<Binding>> _bindings = {};
  final Duration _timeout;
  ChannelStates _state = ChannelStates.closed;
  bool joinedOnce = false;
  late Push joinPush;
  late RetryTimer _rejoinTimer;
  List<Push> _pushBuffer = [];
  late RealtimePresence presence;

  final String topic;
  Map<String, dynamic> params;
  final RealtimeClient socket;

  RealtimeChannel(this.topic, this.socket, {Map<String, dynamic>? params})
      : _timeout = socket.timeout,
        params = (params ?? {}) {
    this.params = {...this.params};
    this.params['config'] = {
      'broadcast': {'ack': false, 'self': false},
      'presence': {'key': ''},
      ...(this.params['config'] ?? {}),
    };
    joinPush = Push(
      this,
      ChannelEvents.join,
      this.params,
      _timeout,
    );
    _rejoinTimer =
        RetryTimer(() => rejoinUntilConnected(), socket.reconnectAfterMs);
    joinPush.receive('ok', (_) {
      _state = ChannelStates.joined;
      _rejoinTimer.reset();
      for (final pushEvent in _pushBuffer) {
        pushEvent.send();
      }
      _pushBuffer = [];
    });

    onClose(() {
      _rejoinTimer.reset();
      socket.log('channel', 'close $topic $joinRef');
      _state = ChannelStates.closed;
      socket.remove(this);
    });

    onError((String? reason) {
      if (isLeaving || isClosed) {
        return;
      }
      socket.log('channel', 'error $topic', reason);
      _state = ChannelStates.errored;
      _rejoinTimer.scheduleTimeout();
    });

    joinPush.receive('timeout', (_) {
      if (!isJoining) {
        return;
      }
      socket.log('channel', 'timeout $topic', joinPush.timeout);
      _state = ChannelStates.errored;
      _rejoinTimer.scheduleTimeout();
    });

    onEvents(ChannelEvents.reply.eventName(), ChannelFilter(), (payload,
        [ref]) {
      trigger(replyEventName(ref), payload);
    });

    presence = RealtimePresence(this);
  }

  void rejoinUntilConnected() {
    _rejoinTimer.scheduleTimeout();
    if (socket.isConnected) {
      rejoin();
    }
  }

  void subscribe([Function? callback, Duration? timeout]) {
    if (joinedOnce == true) {
      throw "tried to subscribe multiple times. 'subscribe' can only be called a single time per channel instance";
    } else {
      final broadcast = params['config']['broadcast'];
      final presence = params['config']['presence'];

      onError((e) {
        if (callback != null) callback('CHANNEL_ERROR', e);
      });
      onClose(() {
        if (callback != null) callback('CLOSED');
      });

      final accessTokenPayload = <String, String>{};
      final config = <String, dynamic>{
        'broadcast': broadcast,
        'presence': presence,
        'postgres_changes':
            _bindings['postgres_changes']?.map((r) => r.filter).toList() ?? [],
      };

      if (socket.accessToken != null) {
        accessTokenPayload['access_token'] = socket.accessToken!;
      }

      updateJoinPayload({'config': config, ...accessTokenPayload});

      joinedOnce = true;
      rejoin(timeout ?? _timeout);

      joinPush.receive(
        'ok',
        (response) {
          final serverPostgresFilters = response['postgres_changes'];
          if (socket.accessToken != null) socket.setAuth(socket.accessToken);

          if (serverPostgresFilters == null) {
            if (callback != null) callback('SUBSCRIBED');
            return;
          } else {
            final clientPostgresBindings = _bindings['postgres_changes'];
            final bindingsLen = clientPostgresBindings?.length ?? 0;
            final newPostgresBindings = <Binding>[];

            for (var i = 0; i < bindingsLen; i++) {
              final clientPostgresBinding = clientPostgresBindings![i];

              final event = clientPostgresBinding.filter['event'];
              final schema = clientPostgresBinding.filter['schema'];
              final table = clientPostgresBinding.filter['table'];
              final filter = clientPostgresBinding.filter['filter'];
              final serverPostgresFilter = serverPostgresFilters[i];

              if (serverPostgresFilter != null &&
                  serverPostgresFilter['event'] == event &&
                  serverPostgresFilter['schema'] == schema &&
                  serverPostgresFilter['table'] == table &&
                  serverPostgresFilter['filter'] == filter) {
                newPostgresBindings.add(clientPostgresBinding.copyWith(
                  id: serverPostgresFilter['id'],
                ));
              } else {
                unsubscribe();
                if (callback != null) {
                  callback(
                    'CHANNEL_ERROR',
                    Exception(
                        'mismatch between server and client bindings for postgres changes'),
                  );
                }
                return;
              }
            }

            _bindings['postgres_changes'] = newPostgresBindings;

            if (callback != null) callback('SUBSCRIBED');
            return;
          }
        },
      ).receive('error', (error) {
        if (callback != null) {
          callback(
            'CHANNEL_ERROR',
            Exception(
              jsonEncode((error as Map<String, dynamic>).isNotEmpty
                  ? (error).values.join(', ')
                  : 'error'),
            ),
          );
        }
        return;
      }).receive('timeout', (_) {
        if (callback != null) callback('TIMED OUT');
        return;
      });
    }
  }

  Map<String, dynamic> presenceState() {
    return presence.state;
  }

  Future<ChannelResponse> track(Map<String, dynamic> payload,
      [Map<String, dynamic> opts = const {}]) {
    return send(
      type: RealtimeListenTypes.presence,
      payload: {
        'event': 'track',
        'payload': payload,
      },
      opts: {'timeout': opts['timeout'] ?? _timeout},
    );
  }

  Future<ChannelResponse> untrack([
    Map<String, dynamic> opts = const {},
  ]) {
    return send(
      type: RealtimeListenTypes.presence,
      payload: {
        'event': 'untrack',
      },
      opts: opts,
    );
  }

  /// Registers a callback that will be executed when the channel closes.
  void onClose(Function callback) {
    onEvents(ChannelEvents.close.eventName(), ChannelFilter(),
        (reason, [ref]) => callback());
  }

  /// Registers a callback that will be executed when the channel encounteres an error.
  void onError(void Function(String?) callback) {
    onEvents(ChannelEvents.error.eventName(), ChannelFilter(),
        (reason, [ref]) => callback(reason.toString()));
  }

  RealtimeChannel on(
    RealtimeListenTypes type,
    ChannelFilter filter,
    BindingCallback callback,
  ) {
    return onEvents(type.toType(), filter, callback);
  }

  RealtimeChannel onEvents(
      String type, ChannelFilter filter, BindingCallback callback) {
    final typeLower = type.toLowerCase();

    final binding = Binding(typeLower, filter.toMap(), callback);

    if (_bindings[typeLower] != null) {
      _bindings[typeLower]!.add(binding);
    } else {
      _bindings[typeLower] = [binding];
    }

    return this;
  }

  RealtimeChannel off(String type, Map<String, String> filter) {
    final typeLower = type.toLowerCase();

    _bindings[typeLower] = _bindings[typeLower]!.where((bind) {
      return !(bind.type.toLowerCase() == typeLower &&
          RealtimeChannel._isEqual(bind.filter, filter));
    }).toList();
    return this;
  }

  /// Returns `true` if the socket is connected and the channel has been joined.
  bool get canPush {
    return socket.isConnected && isJoined;
  }

  Push push(
    ChannelEvents event,
    Map<String, dynamic> payload, [
    Duration? timeout,
  ]) {
    if (!joinedOnce) {
      throw "tried to push '${event.eventName()}' to '$topic' before joining. Use channel.subscribe() before pushing events";
    }
    final pushEvent = Push(this, event, payload, timeout ?? _timeout);
    if (canPush) {
      pushEvent.send();
    } else {
      pushEvent.startTimeout();
      _pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }

  Future<ChannelResponse> send({
    required RealtimeListenTypes type,
    required Map<String, dynamic> payload,
    Map<String, dynamic> opts = const {},
  }) {
    final completer = Completer<ChannelResponse>();

    payload['type'] = type.toType();

    final push = this.push(
      ChannelEvents.fromName(payload['type']),
      payload,
      opts['timeout'] ?? _timeout,
    );

    if (push.rateLimited) {
      completer.complete(ChannelResponse.rateLimited);
    }

    if (payload['type'] == 'broadcast' &&
        (params['config']?['broadcast']?['ack'] == null ||
            params['config']?['broadcast']?['ack'] == false)) {
      if (!completer.isCompleted) {
        completer.complete(ChannelResponse.ok);
      }
    }

    push.receive('ok', (_) {
      if (!completer.isCompleted) {
        completer.complete(ChannelResponse.ok);
      }
    });
    push.receive('timeout', (_) {
      if (!completer.isCompleted) {
        completer.complete(ChannelResponse.timedOut);
      }
    });

    return completer.future;
  }

  void updateJoinPayload(Map<String, dynamic> payload) {
    joinPush.updatePayload(payload);
  }

  /// Leaves the channel
  ///
  /// Unsubscribes from server events, and instructs channel to terminate on server.
  /// Triggers onClose() hooks.
  ///
  /// To receive leave acknowledgements, use the a `receive` hook to bind to the server ack,
  /// ```dart
  /// channel.unsubscribe().receive("ok", (_){print("left!");} );
  /// ```
  Future<String> unsubscribe([Duration? timeout]) {
    _state = ChannelStates.leaving;
    void onClose() {
      socket.log('channel', 'leave $topic');
      trigger(ChannelEvents.close.eventName(), 'leave', joinRef);
    }

    // Destroy joinPush to avoid connection timeouts during unscription phase
    joinPush.destroy();

    final completer = Completer<String>();

    final leavePush = Push(this, ChannelEvents.leave, {}, timeout ?? _timeout);

    leavePush.receive('ok', (_) {
      onClose();
      if (!completer.isCompleted) {
        completer.complete('ok');
      }
    }).receive('timeout', (_) {
      if (!completer.isCompleted) {
        onClose();
      }
      completer.complete('timed out');
    }).receive('error', (_) {
      onClose();
      if (!completer.isCompleted) {
        completer.complete('error');
      }
    });

    leavePush.send();

    if (!canPush) {
      leavePush.trigger('ok', {});
    }

    return completer.future;
  }

  /// Overridable message hook
  ///
  /// Receives all events for specialized message handling before dispatching to the channel callbacks.
  /// Must return the payload, modified or unmodified.
  dynamic onMessage(String event, dynamic payload, [String? ref]) {
    return payload;
  }

  bool isMember(String? topic) {
    return this.topic == topic;
  }

  String get joinRef => joinPush.ref;

  void rejoin([Duration? timeout]) {
    if (isLeaving) {
      return;
    }
    socket.leaveOpenTopic(topic);
    _state = ChannelStates.joining;
    joinPush.resend(timeout ?? _timeout);
  }

  void trigger(String type, [dynamic payload, String? ref]) {
    final typeLower = type.toLowerCase();

    final events = [
      ChannelEvents.close,
      ChannelEvents.error,
      ChannelEvents.leave,
      ChannelEvents.join,
    ].map((e) => e.eventName()).toSet();

    if (ref != null && events.contains(typeLower) && ref != joinRef) {
      return;
    }

    var handledPayload = onMessage(typeLower, payload, ref);
    if (payload != null && handledPayload == null) {
      throw 'channel onMessage callbacks must return the payload, modified or unmodified';
    }

    if (['insert', 'update', 'delete'].contains(typeLower)) {
      final bindings = _bindings['postgres_changes']?.where((bind) {
        return (bind.filter['event'] == '*' ||
            bind.filter['event']?.toLowerCase() == typeLower);
      });

      for (final bind in (bindings ?? <Binding>[])) {
        bind.callback(handledPayload, ref);
      }
    } else {
      final bindings = _bindings[typeLower]?.where((bind) {
        if (['broadcast', 'presence', 'postgres_changes'].contains(typeLower)) {
          if (bind.id != null) {
            final bindId = bind.id;
            final bindEvent = bind.filter['event'];

            return (bindId != null &&
                payload['ids']?.contains(bindId) &&
                (bindEvent == '*' ||
                    bindEvent?.toLowerCase() ==
                        payload['data']?['type'].toLowerCase()));
          } else {
            final bindEvent = bind.filter['event']?.toLowerCase();
            return (bindEvent == '*' ||
                bindEvent == payload?['event']?.toLowerCase());
          }
        } else {
          return bind.type.toLowerCase() == typeLower;
        }
      });
      for (final bind in (bindings ?? <Binding>[])) {
        if (handledPayload is Map && handledPayload.keys.contains('ids')) {
          final postgresChanges = handledPayload['data'];
          final schema = postgresChanges['schema'];
          final table = postgresChanges['table'];
          final commitTimestamp = postgresChanges['commit_timestamp'];
          final type = postgresChanges['type'];
          final errors = postgresChanges['errors'];

          final enrichedPayload = {
            'schema': schema,
            'table': table,
            'commit_timestamp': commitTimestamp,
            'eventType': type,
            'new': {},
            'old': {},
            'errors': errors,
          };
          handledPayload = {
            ...enrichedPayload,
            ..._getPayloadRecords(postgresChanges),
          };
        }

        bind.callback(handledPayload, ref);
      }
    }
  }

  String replyEventName(String? ref) {
    return 'chan_reply_$ref';
  }

  bool get isClosed => _state == ChannelStates.closed;

  bool get isErrored => _state == ChannelStates.errored;

  bool get isJoined => _state == ChannelStates.joined;

  bool get isJoining => _state == ChannelStates.joining;

  bool get isLeaving => _state == ChannelStates.leaving;

  static _isEqual(Map<String, String> obj1, Map<String, String> obj2) {
    if (obj1.keys.length != obj2.keys.length) {
      return false;
    }

    for (final k in obj1.keys) {
      if (obj1[k] != obj2[k]) {
        return false;
      }
    }

    return true;
  }

  Map<String, Map<String, dynamic>> _getPayloadRecords(dynamic payload) {
    final records = <String, Map<String, dynamic>>{
      'new': {},
      'old': {},
    };

    if (payload?['type'] == 'INSERT' || payload?['type'] == 'UPDATE') {
      records['new'] = convertChangeData(
        List<Map<String, dynamic>>.from(payload['columns']),
        Map<String, dynamic>.from(payload['record']),
      );
    }

    if (payload?['type'] == 'UPDATE' || payload?['type'] == 'DELETE') {
      records['old'] = convertChangeData(
        List<Map<String, dynamic>>.from(payload['columns']),
        Map<String, dynamic>.from(payload['old_record']),
      );
    }

    return records;
  }
}
