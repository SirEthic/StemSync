import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  await dotenv.load(fileName: '.env');
  final apiKey = dotenv.env['GOOGLE_DRIVE_API_KEY'];
  final folderId = '1e2C-6d_hA0N72W88Y12l05vF53bU6E27'; // typical ID
  // Wait, I need the actual folder id from shared_preferences... I'll just query without folder filter
  final url = Uri.parse("https://www.googleapis.com/drive/v3/files?q=name+contains+'.zip'&fields=files(id,name,size)&key=$apiKey");
  final res = await http.get(url);
  print(res.body);
}
