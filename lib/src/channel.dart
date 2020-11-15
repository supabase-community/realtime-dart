import 'lib/constants.dart';
import 'lib/push.dart';
import 'lib/retry_timer.dart';
import 'socket.dart';

typedef Callback = void Function(dynamic payload, {String ref});

class Channel {
  ChannelStates _state = ChannelStates.closed;
  final String topic;
  final Map<dynamic, dynamic> params;
  final Socket socket;
  RetryTimer _rejoinTimer;
  List<Push> _pushBuffer = [];
  List<Binding> _bindings = [];
  bool _joinedOnce;
  Push _joinPush;
  final Duration _timeout;

  Channel(this.topic, this.socket, {this.params = const {}}) : _timeout = socket.timeout {
    _joinPush = Push(this, ChannelEvents.join, params, _timeout);
    _rejoinTimer = RetryTimer(() => rejoinUntilConnected(), socket.reconnectAfterMs);
    _joinPush.receive('ok', (response) {
      _state = ChannelStates.joined;
      _rejoinTimer.reset();
      for (final pushEvent in _pushBuffer) {
        pushEvent.send();
      }
      _pushBuffer = [];
    });

    onClose(() {
      _rejoinTimer.reset();
      socket.log('channel', 'close $topic ${joinRef()}');
      _state = ChannelStates.closed;
      socket.remove(this);
    });

    onError((String reason) {
      if (isLeaving() || isClosed()) {
        return;
      }
      socket.log('channel', 'error $topic', reason);
      _state = ChannelStates.errored;
      _rejoinTimer.scheduleTimeout();
    });

    _joinPush.receive('timeout', (response) {
      if (!isJoining()) {
        return;
      }
      socket.log('channel', 'timeout $topic', _joinPush.timeout);
      _state = ChannelStates.errored;
      _rejoinTimer.scheduleTimeout();
    });

    on(ChannelEvents.reply.eventName(), (payload, {ref}) => trigger(replyEventName(ref), payload: payload));
  }

  void rejoinUntilConnected() {
    _rejoinTimer.scheduleTimeout();
    if (socket.isConnected()) {
      rejoin();
    }
  }

  Push subscribe({Duration timeout}) {
    if (_joinedOnce == true) {
      throw "tried to subscribe multiple times. 'subscribe' can only be called a single time per channel instance";
    } else {
      _joinedOnce = true;
      rejoin(timeout ?? _timeout);
      return _joinPush;
    }
  }

  void onClose(Function callback) {
    on(ChannelEvents.close.eventName(), (reason, {ref}) => callback());
  }

  void onError(Function(String) callback) {
    on(ChannelEvents.error.eventName(), (reason, {ref}) => callback(reason as String));
  }

  void on(String event, Callback callback) {
    _bindings.add(Binding(event, callback));
  }

  void off(String event) {
    _bindings = _bindings.where((bind) => bind.event != event).toList();
  }

  bool canPush() {
    return socket.isConnected() && isJoined();
  }

  Push push(ChannelEvents event, Map<String, String> payload, {Duration timeout}) {
    if (!_joinedOnce) {
      throw "tried to push '${event.eventName()}' to '$topic' before joining. Use channel.subscribe() before pushing events";
    }
    final pushEvent = Push(this, event, payload, timeout ?? _timeout);
    if (canPush()) {
      pushEvent.send();
    } else {
      pushEvent.startTimeout();
      _pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }

  /// Leaves the channel
  ///
  /// Unsubscribes from server events, and instructs channel to terminate on server.
  /// Triggers onClose() hooks.
  ///
  /// To receive leave acknowledgements, use the a `receive` hook to bind to the server ack,
  /// ```dart
  /// channel.unsubscribe().receive("ok", () => alert("left!") )
  /// ```
  Push unsubscribe({Duration timeout}) {
    void onClose() {
      socket.log('channel', 'leave $topic');
      trigger(ChannelEvents.close.eventName(), payload: 'leave', ref: joinRef());
    }
    
    _state = ChannelStates.leaving;
    final leavePush = Push(this, ChannelEvents.leave, {}, timeout ?? _timeout);
    leavePush.receive('ok', (_) => onClose()).receive('timeout', (_) => onClose());
    leavePush.send();
    if (!canPush()) {
      leavePush.trigger('ok', {});
    }

    return leavePush;
  }

  /// Overridable message hook
  ///
  /// Receives all events for specialized message handling before dispatching to the channel callbacks.
  /// Must return the payload, modified or unmodified.
  dynamic onMessage(String event, dynamic payload, {String ref}) {
    return payload;
  }

  bool isMember(String topic) {
    return this.topic == topic;
  }

  String joinRef() {
    return _joinPush.ref;
  }

  void sendJoin(Duration timeout) {
    _state = ChannelStates.joining;
    _joinPush.resend(timeout);
  }

  void rejoin([Duration timeout]) {
    if (isLeaving()) {
      return;
    }
    sendJoin(timeout ?? _timeout);
  }

  void trigger(String event, {dynamic payload, String ref}) {
    final events = [ChannelEvents.close, ChannelEvents.error, ChannelEvents.leave, ChannelEvents.join]
        .map((e) => e.eventName())
        .toSet();

    if (ref != null && events.contains(event) && ref != joinRef()) {
      return;
    }
    final handledPayload = onMessage(event, payload, ref: ref);
    if (payload != null && handledPayload == null) {
      throw 'channel onMessage callbacks must return the payload, modified or unmodified';
    }

    _bindings.where((bind) => bind.event == event).map((bind) => bind.callback(handledPayload, ref: ref));
  }

  String replyEventName(String ref) {
    return 'chan_reply_$ref';
  }

  bool isClosed() {
    return _state == ChannelStates.closed;
  }

  bool isErrored() {
    return _state == ChannelStates.errored;
  }

  bool isJoined() {
    return _state == ChannelStates.joined;
  }

  bool isJoining() {
    return _state == ChannelStates.joining;
  }

  bool isLeaving() {
    return _state == ChannelStates.leaving;
  }
}

class Binding {
  String event;
  Callback callback;

  Binding(this.event, this.callback);
}
