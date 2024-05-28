import 'package:phoenix_socket/phoenix_socket.dart';

class SocketService {
  static PhoenixSocket socket = PhoenixSocket('ws://localhost:4001/sockets/dashboard/websocket')..connect();
}