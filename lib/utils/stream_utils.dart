class StreamUtils {
  static int findJpegStart(List<int> data) {
    for (int i = 0; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  static int findJpegEnd(List<int> data, int start) {
    for (int i = start; i < data.length - 1; i++) {
      if (data[i] == 0xFF && data[i + 1] == 0xD9) return i;
    }
    return -1;
  }
}