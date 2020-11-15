import 'package:mockito/mockito.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MockIOWebSocketChannel extends Mock implements IOWebSocketChannel {}

class MockWebSocketSink extends Mock implements WebSocketSink {}

class MockChannel extends Mock implements Channel {}

class SocketWithMockedChannel extends Socket {
  SocketWithMockedChannel(String endPoint) : super(endPoint);

  Map<String, Channel> mockedChannelLooker = {};

  @override
  Channel channel(String topic, {Map chanParams = const {}}) {
    if (mockedChannelLooker.keys.contains(topic)) {
      channels.add(mockedChannelLooker[topic]);
      return mockedChannelLooker[topic];
    } else {
      return super.channel(topic, chanParams: chanParams);
    }
  }
}
