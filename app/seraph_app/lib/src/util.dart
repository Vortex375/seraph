
import 'dart:async';

import 'package:get/get.dart';

T identity<T>(T x) => x;

Future<T> until<T>(Rx<T> rx, bool Function(T) when) {
  if (when(rx.value)) {
    return Future.value(rx.value);
  }
  
  final completer = Completer<T>();
  StreamSubscription? sub;
  sub = rx.listen((v) {
    if (when(v)) {
      sub!.cancel();
      completer.complete(v);
    }
  });
  
  return completer.future;
}