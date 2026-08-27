import 'dart:io';
import 'package:http/io_client.dart';
import 'package:flutter_system_proxy/flutter_system_proxy.dart';
import 'package:flutter/foundation.dart';

class ProxyClient {
  static Future<IOClient> createClient(String targetUrl) async {
    final ioClient = HttpClient();
    try {
      final proxy = await FlutterSystemProxy.findProxyFromEnvironment(targetUrl);
      
      if (proxy != null && proxy.trim().isNotEmpty && proxy.trim().toUpperCase() != "DIRECT") {
        ioClient.findProxy = (uri) {
          return proxy;
        };
      }
    } catch (e) {
      debugPrint("Proxy detection failed: $e");
    }
    
    return IOClient(ioClient);
  }
}
