/// A minimal, pluggable logger used throughout the SDK.
///
/// The SDK never prints on its own. Attach listeners with
/// [DeepgramLogger.addListener] to route events into your logging pipeline,
/// or construct a [DeepgramLogger] with your own sink function.
library;

/// Signature for a log listener.
///
/// [level] is one of `debug`, `info`, `warn`, `error`.
typedef DeepgramLogListener =
    void Function(String level, String message, Object? error);

/// Pluggable logger for the Deepgram SDK.
///
/// ```dart
/// final logger = DeepgramLogger();
/// logger.addListener((level, message, error) {
///   debugPrint('[$level] $message');
/// });
/// ```
class DeepgramLogger {
  /// Creates a logger. Optionally pass [sink] to receive every event.
  DeepgramLogger({DeepgramLogListener? sink}) {
    if (sink != null) _listeners.add(sink);
  }

  /// A logger that discards everything. Used as the default.
  static final DeepgramLogger noop = DeepgramLogger();

  final List<DeepgramLogListener> _listeners = <DeepgramLogListener>[];

  /// Whether any listener is attached.
  bool get hasListeners => _listeners.isNotEmpty;

  /// Attaches a listener. Returns a function that detaches it.
  void Function() addListener(DeepgramLogListener listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  /// Removes all listeners.
  void clearListeners() => _listeners.clear();

  /// Logs a debug-level event.
  void debug(String message, [Object? error]) => _emit('debug', message, error);

  /// Logs an info-level event.
  void info(String message, [Object? error]) => _emit('info', message, error);

  /// Logs a warning-level event.
  void warn(String message, [Object? error]) => _emit('warn', message, error);

  /// Logs an error-level event.
  void error(String message, [Object? error]) => _emit('error', message, error);

  void _emit(String level, String message, Object? error) {
    if (_listeners.isEmpty) return;
    for (final listener in List<DeepgramLogListener>.of(_listeners)) {
      try {
        listener(level, message, error);
      } catch (_) {
        // A misbehaving listener must never break the SDK.
      }
    }
  }
}
