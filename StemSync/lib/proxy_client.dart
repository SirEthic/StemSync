import 'dart:io';
import 'package:http/io_client.dart';
import 'package:flutter_system_proxy/flutter_system_proxy.dart';

class ProxyClient {
  static Future<IOClient> createClient(String targetUrl) async {
    final proxy = await FlutterSystemProxy.findProxyFromEnvironment(targetUrl);
    final ioClient = HttpClient();
    
    if (proxy != null && proxy.trim().isNotEmpty && proxy.trim().toUpperCase() != "DIRECT") {
      ioClient.findProxy = (uri) {
        return proxy;
      };
    }
    
    return IOClient(ioClient);
  }
}
