import 'dart:async';
import 'dart:collection';

/// Runs async critical sections one at a time (like a lock).
///
/// Dart is single-threaded, but `await` lets other code run in between, so
/// two writers could interleave operations on the same file or socket.
class Mutex {
  Future<void> _last = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final previous = _last;
    final done = Completer<void>();
    _last = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}

/// A bounded async queue (producer/consumer channel).
///
/// The producer's [put] waits when the queue is full, which keeps memory use
/// bounded while still letting the disk reader run ahead of the network.
class AsyncChannel<T> {
  AsyncChannel(this.capacity);

  final int capacity;
  final _items = ListQueue<T>();
  final _takers = ListQueue<Completer<T?>>();
  final _spaceWaiters = ListQueue<Completer<void>>();
  bool _closed = false;

  bool get isClosed => _closed;
  int get length => _items.length;

  /// Adds [item], waiting while the channel is full.
  Future<void> put(T item) async {
    while (!_closed && _items.length >= capacity && _takers.isEmpty) {
      final c = Completer<void>();
      _spaceWaiters.add(c);
      await c.future;
    }
    if (_closed) throw StateError('channel closed');
    _deliver(item, front: false);
  }

  /// Adds [item] at the front, ignoring capacity (used for resends).
  void putFront(T item) {
    if (_closed) return;
    _deliver(item, front: true);
  }

  void _deliver(T item, {required bool front}) {
    if (_takers.isNotEmpty) {
      _takers.removeFirst().complete(item);
    } else if (front) {
      _items.addFirst(item);
    } else {
      _items.addLast(item);
    }
  }

  /// Takes the next item, or returns null once the channel is closed.
  Future<T?> take() {
    if (_items.isNotEmpty) {
      final item = _items.removeFirst();
      if (_spaceWaiters.isNotEmpty) _spaceWaiters.removeFirst().complete();
      return Future.value(item);
    }
    if (_closed) return Future.value(null);
    final c = Completer<T?>();
    _takers.add(c);
    return c.future;
  }

  /// Closes the channel; waiting takers get null and pending items are dropped.
  void close() {
    if (_closed) return;
    _closed = true;
    _items.clear();
    while (_takers.isNotEmpty) {
      _takers.removeFirst().complete(null);
    }
    while (_spaceWaiters.isNotEmpty) {
      _spaceWaiters.removeFirst().complete();
    }
  }
}

/// A gate that async code can wait on (used for pause/resume).
class Gate {
  Completer<void>? _closedGate;

  bool get isOpen => _closedGate == null;

  void close() => _closedGate ??= Completer<void>();

  void open() {
    _closedGate?.complete();
    _closedGate = null;
  }

  Future<void> wait() => _closedGate?.future ?? Future<void>.value();
}

/// Starts [task] without awaiting it; any error goes to [onError].
void spawn(Future<void> Function() task, void Function(Object error) onError) {
  task().then((_) {}, onError: (Object e) => onError(e));
}
