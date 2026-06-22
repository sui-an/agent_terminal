import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// POSIX bindings for PTY
final DynamicLibrary _libc = DynamicLibrary.open('libc.so.6');

// posix_openpt
final int Function(int flags) _posixOpenpt = _libc
    .lookupFunction<int Function(Int32), int Function(int)>('posix_openpt');

// unlockpt
final int Function(int fd) _unlockpt = _libc
    .lookupFunction<int Function(Int32), int Function(int)>('unlockpt');

// ptsname
final Pointer<Utf8> Function(int fd) _ptsname = _libc
    .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('ptsname');

// struct winsize
final class _WinSize extends Struct {
  @Int16()
  external int wsRow;
  @Int16()
  external int wsCol;
  @Int16()
  external int wsXpixel;
  @Int16()
  external int wsYpixel;
}

// ioctl
final int Function(int fd, int request, Pointer<_WinSize> winsize) _ioctl = _libc
    .lookupFunction<
        Int32 Function(Int32, Int64, Pointer<_WinSize>),
        int Function(int, int, Pointer<_WinSize>)>('ioctl');

// Constants
const int _O_RDWR = 2;
const int _TIOCSWINSZ = 0x5414;

class PTYSession {
  final int masterFd;
  final String slaveName;
  final StreamController<String> _outputController = StreamController<String>.broadcast();
  StreamSubscription<List<int>>? _subscription;

  PTYSession({required this.masterFd, required this.slaveName});

  Stream<String> get output => _outputController.stream;

  void startReading(File masterFile) {
    _subscription = masterFile.openRead().listen(
      (data) {
        final text = String.fromCharCodes(data);
        _outputController.add(text);
      },
      onError: (error) {
        _outputController.addError(error);
      },
      onDone: () {
        _outputController.close();
      },
    );
  }

  void write(String data) {
    // Write will be handled by the caller using the master fd
  }

  void dispose() {
    _subscription?.cancel();
    _outputController.close();
  }
}

class PTY {
  static PTYSession create({
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    int cols = 80,
    int rows = 24,
  }) {
    // Open master PTY
    final masterFd = _posixOpenpt(_O_RDWR);
    if (masterFd == -1) {
      throw Exception('Failed to open PTY master');
    }

    // Unlock slave
    if (_unlockpt(masterFd) == -1) {
      throw Exception('Failed to unlock PTY slave');
    }

    // Get slave name
    final slaveNamePtr = _ptsname(masterFd);
    final slaveName = slaveNamePtr.toDartString();

    // Set window size
    final winsize = calloc<_WinSize>();
    winsize.ref.wsRow = rows;
    winsize.ref.wsCol = cols;
    _ioctl(masterFd, _TIOCSWINSZ, winsize);
    calloc.free(winsize);

    // Create master file for reading
    final masterFile = File.fromRawPointer(
      nullptr,
    ).openSync(mode: FileMode.read);

    final session = PTYSession(
      masterFd: masterFd,
      slaveName: slaveName,
    );

    session.startReading(masterFile);

    return session;
  }

  static void write(int masterFd, String data) {
    final bytes = data.codeUnits;
    final ptr = calloc<Uint8>(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      ptr[i] = bytes[i];
    }
    // Write to master fd
    _write(masterFd, ptr, bytes.length);
    calloc.free(ptr);
  }

  static void resize(int masterFd, int cols, int rows) {
    final winsize = calloc<_WinSize>();
    winsize.ref.wsRow = rows;
    winsize.ref.wsCol = cols;
    _ioctl(masterFd, _TIOCSWINSZ, winsize);
    calloc.free(winsize);
  }

  static final int Function(int fd, Pointer<Uint8> buf, int count) _write = _libc
      .lookupFunction<
          Int64 Function(Int32, Pointer<Uint8>, Int64),
          int Function(int, Pointer<Uint8>, int)>('write');
}
