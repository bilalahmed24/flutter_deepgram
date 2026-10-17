/// Platform-conditional WebSocket factory.
///
/// Browsers cannot set custom headers on WebSocket upgrades. On VM platforms
/// (Android, iOS, macOS, Windows, Linux) the SDK sends the standard
/// `Authorization` header. On the web it uses Deepgram's documented
/// `Sec-WebSocket-Protocol` fallback, offering the subprotocols
/// `token, <API key>` or `bearer, <JWT>`.
///
/// This file selects the right implementation via conditional imports.
library;

export 'ws_factory_stub.dart'
    if (dart.library.io) 'ws_factory_io.dart'
    if (dart.library.js_interop) 'ws_factory_web.dart';
