import 'dart:io';

class MemoryTracker {
  int get current => ProcessInfo.currentRss;
}
