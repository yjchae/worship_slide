/// 32비트 FNV-1a 두 개(정방향·역방향)를 이은 16자리 hex. 캐시·공유 파일 이름용이라
/// 암호학적 강도는 필요 없다.
String fnvHex(List<int> bytes) =>
    _fnv1a(bytes).toRadixString(16).padLeft(8, '0') +
    _fnv1a(bytes.reversed).toRadixString(16).padLeft(8, '0');

int _fnv1a(Iterable<int> bytes) {
  var hash = 0x811c9dc5;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
